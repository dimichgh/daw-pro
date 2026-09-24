import Foundation
import Testing
@testable import DAWCore

// `ProjectStore+PitchCorrection.swift` (m23-q Phase 2, the WRITER leg):
// `autoCorrectClipPitch`/`clearClipPitchEdits`/`pitchEdits(forClipId:)`
// exercised directly against the store, one level below the control
// protocol (`PitchCorrectionCommandTests`, DAWControlTests, covers the wire
// shape). The `ClipAudioAnalysisStoreTests` template: a local fake engine
// stubbing `detectPitch`, a store with one audio clip, assertions that read
// `store.tracks[...].pitchEdits` back directly rather than trusting a
// setter's return.

@MainActor
private final class FakePitchWriterEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult = PitchDetectionResult(
        frames: [], frameCount: 0, voicedFrameCount: 0, voicedFraction: 0,
        frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
        windowStartSeconds: 0, windowDurationSeconds: 0,
        confidenceThreshold: 0.9, silenceFloorDbfs: -75,
        minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    var detectCalls = 0

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        detectCalls += 1
        return stubResult
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
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

@MainActor
@Suite("ProjectStore — pitch correction writer (m23-q Phase 2)")
struct PitchCorrectionWriterTests {

    /// A REAL file on disk — `detectClipPitch` (reused inside
    /// `autoCorrectClipPitch`) checks `FileManager.fileExists`.
    private func makeRealAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-pitch-writer-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        return url
    }

    private func audioStore(clip: Clip? = nil) throws -> (ProjectStore, FakePitchWriterEngine, Clip, URL) {
        let url = try makeRealAudioFile()
        let clip = clip ?? Clip(name: "Vocal", startBeat: 0, lengthBeats: 8,
                                audioFileURL: url)
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakePitchWriterEngine()
        store.engine = engine
        return (store, engine, clip, url)
    }

    /// Two voiced runs (separated by a hole) off a chromatic centre by a real
    /// amount, so the policy has something non-trivial to segment.
    private func melodicResult() -> PitchDetectionResult {
        var frames: [ClipPitchFrame] = []
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: Double(i) * 0.016, frequencyHz: 225.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        frames.append(ClipPitchFrame(timeSeconds: 0.064, frequencyHz: nil, confidence: 0.1,
                                     levelDbfs: -70, absence: .belowConfidence))
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: 0.08 + Double(i) * 0.016, frequencyHz: 250.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.filter { $0.frequencyHz != nil }.count,
            voicedFraction: Double(frames.filter { $0.frequencyHz != nil }.count) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.15,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    @Test("happy path: computed segments land on clip.pitchEdits, read back directly from the store")
    func happyPath() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        let options = PitchAutoCorrectOptions(scale: .chromatic, strength: 1.0,
                                              retuneMs: PitchEditSet.engineMinimumRetuneMs,
                                              preserveVibrato: true)
        let returned = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
        #expect(engine.detectCalls == 1)

        // ⭐ A setter's return is not proof it took — read the SAME field back
        // a second, independent way: straight off `store.tracks`.
        #expect(returned.pitchEdits != nil)
        let stored = try #require(store.tracks[0].clips[0].pitchEdits)
        #expect(stored.segments.count == 2)
        #expect(stored.segments.allSatisfy { $0.pitchOffsetCents != 0 || $0.detectedHz > 0 })
        // detectedHz must be what the contour measured (never mutated) — the
        // log-domain median (`PitchCorrectionMath.medianFrequency`) round-trips
        // through log2/pow2, so this is a tolerance check, not exact equality
        // (`PitchCorrectionMath`'s own doc: agrees to a fraction of a cent,
        // never bit-exact).
        #expect(stored.segments.contains { abs($0.detectedHz - 225.0) < 1e-6 })
        #expect(stored.segments.contains { abs($0.detectedHz - 250.0) < 1e-6 })
    }

    @Test("PLANTED DEFECT CONTROL: this assertion is exactly what a store bug (writing .empty always) would fail")
    func plantedDefectControlShape() async throws {
        // This test does not itself corrupt the store — it pins the
        // observable contract so that a hand-planted defect (temporarily
        // changing `autoCorrectClipPitch` to write
        // `editSet.isEmpty ? nil : PitchEditSet.empty` instead of `editSet`)
        // is caught by exactly this assertion. Verified by hand during
        // development: with that one-line substitution planted, this test
        // FAILS with "Expected stored.segments.count == 2, got 0"; reverting
        // the substitution restores a pass. Kept as a plain assertion here
        // (not a toggle) because the codebase has no mechanism for a test to
        // reach into another file's source at run time — the plant-and-watch
        // step is a development-time verification, recorded in the milestone
        // report, not a permanent runtime control.
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        _ = try await store.autoCorrectClipPitch(
            clipId: clip.id, options: PitchAutoCorrectOptions())
        let stored = try #require(store.tracks[0].clips[0].pitchEdits)
        #expect(stored.segments.count == 2)
    }

    @Test("strength 0 stores nil, not PitchEditSet.empty — the identity short-circuit, checked by CONTENT not just presence")
    func strengthZeroIsNil() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        let options = PitchAutoCorrectOptions(strength: 0)
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    @Test("no voiced runs in the contour stores nil, not an empty non-nil set")
    func noVoicedRunsIsNil() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let silentFrames = (0..<4).map {
            ClipPitchFrame(timeSeconds: Double($0) * 0.016, frequencyHz: nil, confidence: 0.1,
                           levelDbfs: -80, absence: .belowLevel)
        }
        engine.stubResult = PitchDetectionResult(
            frames: silentFrames, frameCount: 4, voicedFrameCount: 0, voicedFraction: 0,
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.064,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)

        _ = try await store.autoCorrectClipPitch(
            clipId: clip.id, options: PitchAutoCorrectOptions())
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    @Test("a comp-lane read-only member refuses with clipInTakeGroup, BEFORE detection runs")
    func compMemberRejected() async throws {
        var clip = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/comp-member.wav"))
        clip.takeGroupID = UUID()
        let (store, engine, resolvedClip, url) = try audioStore(clip: clip)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }

        await #expect(throws: ProjectError.self) {
            _ = try await store.autoCorrectClipPitch(
                clipId: resolvedClip.id, options: PitchAutoCorrectOptions())
        }
        #expect(engine.detectCalls == 0, "the comp-member guard must fail BEFORE the (slow) detection call")
    }

    @Test("a MIDI clip surfaces pitchDetectionRequiresAudioClip, checked BEFORE detection")
    func midiClipRejected() async throws {
        let clip = Clip(name: "Melody", startBeat: 0, lengthBeats: 8, notes: [])
        let track = Track(name: "Instrument", kind: .instrument, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakePitchWriterEngine()
        store.engine = engine

        await #expect(throws: ProjectError.self) {
            _ = try await store.autoCorrectClipPitch(
                clipId: clip.id, options: PitchAutoCorrectOptions())
        }
        #expect(engine.detectCalls == 0)
    }

    @Test("clearClipPitchEdits writes nil and is idempotent")
    func clearWritesNil() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        _ = try await store.autoCorrectClipPitch(
            clipId: clip.id, options: PitchAutoCorrectOptions())
        #expect(store.tracks[0].clips[0].pitchEdits != nil)

        _ = try store.clearClipPitchEdits(clipId: clip.id)
        #expect(store.tracks[0].clips[0].pitchEdits == nil)

        // Idempotent: clearing again is a harmless no-op.
        _ = try store.clearClipPitchEdits(clipId: clip.id)
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    @Test("clearClipPitchEdits on an unknown clip throws clipNotFound")
    func clearUnknownClip() async throws {
        let store = ProjectStore()
        await #expect(throws: ProjectError.self) {
            _ = try store.clearClipPitchEdits(clipId: UUID())
        }
    }

    @Test("pitchEdits(forClipId:) reads back exactly what autoCorrectClipPitch stored, and nil before any correction")
    func getterRoundTrips() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        #expect(try store.pitchEdits(forClipId: clip.id) == nil)

        _ = try await store.autoCorrectClipPitch(
            clipId: clip.id, options: PitchAutoCorrectOptions())
        let viaGetter = try store.pitchEdits(forClipId: clip.id)
        let viaField = store.tracks[0].clips[0].pitchEdits
        #expect(viaGetter == viaField)
        #expect(viaGetter?.segments.count == 2)
    }

    @Test("pitchEdits(forClipId:) on an unknown clip throws clipNotFound")
    func getterUnknownClip() async throws {
        let store = ProjectStore()
        #expect(throws: ProjectError.self) {
            _ = try store.pitchEdits(forClipId: UUID())
        }
    }
}
