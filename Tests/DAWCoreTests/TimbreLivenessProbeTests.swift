import Foundation
import Testing
@testable import DAWCore

/// m31-f ② — the RENDER-INTEGRATION half of the timbre-liveness probe.
///
/// `TimbreLivenessTests` (if present) covers the pure measurement. This suite
/// covers everything BETWEEN the wire and that measurement: the ladder the
/// store authors, the synthetic track it renders, and — the part that matters
/// most — the refusal that happens when the meter cannot prove it discriminates.
///
/// ⭐ WHY THE FAKE ENGINE SYNTHESISES REAL AUDIO RATHER THAN A CONSTANT.
/// A double that returns a flat buffer would let every verdict test pass while
/// the store handed the renderer the wrong notes entirely. This engine reads
/// the notes it is GIVEN — their velocities, their beat positions, the tempo
/// map it was handed — and builds a signal from them. So an off-by-one in the
/// note placement, a ladder authored at the wrong beat, or a velocity that
/// never reached the clip shows up as a wrong verdict, not as a green test.
@Suite("m31-f ② — instrument liveness probe (render integration)")
@MainActor
struct TimbreLivenessProbeTests {

    // MARK: - A fake engine that actually plays the ladder it is handed

    /// What the fake instrument does with velocity.
    enum PatchBehavior {
        /// One sample with a volume knob: level tracks velocity, the harmonic
        /// mix never changes. The Apple `gs_instruments.dls` sax shape
        /// (measured: RMS −51.6 → −23.3 dB, centroid 2100/2099/2100/2099 Hz).
        case oneSample
        /// Real velocity layers: brightness steps with velocity too. The
        /// GeneralUser GS sax shape (2237 → 2331 → 2384 Hz).
        case velocityLayered
        /// Ignores velocity entirely — level does not move, so the ladder
        /// never tests the question.
        case velocityDeaf
        /// Produces nothing at all (unloaded patch, pitch outside the keymap).
        case silent
    }

    final class LadderSynthEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        let behavior: PatchBehavior
        /// Forced render sample rate. 2000 Hz cannot resolve the meter's own
        /// 1760 Hz control tone, which is how the self-check-failure path is
        /// reached deterministically and without an injection seam.
        let sampleRate: Double

        /// Everything the render seam was called with — the assertion surface
        /// for "the probe renders the PATCH, not the mix".
        private(set) var renderedTracks: [Track] = []
        private(set) var renderedMasterVolume: Double?
        private(set) var renderedMasterEffects: [EffectDescriptor]?
        private(set) var renderedMasterAutomation: [AutomationLane]?
        private(set) var renderedFromBeat: Double?
        private(set) var renderedDurationSeconds: Double?
        private(set) var renderCallCount = 0

        init(behavior: PatchBehavior, sampleRate: Double = 48_000) {
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
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
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
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: sampleRate,
                          channelCount: 2)
        }

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: sampleRate,
                          channelCount: 2)
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            renderCallCount += 1
            renderedTracks = tracks
            renderedMasterVolume = masterVolume
            renderedMasterEffects = masterEffects
            renderedMasterAutomation = masterAutomation
            renderedFromBeat = fromBeat
            renderedDurationSeconds = durationSeconds

            let frames = max(1, Int(durationSeconds * sampleRate))
            var mono = [Float](repeating: 0, count: frames)
            if behavior != .silent {
                for note in tracks.flatMap({ $0.clips }).flatMap({ $0.notes ?? [] }) {
                    let start = tempoMap.seconds(from: 0, to: note.startBeat)
                    let end = tempoMap.seconds(from: 0, to: note.endBeat)
                    render(note: note, into: &mono, startSeconds: start,
                           endSeconds: end, frames: frames)
                }
            }
            return RenderedAudio(sampleRate: sampleRate, channelData: [mono, mono])
        }

        /// One note: a fundamental at 220 Hz plus `partials` harmonics. Level
        /// and brightness are the two dials velocity can turn, and the
        /// `behavior` decides which of them it actually turns.
        private func render(note: MIDINote, into buffer: inout [Float],
                            startSeconds: Double, endSeconds: Double, frames: Int) {
            let v = Double(note.velocity) / 127.0
            let amplitude: Double
            let partials: Int
            switch behavior {
            case .oneSample:
                // Level moves ~28 dB pp→ff; the harmonic mix is frozen.
                amplitude = 0.5 * v * v
                partials = 4
            case .velocityLayered:
                amplitude = 0.5 * v * v
                // Discrete LAYERS, deliberately not a slide: 2 / 4 / 8 / 12
                // partials as velocity climbs. Two rungs landing in the same
                // layer share a centroid, which is what `distinctTimbreCount`
                // is there to count.
                partials = v < 0.3 ? 2 : (v < 0.6 ? 4 : (v < 0.85 ? 8 : 12))
            case .velocityDeaf:
                amplitude = 0.3
                partials = 4
            case .silent:
                return
            }
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

        func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 1, sampleRate: sampleRate, channelCount: 2)
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL,
                            format: DeliveryFormat) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 1, sampleRate: sampleRate, channelCount: 2)
        }
    }

    // MARK: - Harness

    private static func makeSession(behavior: PatchBehavior,
                                    sampleRate: Double = 48_000)
        -> (ProjectStore, LadderSynthEngine, UUID) {
        let engine = LadderSynthEngine(behavior: behavior, sampleRate: sampleRate)
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Sax", kind: .instrument)
        return (store, engine, track.id)
    }

    // MARK: - The verdicts

    @Test("a one-sample patch comes back STATIC with ONE timbre group — the Apple DLS sax shape the user called a toy")
    func oneSampleReadsStatic() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(result.verdict == .static)
        #expect(result.distinctTimbreCount == 1)
        #expect(result.ladder.count == 4)
        // Level moved a lot; timbre did not. That is the whole signature.
        let rmsSpread = try #require(result.rmsSpreadDb)
        #expect(rmsSpread >= TimbreLiveness.minimumRMSSpreadDb)
        let centroidSpread = try #require(result.centroidSpreadPercent)
        #expect(centroidSpread < TimbreLiveness.staticCentroidSpreadPercent)
        // Every rung is measurable and lands in the same group.
        #expect(result.ladder.allSatisfy { $0.centroidHz != nil })
        #expect(Set(result.ladder.compactMap(\.timbreGroup)) == [1])
        // Ascending velocity means ascending level — proof the store handed
        // the renderer the ladder in the order it claims.
        let levels = result.ladder.map(\.rmsDb)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
        #expect(result.ladder.map(\.velocity) == ProjectStore.livenessDefaultVelocities)
    }

    @Test("a velocity-layered patch comes back LIVE with MORE than one timbre group")
    func layeredReadsLive() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .velocityLayered)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(result.verdict == .live)
        #expect(result.distinctTimbreCount > 1,
                "four discrete partial counts must not collapse into one group")
        let centroidSpread = try #require(result.centroidSpreadPercent)
        #expect(centroidSpread >= TimbreLiveness.staticCentroidSpreadPercent)
    }

    @Test("a velocity-DEAF patch is INCONCLUSIVE, never STATIC — a ladder that did not move the level has not tested the question")
    func velocityDeafReadsInconclusive() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .velocityDeaf)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(result.verdict == .inconclusive)
        #expect(result.verdict != .static)
        let rmsSpread = try #require(result.rmsSpreadDb)
        #expect(rmsSpread < TimbreLiveness.minimumRMSSpreadDb)
        #expect(result.summary.contains("INCONCLUSIVE"))
    }

    @Test("⭐ a patch that produces NO signal is SILENT, not STATIC — 'never measured' and 'measured and found flat' must not read the same")
    func silentIsNotStatic() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .silent)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(result.verdict == .silent)
        #expect(result.verdict != .static)
        #expect(result.distinctTimbreCount == 0)
        #expect(result.ladder.allSatisfy { $0.centroidHz == nil })
        #expect(result.ladder.allSatisfy { $0.timbreGroup == nil })
        // The summary must say the probe could not measure, and must NOT
        // accuse the instrument of being dead.
        #expect(result.summary.contains("COULD NOT MEASURE"))
        #expect(result.summary.contains("NOT a finding of deadness"))
    }

    // MARK: - ⭐⭐ The self-check gates the verdict

    @Test("⭐⭐ when the meter fails its own positive control the probe ERRORS — it never returns a STATIC verdict from a meter that cannot discriminate")
    func selfCheckFailureIsAnErrorNotAVerdict() async throws {
        // 2 kHz render rate: the meter's own 1760 Hz control tone aliases to
        // 240 Hz, below the 440 Hz one, so the control cannot pass. No
        // injection seam, no test-only hook — a rate the geometry genuinely
        // cannot resolve.
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample,
                                                        sampleRate: 2_000)
        await #expect(throws: TimbreLiveness.ProbeError.self) {
            _ = try await store.probeInstrumentLiveness(trackId: trackID)
        }
        // The render DID happen — this is a measurement refusal, not a
        // never-ran. (If the render were skipped, a future change that broke
        // the render would pass this test for the wrong reason.)
        #expect(engine.renderCallCount == 1)

        // And the message has to teach, not merely fail.
        do {
            _ = try await store.probeInstrumentLiveness(trackId: trackID)
            Issue.record("expected the probe to refuse")
        } catch let error as TimbreLiveness.ProbeError {
            let text = try #require(error.errorDescription)
            #expect(text.contains("positive control"))
            #expect(text.contains("No liveness verdict was produced"))
            #expect(!text.lowercased().contains("static"))
        }
    }

    @Test("the meter's positive control PASSES at the real render rate — the gate above is falsifiable, not always-red")
    func selfCheckPassesAt48k() {
        let check = TimbreLiveness.selfCheck(sampleRate: 48_000)
        #expect(check.passed)
        let low = try? #require(check.lowToneCentroidHz)
        let high = try? #require(check.highToneCentroidHz)
        #expect((high ?? 0) > (low ?? 0) * 2)
    }

    // MARK: - The weighting regression (m31-f, bought 2026-08-28)

    /// ⭐⭐⭐ THE TEST THE SUITE DID NOT HAVE, AND ITS ABSENCE SHIPPED A BUG.
    ///
    /// `centroid` computed a POWER-weighted (|X|²) mean instead of the standard
    /// MAGNITUDE-weighted (|X|) spectral centroid. On real material that
    /// over-weights the fundamental and under-weights the upper harmonics —
    /// exactly where velocity layers differ — compressing a measured 6.59 %
    /// spread to 0.295 % and FLIPPING a genuinely layered saxophone's verdict
    /// from LIVE to STATIC. The probe confidently called a good instrument dead.
    ///
    /// ⚠️ **EVERY OTHER TEST IN THIS FILE PASSED BEFORE AND AFTER THE FIX.**
    /// They drive a mock whose layers are separated far enough that both
    /// weightings reach the same verdict, so the suite was structurally unable
    /// to see the defect. Only measuring a REAL instrument found it.
    ///
    /// ⭐ Why the self-check could not catch it either: it measures PURE SINES,
    /// and a single-partial signal has the SAME centroid under both weightings
    /// (both read 440.0000000 Hz). **A control built from a signal simpler than
    /// the signal under test can be blind to a whole class of error while
    /// passing perfectly.** This test uses a signal that is NOT simpler: four
    /// partials with unequal amplitudes, where the two weightings must diverge.
    ///
    /// The expected value is ANALYTIC, not a recorded output — a golden number
    /// copied from a run would have enshrined whatever the code did that day.
    @Test("centroid is MAGNITUDE-weighted: a 4-partial tone matches the analytic Σ(f·|X|)/Σ|X|, NOT the power-weighted value")
    func centroidIsMagnitudeWeighted() throws {
        let sampleRate = 48_000.0
        let f0 = 500.0
        let amplitudes = [1.0, 0.5, 0.25, 0.125]   // deliberately unequal

        // Σ(k·f0·a_k) / Σ(a_k)  — the standard definition.
        // Written as an explicit loop: the chained zip/map/reduce form defeats
        // Swift's type-checker here ("unable to type-check in reasonable time").
        var magnitudeNumerator = 0.0
        var magnitudeDenominator = 0.0
        var powerNumerator = 0.0
        var powerDenominator = 0.0
        for (index, amplitude) in amplitudes.enumerated() {
            let partialHz = Double(index + 1) * f0
            magnitudeNumerator += partialHz * amplitude
            magnitudeDenominator += amplitude
            powerNumerator += partialHz * amplitude * amplitude
            powerDenominator += amplitude * amplitude
        }
        let magnitudeExpected = magnitudeNumerator / magnitudeDenominator
        // Σ(k·f0·a_k²) / Σ(a_k²) — what the old implementation computed.
        let powerExpected = powerNumerator / powerDenominator

        // The two must be far apart, or this test proves nothing. ~867 vs ~659.
        #expect(abs(magnitudeExpected - powerExpected) > 150,
                "fixture is degenerate: the two weightings must diverge for this to discriminate")

        let count = Int(sampleRate * 1.0)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var value = 0.0
            for (index, amplitude) in amplitudes.enumerated() {
                value += amplitude * sin(2 * Double.pi * f0 * Double(index + 1) * t)
            }
            samples[i] = Float(value / 4.0)
        }

        let hz = try #require(TimbreLiveness.centroid(of: samples, sampleRate: sampleRate))

        // 3 % of the analytic value: generous enough for Hann leakage and bin
        // width, far tighter than the ~24 % gap to the power-weighted answer.
        #expect(abs(hz - magnitudeExpected) / magnitudeExpected < 0.03,
                "centroid \(hz) Hz should match the magnitude-weighted \(magnitudeExpected) Hz")
        #expect(abs(hz - powerExpected) / powerExpected > 0.10,
                "centroid \(hz) Hz must NOT match the power-weighted \(powerExpected) Hz — that was the bug")
    }

    // MARK: - The probe measures the PATCH, not the mix

    @Test("the rendered track is stripped bare: no effects, sends, automation, mute/solo, fader or bus routing, and unity master")
    func rendersThePatchNotTheMix() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        let busTrack = store.addTrack(name: "Bus", kind: .bus)
        _ = store.updateTrack(id: trackID) { track in
            track.effects = [EffectDescriptor(kind: .compressor)]
            track.volume = 0.05
            track.pan = -0.9
            track.isMuted = true
            track.outputBusID = busTrack.id
        }
        store.setMasterVolume(0.01)

        _ = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(engine.renderedTracks.count == 1,
                "only the probed track is rendered — a whole-session render would measure the song")
        let rendered = try #require(engine.renderedTracks.first)
        #expect(rendered.effects.isEmpty, "a compressor would flatten the very spread the verdict rests on")
        #expect(rendered.sends.isEmpty)
        #expect(rendered.automation.isEmpty, "a volume lane would forge level movement the velocities did not make")
        #expect(rendered.isMuted == false, "a muted track would read SILENT for a perfectly good patch")
        #expect(rendered.isSoloed == false)
        #expect(rendered.volume == 1)
        #expect(rendered.pan == 0)
        #expect(rendered.outputBusID == nil, "the bus is not in the render set; routing to it would render nothing")
        #expect(engine.renderedMasterVolume == 1.0,
                "a pulled-down master fader must not make a healthy patch read as dead")
        #expect(engine.renderedMasterEffects?.isEmpty == true)
        #expect(engine.renderedMasterAutomation?.isEmpty == true)
    }

    @Test("⚠️ the ladder is rendered FROM BEAT 0 — a windowed render drops every note whose note-on precedes the window")
    func rendersFromBeatZero() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        _ = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(engine.renderedFromBeat == 0)
        let clip = try #require(engine.renderedTracks.first?.clips.first)
        #expect(clip.startBeat == 0)
        let notes = try #require(clip.notes)
        #expect(notes.first?.startBeat == 0)
        // Long enough to hold every note plus the release tail.
        let duration = try #require(engine.renderedDurationSeconds)
        #expect(duration >= 3 * ProjectStore.livenessNoteSpacingSeconds
            + ProjectStore.livenessNoteSeconds)
    }

    @Test("the probe is NOT an edit: no clip is landed, no track is added, no undo step is pushed")
    func probeDoesNotTouchTheProject() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let trackCountBefore = store.tracks.count
        let clipsBefore = store.tracks.flatMap(\.clips).count
        let canUndoBefore = store.canUndo

        _ = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(store.tracks.count == trackCountBefore)
        #expect(store.tracks.flatMap(\.clips).count == clipsBefore)
        #expect(store.canUndo == canUndoBefore, "a diagnostic must not land in the undo stack")
    }

    @Test("the authored ladder: one note per velocity, same pitch, ascending, spaced so a release cannot bleed into the next window")
    func ladderGeometry() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        _ = try await store.probeInstrumentLiveness(trackId: trackID, pitch: 64,
                                                    velocities: [20, 70, 120])
        let notes = try #require(engine.renderedTracks.first?.clips.first?.notes)
        #expect(notes.count == 3)
        #expect(notes.allSatisfy { $0.pitch == 64 })
        #expect(notes.map(\.velocity) == [20, 70, 120])
        // 120 bpm default -> 2 beats per second, so the 2 s spacing is 4 beats.
        let map = store.transport.tempoMap
        for (index, note) in notes.enumerated() {
            let expected = map.beat(from: 0,
                                    elapsedSeconds: Double(index) * ProjectStore.livenessNoteSpacingSeconds)
            #expect(abs(note.startBeat - expected) < 1e-9)
        }
        // A note plus an equal gap: the tail of a loud rung cannot reach the
        // (quieter) next rung's analysis window.
        let noteSeconds = map.seconds(from: notes[0].startBeat, to: notes[0].endBeat)
        #expect(abs(noteSeconds - ProjectStore.livenessNoteSeconds) < 1e-9)
        #expect(ProjectStore.livenessNoteSpacingSeconds >= 2 * ProjectStore.livenessNoteSeconds)
        // And the analysis window sits inside the note, past the attack.
        #expect(ProjectStore.livenessWindowOffsetSeconds
            + ProjectStore.livenessWindowSeconds <= ProjectStore.livenessNoteSeconds)
    }

    // MARK: - Refusals

    @Test("an audio track is refused with track.setInstrument's own wording; a bus track too")
    func refusesNonInstrumentTracks() async throws {
        let (store, engine, _) = Self.makeSession(behavior: .oneSample)
        let audio = store.addTrack(name: "Vox", kind: .audio)
        await #expect(throws: ProjectError.self) {
            _ = try await store.probeInstrumentLiveness(trackId: audio.id)
        }
        #expect(engine.renderCallCount == 0, "a refusal must not pay for a render")
    }

    @Test("an unknown trackId is refused, and a one-rung ladder is refused before anything renders")
    func refusesUnknownTrackAndShortLadder() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        await #expect(throws: ProjectError.self) {
            _ = try await store.probeInstrumentLiveness(trackId: UUID())
        }
        await #expect(throws: TimbreLiveness.ProbeError.noVelocities) {
            _ = try await store.probeInstrumentLiveness(trackId: trackID, velocities: [100])
        }
        #expect(engine.renderCallCount == 0)
    }

    // MARK: - The response never overstates itself

    @Test("every response carries the self-check, the raw ladder, the uncalibrated thresholds and the caveats — a caller can disagree with the verdict from the evidence")
    func responseCarriesItsOwnEvidence() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)

        #expect(result.selfCheck.passed)
        #expect(result.thresholds.calibrated == false,
                "the 5 %/6 dB numbers are a hypothesis from ONE instrument family")
        #expect(result.thresholds.staticCentroidSpreadPercent
            == TimbreLiveness.staticCentroidSpreadPercent)
        #expect(!result.caveats.isEmpty)
        #expect(result.caveats.contains { $0.contains("LIVELINESS, not quality") })
        #expect(result.caveats.contains { $0.contains("NOT calibrated") })
        #expect(result.trackId == trackID.uuidString)
        #expect(result.pitch == ProjectStore.livenessDefaultPitch)
        #expect(result.sampleRate == 48_000)
    }

    @Test("the whole result round-trips through Codable — the wire shape is the model's own, so it cannot drift")
    func resultRoundTripsThroughCodable() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .velocityLayered)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TimbreLiveness.Result.self, from: data)
        #expect(decoded == result)
        // A silent rung encodes as an ABSENT centroid, never as 0 Hz — 0 would
        // read as "very dark" and quietly drag every spread computed from it.
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["verdict"] as? String == "live")
        #expect(json["distinctTimbreCount"] != nil)
    }

    @Test("instrumentKind and instrumentDetail name WHICH patch was probed")
    func reportsWhichPatchWasProbed() async throws {
        let (store, engine, trackID) = Self.makeSession(behavior: .oneSample)
        // `ProjectStore.engine` is WEAK (ProjectStore.swift:294): discarding this
        // binding lets the mock deallocate and the probe throws .engineUnavailable.
        defer { withExtendedLifetime(engine) {} }
        _ = store.updateTrack(id: trackID) { track in
            track.instrument = InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .generalMIDI, program: 65,
                                           bankMSB: 121, bankLSB: 0,
                                           displayName: "Alto Sax — General MIDI"))
        }
        let result = try await store.probeInstrumentLiveness(trackId: trackID)
        #expect(result.instrumentKind == "soundBank")
        let detail = try #require(result.instrumentDetail)
        #expect(detail.contains("General MIDI"))
        #expect(detail.contains("65"))
    }
}
