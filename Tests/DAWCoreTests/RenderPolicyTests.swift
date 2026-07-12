import Foundation
import Testing
@testable import DAWCore

/// Buffer-out engine fake for the M5 iv-b render-policy suite: `renderOffline`
/// returns a SYNTHETIC program (tests craft its loudness/true-peak precisely),
/// `writeAudioFile` records what would hit disk — so gain math, ceiling
/// clamping, and file-write policy are all assertable headless, no
/// AVFoundation, no real render.
@MainActor
final class FakeBufferEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    /// The synthetic program every `renderOffline` call returns.
    var stub = RenderedAudio(sampleRate: 48_000, channelData: [[], []])
    var renderError: (any Error)?
    var writeError: (any Error)?
    private(set) var renderCalls: [(fromBeat: Double, duration: Double)] = []
    private(set) var written: [(audio: RenderedAudio, url: URL)] = []

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
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        if let renderError { throw renderError }
        renderCalls.append((fromBeat, durationSeconds))
        return stub
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        if let writeError { throw writeError }
        written.append((audio, url))
        return AudioFileInfo(
            durationSeconds: audio.sampleRate > 0
                ? Double(audio.frameCount) / audio.sampleRate : 0,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelData.count
        )
    }
}

/// M5 iv-b render policy (spec §4.1–4.3, §7): static-gain normalization with
/// the true-peak ceiling CLAMP, honest reporting, silence semantics, default
/// window math, and the file-write discipline — all over the mock buffer
/// engine.
@MainActor
@Suite("Render policy — measured/normalized bounce (M5 iv-b)")
struct RenderPolicyTests {

    // MARK: - Fixtures

    /// One channel of `frequency` Hz sine at `dbfs` (per-channel level).
    /// A 997 Hz stereo sine at X dBFS/channel measures X LUFS (the iv-a
    /// calibration: the −0.691 offset cancels the K-gain at 997 Hz).
    private func sineSamples(dbfs: Double, seconds: Double,
                             frequency: Double = 997, sampleRate: Double = 48_000) -> [Float] {
        let amplitude = pow(10.0, dbfs / 20.0)
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
            samples[frame] = Float(amplitude * sin(phase))
        }
        return samples
    }

    private func stereo(_ samples: [Float]) -> RenderedAudio {
        RenderedAudio(sampleRate: 48_000, channelData: [samples, samples])
    }

    private func makeStore(with engine: FakeBufferEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        return store
    }

    // MARK: - Engine-seam defaults (fakes without the new methods stay green)

    @Test("protocol defaults: renderOffline/writeAudioFile refuse, targets empty")
    func protocolDefaultsKeepFakesGreen() async {
        // FakeRecordingEngine predates iv-b and implements NONE of the new
        // methods — it compiling at all is the additive-seam proof; the
        // defaults must refuse readably rather than fake a render.
        let legacy = FakeRecordingEngine()
        await #expect(throws: ProjectError.self) {
            _ = try await legacy.renderOffline(
                tracks: [], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
                fromBeat: 0, durationSeconds: 1, forcedCompensationTargets: nil)
        }
        let targets = await legacy.offlineCompensationTargets(tracks: [])
        #expect(targets.isEmpty)
        #expect(throws: ProjectError.self) {
            _ = try legacy.writeAudioFile(
                RenderedAudio(sampleRate: 48_000, channelData: [[0], [0]]),
                to: URL(fileURLWithPath: "/dev/null"))
        }
    }

    // MARK: - Gain math (spec §7: target −20 on a −14 program → G = −6)

    @Test("normalize down: −14 LUFS program to −20 target applies exactly −6 dB")
    func gainMathExact() async throws {
        let engine = FakeBufferEngine()
        engine.stub = stereo(sineSamples(dbfs: -14, seconds: 10))
        let result = try await makeStore(with: engine).renderBounce(
            durationSeconds: 10, lufsTarget: -20)

        let report = result.report
        #expect(abs((report.input.integratedLufs ?? .nan) - (-14.0)) <= 0.05)
        #expect(abs(report.appliedGainDb - (-6.0)) <= 0.05)
        #expect(!report.limitedByCeiling)
        #expect(report.lufsTarget == -20)
        #expect(report.truePeakCeilingDbtp == -1.0)
        // Output is re-measured, not derived — and it is the buffer that was
        // handed to the writer, so re-measuring the "written" audio agrees.
        #expect(abs((report.output.integratedLufs ?? .nan) - (-20.0)) <= 0.1)
        #expect(engine.written.count == 1)
        let writtenMeasure = Loudness.measure(engine.written[0].audio)
        #expect(abs((writtenMeasure.integratedLufs ?? .nan) - (-20.0)) <= 0.1)
    }

    // MARK: - Ceiling clamp (spec §7: −20 LUFS / −2 dBTP, target −14 → G = +1)

    @Test("ceiling clamps the gain: +6 wanted, +1 granted, honestly reported")
    func ceilingClampCase() async throws {
        // −20 LUFS program whose true peak is −2 dBTP: a −20 dBFS sine plus
        // one ISOLATED −2 dBFS impulse (neighborhood zeroed so the 4×
        // interpolator sees a lone spike — its true peak IS the sample peak;
        // energy contribution to the integrated measure is negligible).
        var samples = sineSamples(dbfs: -20, seconds: 10)
        for frame in (48_000 - 64)...(48_000 + 64) { samples[frame] = 0 }
        samples[48_000] = Float(pow(10.0, -2.0 / 20.0))
        let engine = FakeBufferEngine()
        engine.stub = stereo(samples)

        let result = try await makeStore(with: engine).renderBounce(
            durationSeconds: 10, lufsTarget: -14, truePeakCeilingDb: -1.0)

        let report = result.report
        print("[measured] clamp case: input \(report.input.integratedLufs ?? .nan) LUFS"
            + " / TP \(report.input.truePeakDbtp ?? .nan) dBTP, gain \(report.appliedGainDb) dB,"
            + " output \(report.output.integratedLufs ?? .nan) LUFS"
            + " / TP \(report.output.truePeakDbtp ?? .nan) dBTP")
        #expect(abs((report.input.integratedLufs ?? .nan) - (-20.0)) <= 0.05)
        #expect(abs((report.input.truePeakDbtp ?? .nan) - (-2.0)) <= 0.1)
        // Unclamped gain would be +6 dB; the −1 dBTP ceiling grants +1 dB.
        #expect(abs(report.appliedGainDb - 1.0) <= 0.1)
        #expect(report.limitedByCeiling)
        // Achieved loudness lands 5 LU under target — the report is ground
        // truth for how far (spec §4.1: the agent reads the gap and decides).
        #expect(abs((report.output.integratedLufs ?? .nan) - (-19.0)) <= 0.1)
        #expect(abs((report.output.truePeakDbtp ?? .nan) - (-1.0)) <= 0.1)
    }

    // MARK: - Omitted target = measured mixdown

    @Test("no lufsTarget: zero gain, report echoes, buffer written untouched")
    func omittedTargetIsMeasuredMixdown() async throws {
        let samples = sineSamples(dbfs: -14, seconds: 5)
        let engine = FakeBufferEngine()
        engine.stub = stereo(samples)
        let result = try await makeStore(with: engine).renderBounce(durationSeconds: 5)

        let report = result.report
        #expect(report.appliedGainDb == 0)
        #expect(report.lufsTarget == nil)
        #expect(!report.limitedByCeiling)
        #expect(report.output == report.input)
        #expect(engine.written.count == 1)
        // The written buffer is the render, sample for sample — no gain baked.
        #expect(engine.written[0].audio.channelData == [samples, samples])
    }

    // MARK: - Silence semantics (spec §4.1)

    @Test("gated-silent program + target throws bounceSilent, writes nothing")
    func silentPlusTargetThrows() async throws {
        let engine = FakeBufferEngine()
        engine.stub = stereo([Float](repeating: 0, count: 5 * 48_000))
        let store = makeStore(with: engine)
        do {
            _ = try await store.renderBounce(durationSeconds: 5, lufsTarget: -14)
            Issue.record("expected bounceSilent")
        } catch let error as ProjectError {
            guard case .bounceSilent = error else {
                Issue.record("expected bounceSilent, got \(error)")
                return
            }
            // Exact wording is contract (surfaced verbatim on the wire).
            #expect(error.localizedDescription
                == "program is silent below the -70 LUFS gate — cannot loudness-normalize")
        }
        #expect(engine.written.isEmpty)
    }

    @Test("gated-silent program without a target succeeds with all-nil fields")
    func silentWithoutTargetSucceeds() async throws {
        let engine = FakeBufferEngine()
        engine.stub = stereo([Float](repeating: 0, count: 5 * 48_000))
        let result = try await makeStore(with: engine).renderBounce(durationSeconds: 5)
        #expect(result.report.input == LoudnessMeasurement())
        #expect(result.report.output == LoudnessMeasurement())
        #expect(result.report.appliedGainDb == 0)
        #expect(engine.written.count == 1)
    }

    // MARK: - Measure-only leaves no file

    @Test("measureLoudness renders, measures, and never touches the writer")
    func measureOnlyLeavesNoFile() async throws {
        let samples = sineSamples(dbfs: -23, seconds: 5)
        let engine = FakeBufferEngine()
        engine.stub = stereo(samples)
        let result = try await makeStore(with: engine).measureLoudness(durationSeconds: 5)

        #expect(engine.written.isEmpty)
        #expect(engine.renderCalls.count == 1)
        #expect(result.measurement == Loudness.measure(stereo(samples)))
        #expect(abs((result.measurement.integratedLufs ?? .nan) - (-23.0)) <= 0.1)
        #expect(result.sampleRate == 48_000)
        #expect(abs(result.durationSeconds - 5.0) <= 0.001)
    }

    // MARK: - Shared default window (spec §4.3)

    @Test("default duration = ALL clips' extent (instrument included) + 2 s tail")
    func defaultDurationCoversAllClipKinds() async throws {
        let engine = FakeBufferEngine()
        engine.stub = stereo(sineSamples(dbfs: -23, seconds: 1))
        let store = makeStore(with: engine)
        // Audio clip ends at beat 4; a MIDI clip ends at beat 8 — the LATEST
        // extent wins, deliberately broader than renderMixdown's audio-only
        // legacy default. 8 beats @ 120 BPM = 4 s, + 2.0 s tail.
        store.tracks = [
            Track(name: "A", kind: .audio, clips: [
                Clip(name: "a", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/unused.wav")),
            ]),
            Track(name: "I", kind: .instrument, clips: [
                Clip(name: "m", startBeat: 4, lengthBeats: 4, notes: []),
            ]),
        ]
        _ = try await store.measureLoudness()
        #expect(engine.renderCalls.count == 1)
        #expect(abs(engine.renderCalls[0].duration - 6.0) <= 1e-9)

        // fromBeat past every clip → nothing to render.
        await #expect(throws: ProjectError.self) {
            _ = try await store.measureLoudness(fromBeat: 8)
        }
        // No clips at all → nothing to render (and nothing was written ever).
        store.tracks = []
        await #expect(throws: ProjectError.self) {
            _ = try await store.renderBounce()
        }
        #expect(engine.written.isEmpty)
    }

    // MARK: - Errors surface verbatim

    @Test("engine failures pass through renderBounce/measureLoudness untouched")
    func engineErrorsSurfaceVerbatim() async throws {
        let engine = FakeBufferEngine()
        engine.renderError = ProjectError.transportBusy("render seam is on fire")
        let store = makeStore(with: engine)
        do {
            _ = try await store.renderBounce(durationSeconds: 1)
            Issue.record("expected the render error to surface")
        } catch {
            #expect(error.localizedDescription == "render seam is on fire")
        }

        engine.renderError = nil
        engine.stub = stereo(sineSamples(dbfs: -23, seconds: 1))
        engine.writeError = ProjectError.saveFailed("disk detached mid-write")
        do {
            _ = try await store.renderBounce(durationSeconds: 1)
            Issue.record("expected the write error to surface")
        } catch let error as ProjectError {
            guard case .saveFailed(let reason) = error else {
                Issue.record("expected saveFailed, got \(error)")
                return
            }
            #expect(reason == "disk detached mid-write")
        }

        // Headless store (no engine): the same engineUnavailable everything
        // engine-backed throws.
        let bare = ProjectStore()
        await #expect(throws: ProjectError.self) {
            _ = try await bare.measureLoudness(durationSeconds: 1)
        }
    }

    // MARK: - Destination policy

    @Test("nil path lands under DAWPro/bounce-…; explicit paths gain .wav")
    func destinationPolicy() async throws {
        let engine = FakeBufferEngine()
        engine.stub = stereo(sineSamples(dbfs: -23, seconds: 1))
        let store = makeStore(with: engine)

        let defaulted = try await store.renderBounce(durationSeconds: 1)
        #expect(defaulted.path.contains("/DAWPro/bounce-"))
        #expect(defaulted.path.hasSuffix(".wav"))

        let explicit = try await store.renderBounce(
            toPath: "/tmp/daw-pro-tests/no-extension", durationSeconds: 1)
        #expect(explicit.path == "/tmp/daw-pro-tests/no-extension.wav")
        #expect(engine.written.count == 2)
    }
}
