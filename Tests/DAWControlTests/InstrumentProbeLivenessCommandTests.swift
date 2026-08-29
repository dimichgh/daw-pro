import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m31-f ②'s `instrument.probeLiveness`.
///
/// This is the WIRE layer, and it is deliberately narrow about it:
///
/// - `Tests/DAWCoreTests/TimbreLivenessProbeTests.swift` proves the
///   store/measurement layer — `store.probeInstrumentLiveness(...)` called
///   directly, the STATIC/LIVE/INCONCLUSIVE/SILENT verdict ladder, the
///   self-check gate, the "renders the patch not the mix" stripping, and the
///   no-edit guarantee. This suite does not re-derive any of that DSP.
/// - `mcp-server/test/` proves the MCP tool forwards to the bridge correctly.
/// - THIS suite proves the thing neither of those can: the JSON contract at
///   `Sources/DAWControl/Commands.swift`'s `case "instrument.probeLiveness"`
///   — param decoding (`trackId`/`pitch`/`velocities`/`noteSeconds`),
///   defaulting, the control layer's OWN validation (the `velocities` shape
///   checks live only here — `store.probeInstrumentLiveness` takes a native
///   `[Int]` and never sees a malformed JSON array), the refusal wording, the
///   field NAMES on the wire, and — ⭐⭐ the one that matters most — that a
///   failed self-check surfaces as a control-layer ERROR, never a `STATIC`
///   verdict, when reached through the router rather than called directly.
///
/// `ProbeLivenessFakeEngine` below is a trimmed, target-local twin of
/// `TimbreLivenessProbeTests.LadderSynthEngine`: it renders the notes it is
/// actually handed (level tracks velocity; harmonic content is FIXED, so it
/// reads STATIC) rather than returning a constant buffer, and its
/// `sampleRate` is the same seam DAWCoreTests uses to reach the self-check
/// refusal deterministically — no injection hook of its own, ordinary DI
/// through `ProjectStore.engine`.
@MainActor
@Suite("Instrument liveness probe — control protocol (m31-f ②)")
struct InstrumentProbeLivenessCommandTests {

    // MARK: - A fake engine that actually plays the ladder it is handed

    @MainActor
    private final class ProbeLivenessFakeEngine: AudioEngineControlling {
        enum Behavior {
            /// One sample with a volume knob: level tracks velocity, the
            /// harmonic mix never changes — reads STATIC.
            case oneSample
            /// Produces nothing at all — reads SILENT.
            case silent
        }

        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        let behavior: Behavior
        /// Forced render sample rate. 2 kHz cannot resolve the meter's own
        /// 1760 Hz control tone (it aliases to 240 Hz, below the 440 Hz
        /// tone), which is how the self-check-failure path is reached
        /// deterministically — the TimbreLivenessProbeTests precedent.
        let sampleRate: Double

        private(set) var renderCallCount = 0
        private(set) var renderedTracks: [Track] = []

        init(behavior: Behavior = .oneSample, sampleRate: Double = 48_000) {
            self.behavior = behavior
            self.sampleRate = sampleRate
        }

        func prepare() throws { isRunning = true }
        func shutdown() { isRunning = false }
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: sampleRate, channelCount: 2)
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            renderCallCount += 1
            renderedTracks = tracks
            let frames = max(1, Int(durationSeconds * sampleRate))
            var mono = [Float](repeating: 0, count: frames)
            switch behavior {
            case .silent:
                break
            case .oneSample:
                for note in tracks.flatMap({ $0.clips }).flatMap({ $0.notes ?? [] }) {
                    let start = tempoMap.seconds(from: 0, to: note.startBeat)
                    let end = tempoMap.seconds(from: 0, to: note.endBeat)
                    render(note: note, into: &mono, startSeconds: start, endSeconds: end, frames: frames)
                }
            }
            return RenderedAudio(sampleRate: sampleRate, channelData: [mono, mono])
        }

        /// A fundamental at 220 Hz plus a FIXED partial count: level tracks
        /// velocity, brightness never does — "one sample with a volume knob",
        /// the exact shape the item exists to catch.
        private func render(note: MIDINote, into buffer: inout [Float],
                            startSeconds: Double, endSeconds: Double, frames: Int) {
            let v = Double(note.velocity) / 127.0
            let amplitude = 0.5 * v * v
            let partials = 4
            let first = max(0, Int(startSeconds * sampleRate))
            let last = min(frames, Int(endSeconds * sampleRate))
            guard last > first else { return }
            for i in first..<last {
                let t = Double(i) / sampleRate
                var value = 0.0
                for h in 1...partials {
                    value += sin(2 * Double.pi * 220 * Double(h) * t) / Double(h)
                }
                buffer[i] += Float(amplitude * value / Double(partials))
            }
        }
    }

    // MARK: - Harness

    private func makeRouter(engine: ProbeLivenessFakeEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    // MARK: - Happy path: the full wire contract, and the defaults it rests on

    @Test("happy path (defaults): ok:true and the full wire contract — trackId, instrumentKind, pitch, noteSeconds, sampleRate, selfCheck, ladder, distinctTimbreCount, verdict, summary, thresholds, caveats")
    func happyPathReturnsFullWireContractShape() async throws {
        let engine = ProbeLivenessFakeEngine(behavior: .oneSample)
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID)]))
        #expect(response.ok, "instrument.probeLiveness failed: \(response.error ?? "?")")
        let result = try #require(response.result)

        #expect(result["trackId"]?.stringValue == trackID)
        // No instrument was ever set on the track — the store's own
        // `InstrumentDescriptor.default.kind` fallback.
        #expect(result["instrumentKind"]?.stringValue == "polySynth")
        #expect(result["instrumentDetail"] == nil, "nothing to detail with no instrument configured")
        #expect(result["pitch"]?.doubleValue == Double(ProjectStore.livenessDefaultPitch))
        #expect(result["noteSeconds"]?.doubleValue == ProjectStore.livenessNoteSeconds)
        #expect(result["sampleRate"]?.doubleValue == engine.sampleRate)

        let selfCheck = try #require(result["selfCheck"]?.objectValue)
        #expect(selfCheck["passed"]?.boolValue == true)
        #expect(selfCheck["lowToneHz"]?.doubleValue == TimbreLiveness.selfCheckLowHz)
        #expect(selfCheck["highToneHz"]?.doubleValue == TimbreLiveness.selfCheckHighHz)
        #expect(selfCheck["lowToneCentroidHz"]?.doubleValue != nil)
        #expect(selfCheck["highToneCentroidHz"]?.doubleValue != nil)
        #expect(selfCheck["rule"]?.stringValue?.isEmpty == false)

        let ladder = try #require(result["ladder"]?.arrayValue)
        #expect(ladder.count == ProjectStore.livenessDefaultVelocities.count)
        let velocities = ladder.compactMap { $0["velocity"]?.doubleValue }.map { Int($0) }
        #expect(velocities == ProjectStore.livenessDefaultVelocities)
        for rung in ladder {
            #expect(rung["rmsDb"]?.doubleValue != nil)
            #expect(rung["centroidHz"]?.doubleValue != nil, "an audible rung must report a centroid")
            #expect(rung["timbreGroup"]?.doubleValue != nil)
        }

        #expect(result["distinctTimbreCount"]?.doubleValue == 1)
        #expect(result["verdict"]?.stringValue == "static")
        #expect(result["summary"]?.stringValue?.isEmpty == false)

        let thresholds = try #require(result["thresholds"]?.objectValue)
        #expect(thresholds["staticCentroidSpreadPercent"]?.doubleValue == TimbreLiveness.staticCentroidSpreadPercent)
        #expect(thresholds["minimumRMSSpreadDb"]?.doubleValue == TimbreLiveness.minimumRMSSpreadDb)
        #expect(thresholds["timbreGroupTolerancePercent"]?.doubleValue == TimbreLiveness.timbreGroupTolerancePercent)
        #expect(thresholds["calibrated"]?.boolValue == false)

        let caveats = try #require(result["caveats"]?.arrayValue)
        #expect(!caveats.isEmpty)
        #expect(engine.renderCallCount == 1)
    }

    // MARK: - Param decoding

    @Test("pitch/velocities/noteSeconds are HONOURED when supplied, not just defaulted")
    func suppliedParamsOverrideDefaults() async throws {
        let engine = ProbeLivenessFakeEngine(behavior: .oneSample)
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID),
                     "pitch": .number(64),
                     "velocities": .array([.number(10), .number(50), .number(110)]),
                     "noteSeconds": .number(2.0)]))
        #expect(response.ok, "instrument.probeLiveness failed: \(response.error ?? "?")")
        let result = try #require(response.result)

        #expect(result["pitch"]?.doubleValue == 64)
        #expect(result["noteSeconds"]?.doubleValue == 2.0)
        let ladder = try #require(result["ladder"]?.arrayValue)
        #expect(ladder.count == 3)
        let velocities = ladder.compactMap { $0["velocity"]?.doubleValue }.map { Int($0) }
        #expect(velocities == [10, 50, 110])

        // Every supplied value here must genuinely differ from the shipped
        // default, or this test would pass for the wrong reason (it would
        // read the SAME as the happy-path/defaults test above even if the
        // handler silently ignored every param).
        #expect(ProjectStore.livenessDefaultPitch != 64)
        #expect(ProjectStore.livenessNoteSeconds != 2.0)
        #expect(ProjectStore.livenessDefaultVelocities != [10, 50, 110])
    }

    @Test("⚠️ a wrong-type `pitch` silently falls back to the default rather than erroring — an asymmetry with `velocities`, which IS type-checked below; documented as current behavior, not endorsed (see QA report)")
    func pitchWrongTypeSilentlyFallsBackToDefault() async throws {
        let engine = ProbeLivenessFakeEngine(behavior: .oneSample)
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID), "pitch": .string("sixty")]))
        #expect(response.ok, "instrument.probeLiveness failed: \(response.error ?? "?")")
        #expect(response.result?["pitch"]?.doubleValue == Double(ProjectStore.livenessDefaultPitch))
    }

    // MARK: - Refusals

    @Test("missing trackId, and a non-UUID trackId, are both refused readably")
    func missingOrInvalidTrackIdIsRefused() async throws {
        let (router, _) = makeRouter()

        let missing = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness"))
        #expect(!missing.ok)
        #expect(missing.error == "missing or invalid required param 'trackId'")

        let notUUID = await router.handle(ControlRequest(
            id: "2", command: "instrument.probeLiveness",
            params: ["trackId": .string("not-a-uuid")]))
        #expect(!notUUID.ok)
        #expect(notUUID.error?.contains("'trackId' is not a valid UUID") == true)
    }

    @Test("a trackId that names no track is refused with the store's trackNotFound wording, and pays for no render")
    func unknownTrackIdIsRefused() async throws {
        let engine = ProbeLivenessFakeEngine()
        let (router, _) = makeRouter(engine: engine)
        let ghost = UUID()

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(ghost.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "No track with id \(ghost.uuidString).")
        #expect(engine.renderCallCount == 0, "a refusal must not pay for a render")
    }

    @Test("a non-instrument track is refused with the shared instrumentRequiresInstrumentTrack wording")
    func nonInstrumentTrackIsRefused() async throws {
        let engine = ProbeLivenessFakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let audioTrackID = store.addTrack(name: "Vox", kind: .audio).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(audioTrackID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("cannot host an instrument") == true)
        #expect(response.error?.contains("track.add kind=instrument") == true)
        #expect(engine.renderCallCount == 0)
    }

    @Test("no engine at all is refused with 'audio engine not available'")
    func noEngineIsRefused() async throws {
        let (router, store) = makeRouter()  // engine left nil
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("an unknown param key is rejected with the teaching key list, naming all four real keys")
    func unknownParamKeyIsRefused() async throws {
        let engine = ProbeLivenessFakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error == "instrument.probeLiveness: unknown parameter 'bogus'"
            + " — valid keys are 'noteSeconds', 'pitch', 'trackId', 'velocities'")
        #expect(engine.renderCallCount == 0)
    }

    @Test("velocities: wrong type, a non-numeric entry, and a too-short ladder are each refused readably; a valid array is a positive control")
    func velocitiesParamIsValidated() async throws {
        let engine = ProbeLivenessFakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let wrongType = await router.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID), "velocities": .string("loud")]))
        #expect(!wrongType.ok)
        #expect(wrongType.error?.contains("must be an array of MIDI velocities") == true)

        let nonNumeric = await router.handle(ControlRequest(
            id: "2", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID),
                     "velocities": .array([.number(50), .string("loud")])]))
        #expect(!nonNumeric.ok)
        #expect(nonNumeric.error == "`velocities` must contain only numbers.")

        let tooShort = await router.handle(ControlRequest(
            id: "3", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID), "velocities": .array([.number(100)])]))
        #expect(!tooShort.ok)
        #expect(tooShort.error == "a velocity ladder needs at least two velocities"
            + " — one rung cannot show whether the timbre moves.")

        #expect(engine.renderCallCount == 0, "every refusal above must be caught before a render is paid for")

        // Positive control: an otherwise-identical, VALID two-entry array is
        // accepted — proving the three refusals above are the validation
        // firing, not a broken fixture that refuses everything.
        let valid = await router.handle(ControlRequest(
            id: "4", command: "instrument.probeLiveness",
            params: ["trackId": .string(trackID), "velocities": .array([.number(40), .number(100)])]))
        #expect(valid.ok, "instrument.probeLiveness failed: \(valid.error ?? "?")")
        #expect(valid.result?["ladder"]?.arrayValue?.count == 2)
        #expect(engine.renderCallCount == 1)
    }

    // MARK: - ⭐⭐ The safety property: a failed self-check is an ERROR, never a verdict

    @Test("⭐⭐ when the meter's self-check fails, instrument.probeLiveness returns an ERROR — never a STATIC verdict — and this failure mode IS reachable through the control layer")
    func selfCheckFailureRefusesRatherThanReportingStatic() async throws {
        // 2 kHz render rate: the meter's own 1760 Hz control tone aliases to
        // 240 Hz, below the 440 Hz one, so the self-check cannot pass — the
        // exact TimbreLivenessProbeTests (DAWCoreTests) mechanism, reached
        // here by injecting an AudioEngineControlling fake into
        // ProjectStore.engine the ordinary way. No control-layer-specific
        // injection seam was needed: a real engine that could not resolve
        // its own control tone would hit this exact path.
        let brokenEngine = ProbeLivenessFakeEngine(behavior: .oneSample, sampleRate: 2_000)
        let (brokenRouter, brokenStore) = makeRouter(engine: brokenEngine)
        let brokenTrackID = brokenStore.addTrack(name: "Sax", kind: .instrument).id.uuidString

        let response = await brokenRouter.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(brokenTrackID)]))
        #expect(!response.ok, "a failed self-check must not report ok:true")
        let message = try #require(response.error)
        #expect(message.contains("positive control"))
        #expect(message.contains("No liveness verdict was produced"))
        #expect(!message.lowercased().contains("static"),
                "the refusal text must never say the S-word — that would read like a verdict")
        // The render DID happen — a measurement refusal, not a never-ran. (If
        // the render were skipped, a future change that broke it would pass
        // this test for the wrong reason.)
        #expect(brokenEngine.renderCallCount == 1)

        // Positive control, same test: the IDENTICAL request against a
        // real-rate engine succeeds and returns a verdict — proving the
        // refusal above is the self-check firing, not a broken fixture or an
        // unrelated wiring failure.
        let healthyEngine = ProbeLivenessFakeEngine(behavior: .oneSample, sampleRate: 48_000)
        let (healthyRouter, healthyStore) = makeRouter(engine: healthyEngine)
        let healthyTrackID = healthyStore.addTrack(name: "Sax", kind: .instrument).id.uuidString
        let healthy = await healthyRouter.handle(ControlRequest(
            id: "2", command: "instrument.probeLiveness",
            params: ["trackId": .string(healthyTrackID)]))
        #expect(healthy.ok, "instrument.probeLiveness failed: \(healthy.error ?? "?")")
        #expect(healthy.result?["verdict"]?.stringValue == "static")
    }

    // MARK: - SILENT vs STATIC must not collapse over the wire

    @Test("SILENT and STATIC read as DISTINCT verdicts over the wire — 'never measured' must not collapse into 'measured and found flat'")
    func silentAndStaticVerdictsDoNotCollapseOnTheWire() async throws {
        let silentEngine = ProbeLivenessFakeEngine(behavior: .silent)
        let (silentRouter, silentStore) = makeRouter(engine: silentEngine)
        let silentTrackID = silentStore.addTrack(name: "Unloaded", kind: .instrument).id.uuidString
        let silentResponse = await silentRouter.handle(ControlRequest(
            id: "1", command: "instrument.probeLiveness",
            params: ["trackId": .string(silentTrackID)]))
        #expect(silentResponse.ok, "instrument.probeLiveness failed: \(silentResponse.error ?? "?")")
        #expect(silentResponse.result?["verdict"]?.stringValue == "silent")
        #expect(silentResponse.result?["summary"]?.stringValue?.contains("COULD NOT MEASURE") == true)
        #expect(silentResponse.result?["centroidSpreadPercent"] == nil,
                "no centroid was ever measured — there is nothing to compute a spread from")

        let staticEngine = ProbeLivenessFakeEngine(behavior: .oneSample)
        let (staticRouter, staticStore) = makeRouter(engine: staticEngine)
        let staticTrackID = staticStore.addTrack(name: "Sax", kind: .instrument).id.uuidString
        let staticResponse = await staticRouter.handle(ControlRequest(
            id: "2", command: "instrument.probeLiveness",
            params: ["trackId": .string(staticTrackID)]))
        #expect(staticResponse.ok, "instrument.probeLiveness failed: \(staticResponse.error ?? "?")")
        #expect(staticResponse.result?["verdict"]?.stringValue == "static")

        // The whole point: two different findings must not produce the same
        // wire answer.
        #expect(silentResponse.result?["verdict"]?.stringValue != staticResponse.result?["verdict"]?.stringValue)
    }
}
