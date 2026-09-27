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
    /// C5b-3a: how many times a writer pushed the engine ("ONE tracksDidChange").
    var tracksDidChangeCalls = 0
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCalls += 1 }
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

    // MARK: - m23-ap Increment C — the PER-NOTE writer
    //
    // `ProjectStore+PitchNoteEdits.swift`. Every assertion here reads the field
    // BACK out of the store: "the call returned a Clip" is the exact shape this
    // tree keeps paying for.

    /// ONE long voiced run — long enough that both halves of a split clear
    /// `PitchAutoCorrect.minimumNoteSeconds` (0.06 s), which `melodicResult`'s
    /// 0.064 s runs deliberately do not.
    private func longNoteResult(seconds: Double = 1.0, hz: Double = 220) -> PitchDetectionResult {
        let period = 1.0 / 62.5
        let count = Int(seconds / period)
        let frames = (0..<count).map { i in
            ClipPitchFrame(timeSeconds: Double(i) * period, frequencyHz: hz,
                           confidence: 0.95, levelDbfs: -12, absence: nil)
        }
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: frames.count,
            voicedFraction: 1, frameRateHz: 62.5, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 44_100, windowStartSeconds: 0,
            windowDurationSeconds: seconds, confidenceThreshold: 0.9,
            silenceFloorDbfs: -75, minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    private func seedTable(_ result: PitchDetectionResult) -> PitchEditSet {
        PitchNoteTable.detected(from: result)
    }

    @Test("PitchNoteTable.detected is the NOTES with no correction — not the empty set strength 0 returns")
    func detectedTableIsIdentityNotEmpty() throws {
        let result = melodicResult()
        let table = PitchNoteTable.detected(from: result)
        #expect(table.segments.count == 2)
        #expect(table.isIdentity)
        #expect(!table.isEmpty)
        for segment in table.segments {
            #expect(segment.pitchOffsetCents == 0)
            #expect(segment.driftScale == 1)
            #expect(segment.vibratoScale == 1)
        }
        // ⭐ THE CONTRAST THAT MAKES THIS A SEPARATE CONSTRUCTOR AT ALL, asserted
        // rather than described: the correction policy at strength 0 returns NO
        // SEGMENTS. An editor needs the notes without the correction, which is a
        // different thing from no correction at all.
        let zeroStrength = PitchAutoCorrect.editSet(
            from: result, options: PitchAutoCorrectOptions(strength: 0))
        #expect(zeroStrength.segments.isEmpty)
        #expect(zeroStrength.isEmpty)
        // Segmentation is the SAME home as the corrector's: `PitchNoteSplitter`
        // over `voicedRuns` (p2-seg). These two notes are separated by a hole
        // and neither changes pitch inside, so the parts ARE the runs…
        let runs = PitchAutoCorrect.voicedRuns(in: result.frames, frameRateHz: result.frameRateHz)
        #expect(table.segments.map(\.startSeconds) == runs.map(\.startSeconds))
        #expect(table.segments.map(\.endSeconds) == runs.map(\.endSeconds))
        // …and design §5.2's three legs hold on this fixture: unit, edit set and
        // note table all equal the pre-p2-seg builders field by field.
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: result.frames,
                                                                       frameRateHz: result.frameRateHz)
        #expect(invariance.isEmpty, "\(invariance.prefix(3))")
    }

    @Test("C1: the offset lands on the named note and NOTHING else moves")
    func setNotePitchWritesAndLeavesTheRestAlone() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        #expect(seed.segments.count == 2)
        let target = seed.segments[0].id
        let other = seed.segments[1]

        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: target,
                                             offsetCents: -37, seedIfAbsent: seed)

        // READ IT BACK OUT OF THE STORE, never off the return value.
        let stored = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(stored.segments.count == 2)
        let moved = try #require(stored.segments.first(where: { $0.id == target }))
        #expect(moved.pitchOffsetCents == -37)
        // ⭐ THE INVARIANCE CONTROL. A headline number that moved proves the write
        // happened; only the neighbours proving they did NOT move shows it wrote
        // the note it was asked about.
        let untouched = try #require(stored.segments.first(where: { $0.id == other.id }))
        #expect(untouched == other)
        #expect(moved.startSeconds == seed.segments[0].startSeconds)
        #expect(moved.endSeconds == seed.segments[0].endSeconds)
        #expect(moved.detectedHz == seed.segments[0].detectedHz)
    }

    @Test("C1: the offset is CLAMPED to the whole-clip pitch range, and reads back clamped")
    func setNotePitchClamps() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[0].id,
                                             offsetCents: 99_999, seedIfAbsent: seed)
        let stored = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(stored.segments[0].pitchOffsetCents
                == NoteSegment.pitchOffsetCentsRange.upperBound)
    }

    @Test("C1: a seed is IGNORED when the clip already carries a table — a deliberate clobber fails to clobber")
    func seedIgnoredWhenTheClipAlreadyCarriesATable() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchAutoCorrectOptions())
        let real = try #require(try store.pitchEdits(forClipId: clip.id))
        let realTarget = real.segments[0].id

        // A STALE seed from an editor that has been open across the preset:
        // different ids, different spans, a value nobody asked for.
        let stale = PitchEditSet(segments: [
            NoteSegment(startSeconds: 9, endSeconds: 9.5, detectedHz: 440,
                        detectedConfidence: 0.9, pitchOffsetCents: 1_200)
        ])
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: realTarget,
                                             offsetCents: 11, seedIfAbsent: stale)

        let after = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(after.segments.count == real.segments.count)
        #expect(after.segments.map(\.id) == real.segments.map(\.id))
        #expect(!after.segments.contains(where: { $0.startSeconds == 9 }))
        #expect(after.segments[0].pitchOffsetCents == 11)
        // POSITIVE CONTROL for the whole test: on a clip with NO table the same
        // stale seed IS adopted, so "it was ignored" is a measurement rather
        // than a seed the store never looks at.
        let (store2, engine2, clip2, url2) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url2); _ = engine2 }
        _ = try store2.setClipNotePitchOffset(clipId: clip2.id,
                                              segmentId: stale.segments[0].id,
                                              offsetCents: 11, seedIfAbsent: stale)
        let adopted = try #require(try store2.pitchEdits(forClipId: clip2.id))
        #expect(adopted.segments.count == 1)
        #expect(adopted.segments[0].startSeconds == 9)
    }

    @Test("C1: no table and no seed is a REFUSAL with teaching text, not a silent no-op")
    func setNotePitchWithoutATableRefuses() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        var message = ""
        do {
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: UUID(),
                                                 offsetCents: 10)
            Issue.record("a clip with no note table accepted a per-note edit")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("no notes to edit yet"))
        #expect(message.contains("clip.autoCorrectPitch"))
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
    }

    @Test("C1: an unknown segment id names the count it DID find")
    func setNotePitchUnknownSegmentNamesTheCount() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        var message = ""
        do {
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: UUID(),
                                                 offsetCents: 10, seedIfAbsent: seed)
            Issue.record("an unknown segment id was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("2 note(s)"))
        // ⛔ AND NOTHING WAS WRITTEN. A refusal that half-committed would be
        // worse than one that did nothing.
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
    }

    @Test("C1: a MIDI clip and a comp member are both refused")
    func setNotePitchRefusesMidiAndCompMembers() throws {
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let store = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(throws: ProjectError.self) {
            _ = try store.setClipNotePitchOffset(clipId: midi.id, segmentId: UUID(),
                                                 offsetCents: 5,
                                                 seedIfAbsent: PitchEditSet(segments: [
                                                    NoteSegment(startSeconds: 0, endSeconds: 1,
                                                                detectedHz: 220,
                                                                detectedConfidence: 0.9)]))
        }
    }

    @Test("C1: the undo key is PER SEGMENT — one note coalesces, two notes do not")
    func perSegmentUndoKeys() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        let a = seed.segments[0].id, b = seed.segments[1].id

        let before = store.undoHistory().undo.count
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: a,
                                             offsetCents: -10, seedIfAbsent: seed)
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: a, offsetCents: -20)
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: a, offsetCents: -30)
        let afterOneNote = store.undoHistory().undo.count
        #expect(afterOneNote == before + 1,
                "three drags of ONE note inside the coalescing window must be ONE undo step")

        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: b, offsetCents: 15)
        #expect(store.undoHistory().undo.count == afterOneNote + 1,
                "a different note must start a NEW undo step — that is what the key is for")
        #expect(store.undoHistory().undo.first == "Tune Note")
    }

    @Test("C1: writing the offset a note already carries records NO undo entry")
    func aNoOpWriteIsSilent() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[0].id,
                                             offsetCents: -10, seedIfAbsent: seed)
        let depth = store.undoHistory().undo.count
        // Same value again — and a DIFFERENT undo key would be needed for this
        // to be a fair test, so use the other note at ITS current value too.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[1].id,
                                             offsetCents: 0)
        #expect(store.undoHistory().undo.count == depth,
                "a write of the value already stored must journal nothing")
    }

    @Test("C3: a split makes two notes that tile the parent exactly, and both keep its edits")
    func splitCarriesEveryEditFieldTheParentHad() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let detection = longNoteResult(seconds: 1.0, hz: 220)
        var seed = seedTable(detection)
        #expect(seed.segments.count == 1)
        // A parent carrying EVERY edit field this build has, at a non-default
        // value, so a dropped carry is visible rather than coincidentally equal.
        // U-A: `origin` is a `let`, so the parent is REBUILT as a sound: a
        // `.detected` parent would pass the carry check trivially (the
        // default on both sides).
        let detectedParent = seed.segments[0]
        var parent = NoteSegment(id: detectedParent.id,
                                 startSeconds: detectedParent.startSeconds,
                                 endSeconds: detectedParent.endSeconds,
                                 detectedHz: detectedParent.detectedHz,
                                 detectedConfidence: detectedParent.detectedConfidence,
                                 origin: .unpitched)
        parent.pitchOffsetCents = -44
        parent.driftScale = 0.25
        parent.vibratoScale = 0.5
        parent.formantOffsetSemitones = 3
        parent.amplitudeDb = -2.5
        // C5a-2: a GENERATED wobble with a fade, so rate, depth and the phase
        // anchor are carried by the round trip (checked by the census below,
        // not trivially at their defaults) and the onset is RE-DERIVED on the
        // right half (§11.1), which is why it joins `changeable`.
        parent.vibratoRateHz = 5.5
        parent.vibratoDepthCents = 40
        parent.vibratoOnsetSeconds = 0.25
        parent.vibratoPhaseAnchorSeconds = 0.37
        // I7a: a cleared note split in two is two cleared halves. The right
        // half is carried through the Codable round trip (`reidentified`).
        parent.isCleared = true
        // C5b-1: a DRAWN shape, so both shape fields are at non-default
        // values. C5b-3a: across the note's WHOLE grid span (the one grid
        // rule, `NoteShapeSamples.gridSpan`), so each half's slice is
        // non-empty and the per-half storage assertions below compare real
        // samples rather than two clears.
        let parentSpan = NoteShapeSamples.gridSpan(of: parent)
        parent.shapeStartIndex = parentSpan.lowerBound
        parent.shapeTenthsOfCents = parentSpan.map { Int16(($0 - parentSpan.lowerBound) % 40 * 25 - 490) }
        seed = PitchEditSet(segments: [parent])
        let parentID = parent.id
        let cut = (parent.startSeconds + parent.endSeconds) / 2

        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parentID,
                                           atSourceSecond: cut, seedIfAbsent: seed)

        let stored = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(stored.segments.count == 2)
        let left = try #require(stored.segments.first(where: { $0.id == parentID }))
        let right = try #require(stored.segments.first(where: { $0.id != parentID }))

        // ⛔ THE PHYSICS: the two halves TILE the parent — same start, same end,
        // meeting exactly at the cut. A split that lost a millisecond would
        // leave a hole the curve reads as "no note here".
        #expect(left.startSeconds == parent.startSeconds)
        #expect(left.endSeconds == cut)
        #expect(right.startSeconds == cut)
        #expect(right.endSeconds == parent.endSeconds)

        // Every edit field, on BOTH halves. The right half is built by a
        // `Codable` round trip precisely so this list cannot silently go stale.
        for half in [left, right] {
            #expect(half.pitchOffsetCents == -44)
            #expect(half.driftScale == 0.25)
            #expect(half.vibratoScale == 0.5)
            #expect(half.vibratoRateHz == 5.5 && half.vibratoDepthCents == 40)
            #expect(half.vibratoPhaseAnchorSeconds == 0.37, "a split re-phased one half's wobble")
            #expect(half.formantOffsetSemitones == 3)
            #expect(half.amplitudeDb == -2.5)
            #expect(half.isCleared, "a split dropped the clear on one half")
            #expect(half.origin == .unpitched, "a split turned one half of a sound into a note")
            #expect(half.detectedHz == parent.detectedHz)
            #expect(half.detectedConfidence == parent.detectedConfidence)
        }
        // ⭐ C5b-3a (design §5.3): the drawing is SLICED BY INDEX at
        // `ceil(cut · 100)`, never copied — each half holds exactly its own
        // grid span, and together they hold the parent's samples, in order.
        // (Its own storage gate, with the plant, is
        // `splitStoresEachHalfsOwnGridSpan` below.)
        let k = NoteShapeSamples.gridIndex(atOrAfter: cut)
        let leftCount = k - parent.shapeStartIndex
        try #require(leftCount > 0 && leftCount < parent.shapeTenthsOfCents.count,
                     "precondition: the cut falls inside the drawing")
        #expect(left.shapeStartIndex == parent.shapeStartIndex)
        #expect(left.shapeTenthsOfCents == Array(parent.shapeTenthsOfCents[..<leftCount]),
                "the left half does not hold exactly its own grid span of the drawing")
        #expect(right.shapeStartIndex == k)
        #expect(right.shapeTenthsOfCents == Array(parent.shapeTenthsOfCents[leftCount...]),
                "the right half does not hold exactly its own grid span of the drawing")
        #expect(left.id != right.id)
        // C5a-2 §11.1: the ONE re-derived field. The left half keeps the
        // parent's fade; the right half keeps only what was LEFT of it at the
        // cut (the cut is 0.5 s in, past the 0.25 s fade, so nothing is).
        #expect(left.vibratoOnsetSeconds == 0.25)
        #expect(right.vibratoOnsetSeconds == max(0, 0.25 - (cut - parent.startSeconds)))
        #expect(right.vibratoOnsetSeconds == 0)

        // ⭐ THE FIELD CENSUS BY METHOD RATHER THAN BY HAND-LIST — AND ITS
        // EXACT LIMIT, SAID OUT LOUD. `Mirror` enumerates `NoteSegment`'s
        // stored properties and the loop asserts every one except the three a
        // split may change is equal across parent and right half.
        //
        // ⚠️ **THIS DOES NOT PROVE A FIELD ADDED TOMORROW IS CARRIED**, and it
        // would be easy to write that it does: a new field sits at its DEFAULT
        // on both sides, so equality holds trivially and the loop passes while
        // the value is dropped. What this catches is a field the test can SET
        // being lost, plus a shape change (the counts must agree). **The real
        // guarantee is in the implementation**, where the right half is built
        // by the type's own `encode`/`init(from:)` rather than a hand-listed
        // argument list — there is no line there for a new field to be missing
        // from. This is the check on that claim, not a second source of it.
        // C5a-2 (§11.1) adds `vibratoOnsetSeconds`: re-derived, asserted above.
        // C5b-3a (§5.3) adds both drawn-shape fields: sliced, asserted above.
        let changeable: Set<String> = ["id", "startSeconds", "endSeconds", "vibratoOnsetSeconds",
                                       "shapeStartIndex", "shapeTenthsOfCents"]
        let parentFields = Mirror(reflecting: parent).children
        let rightFields = Mirror(reflecting: right).children
        #expect(parentFields.count == rightFields.count)
        for (p, r) in zip(parentFields, rightFields) {
            let label = p.label ?? "?"
            guard !changeable.contains(label) else { continue }
            #expect(String(describing: p.value) == String(describing: r.value),
                    "\(label) was not carried onto the right half of a split")
        }
    }

    /// UA-2 (unpitched-notes design §1.4): a split carries `origin`, a `let`,
    /// through `reidentified`'s Codable round trip. The parent is a REAL sung
    /// slide, stamped by the editor builder rather than rebuilt by hand, so
    /// this checks the stamp that ships. (The test above carries `.unpitched`.)
    @Test("UA-2: splitting a sung slide leaves BOTH halves .transition, and no other note changes")
    func splitOfASlideKeepsItsOriginOnBothHalves() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = PitchNoteTable.detected(from: SlideOriginStampTests.phrase())
        let slides = seed.segments.filter { $0.origin == .transition }
        try #require(slides.count == 3, "positive control: the phrase has three stamped slides")
        // The link between the two held notes: 12 frames, so each half clears
        // the 60 ms floor.
        let parent = slides[1]
        let cut = (parent.startSeconds + parent.endSeconds) / 2

        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                           atSourceSecond: cut, seedIfAbsent: seed)

        let stored = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(stored.segments.count == seed.segments.count + 1)
        let left = try #require(stored.segments.first { $0.id == parent.id })
        let right = try #require(stored.segments.first { $0.id != parent.id && $0.startSeconds == cut })
        #expect(left.endSeconds == cut && right.endSeconds == parent.endSeconds)
        for half in [left, right] {
            #expect(half.origin == .transition, "a split turned half of a slide into a held note")
            #expect(half.glideFollow == parent.glideFollow, "a split dropped the slide's follow")
        }
        // Every other segment keeps its id and its origin.
        let others = stored.segments.filter { $0.id != left.id && $0.id != right.id }
        let unsplit = seed.segments.filter { $0.id != parent.id }
        #expect(others.map(\.id) == unsplit.map(\.id))
        #expect(others.map(\.origin) == unsplit.map(\.origin))
    }

    @Test("C3: a cut too near an edge is REFUSED in words, and the table is untouched")
    func splitRefusesASliverAndChangesNothing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(longNoteResult(seconds: 1.0))
        let parent = seed.segments[0]
        // Seed the table with a real (legal) split first, so there IS something
        // to be damaged by the refusal.
        _ = try store.splitClipNoteSegment(
            clipId: clip.id, segmentId: parent.id,
            atSourceSecond: parent.startSeconds + 0.5, seedIfAbsent: seed)
        let before = try #require(try store.pitchEdits(forClipId: clip.id))

        var message = ""
        do {
            _ = try store.splitClipNoteSegment(
                clipId: clip.id, segmentId: parent.id,
                atSourceSecond: parent.startSeconds + 0.01)    // 10 ms < the 60 ms floor
            Issue.record("a 10 ms half was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("60 ms"))
        #expect(message.contains("too short to split"))
        let after = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(after == before, "a refused split must leave the table byte-identical")

        // POSITIVE CONTROL: a cut the same distance from the OTHER side of the
        // floor is accepted — so the refusal is the floor talking, not the op
        // refusing everything.
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                           atSourceSecond: parent.startSeconds + 0.2)
        #expect(try store.pitchEdits(forClipId: clip.id)?.segments.count == 3)
    }

    @Test("C3: a split is STRUCTURAL — two cuts in a row are two undo steps")
    func splitsNeverCoalesce() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(longNoteResult(seconds: 1.0))
        let parent = seed.segments[0]
        let before = store.undoHistory().undo.count
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                           atSourceSecond: parent.startSeconds + 0.3,
                                           seedIfAbsent: seed)
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                           atSourceSecond: parent.startSeconds + 0.15)
        #expect(store.undoHistory().undo.count == before + 2)
        #expect(store.undoHistory().undo.first == "Split Note")
        #expect(try store.pitchEdits(forClipId: clip.id)?.segments.count == 3)
    }

    @Test("C3: the halves are INDEPENDENT — tuning one leaves the other where it was")
    func splitHalvesTuneIndependently() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(longNoteResult(seconds: 1.0))
        let parent = seed.segments[0]
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                           atSourceSecond: parent.startSeconds + 0.5,
                                           seedIfAbsent: seed)
        let table = try #require(try store.pitchEdits(forClipId: clip.id))
        let right = try #require(table.segments.first(where: { $0.id != parent.id }))

        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: right.id,
                                             offsetCents: 120)
        let after = try #require(try store.pitchEdits(forClipId: clip.id))
        #expect(after.segments.first(where: { $0.id == right.id })?.pitchOffsetCents == 120)
        #expect(after.segments.first(where: { $0.id == parent.id })?.pitchOffsetCents == 0)
    }

    // MARK: - m23-ap C-F3 — "hand-edited since the last preset?" (F22)
    //
    // `PitchEditSet.hasHandEditsSinceAutoCorrect` is the ONE question both preset
    // doors ask before `autoCorrectClipPitch` replaces a clip's notes. It must be
    // FALSE for a preset's own output (or comparing presets asks every time) and
    // TRUE after any hand edit (or a preset erases it silently). Every assertion
    // reads the set back out of the store.

    private func storedSet(_ store: ProjectStore, clip index: Int = 0) throws -> PitchEditSet {
        try #require(store.tracks[0].clips[index].pitchEdits)
    }

    @Test("C-F3: FALSE after a preset, TRUE after a hand move, FALSE again after another preset")
    func handEditSignalFollowsPresetsAndHandMoves() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()

        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let natural = try storedSet(store)
        #expect(natural.autoCorrectStamp != nil, "the preset did not stamp what it wrote")
        #expect(natural.hasHandEditsSinceAutoCorrect == false,
                "a clip holding ONLY a preset's output reads as hand-edited, so every preset switch would ask")
        // ⭐ WHY `isEdited` COULD NOT BE THE QUESTION: the preset's own output
        // already sets per-note fields, so "edited" is true before any hand has
        // touched it.
        let presetOutputIsEdited = natural.segments.contains(where: \.isEdited)
        #expect(presetOutputIsEdited)

        let target = natural.segments[0]
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: target.id,
                                             offsetCents: target.pitchOffsetCents + 50)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == true,
                "a note moved by hand reads as untouched, so the next preset would erase it with no warning (F22)")

        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.tight.options())
        let tight = try storedSet(store)
        #expect(tight.hasHandEditsSinceAutoCorrect == false,
                "after a fresh preset the clip still reads as hand-edited, so comparing presets would ask every time")
        // The second preset really did write a DIFFERENT table, so the false
        // above is a new stamp over new notes, not a write that never happened.
        #expect(tight.segments.map(\.pitchOffsetCents) != natural.segments.map(\.pitchOffsetCents))
        #expect(tight.autoCorrectStamp != natural.autoCorrectStamp)
    }

    @Test("C-F3: a note SPLIT by hand reads as hand-edited")
    func aSplitIsAHandEdit() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = longNoteResult(seconds: 1.0, hz: 225)
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let preset = try storedSet(store)
        #expect(preset.hasHandEditsSinceAutoCorrect == false)
        let note = try #require(preset.segments.first)

        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: note.id,
                                           atSourceSecond: (note.startSeconds + note.endSeconds) / 2)
        let after = try storedSet(store)
        #expect(after.segments.count == preset.segments.count + 1)
        // The split rebuilds the set through `PitchEditSet.init`, which drops the
        // stamp. That reads as "hand-edited" by the no-stamp rule. Kept or dropped,
        // the answer must be TRUE; pinned so it is a decision, not luck.
        #expect(after.hasHandEditsSinceAutoCorrect == true,
                "a split reads as untouched, so the next preset would silently re-merge the cut")
    }

    @Test("C-F3: move a note away and BACK and it is the preset's output again, so nothing asks")
    func moveAwayAndBackIsNotAHandEdit() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let preset = try storedSet(store)
        let note = preset.segments[1]

        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id,
                                             offsetCents: note.pitchOffsetCents - 30)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == true)
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id,
                                             offsetCents: note.pitchOffsetCents)
        // Byte-identical to what the preset wrote, stamp included: there is
        // nothing to lose, so there is nothing to ask.
        #expect(try storedSet(store) == preset)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == false)

        // And a write of the value a note ALREADY holds, on a preset's output,
        // changes neither the answer nor the undo history (the silent no-op
        // `aNoOpWriteIsSilent` pins on a seeded table, here on a stamped one).
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: preset.segments[0].id,
                                             offsetCents: preset.segments[0].pitchOffsetCents)
        #expect(store.undoHistory().undo.count == depth)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == false)
    }

    @Test("C-F3: THE CARD'S PROMISE — after a confirmed replace, Undo brings the hand edits back")
    func undoRestoresHandEditsAfterAReplace() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let target = try storedSet(store).segments[0]
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: target.id,
                                             offsetCents: target.pitchOffsetCents + 80)
        let handEdited = try storedSet(store)
        #expect(handEdited.hasHandEditsSinceAutoCorrect == true)

        // The person pressed "Replace my edits".
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.tight.options())
        let replaced = try storedSet(store)
        #expect(replaced != handEdited)

        // ⌘Z — ONE step, and the hand edit is back exactly, still reading as
        // hand-edited, so a second preset click would ask again.
        #expect(try store.undo() == "Auto-Correct Pitch")
        #expect(try storedSet(store) == handEdited,
                "Undo did not restore the hand edits the card promised it would")
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == true)
        // And redo returns the preset, quiet again.
        _ = try store.redo()
        #expect(try storedSet(store) == replaced)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == false)
    }

    @Test("C-F3: preset → Remove Tuning → preset has nothing to lose, so it never asks")
    func removeTuningLeavesNothingToProtect() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        _ = try store.clearClipPitchEdits(clipId: clip.id)
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
        // The doors ask `pitchEdits?.hasHandEditsSinceAutoCorrect == true`: nil
        // is NOT true, so a cleared clip applies straight away.
        #expect((store.tracks[0].clips[0].pitchEdits?.hasHandEditsSinceAutoCorrect == true) == false)
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.gentle.options())
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == false)
    }

    @Test("C-F3: an ARRANGE split keeps both halves quiet, because each carries the preset's set and stamp verbatim")
    func arrangeSplitHalvesStayPresetOutput() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let preset = try storedSet(store)

        let (left, right) = try store.splitClip(trackId: store.tracks[0].id, clipId: clip.id,
                                                atBeat: 4)
        #expect(store.tracks[0].clips.count == 2)
        for half in [left.id, right.id] {
            let set = try #require(store.tracks[0].clips.first(where: { $0.id == half })?.pitchEdits)
            #expect(set == preset, "an arrange split changed the half's set, so the stamp no longer matches")
            #expect(set.hasHandEditsSinceAutoCorrect == false,
                    "cutting a clip in two reads as a hand edit, so presets on either half would ask")
        }
        // A preset on one half is still the machine's own output.
        _ = try await store.autoCorrectClipPitch(clipId: right.id,
                                                 options: PitchCorrectionPreset.tight.options())
        let rightSet = try #require(store.tracks[0].clips.first(where: { $0.id == right.id })?.pitchEdits)
        #expect(rightSet.hasHandEditsSinceAutoCorrect == false)
    }

    @Test("C-F3: a table the note editor seeded, then edited by hand (no preset ever), reads as hand-edited")
    func aSeededHandEditIsAHandEdit() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[0].id,
                                             offsetCents: -25, seedIfAbsent: seed)
        let stored = try storedSet(store)
        #expect(stored.autoCorrectStamp == nil)
        #expect(stored.hasHandEditsSinceAutoCorrect == true,
                "notes moved by hand on a never-tuned clip read as a preset's output, so the first preset would erase them silently")
    }

    // MARK: - I7a: clear a note in place (`setClipNotesCleared`)

    /// Four notes, the third at −6 dB so a Restore has a level of its own to
    /// come back to. Built by hand: the store never inspects detection here.
    private func fourNoteTable() -> PitchEditSet {
        var segments: [NoteSegment] = []
        for index in 0..<4 {
            let start: Double = Double(index) * 0.5
            let hz: Double = 220 + Double(index) * 20
            let level: Double = index == 2 ? -6 : 0
            segments.append(NoteSegment(startSeconds: start, endSeconds: start + 0.4,
                                        detectedHz: hz, detectedConfidence: 0.9,
                                        amplitudeDb: level))
        }
        return PitchEditSet(segments: segments)
    }

    @Test("I7a: clearing three notes is ONE undo step, moves nothing else, and undo brings all three back")
    func clearingNNotesIsOneUndoStep() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        // Store the table first with an unrelated edit, so "before" is a real
        // stored state and not nil.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[3].id,
                                             offsetCents: 12, seedIfAbsent: seed)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count
        let named = seed.segments[0...2].map(\.id)

        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: named, cleared: true)

        #expect(store.undoHistory().undo.count == depth + 1, "three notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Clear Notes")
        // READ IT BACK OUT OF THE STORE.
        let after = try storedSet(store)
        #expect(after.segments.filter(\.isCleared).map(\.id) == named)
        // ⭐ THE INVARIANCE CONTROL: apart from the flag, every field of every
        // note is exactly what it was. Nothing moved, no level was written.
        #expect(after.segments.count == before.segments.count)
        for (now, was) in zip(after.segments, before.segments) {
            var flagRestored = now
            flagRestored.isCleared = was.isCleared
            #expect(flagRestored == was, "clearing changed more than the flag on \(now.id)")
        }
        // A deliberate on/off never coalesces: a second clear is a second step.
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [seed.segments[3].id],
                                          cleared: true)
        #expect(store.undoHistory().undo.count == depth + 2)

        #expect(try store.undo() == "Clear Notes")
        #expect(try store.undo() == "Clear Notes")
        #expect(try storedSet(store) == before, "undo did not bring the notes back")
        #expect(try storedSet(store).segments.allSatisfy { !$0.isCleared })
    }

    @Test("I7a: Restore brings a note back at its OWN level, never 0 dB, as 'Restore Notes'")
    func restoreKeepsTheNotesOwnLevel() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let levelled = seed.segments[2].id
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [levelled], cleared: true,
                                          seedIfAbsent: seed)
        let cleared = try #require(try storedSet(store).segments.first { $0.id == levelled })
        #expect(cleared.isCleared)
        #expect(cleared.amplitudeDb == -6, "clearing must not touch the level")

        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [levelled], cleared: false)
        #expect(store.undoHistory().undo.first == "Restore Notes")
        let restored = try #require(try storedSet(store).segments.first { $0.id == levelled })
        #expect(!restored.isCleared)
        #expect(restored.amplitudeDb == -6, "Restore must return the note's OWN level")
    }

    @Test("I7a: a clear ALONE takes an untouched clip out of the identity bypass, so it renders")
    func aClearAloneMakesTheClipRender() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        #expect(seed.isIdentity, "fixture: a detected table that bends nothing")
        #expect(!Clip(name: "c", audioFileURL: url, pitchEdits: seed).rendersThroughStretchCache)

        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [seed.segments[0].id],
                                          cleared: true, seedIfAbsent: seed)
        let stored = store.tracks[0].clips[0]
        #expect(stored.hasPitchEdits, "a cleared note is an edit: Clip.hasPitchEdits must say so")
        #expect(stored.rendersThroughStretchCache,
                "a clip with a cleared note must leave the bypass, or the note plays from the source")
        #expect(try #require(stored.pitchEdits).isPitchIdentity,
                "a clear bends no pitch: the render must be able to skip the stretcher")
    }

    @Test("I7a: a no-op journals nothing, and a repeated id is folded")
    func aNoOpClearJournalsNothing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let target = seed.segments[1].id
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [target, target],
                                          cleared: true, seedIfAbsent: seed)
        #expect(try storedSet(store).segments.filter(\.isCleared).map(\.id) == [target])
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [target], cleared: true)
        #expect(store.undoHistory().undo.count == depth,
                "clearing a note that is already cleared must journal nothing")
    }

    @Test("I7a: ALL OR NOTHING — one unknown id among several changes nothing, and names the count")
    func anUnknownIdAmongSeveralChangesNothing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [seed.segments[3].id],
                                          cleared: true, seedIfAbsent: seed)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count
        var message = ""
        do {
            _ = try store.setClipNotesCleared(clipId: clip.id,
                                              segmentIds: [seed.segments[0].id, UUID()],
                                              cleared: true)
            Issue.record("an unknown note id was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("4 note(s)"), "the refusal must name how many notes the clip DOES carry")
        #expect(try storedSet(store) == before, "a refused clear half-cleared the table")
        #expect(store.undoHistory().undo.count == depth)
    }

    @Test("I7a: the per-note setters' refusals — no table, no ids, unknown clip, MIDI clip, comp member")
    func clearSharesThePerNoteRefusals() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        func refusal(_ body: () throws -> Void) -> String {
            do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
        }
        // No stored table and no seed: the same teaching text as setNotePitch.
        let noTable = refusal {
            _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [UUID()], cleared: true)
        }
        #expect(noTable.contains("no notes to edit yet"), "\(noTable)")
        // No ids at all: refused in words, and the seed is NOT stored.
        let noIDs = refusal {
            _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [], cleared: true,
                                              seedIfAbsent: fourNoteTable())
        }
        #expect(noIDs.contains("at least one note"), "\(noIDs)")
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        // An unknown clip.
        #expect(refusal {
            _ = try store.setClipNotesCleared(clipId: UUID(), segmentIds: [UUID()], cleared: true)
        } != "ACCEPTED")
        // A MIDI clip.
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(refusal {
            _ = try midiStore.setClipNotesCleared(clipId: midi.id, segmentIds: [UUID()],
                                                  cleared: true, seedIfAbsent: fourNoteTable())
        }.contains("MIDI"))
        // A take-group comp member.
        var member = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                          audioFileURL: URL(fileURLWithPath: "/tmp/i7a-comp-member.wav"))
        member.takeGroupID = UUID()
        let memberStore = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [member])])
        let table = fourNoteTable()
        #expect(refusal {
            _ = try memberStore.setClipNotesCleared(clipId: member.id,
                                                    segmentIds: [table.segments[0].id],
                                                    cleared: true, seedIfAbsent: table)
        } != "ACCEPTED")
        #expect(memberStore.tracks[0].clips[0].pitchEdits == nil)
    }

    // MARK: - U-D: set a group of notes' level (`setClipNoteGain`)

    @Test("U-D: setting a group's level round-trips, and clamps at both ends against Clip.gainDbRange")
    func settingGainRoundTripsAndClampsAtBothEnds() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let named = seed.segments[0...1].map(\.id)

        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: named, gainDb: -6,
                                      seedIfAbsent: seed)
        let after = try storedSet(store)
        for id in named {
            #expect(after.segments.first { $0.id == id }?.amplitudeDb == -6)
        }
        // The untouched notes (index 2 carries fourNoteTable's own −6 seed,
        // index 3 is 0) are exactly what they were.
        #expect(after.segments[2].amplitudeDb == -6)
        #expect(after.segments[3].amplitudeDb == 0)

        // ⛔ CLAMPED IN THE STORE, not merely asserted in range: a direct
        // field assignment (this function's own ⛔) bypasses NoteSegment.init's
        // healing clamp entirely, so this is the test that would catch a
        // first draft that forgot the explicit `.clamped(to:)` call.
        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: named, gainDb: 999)
        let high = try storedSet(store)
        for id in named {
            #expect(high.segments.first { $0.id == id }?.amplitudeDb == Clip.gainDbRange.upperBound)
        }
        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: named, gainDb: -999)
        let low = try storedSet(store)
        for id in named {
            #expect(low.segments.first { $0.id == id }?.amplitudeDb == Clip.gainDbRange.lowerBound)
        }
    }

    @Test("U-D: N notes in one call is ONE undo step, a repeated id is folded, a no-op journals nothing, and undo restores the group")
    func settingGainOnNNotesIsOneUndoStepAndNoOpJournalsNothing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        // Store the table first with an unrelated edit, so "before" (and what
        // undo restores TO) is a real stored state and not nil — the
        // `clearingNNotesIsOneUndoStep` precedent.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[3].id,
                                             offsetCents: 12, seedIfAbsent: seed)
        let depth = store.undoHistory().undo.count
        let named = [seed.segments[0].id, seed.segments[1].id]

        // A repeated id folds to the same set of writes, still ONE step.
        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [named[0], named[1], named[0]],
                                      gainDb: -9)
        #expect(store.undoHistory().undo.count == depth + 1, "N notes, one repeated, must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Set Note Level")
        for id in named {
            #expect(try storedSet(store).segments.first { $0.id == id }?.amplitudeDb == -9)
        }

        // A no-op — writing the SAME value again — journals nothing.
        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: named, gainDb: -9)
        #expect(store.undoHistory().undo.count == depth + 1,
                "setting notes to the level they already carry must journal nothing")

        #expect(try store.undo() == "Set Note Level")
        for (index, id) in named.enumerated() {
            let expected = seed.segments[index].amplitudeDb  // both 0 dB in fourNoteTable
            #expect(try storedSet(store).segments.first { $0.id == id }?.amplitudeDb == expected,
                    "undo did not restore the group's pre-edit level")
        }
    }

    @Test("U-D: a level alone takes an untouched clip out of the identity bypass, so it renders, without touching pitch")
    func aLevelAloneMakesTheClipRenderAndIsAnEdit() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        #expect(seed.isIdentity, "fixture: a detected table that bends nothing")
        #expect(!Clip(name: "c", audioFileURL: url, pitchEdits: seed).rendersThroughStretchCache)

        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [seed.segments[0].id],
                                      gainDb: -6, seedIfAbsent: seed)
        let stored = store.tracks[0].clips[0]
        #expect(stored.hasPitchEdits, "a leveled note is an edit: Clip.hasPitchEdits must say so")
        #expect(stored.rendersThroughStretchCache,
                "a clip with a leveled note must leave the bypass, or the note plays unleveled")
        #expect(try #require(stored.pitchEdits).isPitchIdentity,
                "a level bends no pitch: the render must be able to skip the stretcher")
        #expect(try #require(stored.pitchEdits).isIdentity == false,
                "the SET-level isIdentity (segments.allSatisfy(.isIdentity)) must see the level too")
    }

    @Test("U-D: ALL OR NOTHING, and the per-note setters' shared refusals — no table, no ids, unknown clip, MIDI clip, comp member")
    func gainSharesThePerNoteRefusalsAndAllOrNothing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        func refusal(_ body: () throws -> Void) -> String {
            do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
        }
        // No stored table and no seed: the same teaching text as setNotePitch.
        let noTable = refusal {
            _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [UUID()], gainDb: -6)
        }
        #expect(noTable.contains("no notes to edit yet"), "\(noTable)")
        // No ids at all: refused in words, and the seed is NOT stored.
        let noIDs = refusal {
            _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [], gainDb: -6,
                                          seedIfAbsent: fourNoteTable())
        }
        #expect(noIDs.contains("at least one note"), "\(noIDs)")
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        // An unknown clip.
        #expect(refusal {
            _ = try store.setClipNoteGain(clipId: UUID(), segmentIds: [UUID()], gainDb: -6)
        } != "ACCEPTED")
        // A MIDI clip.
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(refusal {
            _ = try midiStore.setClipNoteGain(clipId: midi.id, segmentIds: [UUID()],
                                              gainDb: -6, seedIfAbsent: fourNoteTable())
        }.contains("MIDI"))
        // A take-group comp member.
        var member = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                          audioFileURL: URL(fileURLWithPath: "/tmp/u-d-comp-member.wav"))
        member.takeGroupID = UUID()
        let memberStore = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [member])])
        let table = fourNoteTable()
        #expect(refusal {
            _ = try memberStore.setClipNoteGain(clipId: member.id,
                                                segmentIds: [table.segments[0].id],
                                                gainDb: -6, seedIfAbsent: table)
        } != "ACCEPTED")
        #expect(memberStore.tracks[0].clips[0].pitchEdits == nil)

        // ALL OR NOTHING: an unknown id among real ones changes nothing, and
        // the refusal names how many notes the clip DOES carry. `clip`'s
        // table is still nil at this point (neither refusal above wrote to
        // it), so this seeds it fresh.
        let seed = fourNoteTable()
        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [seed.segments[3].id],
                                      gainDb: -2, seedIfAbsent: seed)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count
        var message = ""
        do {
            _ = try store.setClipNoteGain(clipId: clip.id,
                                          segmentIds: [seed.segments[0].id, UUID()],
                                          gainDb: -2)
            Issue.record("an unknown note id was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("4 note(s)"), "the refusal must name how many notes the clip DOES carry")
        #expect(try storedSet(store) == before, "a refused level-set half-wrote the table")
        #expect(store.undoHistory().undo.count == depth)
    }

    // MARK: - I4: a group pitch drag (`setClipNotePitchOffsets`)

    private func offsets(_ pairs: [(UUID, Double)]) -> [NotePitchOffset] {
        pairs.map { NotePitchOffset(segmentId: $0.0, offsetCents: $0.1) }
    }

    @Test("I4: N notes in one call is ONE 'Tune Notes' step, each lands at its OWN offset, nothing else moves, and undo restores all N")
    func groupPitchIsOneUndoStepAndUndoRestoresAllN() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        // Store the table first with an unrelated edit, so "before" is a real
        // stored state (the `clearingNNotesIsOneUndoStep` precedent).
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: seed.segments[3].id,
                                             offsetCents: 12, seedIfAbsent: seed)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count
        let ids = seed.segments.map(\.id)
        let key = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID())

        // A group drag of +200 cents over notes 0-2: each lands at its own
        // absolute value (all start at 0 here, so 200 each).
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 200), (ids[1], 200), (ids[2], 200)]),
            undoKey: key)
        #expect(store.undoHistory().undo.count == depth + 1, "three notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Tune Notes")
        // READ IT BACK OUT OF THE STORE.
        let after = try storedSet(store)
        #expect(after.segments.prefix(3).map(\.pitchOffsetCents) == [200, 200, 200])
        // ⭐ THE INVARIANCE CONTROL: apart from the offset, every field of every
        // note is exactly what it was, and the fourth note did not move at all.
        #expect(after.segments.count == before.segments.count)
        for (now, was) in zip(after.segments, before.segments) {
            var restored = now
            restored.pitchOffsetCents = was.pitchOffsetCents
            #expect(restored == was, "a group pitch write changed more than the offset on \(now.id)")
        }
        #expect(after.segments[3].pitchOffsetCents == 12)

        #expect(try store.undo() == "Tune Notes")
        #expect(try storedSet(store) == before, "undo did not bring all three notes back")
    }

    @Test("I4: the group key coalesces a second drag of the SAME selection, and not a different selection (UI design §8.4)")
    func groupKeyCoalescesTheSameSelectionOnly() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let ids = seed.segments.map(\.id)
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: ids[3],
                                             offsetCents: 12, seedIfAbsent: seed)
        let untouched = try storedSet(store)
        let depth = store.undoHistory().undo.count
        let sameSelection = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID())

        // Two drags of the SAME selection inside the journal's window.
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 100), (ids[1], 100)]), undoKey: sameSelection)
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 300), (ids[1], 300)]), undoKey: sameSelection)
        #expect(store.undoHistory().undo.count == depth + 1,
                "a second drag of the SAME selection must coalesce into one step (§8.4)")
        let afterSameSelection = try storedSet(store)

        // A DIFFERENT selection (a new token) starts a new step.
        let otherSelection = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID())
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[1], 500), (ids[2], 200)]), undoKey: otherSelection)
        #expect(store.undoHistory().undo.count == depth + 2,
                "a drag of a DIFFERENT selection must start a new undo step")
        // ⚠️ AND NOT THE SEGMENT KEY OF A MEMBER: a one-note drag of note 1 right
        // after is its own step too, never folded into the group's.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: ids[1], offsetCents: 600)
        #expect(store.undoHistory().undo.count == depth + 3)

        // Undo walks back one DECISION per step: the one-note drag, the other
        // selection, then BOTH drags of the first selection at once.
        #expect(try store.undo() == "Tune Note")
        #expect(try store.undo() == "Tune Notes")
        #expect(try storedSet(store) == afterSameSelection)
        #expect(try store.undo() == "Tune Notes")
        #expect(try storedSet(store) == untouched,
                "one undo must take back BOTH coalesced drags of the same selection")
        // The key strings themselves: distinct per token, and never a segment key.
        #expect(sameSelection != otherSelection)
        #expect(sameSelection.hasPrefix("pitch.group:"))
        #expect(sameSelection != PitchCorrectionUndoKey.segment(clipID: clip.id, segmentID: ids[0]))
    }

    @Test("I4: a no-op journals nothing; a repeated id is folded when it agrees and REFUSED when it does not")
    func groupPitchNoOpAndRepeatedIds() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let ids = seed.segments.map(\.id)
        let key = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID())
        // A repeated id with the SAME value folds: one step, one write.
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 100), (ids[1], -50), (ids[0], 100)]),
            seedIfAbsent: seed, undoKey: key)
        #expect(try storedSet(store).segments[0].pitchOffsetCents == 100)
        #expect(try storedSet(store).segments[1].pitchOffsetCents == -50)
        let depth = store.undoHistory().undo.count

        // ⭐ A NO-OP JOURNALS NOTHING — under a FRESH key, so coalescing cannot
        // be what hides the entry: the notes already sit at these offsets.
        let fresh = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID())
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 100), (ids[1], -50)]), undoKey: fresh)
        #expect(store.undoHistory().undo.count == depth,
                "writing the offsets the notes already carry must journal nothing")
        // POSITIVE CONTROL: the same call with ONE value changed does journal.
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(ids[0], 100), (ids[1], -40)]), undoKey: fresh)
        #expect(store.undoHistory().undo.count == depth + 1)

        // A repeated id with two DIFFERENT values is refused in words, and
        // nothing is written.
        let beforeConflict = try storedSet(store)
        var message = ""
        do {
            _ = try store.setClipNotePitchOffsets(
                clipId: clip.id, offsets: offsets([(ids[2], 100), (ids[2], 200)]),
                undoKey: PitchCorrectionUndoKey.structuralKey)
            Issue.record("a note named twice with two pitches was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("named twice"), "\(message)")
        #expect(try storedSet(store) == beforeConflict)
    }

    @Test("I4: every offset is CLAMPED to the pitch range, per note, at both ends")
    func groupPitchClampsEachNote() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = fourNoteTable()
        let ids = seed.segments.map(\.id)
        let range = NoteSegment.pitchOffsetCentsRange
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id,
            offsets: offsets([(ids[0], 99_999), (ids[1], -99_999), (ids[2], .nan), (ids[3], 250)]),
            seedIfAbsent: seed, undoKey: PitchCorrectionUndoKey.structuralKey)
        let stored = try storedSet(store).segments
        #expect(stored[0].pitchOffsetCents == range.upperBound)
        #expect(stored[1].pitchOffsetCents == range.lowerBound)
        #expect(stored[2].pitchOffsetCents == 0, "a non-finite offset must land as 0, never NaN")
        // CONTROL: an in-range value is written verbatim.
        #expect(stored[3].pitchOffsetCents == 250)
    }

    @Test("I4: ALL OR NOTHING, and the per-note setters' shared refusals — no ids, unknown note, unknown clip, MIDI clip, no table and no seed, comp member")
    func groupPitchSharesThePerNoteRefusals() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        func refusal(_ body: () throws -> Void) -> String {
            do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
        }
        let key = PitchCorrectionUndoKey.structuralKey
        // No stored table and no seed: the same teaching text as setNotePitch.
        let noTable = refusal {
            _ = try store.setClipNotePitchOffsets(clipId: clip.id, offsets: offsets([(UUID(), 100)]),
                                                  undoKey: key)
        }
        #expect(noTable.contains("no notes to edit yet"), "\(noTable)")
        // No notes named: refused in words, and the seed is NOT stored.
        let noIDs = refusal {
            _ = try store.setClipNotePitchOffsets(clipId: clip.id, offsets: [],
                                                  seedIfAbsent: fourNoteTable(), undoKey: key)
        }
        #expect(noIDs.contains("at least one note"), "\(noIDs)")
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        // An unknown clip.
        #expect(refusal {
            _ = try store.setClipNotePitchOffsets(clipId: UUID(), offsets: offsets([(UUID(), 1)]),
                                                  undoKey: key)
        } != "ACCEPTED")
        // A MIDI clip.
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(refusal {
            _ = try midiStore.setClipNotePitchOffsets(clipId: midi.id, offsets: offsets([(UUID(), 1)]),
                                                      seedIfAbsent: fourNoteTable(), undoKey: key)
        }.contains("MIDI"))
        // A take-group comp member.
        var member = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                          audioFileURL: URL(fileURLWithPath: "/tmp/i4-comp-member.wav"))
        member.takeGroupID = UUID()
        let memberStore = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [member])])
        let table = fourNoteTable()
        #expect(refusal {
            _ = try memberStore.setClipNotePitchOffsets(
                clipId: member.id, offsets: offsets([(table.segments[0].id, 100)]),
                seedIfAbsent: table, undoKey: key)
        } != "ACCEPTED")
        #expect(memberStore.tracks[0].clips[0].pitchEdits == nil)

        // ALL OR NOTHING: an unknown id AFTER real ones changes nothing (the
        // real ones are not half-written), and the refusal names the count.
        let seed = fourNoteTable()
        _ = try store.setClipNotePitchOffsets(clipId: clip.id,
                                              offsets: offsets([(seed.segments[3].id, 30)]),
                                              seedIfAbsent: seed, undoKey: key)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count
        var message = ""
        do {
            _ = try store.setClipNotePitchOffsets(
                clipId: clip.id,
                offsets: offsets([(seed.segments[0].id, 100), (seed.segments[1].id, 100), (UUID(), 100)]),
                undoKey: key)
            Issue.record("an unknown note id was accepted")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("4 note(s)"), "the refusal must name how many notes the clip DOES carry")
        #expect(try storedSet(store) == before, "a refused group write half-wrote the table")
        #expect(store.undoHistory().undo.count == depth)
    }

    @Test("I4: the FIRST group edit on an untuned clip seeds the table verbatim, so the editor's ids survive")
    func groupPitchSeedsVerbatim() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = seedTable(melodicResult())
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: offsets([(seed.segments[0].id, 100), (seed.segments[1].id, 100)]),
            seedIfAbsent: seed,
            undoKey: PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: UUID()))
        let stored = try storedSet(store)
        // The ids the editor drew and selected are the ids that were saved.
        #expect(stored.segments.map(\.id) == seed.segments.map(\.id))
        #expect(stored.segments.map(\.pitchOffsetCents) == [100, 100])
    }

    // MARK: - Natural tuning C0: every DAWCore writer carries every field (X2)

    /// `fourNoteTable()` with every set-level field off legacy AND off the
    /// seed (`NaturalTuningFieldCarryTests.nonLegacy`), and the first note's
    /// two natural-tuning fields off their defaults.
    private func naturalTuningSeed() -> PitchEditSet {
        var seed = NaturalTuningFieldCarryTests.nonLegacy(fourNoteTable())
        seed.segments[0].transitionOutMs = 150
        seed.segments[0].glideFollow = 0.5
        return seed
    }

    /// ⭐ X2 rule 4's STORE half (the pure half, and the census that keeps this
    /// honest, is `NaturalTuningFieldCarryTests`). Each writer runs on a fresh
    /// store seeded with the SAME non-legacy table, and every set-level field
    /// is compared by `Mirror`, so a field added tomorrow is compared without
    /// this test changing. `autoCorrectClipPitch` is deliberately absent: it
    /// SEEDS a new set (`PitchEditSet.seeded`), it does not carry one.
    @Test("NT-C C0: every note writer keeps every set-level field and the note's own new fields (X2 carry)")
    func naturalTuningFieldsSurviveEveryWriter() throws {
        let seed = naturalTuningSeed()
        let first = seed.segments[0].id
        let expected = NaturalTuningFieldCarryTests.setLevelFields(seed)
        // The comparison is not trivially true: the seed departs from legacy.
        #expect(expected != NaturalTuningFieldCarryTests.setLevelFields(.empty))
        let writers: [(String, (ProjectStore, UUID) throws -> Void)] = [
            ("setClipNotePitchOffset", { store, clip in
                _ = try store.setClipNotePitchOffset(clipId: clip, segmentId: first,
                                                     offsetCents: 50, seedIfAbsent: seed) }),
            ("setClipNotePitchOffsets", { store, clip in
                _ = try store.setClipNotePitchOffsets(
                    clipId: clip, offsets: [NotePitchOffset(segmentId: first, offsetCents: -50)],
                    seedIfAbsent: seed, undoKey: PitchCorrectionUndoKey.structuralKey) }),
            ("splitClipNoteSegment", { store, clip in
                _ = try store.splitClipNoteSegment(clipId: clip, segmentId: first,
                                                   atSourceSecond: 0.2, seedIfAbsent: seed) }),
            ("setClipNotesCleared", { store, clip in
                _ = try store.setClipNotesCleared(clipId: clip, segmentIds: [first],
                                                  cleared: true, seedIfAbsent: seed) }),
            ("setClipNoteGain", { store, clip in
                _ = try store.setClipNoteGain(clipId: clip, segmentIds: [first],
                                              gainDb: -6, seedIfAbsent: seed) }),
            // C5a-2 / natural tuning §3 L2: the three wobble writers.
            ("setClipNoteVibrato", { store, clip in
                _ = try store.setClipNoteVibrato(clipId: clip, segmentId: first,
                                                 edit: NoteVibratoEdit(vibratoRateHz: 5.5,
                                                                       vibratoDepthCents: 30),
                                                 seedIfAbsent: seed) }),
            ("setClipNotesVibrato", { store, clip in
                _ = try store.setClipNotesVibrato(
                    clipId: clip, edits: [NoteVibratoItem(segmentId: first,
                                                          edit: NoteVibratoEdit(driftScale: 0.3))],
                    seedIfAbsent: seed, undoKey: PitchCorrectionUndoKey.structuralKey) }),
            // A reset of an as-sung note writes nothing, so another note is
            // edited first: "wrote nothing" below would otherwise be true.
            ("resetClipNoteVibrato", { store, clip in
                _ = try store.setClipNoteVibrato(clipId: clip, segmentId: seed.segments[1].id,
                                                 edit: NoteVibratoEdit(vibratoScale: 0.5),
                                                 seedIfAbsent: seed)
                _ = try store.setClipNoteVibrato(clipId: clip, segmentId: first,
                                                 edit: NoteVibratoEdit(vibratoScale: 0.5))
                _ = try store.resetClipNoteVibrato(clipId: clip, segmentId: first) }),
            // C5b-3a: the drawn pitch line.
            ("setClipNoteShapes", { store, clip in
                _ = try store.setClipNoteShapes(
                    clipId: clip,
                    shapes: [first: NoteShapeSamples(
                        startIndex: NoteShapeSamples.gridSpan(of: seed.segments[0]).lowerBound + 5,
                        tenthsOfCents: [250, 400])],
                    seedIfAbsent: seed) }),
        ]
        for (name, write) in writers {
            let (store, engine, clip, url) = try audioStore()
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            try write(store, clip.id)
            let stored = try storedSet(store)
            #expect(stored != seed, "\(name) wrote nothing, so the carry below proves nothing")
            #expect(NaturalTuningFieldCarryTests.setLevelFields(stored) == expected,
                    "\(name) dropped a set-level field: \(NaturalTuningFieldCarryTests.setLevelFields(stored))")
            // `contains`, not `first`: C4's split rule (§4.b.5) resets the LEFT
            // half's width to Auto by design, and the RIGHT half inherits both.
            #expect(stored.segments.contains { $0.transitionOutMs == 150 && $0.glideFollow == 0.5 },
                    "\(name) dropped a note's natural-tuning fields")
        }
    }

    /// X4: THE one upgrade path. All three set-level fields to their seed
    /// values in ONE undo step, nothing else touched, refused in words when
    /// there is nothing to upgrade.
    @Test("NT-C C0: upgradeToNaturalTuning seeds the three set-level fields as ONE undo step and moves nothing else")
    func upgradeToNaturalTuningIsOneStep() throws {
        // A LEGACY tuned set, as a project saved before the feature reopens:
        // held ON the clip (`storeHolding`), because a hand-edit setter that
        // changes a note updates a legacy vocal on the way in (D4-1 (b)).
        var legacy = fourNoteTable()
        legacy.segments[1].pitchOffsetCents = 200
        legacy.retuneMs = 80
        legacy.autoCorrectStamp = "0123456789abcdef"
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let before = try storedSet(store)
        #expect(before.predatesNaturalTuning)
        let depth = store.undoHistory().undo.count

        _ = try store.upgradeToNaturalTuning(clipId: clip.id)
        let after = try storedSet(store)
        #expect(after.formantCorrection == PitchEditSet.newSetFormantCorrection)
        #expect(after.keepsConsonantsUntuned)
        #expect(after.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(!after.predatesNaturalTuning)
        // Nothing else moved: notes, retune, analysis version, stamp.
        #expect(after.segments == before.segments)
        #expect(after.retuneMs == 80 && after.analysisVersion == before.analysisVersion)
        #expect(after.autoCorrectStamp == before.autoCorrectStamp)
        #expect(store.undoHistory().undo.count == depth + 1, "the upgrade must be exactly one undo step")

        // A second tap is a no-op and journals nothing.
        _ = try store.upgradeToNaturalTuning(clipId: clip.id)
        #expect(store.undoHistory().undo.count == depth + 1)

        // Undo restores the legacy set exactly.
        _ = try store.undo()
        #expect(try storedSet(store) == before)

        // Refusals: no table, a MIDI clip, an unknown clip.
        let (bare, bareEngine, bareClip, bareURL) = try audioStore()
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        var message = ""
        do {
            _ = try bare.upgradeToNaturalTuning(clipId: bareClip.id)
            Issue.record("an untuned clip was 'upgraded'")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("no tuning"), "\(message)")
        #expect(bare.tracks[0].clips[0].pitchEdits == nil)
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(throws: ProjectError.self) { _ = try midiStore.upgradeToNaturalTuning(clipId: midi.id) }
        #expect(throws: ProjectError.self) { _ = try store.upgradeToNaturalTuning(clipId: UUID()) }
    }

    // MARK: - U-B: findUnpitchedSounds, the merge verb (unpitched-notes design §1.10)

    /// Six seconds at 62.5 fps with a real noise floor and three SOUNDS (an
    /// unvoiced stretch 30 dB above the floor):
    ///
    ///     frames    0..<75   quiet −60 dBFS  (1.2 s: the floor needs ≥ 1 s)
    ///              75..<87   SOUND 1, −30    abuts note A (borrows A, following)
    ///              87..<150  note A, 220 Hz  −20
    ///             150..<212  quiet
    ///             212..<218  SOUND 2, −30    abuts note B (borrows B, following)
    ///             218..<281  note B, 247 Hz  −20
    ///             281..<287  SOUND 3, −30    after the last note (borrows B, previous)
    ///             287..<375  quiet
    ///
    /// F = −60, V = −20 (40 dB of headroom), threshold −51: the quiet is never
    /// a sound, each −30 stretch always is.
    private func soundsResult() -> PitchDetectionResult {
        let period = 1.0 / 62.5
        let frames = (0..<375).map { i -> ClipPitchFrame in
            let time = Double(i) * period
            switch i {
            case 87..<150:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: 220, confidence: 0.95,
                                      levelDbfs: -20, absence: nil)
            case 218..<281:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: 247, confidence: 0.95,
                                      levelDbfs: -20, absence: nil)
            case 75..<87, 212..<218, 281..<287:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0.5,
                                      levelDbfs: -30, absence: .belowConfidence)
            default:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0.2,
                                      levelDbfs: -60, absence: .belowConfidence)
            }
        }
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 6,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// A table as a preset wrote it BEFORE sounds existed: today's Natural
    /// pass over `soundsResult`, its sounds removed, stamped as that pass's
    /// own output. What every clip tuned before U-A carries (F-stale).
    private func preSoundsPresetTable() -> PitchEditSet {
        let full = PitchAutoCorrect.editSet(from: soundsResult(), options: PitchAutoCorrectOptions())
        return full.withSegments(full.segments.filter { $0.origin != .unpitched })
            .stampedAsAutoCorrectOutput()
    }

    /// A store whose one clip carries `table` (or none) and whose engine
    /// detects `stub` (`soundsResult` by default). The returned URL is the
    /// clip's own file, for the caller's `defer`.
    private func soundStore(table: PitchEditSet?,
                            stub: PitchDetectionResult? = nil) throws
    -> (ProjectStore, FakePitchWriterEngine, Clip, URL) {
        let url = try makeRealAudioFile()
        let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 16, audioFileURL: url,
                        pitchEdits: table)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = FakePitchWriterEngine()
        engine.stubResult = stub ?? soundsResult()
        store.engine = engine
        return (store, engine, clip, url)
    }

    @Test("U-B: Find Sounds adds the three sounds, moves and re-identifies nothing, borrows the right note, re-stamps a preset's set, and undoes in ONE step")
    func findUnpitchedSoundsMergesIntoAPresetTable() async throws {
        let old = preSoundsPresetTable()
        #expect(old.segments.count == 2, "positive control: the old table is the two notes")
        #expect(!old.hasHandEditsSinceAutoCorrect)
        let (store, engine, clip, url) = try soundStore(table: old)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count

        let report = try await store.findUnpitchedSounds(clipId: clip.id)
        #expect(engine.detectCalls == 1)
        #expect(report.finder.skipped == nil)
        #expect(report.finder.floorDbfs == -60)
        #expect(report.finder.thresholdDbfs == -51)
        #expect(report.added == 3)

        // READ IT BACK OUT OF THE STORE.
        let stored = try storedSet(store)
        #expect(stored.segments.count == 5)
        // ⭐ THE INVARIANCE CONTROL: every stored note is exactly what it was
        // (same id, same span, same edits). Nothing moved, nothing re-keyed.
        for note in old.segments {
            #expect(stored.segments.first { $0.id == note.id } == note,
                    "the merge changed a stored note: \(note.id)")
        }
        let sounds = stored.segments.filter { $0.origin == .unpitched }
        #expect(sounds.map(\.id) == report.sounds.map(\.segmentId))
        #expect(sounds.allSatisfy { $0.isIdentity }, "a merged sound carries an edit")
        // Only uncovered time: no sound overlaps a stored note.
        for sound in sounds {
            #expect(!old.segments.contains {
                $0.startSeconds < sound.endSeconds && sound.startSeconds < $0.endSeconds
            }, "a sound was added over a stored note")
        }
        // The lenders, by stored id and side (U3: nearer, ties to the following).
        let noteA = old.segments[0], noteB = old.segments[1]
        #expect(report.sounds.map(\.borrowedFromSegmentId) == [noteA.id, noteB.id, noteB.id])
        #expect(report.sounds.map(\.borrowedFrom) == [.following, .following, .previous])
        #expect(sounds.map(\.detectedHz) == [noteA.detectedHz, noteB.detectedHz, noteB.detectedHz])
        // The same sounds a FRESH preset pass draws: one finder, two doors.
        let fresh = PitchAutoCorrect.editSet(from: soundsResult(), options: PitchAutoCorrectOptions())
            .segments.filter { $0.origin == .unpitched }
        #expect(sounds.map(\.startSeconds) == fresh.map(\.startSeconds))
        #expect(sounds.map(\.endSeconds) == fresh.map(\.endSeconds))
        #expect(sounds.map(\.detectedHz) == fresh.map(\.detectedHz))

        // THE RE-STAMP RULE: it was exactly a preset's output, so it still is.
        #expect(stored.autoCorrectStamp != old.autoCorrectStamp, "the stamp was not renewed")
        #expect(!stored.hasHandEditsSinceAutoCorrect,
                "Find Sounds made a preset's own set read as hand-edited")
        // Untouched sounds bend nothing new: the identity question is unchanged.
        #expect(stored.isPitchIdentity == old.isPitchIdentity)

        // ONE undo step, and undo is exact.
        #expect(store.undoHistory().undo.count == depth + 1)
        #expect(try store.undo() == "Find Sounds")
        #expect(try storedSet(store) == old)
    }

    @Test("U-B: Find Sounds fills ONLY uncovered time, and never borrows from a sound already stored")
    func findUnpitchedSoundsNeverBorrowsFromAStoredSound() async throws {
        let base = preSoundsPresetTable()
        let noteB = base.segments[1]
        // A stored sound Y exactly over SOUND 2's time, and a stored sound X
        // abutting SOUND 3's END at a wild anchor. SOUND 3 then touches B
        // before it and X after it: a tie, which goes to the FOLLOWING
        // neighbour, so if X could lend, SOUND 3 would borrow 400 Hz from it.
        // Frame times are spelled as the fixture spells them (`i · period`),
        // so the stored edges are bit-equal to the notes' own.
        let period = 1.0 / 62.5
        let y = NoteSegment(startSeconds: 212 * period, endSeconds: 218 * period,
                            detectedHz: 247, detectedConfidence: 0.5, origin: .unpitched)
        let x = NoteSegment(startSeconds: 287 * period, endSeconds: 300 * period,
                            detectedHz: 400, detectedConfidence: 0.5, origin: .unpitched)
        let old = base.withSegments(base.segments + [y, x])
        #expect(old.segments.count == 4)
        let (store, engine, clip, url) = try soundStore(table: old)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }

        let report = try await store.findUnpitchedSounds(clipId: clip.id)
        let stored = try storedSet(store)
        // SOUND 1 and SOUND 3 only: SOUND 2's time is already covered by Y.
        #expect(report.added == 2)
        #expect(stored.segments.count == 6)
        for note in old.segments {
            #expect(stored.segments.first { $0.id == note.id } == note)
        }
        let added = stored.segments.filter { segment in
            report.sounds.contains { $0.segmentId == segment.id }
        }
        for sound in added {
            #expect(!old.segments.contains {
                $0.startSeconds < sound.endSeconds && sound.startSeconds < $0.endSeconds
            }, "a sound was added over covered time")
        }
        // ⛔ SOUND 3 borrows the NOTE before it, never the stored sound after it.
        let last = try #require(report.sounds.last)
        #expect(last.borrowedFromSegmentId == noteB.id,
                "a sound borrowed its anchor from another sound")
        #expect(last.borrowedFrom == .previous)
        #expect(last.anchorHz == noteB.detectedHz)
    }

    @Test("U-B: the re-stamp rule never launders a hand edit, and a table no preset wrote keeps no stamp")
    func findUnpitchedSoundsKeepsAHandEditAHandEdit() async throws {
        // (a) a preset's set, then a hand move: still hand-edited after the merge.
        var handEdited = preSoundsPresetTable()
        handEdited.segments[0].pitchOffsetCents += 30
        #expect(handEdited.hasHandEditsSinceAutoCorrect)
        let (store, engine, clip, url) = try soundStore(table: handEdited)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let report = try await store.findUnpitchedSounds(clipId: clip.id)
        #expect(report.added == 3, "positive control: the merge did write")
        let stored = try storedSet(store)
        #expect(stored.autoCorrectStamp == handEdited.autoCorrectStamp)
        #expect(stored.hasHandEditsSinceAutoCorrect, "Find Sounds laundered a hand edit")

        // (b) an editor-seeded table (no preset ever): no stamp before, none after.
        let seeded = PitchNoteTable.detected(from: soundsResult())
        let seededOld = seeded.withSegments(seeded.segments.filter { $0.origin != .unpitched })
        #expect(seededOld.autoCorrectStamp == nil)
        let (store2, engine2, clip2, url2) = try soundStore(table: seededOld)
        defer { try? FileManager.default.removeItem(at: url2); _ = engine2 }
        _ = try await store2.findUnpitchedSounds(clipId: clip2.id)
        let stored2 = try storedSet(store2)
        #expect(stored2.segments.count == seededOld.segments.count + 3)
        #expect(stored2.autoCorrectStamp == nil)
    }

    @Test("U-B: finding nothing journals nothing, and the refusals are in words and change nothing")
    func findUnpitchedSoundsNothingAndRefusals() async throws {
        // Nothing to find: the fixture has no second of quiet (notEnoughQuiet).
        let quietless = PitchNoteTable.detected(from: melodicResult())
        let (store, engine, clip, url) = try soundStore(table: quietless, stub: melodicResult())
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count
        let report = try await store.findUnpitchedSounds(clipId: clip.id)
        #expect(report.finder.skipped == .notEnoughQuiet)
        #expect(report.added == 0)
        #expect(store.undoHistory().undo.count == depth, "finding nothing journalled a step")
        #expect(try storedSet(store) == quietless)

        // No stored table: refused BEFORE detection, nothing written.
        let (bare, bareEngine, bareClip, bareURL) = try soundStore(table: nil)
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        var message = ""
        do {
            _ = try await bare.findUnpitchedSounds(clipId: bareClip.id)
            Issue.record("a clip with no note table was merged into")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("no note table"), "\(message)")
        #expect(bareEngine.detectCalls == 0, "the refusal paid for a detection")
        #expect(bare.tracks[0].clips[0].pitchEdits == nil)

        // Another detector generation: refused, nothing written.
        let stale = PitchEditSet(analysisVersion: PitchEditSet.currentAnalysisVersion + 1,
                                 segments: preSoundsPresetTable().segments)
        let (staleStore, staleEngine, staleClip, staleURL) = try soundStore(table: stale)
        defer { try? FileManager.default.removeItem(at: staleURL); _ = staleEngine }
        message = ""
        do {
            _ = try await staleStore.findUnpitchedSounds(clipId: staleClip.id)
            Issue.record("a table from another detector generation was merged into")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("different version of the pitch detector"), "\(message)")
        #expect(staleEngine.detectCalls == 0)
        #expect(staleStore.tracks[0].clips[0].pitchEdits == stale)

        // A MIDI clip and an unknown clip.
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        await #expect(throws: ProjectError.self) {
            _ = try await midiStore.findUnpitchedSounds(clipId: midi.id)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await store.findUnpitchedSounds(clipId: UUID())
        }
    }

    @Test("U-A/R21: the pitch setters MOVE a sound (never refuse it), and the moved sound enters the curve")
    func pitchSettersMoveSounds() throws {
        let seed = PitchNoteTable.detected(from: soundsResult())
        let sounds = seed.segments.filter { $0.origin == .unpitched }
        #expect(sounds.count == 3, "positive control: the seed carries its sounds")
        let (store, engine, clip, url) = try soundStore(table: nil)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }

        // One sound through the one-note setter, two through the group setter.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: sounds[0].id,
                                             offsetCents: 300, seedIfAbsent: seed)
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id,
            offsets: offsets([(sounds[1].id, -200), (sounds[2].id, 100)]),
            undoKey: PitchCorrectionUndoKey.structuralKey)
        let stored = try storedSet(store)
        let moved = stored.segments.filter { $0.origin == .unpitched }
        #expect(moved.map(\.pitchOffsetCents) == [300, -200, 100])
        #expect(moved.allSatisfy { $0.entersPitchCurve }, "a moved sound must render moved (R21)")
        #expect(moved.map(\.id) == sounds.map(\.id), "moving a sound re-identified it")
        // A moved sound is a real edit: the set now bends the curve.
        #expect(!stored.isPitchIdentity)
    }

    @Test("U-A: a preset pass stores its sounds as identity and reports them; a skip is reported, not silent")
    func autoCorrectReportCarriesTheFinderResult() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = soundsResult()
        // Hard Tune: the harshest preset, and the one whose shape scale 0
        // must NOT reach a sound.
        let hardTune = PitchAutoCorrectOptions(scale: .chromatic, strength: 1,
                                               retuneMs: PitchEditSet.engineMinimumRetuneMs,
                                               preserveVibrato: false)
        let report = try await store.autoCorrectClipPitchReport(clipId: clip.id, options: hardTune)
        #expect(report.unpitchedCount == 3)
        #expect(report.unpitched?.skipped == nil)
        #expect(report.unpitched?.sounds.count == 3)
        let stored = try storedSet(store)
        #expect(report.clip.pitchEdits == stored)
        let sounds = stored.segments.filter { $0.origin == .unpitched }
        #expect(sounds.count == 3)
        #expect(sounds.allSatisfy { $0.isIdentity }, "a preset put an edit on a sound")
        #expect(stored.segments.filter { $0.origin != .unpitched }
            .allSatisfy { $0.driftScale == 0 }, "control: Hard Tune did flatten the notes")
        // A preset's own output, sounds and all, reads as untouched.
        #expect(!stored.hasHandEditsSinceAutoCorrect)

        // A skip is REPORTED: no second of quiet in this fixture.
        engine.stubResult = melodicResult()
        let quiet = try await store.autoCorrectClipPitchReport(clipId: clip.id,
                                                              options: PitchAutoCorrectOptions())
        #expect(quiet.unpitched?.skipped == .notEnoughQuiet)
        #expect(quiet.unpitchedCount == 0)
        // Strength 0 never runs the finder.
        let none = try await store.autoCorrectClipPitchReport(
            clipId: clip.id, options: PitchAutoCorrectOptions(strength: 0))
        #expect(none.unpitched == nil)
    }

    // MARK: - Natural tuning C1: the voice setters (design §1(b) "Store")

    /// `fourNoteTable()` plus one SOUND after the last note and a +12 c move
    /// on the fourth note: a LEGACY tuned vocal, held ON the clip as a
    /// project saved before natural tuning reopens, so "before" is a real
    /// stored state. (It used to be stored through the pitch setter, which
    /// now updates a legacy vocal on the way in: D4-1 (b).)
    private func voiceStore() throws -> (ProjectStore, FakePitchWriterEngine, Clip, URL, PitchEditSet) {
        var table = fourNoteTable()
        table.segments.append(NoteSegment(startSeconds: 1.9, endSeconds: 2.1, detectedHz: 280,
                                          detectedConfidence: 0.4, origin: .unpitched))
        table.segments[3].pitchOffsetCents = 12
        table = table.withSegments(table.segments)
        let (store, engine, clip, url) = try storeHolding(table)
        return (store, engine, clip, url, try storedSet(store))
    }

    @Test("NT-C C1: setClipNoteFormant writes N notes in ONE 'Set Note Voice' step, clamps to ±24, undo restores")
    func setNoteFormantIsOneClampedStep() throws {
        let (store, engine, clip, url, before) = try voiceStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count
        let named = before.segments[0...1].map(\.id)

        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: named + [named[0]], semitones: -2)
        let after = try storedSet(store)
        #expect(after.segments[0...1].allSatisfy { $0.formantOffsetSemitones == -2 })
        #expect(after.segments[2...].allSatisfy { $0.formantOffsetSemitones == 0 }, "only the named notes")
        #expect(after.segments.map(\.pitchOffsetCents) == before.segments.map(\.pitchOffsetCents))
        // The amount is another setter's; the ONE thing that sets it here is
        // D4-1 (b): `before` is a legacy vocal, so this first hand edit
        // updates it (the seed amount, never a value of this call's).
        #expect(before.predatesNaturalTuning && after.formantCorrection == PitchEditSet.newSetFormantCorrection,
                "a note's Voice on an old vocal did not update it (D4-1 (b))")
        #expect(after.engagesFormantCurve, "a note offset engages the formant curve")
        #expect(store.undoHistory().undo.count == depth + 1)
        #expect(store.undoHistory().undo.first == "Set Note Voice")

        // Clamped explicitly (a field write bypasses the healing init); NaN reads 0.
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [named[0]], semitones: 99)
        #expect(try storedSet(store).segments[0].formantOffsetSemitones == 24)
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [named[0]], semitones: -99)
        #expect(try storedSet(store).segments[0].formantOffsetSemitones == -24)
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [named[0]], semitones: .nan)
        #expect(try storedSet(store).segments[0].formantOffsetSemitones == 0)

        // A no-op journals nothing; undo walks back to the table before.
        let settled = store.undoHistory().undo.count
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [named[0]], semitones: 0)
        #expect(store.undoHistory().undo.count == settled)
        for _ in 0..<(settled - depth) { _ = try store.undo() }
        #expect(try storedSet(store) == before)
    }

    @Test("NT-C C1: setClipNoteFormant refuses a SOUND, an unknown id and an empty list, all or nothing")
    func setNoteFormantRefusals() throws {
        let (store, engine, clip, url, before) = try voiceStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count
        let noteID = before.segments[0].id
        let sound = try #require(before.segments.first { $0.origin == .unpitched })

        // A sound named beside a note: refused in words, and the NOTE is not written either.
        var message = ""
        do {
            _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [noteID, sound.id],
                                             semitones: -2)
            Issue.record("a sound took a voice offset")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains("no sung pitch") && message.contains("Nothing was changed"), "\(message)")
        #expect(try storedSet(store) == before)
        // An unknown id among good ones: nothing written.
        #expect(throws: ProjectError.self) {
            _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [noteID, UUID()], semitones: 1)
        }
        #expect(throws: ProjectError.self) {
            _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [], semitones: 1)
        }
        #expect(throws: ProjectError.self) {
            _ = try store.setClipNoteFormant(clipId: UUID(), segmentIds: [noteID], semitones: 1)
        }
        #expect(try storedSet(store) == before)
        #expect(store.undoHistory().undo.count == depth)

        // No table and no seed: refused; with a seed, the seed is stored.
        let (bare, bareEngine, bareClip, bareURL) = try audioStore()
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        let seed = fourNoteTable()
        #expect(throws: ProjectError.self) {
            _ = try bare.setClipNoteFormant(clipId: bareClip.id, segmentIds: [seed.segments[0].id],
                                            semitones: 1)
        }
        _ = try bare.setClipNoteFormant(clipId: bareClip.id, segmentIds: [seed.segments[0].id],
                                        semitones: 1.5, seedIfAbsent: seed)
        let seeded = try storedSet(bare)
        #expect(seeded.segments.map(\.id) == seed.segments.map(\.id))
        #expect(seeded.segments[0].formantOffsetSemitones == 1.5)
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(throws: ProjectError.self) {
            _ = try midiStore.setClipNoteFormant(clipId: midi.id, segmentIds: [noteID], semitones: 1)
        }
    }

    @Test("NT-C C1: setClipFormantCorrection clamps to 0...1, nil restores legacy, NaN is refused, one step each")
    func setFormantCorrectionClampsAndRestores() throws {
        let (store, engine, clip, url, before) = try voiceStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        #expect(before.formantCorrection == nil && before.predatesNaturalTuning, "a legacy tuned set")
        let depth = store.undoHistory().undo.count

        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.5)
        var after = try storedSet(store)
        #expect(after.formantCorrection == 0.5)
        #expect(after.segments == before.segments, "the amount moves no note")
        #expect(after.retuneMs == before.retuneMs && after.autoCorrectStamp == before.autoCorrectStamp)
        #expect(!after.predatesNaturalTuning && after.engagesFormantCurve)
        #expect(store.undoHistory().undo.count == depth + 1)
        #expect(store.undoHistory().undo.first == "Keep Voice Size")

        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 1.7)
        #expect(try storedSet(store).formantCorrection == 1)
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: -0.3)
        after = try storedSet(store)
        #expect(after.formantCorrection == 0, "clamped to 0.0, which is ENGAGED, not legacy")
        #expect(after.engagesFormantCurve)

        // nil restores legacy exactly.
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: nil)
        after = try storedSet(store)
        #expect(after == before)
        #expect(after.predatesNaturalTuning && !after.engagesFormantCurve)
        #expect(store.undoHistory().undo.count == depth + 4)

        // A no-op journals nothing; a non-finite amount is refused, nothing written.
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: nil)
        #expect(store.undoHistory().undo.count == depth + 4)
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ProjectError.self) {
                _ = try store.setClipFormantCorrection(clipId: clip.id, amount: bad)
            }
        }
        #expect(try storedSet(store) == before)
        #expect(store.undoHistory().undo.count == depth + 4)

        // Undo walks back through 0.0 -> 1 -> 0.5 -> legacy, one step at a time.
        _ = try store.undo()
        #expect(try storedSet(store).formantCorrection == 0)
        _ = try store.undo()
        #expect(try storedSet(store).formantCorrection == 1)
        _ = try store.undo()
        #expect(try storedSet(store).formantCorrection == 0.5)
        _ = try store.undo()
        #expect(try storedSet(store) == before)

        // Refusals: no table and no seed, an unknown clip, a MIDI clip.
        let (bare, bareEngine, bareClip, bareURL) = try audioStore()
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        #expect(throws: ProjectError.self) { _ = try bare.setClipFormantCorrection(clipId: bareClip.id, amount: 1) }
        #expect(bare.tracks[0].clips[0].pitchEdits == nil)
        _ = try bare.setClipFormantCorrection(clipId: bareClip.id, amount: 0.25, seedIfAbsent: fourNoteTable())
        #expect(try storedSet(bare).formantCorrection == 0.25)
        #expect(throws: ProjectError.self) { _ = try store.setClipFormantCorrection(clipId: UUID(), amount: 1) }
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(throws: ProjectError.self) { _ = try midiStore.setClipFormantCorrection(clipId: midi.id, amount: 1) }
    }

    @Test("NT-C C1: an amount of 0.0 survives save and open as 0.0, NEVER legacy nil; a split keeps it")
    func zeroAmountSurvivesSaveOpenAndSplit() throws {
        let (store, engine, clip, url, before) = try voiceStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.0)
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [before.segments[1].id],
                                         semitones: -1.5)

        // A split rebuilds the set: the amount must ride along (X2's one rebuild).
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: before.segments[0].id,
                                           atSourceSecond: 0.2)
        let split = try storedSet(store)
        #expect(split.segments.count == before.segments.count + 1, "control: the split happened")
        #expect(split.formantCorrection == 0.0)
        #expect(split.formantCorrection != nil)

        // The product's save and open paths, not a bare Codable round trip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntc1-zero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Voice Zero").path
        try store.saveProject(to: path)
        let json = try String(contentsOf: ProjectBundle.normalizedBundleURL(fromPath: path)
            .appendingPathComponent("project.json"), encoding: .utf8)
        #expect(json.contains("\"formantCorrection\" : 0"), "0.0 must be WRITTEN")
        #expect(json.contains("\"formantOffsetSemitones\" : -1.5"), "positive control: the probe finds keys")

        let reopened = ProjectStore()
        _ = try reopened.openProject(at: path)
        let back = try #require(reopened.tracks.first?.clips.first?.pitchEdits)
        #expect(back.formantCorrection == 0.0)
        #expect(back.formantCorrection != nil, "a saved 0.0 reopened as legacy")
        #expect(back.engagesFormantCurve && !back.predatesNaturalTuning)
        #expect(back == split)
    }

    // MARK: - Natural tuning C1: the auto-correct carry (§1(c) D-F2, X4)

    @Test("NT-C C1: re-running auto-correct keeps a set's own amount; a legacy set or no table gets the seed")
    func autoCorrectCarriesTheAmount() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        let options = PitchAutoCorrectOptions(scale: .chromatic, strength: 1.0,
                                              retuneMs: PitchEditSet.engineMinimumRetuneMs,
                                              preserveVibrato: true)
        // No table: the seed.
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
        #expect(try storedSet(store).formantCorrection == PitchEditSet.newSetFormantCorrection)

        // The user's own pick, 0.0 included (the value a careless `?? seed` loses).
        for pick in [0.5, 0.0] {
            _ = try store.setClipFormantCorrection(clipId: clip.id, amount: pick)
            _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
            let rerun = try storedSet(store)
            #expect(rerun.formantCorrection == pick, "a preset reset the user's voice-size pick")
            // Carried BEFORE the stamp: the stored set is still exactly a preset's output.
            #expect(!rerun.hasHandEditsSinceAutoCorrect)
        }

        // A LEGACY set (nil, tuned before §1): the new default, D-F2 "yes" (X4).
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: nil)
        #expect(try storedSet(store).formantCorrection == nil)
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
        #expect(try storedSet(store).formantCorrection == PitchEditSet.newSetFormantCorrection)
    }

    /// X2 rule 4 for the two C1 writers, the C0 carry test's shape: a seed with
    /// EVERY set-level field off legacy, compared by `Mirror`.
    @Test("NT-C C1: both voice setters keep every OTHER set-level field (X2 carry)")
    func voiceSettersCarryEveryOtherField() throws {
        let seed = naturalTuningSeed()
        let expected = NaturalTuningFieldCarryTests.setLevelFields(seed)
        #expect(expected != NaturalTuningFieldCarryTests.setLevelFields(.empty))

        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [seed.segments[1].id],
                                         semitones: 2, seedIfAbsent: seed)
        let voiced = try storedSet(store)
        #expect(voiced != seed, "the writer wrote nothing, so the carry proves nothing")
        #expect(NaturalTuningFieldCarryTests.setLevelFields(voiced) == expected)
        #expect(voiced.segments[0].transitionOutMs == 150 && voiced.segments[0].glideFollow == 0.5)

        let (store2, engine2, clip2, url2) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url2); _ = engine2 }
        _ = try store2.setClipFormantCorrection(clipId: clip2.id, amount: 0.9, seedIfAbsent: seed)
        let amount = try storedSet(store2)
        #expect(amount.formantCorrection == 0.9 && seed.formantCorrection != 0.9)
        var others = NaturalTuningFieldCarryTests.setLevelFields(amount)
        var expectedOthers = expected
        others["formantCorrection"] = nil
        expectedOthers["formantCorrection"] = nil
        #expect(others == expectedOthers)
        #expect(amount.segments == seed.segments)
    }

    // MARK: - m23-ap C5a-2 (+ natural tuning §3 L2): the wobble setters
    //
    // Design `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §10/§11.1
    // (T8, T9, T13) and `docs/design/2026-09-25-natural-tuning.md` §3b/§3g G5.
    // Appended here, not in a new suite: the @MainActor suite cadence is full.
    // The pure clamp and the batch rule are `NoteVibratoLimitsTests`.
    //
    // ⛔ EVERY READ-BACK COMPARES THE STORED NOTE WITH AN INDEPENDENT
    // EXPECTATION, `NoteVibratoLimits.clamp(edit, stretchRatio:).edit`, never
    // with the setter's own return (G5): a store checked against the store
    // passes against a setter that dropped a field.

    /// `fourNoteTable()` plus one SOUND after the last note, on a clip at
    /// `ratio`, stored through an unrelated edit so "before" is a real stored
    /// state (the `voiceStore` shape).
    private func wobbleStore(ratio: Double = 1) throws
    -> (ProjectStore, FakePitchWriterEngine, Clip, URL, PitchEditSet) {
        let url = try makeRealAudioFile()
        let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                        stretchRatio: ratio)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = FakePitchWriterEngine()
        store.engine = engine
        var table = fourNoteTable()
        table.segments.append(NoteSegment(startSeconds: 1.9, endSeconds: 2.1, detectedHz: 280,
                                          detectedConfidence: 0.4, origin: .unpitched))
        table = table.withSegments(table.segments)
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: table.segments[3].id,
                                             offsetCents: 12, seedIfAbsent: table)
        return (store, engine, clip, url, try storedSet(store))
    }

    /// The six wobble fields of the note `id`, READ OUT OF THE STORE.
    private func storedWobble(_ store: ProjectStore, _ id: UUID) throws -> NoteVibratoEdit {
        NoteVibratoEdit(storedIn: try #require(try storedSet(store).segments.first { $0.id == id }))
    }

    @Test("C5a-2 T9: the setter clamps each value to the design's number, says which limit bound, and the store matches an INDEPENDENT clamp")
    func setterClampsAndSaysSo() throws {
        // Ratio 1: rate 12 → 8, depth 500 → 200, keep −1 → 0, anchor 10⁹ → 86 400.
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let note = before.segments[0].id
        let edit = NoteVibratoEdit(vibratoRateHz: 12, vibratoDepthCents: 500,
                                   vibratoOnsetSeconds: 0.2, vibratoPhaseAnchorSeconds: 1e9,
                                   vibratoScale: -1, driftScale: 0.5)
        let result = try store.setClipNoteVibrato(clipId: clip.id, segmentId: note, edit: edit)
        let stored = try storedWobble(store, note)
        // THE PHYSICS, as the design's literals.
        #expect(stored.vibratoRateHz == 8 && stored.vibratoDepthCents == 200)
        #expect(stored.vibratoScale == 0 && stored.vibratoPhaseAnchorSeconds == 86_400)
        #expect(stored.vibratoOnsetSeconds == 0.2 && stored.driftScale == 0.5)
        #expect(result.clamped == [.rateRange, .depthRange, .anchorRange, .scaleRange])
        // ⛔ G5: the stored six against an INDEPENDENT expectation, never `result.segment`.
        let independent = try NoteVibratoLimits.clamp(edit, stretchRatio: clip.stretchRatio).edit
        #expect(stored == independent)
        // Nothing else on the note moved, and no other note moved.
        let after = try storedSet(store)
        var restored = try #require(after.segments.first { $0.id == note })
        let was = before.segments[0]
        restored.vibratoRateHz = was.vibratoRateHz
        restored.vibratoDepthCents = was.vibratoDepthCents
        restored.vibratoOnsetSeconds = was.vibratoOnsetSeconds
        restored.vibratoPhaseAnchorSeconds = was.vibratoPhaseAnchorSeconds
        restored.vibratoScale = was.vibratoScale
        restored.driftScale = was.driftScale
        #expect(restored == was)
        #expect(Array(after.segments.dropFirst()) == Array(before.segments.dropFirst()))
        #expect(store.undoHistory().undo.first == "Change Wobble")

        // Ratio 0.8: rate 7 → 6.4, the heard ceiling (heard 6.4 / 0.8 = 8).
        let (fast, fastEngine, fastClip, fastURL, fastBefore) = try wobbleStore(ratio: 0.8)
        defer { try? FileManager.default.removeItem(at: fastURL); _ = fastEngine }
        let fastNote = fastBefore.segments[1].id
        let fastEdit = NoteVibratoEdit(vibratoRateHz: 7, vibratoDepthCents: 30)
        let fastResult = try fast.setClipNoteVibrato(clipId: fastClip.id, segmentId: fastNote,
                                                     edit: fastEdit)
        let fastStored = try storedWobble(fast, fastNote)
        #expect(abs(try #require(fastStored.vibratoRateHz) - 6.4) < 1e-12)
        #expect(fastResult.clamped == [.heardRateCeiling])
        #expect(abs(fastResult.heardRateHz - 8) < 1e-12, "heard = stored ÷ ratio")
        let expected = try NoteVibratoLimits.clamp(fastEdit, stretchRatio: fastClip.stretchRatio).edit
        #expect(fastStored.vibratoRateHz == expected.vibratoRateHz)
        #expect(fastStored.vibratoDepthCents == expected.vibratoDepthCents)
        // No hidden defaults (§10 item 5): onset, anchor and both scales were not sent, so untouched.
        #expect(fastStored.vibratoOnsetSeconds == 0 && fastStored.vibratoPhaseAnchorSeconds == 0)
        #expect(fastStored.vibratoScale == 1 && fastStored.driftScale == 1)
    }

    @Test("C5a-2: NaN and an empty edit are REFUSED in words and write nothing; a no-op journals nothing; a silent wobble is said, not refused")
    func setterRefusesNonsenseAndIsSilentOnANoOp() throws {
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let note = before.segments[0].id
        let depth = store.undoHistory().undo.count
        func refusal(_ body: () throws -> Void) -> String {
            do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
        }
        #expect(refusal {
            _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: note,
                                             edit: NoteVibratoEdit(vibratoDepthCents: .nan))
        } == "vibratoDepthCents has to be a number from 0 to 200; nan is not one. Nothing was changed.")
        #expect(refusal {
            _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: note, edit: NoteVibratoEdit())
        } == "Nothing to change: give at least one wobble setting.")
        #expect(try storedSet(store) == before && store.undoHistory().undo.count == depth)

        // ⭐ A NO-OP JOURNALS NOTHING — on a note whose values are already stored,
        // under its own fresh `.vibrato` key, so coalescing cannot hide an entry.
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: before.segments[1].id,
                                         edit: .asSung)
        #expect(store.undoHistory().undo.count == depth, "a default-valued edit journaled a step")
        #expect(try storedSet(store) == before, "a default-valued edit changed the table")
        // POSITIVE CONTROL: one real value on the same note does journal.
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: before.segments[1].id,
                                         edit: NoteVibratoEdit(vibratoScale: 0.5))
        #expect(store.undoHistory().undo.count == depth + 1)

        // A depth with no rate never moves: STORED and SAID (design §10 item 10).
        let silent = try store.setClipNoteVibrato(clipId: clip.id, segmentId: note,
                                                  edit: NoteVibratoEdit(vibratoDepthCents: 40))
        #expect(silent.silentWobble)
        #expect(try storedWobble(store, note).vibratoDepthCents == 40)
    }

    @Test("C5a-2 §1.7: a SOUND alone is refused in the design's words; the setters' shared refusals hold")
    func wobbleSettersRefuseSoundsAndShareTheRefusals() throws {
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let sound = try #require(before.segments.first { $0.origin == .unpitched })
        let depth = store.undoHistory().undo.count
        func refusal(_ body: () throws -> Void) -> String {
            do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
        }
        #expect(refusal {
            _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: sound.id,
                                             edit: NoteVibratoEdit(vibratoScale: 0))
        } == "No pitch here, so there is no wobble to change.")
        #expect(refusal {
            _ = try store.resetClipNoteVibrato(clipId: clip.id, segmentId: sound.id)
        } == "No pitch here, so there is no wobble to change.")
        #expect(try storedSet(store) == before && store.undoHistory().undo.count == depth)

        // Unknown note (names the count), unknown clip, MIDI clip, comp member,
        // no table and no seed: the per-note setters' own refusals.
        let unknown = refusal {
            _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: UUID(),
                                             edit: NoteVibratoEdit(vibratoScale: 0))
        }
        #expect(unknown.contains("5 note(s)"), "\(unknown)")
        #expect(refusal {
            _ = try store.setClipNoteVibrato(clipId: UUID(), segmentId: sound.id,
                                             edit: NoteVibratoEdit(vibratoScale: 0))
        } != "ACCEPTED")
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(refusal {
            _ = try midiStore.setClipNotesVibrato(
                clipId: midi.id,
                edits: [NoteVibratoItem(segmentId: UUID(), edit: NoteVibratoEdit(vibratoScale: 0))],
                seedIfAbsent: fourNoteTable(), undoKey: PitchCorrectionUndoKey.structuralKey)
        }.contains("MIDI"))
        var member = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                          audioFileURL: URL(fileURLWithPath: "/tmp/c5a2-comp-member.wav"))
        member.takeGroupID = UUID()
        let memberStore = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [member])])
        let table = fourNoteTable()
        #expect(refusal {
            _ = try memberStore.setClipNoteVibrato(clipId: member.id, segmentId: table.segments[0].id,
                                                   edit: NoteVibratoEdit(vibratoScale: 0),
                                                   seedIfAbsent: table)
        } != "ACCEPTED")
        #expect(memberStore.tracks[0].clips[0].pitchEdits == nil)
        let (bare, bareEngine, bareClip, bareURL) = try audioStore()
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        #expect(refusal {
            _ = try bare.setClipNoteVibrato(clipId: bareClip.id, segmentId: UUID(),
                                            edit: NoteVibratoEdit(vibratoScale: 0))
        }.contains("no notes to edit yet"))
        // The empty list is refused BEFORE the table, and the seed is not stored.
        #expect(refusal {
            _ = try bare.setClipNotesVibrato(clipId: bareClip.id, edits: [], seedIfAbsent: table,
                                             undoKey: PitchCorrectionUndoKey.structuralKey)
        }.hasPrefix("Name at least one note to change the wobble of."))
        #expect(bare.tracks[0].clips[0].pitchEdits == nil)
        // POSITIVE CONTROL: the same bare clip with a seed and a real edit stores the seed's ids.
        _ = try bare.setClipNoteVibrato(clipId: bareClip.id, segmentId: table.segments[0].id,
                                        edit: NoteVibratoEdit(driftScale: 0.3), seedIfAbsent: table)
        #expect(try storedSet(bare).segments.map(\.id) == table.segments.map(\.id))
        #expect(try storedSet(bare).segments[0].driftScale == 0.3)
    }

    @Test("NT §3b L2: a batch is ONE undo step, clamps PER NOTE, skips a sound AND SAYS SO, moves nothing else, and undo restores all N")
    func wobbleBatchIsOneStepAndSkipsSoundsOutLoud() throws {
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let ids = before.segments.map(\.id)
        let sound = try #require(before.segments.first { $0.origin == .unpitched }).id
        let depth = store.undoHistory().undo.count
        // "Select all, then Drift": every id, the sound included, each note ABSOLUTE.
        let items = [NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(driftScale: 0.3)),
                     NoteVibratoItem(segmentId: ids[1], edit: NoteVibratoEdit(driftScale: 0.6)),
                     NoteVibratoItem(segmentId: ids[2], edit: NoteVibratoEdit(driftScale: 9)),
                     NoteVibratoItem(segmentId: sound, edit: NoteVibratoEdit(driftScale: 0.3))]
        let key = PitchCorrectionUndoKey.driftGroup(clipID: clip.id, selectionToken: UUID())
        let result = try store.setClipNotesVibrato(clipId: clip.id, edits: items, undoKey: key)
        #expect(store.undoHistory().undo.count == depth + 1, "N notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Change Drift", "a drift-only batch is named for drift")
        let after = try storedSet(store)
        #expect(after.segments[0].driftScale == 0.3 && after.segments[1].driftScale == 0.6)
        #expect(after.segments[2].driftScale == 4, "clamped PER NOTE to the model's 4")
        #expect(result.notes.map(\.bound) == [[], [], [.driftRange]])
        // ⭐ THE SKIP IS STORED NOWHERE AND SAID IN WORDS.
        #expect(after.segments.first { $0.id == sound } == before.segments.first { $0.id == sound })
        #expect(result.skippedSoundIds == [sound])
        #expect(result.skippedSoundsSentence?.hasPrefix("Left 1 sound alone") == true)
        #expect(result.notes.map(\.segmentId) == Array(ids.prefix(3)))
        // INVARIANCE: only driftScale moved, and only on the three named notes.
        for (now, was) in zip(after.segments, before.segments) {
            var restored = now
            restored.driftScale = was.driftScale
            #expect(restored == was, "a drift batch changed more than driftScale on \(now.id)")
        }
        #expect(after.segments[3].driftScale == 1)
        // Every stored note equals the INDEPENDENT clamp of what was asked (G5).
        for item in items where item.segmentId != sound {
            let expected = try NoteVibratoLimits.clamp(item.edit, stretchRatio: clip.stretchRatio).edit
            #expect(try storedWobble(store, item.segmentId).driftScale == expected.driftScale)
        }
        #expect(try store.undo() == "Change Drift")
        #expect(try storedSet(store) == before, "undo did not bring all the notes back")

        // A batch that writes the wobble (not only drift) is "Change Wobble".
        _ = try store.setClipNotesVibrato(
            clipId: clip.id,
            edits: [NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 0,
                                                                            driftScale: 0))],
            undoKey: PitchCorrectionUndoKey.structuralKey)
        #expect(store.undoHistory().undo.first == "Change Wobble")
    }

    @Test("NT §3b L2: the wobble and drift GROUP keys coalesce the same selection, never a different one, and never a pitch drag of the same selection")
    func wobbleGroupKeysAreTwinsNotThePitchKey() throws {
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let ids = before.segments.map(\.id)
        let token = UUID()
        let wobble = PitchCorrectionUndoKey.vibratoGroup(clipID: clip.id, selectionToken: token)
        let drift = PitchCorrectionUndoKey.driftGroup(clipID: clip.id, selectionToken: token)
        let pitch = PitchCorrectionUndoKey.group(clipID: clip.id, selectionToken: token)
        #expect(Set([wobble, drift, pitch]).count == 3, "three verbs, three keys")
        #expect(wobble.hasPrefix("pitch.vibratoGroup:") && drift.hasPrefix("pitch.driftGroup:"))
        let depth = store.undoHistory().undo.count
        func keep(_ k: Double) -> [NoteVibratoItem] {
            ids.prefix(2).map { NoteVibratoItem(segmentId: $0, edit: NoteVibratoEdit(vibratoScale: k)) }
        }
        // Two wobble drags of the SAME selection inside the window: one step.
        _ = try store.setClipNotesVibrato(clipId: clip.id, edits: keep(0.5), undoKey: wobble)
        _ = try store.setClipNotesVibrato(clipId: clip.id, edits: keep(0.2), undoKey: wobble)
        #expect(store.undoHistory().undo.count == depth + 1)
        // A PITCH drag of the same selection is its own step (it would fold under `group`).
        _ = try store.setClipNotePitchOffsets(
            clipId: clip.id, offsets: ids.prefix(2).map { NotePitchOffset(segmentId: $0, offsetCents: 50) },
            undoKey: pitch)
        #expect(store.undoHistory().undo.count == depth + 2)
        // A drift drag of the same selection: its own step too.
        _ = try store.setClipNotesVibrato(
            clipId: clip.id,
            edits: ids.prefix(2).map { NoteVibratoItem(segmentId: $0, edit: NoteVibratoEdit(driftScale: 0.4)) },
            undoKey: drift)
        #expect(store.undoHistory().undo.count == depth + 3)
        // A different selection: a new step.
        _ = try store.setClipNotesVibrato(
            clipId: clip.id, edits: keep(0.9),
            undoKey: PitchCorrectionUndoKey.vibratoGroup(clipID: clip.id, selectionToken: UUID()))
        #expect(store.undoHistory().undo.count == depth + 4)
    }

    @Test("C5a-2 T13: two commits on one note are ONE undo step, two notes are two, and a reset is ALWAYS its own step")
    func undoIsOneStepAndResetIsItsOwn() throws {
        let (store, engine, clip, url, before) = try wobbleStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let a = before.segments[0].id, b = before.segments[1].id
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: a,
                                         edit: NoteVibratoEdit(vibratoRateHz: 5.5, vibratoDepthCents: 30))
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: a,
                                         edit: NoteVibratoEdit(vibratoDepthCents: 45))
        #expect(store.undoHistory().undo.count == depth + 1,
                "two commits on ONE note inside the window are one undo step (the .vibrato key)")
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: b,
                                         edit: NoteVibratoEdit(vibratoScale: 0.5))
        #expect(store.undoHistory().undo.count == depth + 2, "a different note is a new step")
        // A reset right after a commit on the SAME note, inside the window: its own step.
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: b,
                                         edit: NoteVibratoEdit(vibratoScale: 0.25))
        #expect(store.undoHistory().undo.count == depth + 2, "same note again: coalesced")
        _ = try store.resetClipNoteVibrato(clipId: clip.id, segmentId: b)
        #expect(store.undoHistory().undo.count == depth + 3,
                "a reset must never merge into the drag before it (structuralKey)")
        #expect(store.undoHistory().undo.first == "Reset Wobble")
        // Undo takes back the reset alone: note b is at 0.25 again.
        #expect(try store.undo() == "Reset Wobble")
        #expect(try storedWobble(store, b).vibratoScale == 0.25)
        #expect(try store.undo() == "Change Wobble")
        #expect(try storedWobble(store, b).vibratoScale == 1)
        #expect(try store.undo() == "Change Wobble")
        #expect(try storedSet(store) == before)
    }

    @Test("C5a-2: reset writes all SIX defaults, the anchor back to 0; an as-sung note journals nothing; a hand-authored sound can be cleaned")
    func resetPutsAllSixBack() throws {
        let (store, engine, clip, url, before) = try wobbleStore(ratio: 1.25)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let note = before.segments[2]
        let edit = NoteVibratoEdit(vibratoRateHz: 7.75, vibratoDepthCents: 40,
                                   vibratoOnsetSeconds: 0.1, vibratoPhaseAnchorSeconds: note.startSeconds + 0.2,
                                   vibratoScale: 0, driftScale: 0)
        _ = try store.setClipNoteVibrato(clipId: clip.id, segmentId: note.id, edit: edit)
        #expect(try storedWobble(store, note.id) != .asSung, "control: the note carries a wobble")
        let depth = store.undoHistory().undo.count
        let result = try store.resetClipNoteVibrato(clipId: clip.id, segmentId: note.id)
        #expect(try storedWobble(store, note.id) == .asSung)
        #expect(try storedSet(store).segments.first { $0.id == note.id }?.vibratoPhaseAnchorSeconds == 0)
        #expect(result.requested == .asSung && result.clamped.isEmpty)
        #expect(try storedSet(store) == before, "reset left something behind")
        #expect(store.undoHistory().undo.count == depth + 1)
        // Already as sung: silent.
        _ = try store.resetClipNoteVibrato(clipId: clip.id, segmentId: note.id)
        #expect(store.undoHistory().undo.count == depth + 1)

        // A sound that a hand-authored file gave a wobble: reset is its one cleanup path.
        var table = fourNoteTable()
        var authored = NoteSegment(startSeconds: 1.9, endSeconds: 2.1, detectedHz: 280,
                                   detectedConfidence: 0.4, origin: .unpitched)
        authored.vibratoScale = 0.5
        table.segments.append(authored)
        let url2 = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: url2) }
        let clip2 = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: url2,
                         pitchEdits: table)
        let store2 = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip2])])
        _ = try store2.resetClipNoteVibrato(clipId: clip2.id, segmentId: authored.id)
        #expect(store2.tracks[0].clips[0].pitchEdits?.segments.last?.vibratoScale == 1)
    }

    /// T8 (vibrato-handle design §11.1): a split keeps a generated wobble
    /// GOING, measured on the curve the render evaluates
    /// (`PitchCorrectionCurve.make` → `semitones(atSourceSecond:)`).
    ///
    /// Parent [1.0, 3.0]: heard 5.5 at ratio 1, ±40 c, a 0.25 s fade, the
    /// anchor at the centre. The cut's own boundary ramp (±15 ms at the 30 ms
    /// retune) is excluded: there the two halves' gates blend by design.
    ///
    /// ⚠️ **THE DESIGN'S BOUND FOR A CUT INSIDE THE FADE IS WRONG, AND THIS
    /// TEST ASSERTS THE ONE THAT HOLDS.** §11.1/T8 say the dip is bounded by
    /// `depth × smoothstep((cut − start) / onset)` = 0.352 × depth at a cut
    /// 0.1 s into a 0.25 s fade. It is not: the right half's fade starts with
    /// ZERO slope while the parent's is mid-rise, so the gap WIDENS after the
    /// cut, to 0.427 of the fade (at ~1.127 s) before closing at 1.25 s. What
    /// does hold, and is asserted: the right half never carries MORE wobble
    /// than the parent (its fade is ≤ the parent's everywhere), the gap is
    /// under 0.45 × depth, and it is exactly zero once the parent's fade is done.
    @Test("C5a-2 T8: a split keeps the wobble going — exact past the fade, bounded inside it, and the right half's onset is re-derived")
    func splitKeepsTheWobbleGoing() throws {
        let depthCents = 40.0
        var parent = NoteSegment(startSeconds: 1.0, endSeconds: 3.0, detectedHz: 220,
                                 detectedConfidence: 0.9)
        parent.vibratoRateHz = 5.5
        parent.vibratoDepthCents = depthCents
        parent.vibratoOnsetSeconds = 0.25
        parent.vibratoPhaseAnchorSeconds = 2.0
        let unsplitSet = PitchEditSet(segments: [parent])
        let unsplit = PitchCorrectionCurve.make(editSet: unsplitSet)
        let halfRamp = unsplitSet.retuneMs / 1000 / 2
        let depth = depthCents / 100

        func split(at cut: Double) throws -> (PitchEditSet, NoteSegment) {
            let (store, engine, clip, url) = try audioStore()
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id,
                                               atSourceSecond: cut, seedIfAbsent: unsplitSet)
            let stored = try storedSet(store)
            #expect(stored.segments.count == 2)
            return (stored, try #require(stored.segments.first { $0.id != parent.id }))
        }
        let probes = (0...2000).map { 0.95 + Double($0) * (3.05 - 0.95) / 2000 }

        // Cut at 2.0, PAST the fade: exact. The right half's onset is 0.
        let (late, lateRight) = try split(at: 2.0)
        #expect(lateRight.vibratoOnsetSeconds == 0)
        let lateCurve = PitchCorrectionCurve.make(editSet: late)
        var lateWorst = 0.0
        for t in probes where abs(t - 2.0) > halfRamp + 0.005 {
            lateWorst = max(lateWorst, abs(lateCurve.semitones(atSourceSecond: t)
                                           - unsplit.semitones(atSourceSecond: t)))
        }
        #expect(lateWorst <= 1e-12, "a split past the fade changed the wobble by \(lateWorst) st")
        // POSITIVE CONTROL: the probe sees the wobble at all (±0.4 st at full depth).
        #expect(probes.map { abs(unsplit.semitones(atSourceSecond: $0)) }.max() ?? 0 > 0.39)

        // Cut at 1.1, INSIDE the fade: the right half keeps the 0.15 s left of it.
        let (early, earlyRight) = try split(at: 1.1)
        #expect(abs(earlyRight.vibratoOnsetSeconds - 0.15) < 1e-12)
        let earlyCurve = PitchCorrectionCurve.make(editSet: early)
        var worstGap = 0.0
        for t in probes where abs(t - 1.1) > halfRamp + 0.005 {
            let was = unsplit.semitones(atSourceSecond: t)
            let now = earlyCurve.semitones(atSourceSecond: t)
            if t >= 1.25 || t < 1.1 {
                // Outside the fade that remains, and on the untouched left half: exact.
                #expect(abs(now - was) <= 1e-12, "t=\(t): \(now) vs \(was)")
            } else {
                #expect(abs(now) <= abs(was) + 1e-12, "t=\(t): the split ADDED wobble")
                worstGap = max(worstGap, abs(now - was))
            }
        }
        #expect(worstGap < 0.45 * depth, "the dip after a cut inside the fade is \(worstGap / depth) of the depth")
        // The recorded figure (the design's claimed bound is 0.352).
        print("[measured] C5a-2 T8 cut 1.1 inside a 0.25 s fade: worst dip = "
              + String(format: "%.3f", worstGap / depth) + " x depth (design §11.1 claimed <= 0.352)")
    }

    // MARK: - Natural tuning §4 (NT-C C4): the three slide setters, split, stamp

    /// A (0.5-1.0, +300 c) | B (1.0-1.5, a sung slide) | C (1.5-2.0), all
    /// abutting; an untouched SOUND S (2.05-2.2) in the gap; D (2.3-2.8),
    /// the last note. `slope` 0 makes it a LEGACY table.
    private func slideTable(slope: Double = 3000) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 300),
            NoteSegment(startSeconds: 1.0, endSeconds: 1.5, detectedHz: 230,
                        detectedConfidence: 0.9, origin: .transition),
            NoteSegment(startSeconds: 1.5, endSeconds: 2.0, detectedHz: 240, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 2.05, endSeconds: 2.2, detectedHz: 240,
                        detectedConfidence: 0.3, origin: .unpitched),
            NoteSegment(startSeconds: 2.3, endSeconds: 2.8, detectedHz: 250, detectedConfidence: 0.9),
        ], transitionSlopeCentsPerSecond: slope)
    }

    private func refusal(_ body: () throws -> Void) -> String {
        do {
            try body()
            return "NO REFUSAL"
        } catch let error as ProjectError {
            return error.localizedDescription
        } catch {
            return "\(error)"
        }
    }

    @Test("NT-C C4: setClipNoteTransition writes ONE width as ONE undo step, two drags of one join fold, refusals change nothing")
    func noteTransitionSetterIsOneStep() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = slideTable()
        let a = seed.segments[0].id, c = seed.segments[2].id
        let s = seed.segments[3].id, d = seed.segments[4].id
        let depth = store.undoHistory().undo.count

        _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: a, widthMs: 150,
                                            seedIfAbsent: seed)
        _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: a, widthMs: 220)
        let stored = try storedSet(store)
        #expect(stored.segments[0].transitionOutMs == 220)
        #expect(stored.segments.dropFirst() == seed.segments.dropFirst(), "only the named note moved")
        #expect(stored.transitionSlopeCentsPerSecond == seed.transitionSlopeCentsPerSecond)
        #expect(store.undoHistory().undo.count == depth + 1,
                "two width drags of the SAME join inside the window must fold into one step")
        #expect(stored.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 220)

        // Refusals, in words, and nothing is written or journalled.
        #expect(refusal { _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: c, widthMs: 100) }
                == PitchTransitionSentences.gapHasNoSlide(c))
        #expect(refusal { _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: d, widthMs: 100) }
                == PitchTransitionSentences.lastNoteHasNoSlide(d))
        #expect(refusal { _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: s, widthMs: 100) }
                == PitchTransitionSentences.soundHasNoSlide(s))
        #expect(refusal { _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: a, widthMs: .nan) }
                == PitchTransitionSentences.widthNotANumber(.nan))
        #expect(try storedSet(store) == stored)
        #expect(store.undoHistory().undo.count == depth + 1)

        // Back to Auto, then undo twice: the first undo restores 220, the
        // second the clip as it was (no table).
        _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: seed.segments[1].id, widthMs: 90)
        #expect(store.undoHistory().undo.count == depth + 2, "a different join is a new step")
        _ = try store.undo()
        #expect(try storedSet(store) == stored)
        _ = try store.undo()
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    /// D4-1 = (b), the user's ruling of 2026-09-26 (this test pinned option
    /// (a) until then): a slide width on a LEGACY vocal updates the whole
    /// vocal in the same undo step, and a pitch drag after it changes only
    /// its note. The full writer-by-writer gate is the D4-1 (b) block below.
    @Test("NT-C C4 D4-1 (b): a slide width on a LEGACY vocal updates it in the same step; a pitch drag after it moves only its note")
    func legacyVocalUpdatesOnTheFirstHandEdit() throws {
        let legacy = slideTable(slope: 0)
        #expect(!legacy.usesSoftJoins && legacy.predatesNaturalTuning,
                "positive control: a tuned vocal from before the update")
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNoteTransition(clipId: clip.id, segmentId: legacy.segments[0].id,
                                            widthMs: 200)
        let widened = try storedSet(store)
        #expect(!widened.predatesNaturalTuning && widened.usesSoftJoins
                && widened.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope
                && widened.formantCorrection == PitchEditSet.newSetFormantCorrection
                && widened.keepsConsonantsUntuned,
                "a slide width left an old vocal on the old rule (D4-1 (b))")
        #expect(store.undoHistory().undo.count == depth + 1, "the width and the update are ONE step")
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: legacy.segments[2].id,
                                             offsetCents: 100)
        let stored = try storedSet(store)
        var expected = widened
        expected.segments[2].pitchOffsetCents = 100
        #expect(stored == expected, "the second edit touched the vocal beyond its note")
        #expect(stored.segments[0].transitionOutMs == 200 && stored.segments[2].pitchOffsetCents == 100)
    }

    // MARK: - Natural tuning D4-1 (b): the first hand edit updates an old vocal
    //
    // The user ruled Q-U1 = (b) on 2026-09-26: "Update when I edit them: The
    // first note you drag on an old vocal updates the whole vocal (also one
    // Undo)." Appended here, not in a new suite: the @MainActor suite cadence
    // is full. The census (every writer routes through D4-1's home,
    // `afterHandEdit(from:)`) and the pure leg are
    // `NaturalTuningHandEditCensusTests`.

    /// A store whose clip ALREADY HOLDS `table`, as a project saved before
    /// the update reopens. ⚠️ A legacy fixture must be stored this way: a
    /// hand-edit setter that changes a note, called with `seedIfAbsent`,
    /// would update it on the way in.
    private func storeHolding(_ table: PitchEditSet) throws -> (ProjectStore, FakePitchWriterEngine, Clip, URL) {
        let url = try makeRealAudioFile()
        let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: url, pitchEdits: table)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = FakePitchWriterEngine()
        store.engine = engine
        return (store, engine, clip, url)
    }

    /// `NaturalTuningHandEditCensusTests.legacyVocal()` with a kept wobble on
    /// A, so a Reset Wobble has something to put back.
    private func d41LegacyVocal(slope: Double = 0) -> PitchEditSet {
        var legacy = NaturalTuningHandEditCensusTests.legacyVocal(slope: slope)
        legacy.segments[0].vibratoScale = 0.5
        return legacy
    }

    /// One call of every per-note hand-edit writer (the census's
    /// `handEditWriters`, plus `setClipNoteVibrato`, the one-item form of
    /// `setClipNotesVibrato`), each on a note of `d41LegacyVocal()`'s shape.
    private func d41HandEdits(_ v: PitchEditSet) -> [(String, (ProjectStore, UUID) throws -> Void)] {
        let a = v.segments[0], b = v.segments[1], c = v.segments[3]
        let structural = PitchCorrectionUndoKey.structuralKey
        return [
            ("setClipNotePitchOffset", { store, clip in
                _ = try store.setClipNotePitchOffset(clipId: clip, segmentId: b.id, offsetCents: 50) }),
            ("setClipNotePitchOffsets", { store, clip in
                _ = try store.setClipNotePitchOffsets(
                    clipId: clip, offsets: [NotePitchOffset(segmentId: c.id, offsetCents: -80)],
                    undoKey: structural) }),
            ("splitClipNoteSegment", { store, clip in
                _ = try store.splitClipNoteSegment(clipId: clip, segmentId: a.id, atSourceSecond: 0.2) }),
            ("setClipNotesCleared", { store, clip in
                _ = try store.setClipNotesCleared(clipId: clip, segmentIds: [c.id], cleared: true) }),
            ("setClipNoteGain", { store, clip in
                _ = try store.setClipNoteGain(clipId: clip, segmentIds: [c.id], gainDb: -6) }),
            ("setClipNoteFormant", { store, clip in
                _ = try store.setClipNoteFormant(clipId: clip, segmentIds: [b.id], semitones: -2) }),
            ("setClipNoteTransition", { store, clip in
                _ = try store.setClipNoteTransition(clipId: clip, segmentId: a.id, widthMs: 120) }),
            ("setClipNoteGlideFollow", { store, clip in
                _ = try store.setClipNoteGlideFollow(clipId: clip, segmentId: b.id, amount: 1) }),
            ("setClipNoteVibrato", { store, clip in
                _ = try store.setClipNoteVibrato(clipId: clip, segmentId: b.id,
                                                 edit: NoteVibratoEdit(vibratoRateHz: 5.5,
                                                                       vibratoDepthCents: 30)) }),
            ("setClipNotesVibrato", { store, clip in
                _ = try store.setClipNotesVibrato(
                    clipId: clip, edits: [NoteVibratoItem(segmentId: c.id, edit: NoteVibratoEdit(driftScale: 0.3))],
                    undoKey: structural) }),
            ("resetClipNoteVibrato", { store, clip in
                _ = try store.resetClipNoteVibrato(clipId: clip, segmentId: a.id) }),
            ("setClipNoteShapes", { store, clip in
                _ = try store.setClipNoteShapes(
                    clipId: clip,
                    shapes: [b.id: NoteShapeSamples(startIndex: NoteShapeSamples.gridSpan(of: b).lowerBound + 4,
                                                    tenthsOfCents: [200, 300])]) }),
        ]
    }

    /// ⭐ THE RULING, WRITER BY WRITER. On an old vocal every per-note writer
    /// stores its edit AND the update (X4's `upgradedToNaturalTuning`: voice
    /// size kept, consonants untuned, the default slope), as ONE undo step,
    /// and one Undo gives back the old vocal byte for byte (the encoded clip:
    /// the digest and the render are functions of it). On a NEW set the same
    /// call changes only its notes: the switch is inert there.
    @Test("D4-1 (b): every per-note writer updates an old vocal in ONE undo step, one Undo restores it byte for byte, and a new set is untouched")
    func everyHandEditUpdatesAnOldVocalAsOneStep() throws {
        let legacy = d41LegacyVocal()
        try #require(legacy.predatesNaturalTuning, "precondition: a tuned vocal from before the update")
        let fresh = NaturalTuningFieldCarryTests.nonLegacy(legacy)
        let calls = d41HandEdits(legacy)
        let census = NaturalTuningHandEditCensusTests.self
        #expect(Set(calls.map { "\(census.noteEdits):\($0.0)" })
                    == census.handEditWriters.union(["\(census.noteEdits):setClipNoteVibrato"]),
                "this table must call every writer the census lists, and the census every writer here")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (name, call) in calls {
            let (store, engine, clip, url) = try storeHolding(legacy)
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            let oldClip = try encoder.encode(store.tracks[0].clips[0])
            let depth = store.undoHistory().undo.count
            try call(store, clip.id)
            let stored = try storedSet(store)
            #expect(stored.segments != legacy.segments, "\(name) wrote nothing, so this proves nothing")
            #expect(!stored.predatesNaturalTuning
                    && stored.formantCorrection == PitchEditSet.newSetFormantCorrection
                    && stored.keepsConsonantsUntuned
                    && stored.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope,
                    "\(name): the first hand edit left an old vocal on the old rule (D4-1 (b))")
            #expect(stored == legacy.withSegments(stored.segments).upgradedToNaturalTuning(),
                    "\(name) changed more than its notes and the update")
            #expect(store.undoHistory().undo.count == depth + 1,
                    "\(name): the edit and the update must be ONE undo step")
            _ = try store.undo()
            #expect(try encoder.encode(store.tracks[0].clips[0]) == oldClip,
                    "\(name): one Undo did not give back the old vocal byte for byte")

            // The same call on a NEW set: its notes only.
            let (newStore, newEngine, newClip, newURL) = try storeHolding(fresh)
            defer { try? FileManager.default.removeItem(at: newURL); _ = newEngine }
            try call(newStore, newClip.id)
            let edited = try storedSet(newStore)
            #expect(edited.segments != fresh.segments, "\(name) wrote nothing on the new set")
            #expect(edited == fresh.withSegments(edited.segments),
                    "\(name) touched a set-level field of a set that is already new")
        }
    }

    /// The explicit set-level switches write their own field and nothing
    /// else, on an old vocal too (X4): they are requests, not hand edits.
    @Test("D4-1 (b): a set-level switch on an old vocal changes its own field only, never the other two")
    func setLevelSwitchesDoNotUpdateAnOldVocal() throws {
        let legacy = d41LegacyVocal()
        let switches: [(String, String, (ProjectStore, UUID) throws -> Void)] = [
            ("setClipFormantCorrection", "formantCorrection", { store, clip in
                _ = try store.setClipFormantCorrection(clipId: clip, amount: 0.5) }),
            ("setClipConsonantProtection", "consonantProtection", { store, clip in
                _ = try store.setClipConsonantProtection(clipId: clip, enabled: true) }),
            ("setClipPitchTransitionSmoothness", "transitionSlopeCentsPerSecond", { store, clip in
                _ = try store.setClipPitchTransitionSmoothness(clipId: clip, centsPerSecond: nil) }),
        ]
        for (name, own, flip) in switches {
            let (store, engine, clip, url) = try storeHolding(legacy)
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            let depth = store.undoHistory().undo.count
            try flip(store, clip.id)
            let stored = try storedSet(store)
            var others = NaturalTuningFieldCarryTests.setLevelFields(stored)
            var legacyOthers = NaturalTuningFieldCarryTests.setLevelFields(legacy)
            #expect(others[own] != legacyOthers[own], "\(name) did not write its own field")
            others[own] = nil
            legacyOthers[own] = nil
            #expect(others == legacyOthers, "\(name) updated more of an old vocal than its own field")
            #expect(stored.segments == legacy.segments)
            #expect(store.undoHistory().undo.count == depth + 1)
        }
    }

    /// C4's ruling survives D4-1: a slope somebody PICKED is kept by the
    /// update a hand edit makes; the other two fields are still set.
    @Test("D4-1 (b): a hand edit on an old vocal whose slide smoothness was picked keeps the pick")
    func aPickedSlopeSurvivesTheUpdate() throws {
        let picked = d41LegacyVocal(slope: 6000)
        try #require(picked.predatesNaturalTuning, "a picked slope alone does not make a vocal new")
        let (store, engine, clip, url) = try storeHolding(picked)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: picked.segments[1].id, offsetCents: 40)
        let stored = try storedSet(store)
        #expect(stored.transitionSlopeCentsPerSecond == 6000, "the update threw away an explicit smoothness pick")
        #expect(stored.formantCorrection == PitchEditSet.newSetFormantCorrection && stored.keepsConsonantsUntuned)
    }

    /// Only the FIRST edit updates: the second changes its note alone, each
    /// edit is its own undo step, and undoing both gives back the old vocal.
    /// The draft a pitch drag plays (`applyingNotePitchOffsets`, what
    /// `previewClipNotePitchDraft` span-renders) is the set its release stores.
    @Test("D4-1 (b): the first drag's draft IS the updated vocal the release stores; a second edit changes only its note")
    func firstDraftIsTheCommitAndSecondEditIsPlain() throws {
        let legacy = d41LegacyVocal()
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let depth = store.undoHistory().undo.count
        let offsets = [NotePitchOffset(segmentId: legacy.segments[1].id, offsetCents: 120)]
        let draft = try legacy.applyingNotePitchOffsets(offsets, clipId: clip.id)
        #expect(!draft.predatesNaturalTuning, "the draft plays the old vocal during the first drag")
        _ = try store.setClipNotePitchOffsets(clipId: clip.id, offsets: offsets,
                                              undoKey: PitchCorrectionUndoKey.structuralKey)
        let first = try storedSet(store)
        #expect(first == draft, "the draft heard during the first drag is not what the release stored")

        _ = try store.setClipNoteGain(clipId: clip.id, segmentIds: [legacy.segments[3].id], gainDb: -3)
        let second = try storedSet(store)
        var expected = first
        expected.segments[3].amplitudeDb = -3
        #expect(second == expected, "a second edit touched the vocal beyond its note")
        #expect(store.undoHistory().undo.count == depth + 2)
        _ = try store.undo()
        #expect(try storedSet(store) == first)
        _ = try store.undo()
        #expect(try storedSet(store) == legacy, "two Undos did not give back the old vocal")
    }

    /// One call of every per-note hand-edit writer that changes NO note on
    /// `d41LegacyVocal()`: each writes a value its note already has. The
    /// split has no such form (it always adds a note), so it is not here.
    private func d41NoOpEdits(_ v: PitchEditSet) -> [(String, (ProjectStore, UUID) throws -> Void)] {
        let a = v.segments[0], b = v.segments[1], c = v.segments[3]
        let structural = PitchCorrectionUndoKey.structuralKey
        return [
            ("setClipNotePitchOffset", { store, clip in
                _ = try store.setClipNotePitchOffset(clipId: clip, segmentId: b.id, offsetCents: 0) }),
            ("setClipNotePitchOffsets", { store, clip in
                _ = try store.setClipNotePitchOffsets(
                    clipId: clip, offsets: [NotePitchOffset(segmentId: c.id, offsetCents: 0)],
                    undoKey: structural) }),
            ("setClipNotesCleared", { store, clip in
                _ = try store.setClipNotesCleared(clipId: clip, segmentIds: [c.id], cleared: false) }),
            ("setClipNoteGain", { store, clip in
                _ = try store.setClipNoteGain(clipId: clip, segmentIds: [c.id], gainDb: 0) }),
            ("setClipNoteFormant", { store, clip in
                _ = try store.setClipNoteFormant(clipId: clip, segmentIds: [b.id], semitones: 0) }),
            ("setClipNoteTransition", { store, clip in
                _ = try store.setClipNoteTransition(clipId: clip, segmentId: a.id, widthMs: nil) }),
            ("setClipNoteGlideFollow", { store, clip in
                _ = try store.setClipNoteGlideFollow(clipId: clip, segmentId: b.id, amount: 0) }),
            ("setClipNoteVibrato", { store, clip in
                _ = try store.setClipNoteVibrato(clipId: clip, segmentId: b.id, edit: .asSung) }),
            ("setClipNotesVibrato", { store, clip in
                _ = try store.setClipNotesVibrato(
                    clipId: clip, edits: [NoteVibratoItem(segmentId: c.id, edit: NoteVibratoEdit(driftScale: 1))],
                    undoKey: structural) }),
            ("resetClipNoteVibrato", { store, clip in
                _ = try store.resetClipNoteVibrato(clipId: clip, segmentId: b.id) }),
            ("setClipNoteShapes", { store, clip in
                _ = try store.setClipNoteShapes(clipId: clip, shapes: [b.id: .clear]) }),
        ]
    }

    /// ⭐ THE NO-OP RULE (2026-09-27, on the user's words "the first note you
    /// DRAG"): an edit that changes no note leaves an old vocal EXACTLY as it
    /// is: the clip byte for byte, still predating natural tuning, and no
    /// undo step, so no upgrade can hide in the history. The real-change half
    /// is `everyHandEditUpdatesAnOldVocalAsOneStep`.
    @Test("D4-1 no-op: an edit that changes no note leaves an old vocal byte for byte, still legacy, with no undo step")
    func aNoOpLeavesAnOldVocalAlone() throws {
        let legacy = d41LegacyVocal()
        try #require(legacy.predatesNaturalTuning, "precondition: a tuned vocal from before the update")
        let calls = d41NoOpEdits(legacy)
        let census = NaturalTuningHandEditCensusTests.self
        let expected = census.handEditWriters
            .subtracting(["\(census.noteEdits):splitClipNoteSegment"])
            .union(["\(census.noteEdits):setClipNoteVibrato"])
        #expect(Set(calls.map { "\(census.noteEdits):\($0.0)" }) == expected,
                "this table must call every writer the census lists except the split, which is never a no-op")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (name, call) in calls {
            let (store, engine, clip, url) = try storeHolding(legacy)
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            let oldClip = try encoder.encode(store.tracks[0].clips[0])
            let depth = store.undoHistory().undo.count
            try call(store, clip.id)
            #expect(try encoder.encode(store.tracks[0].clips[0]) == oldClip,
                    "\(name): an edit that changed no note changed the old vocal")
            #expect(try storedSet(store).predatesNaturalTuning, "\(name): a no-op updated an old vocal")
            #expect(store.undoHistory().undo.count == depth, "\(name): a no-op added an undo step")
        }
    }


    @Test("NT-C C4: setClipPitchTransitionSmoothness — nil is the default, 0 refused in words, ONE step each, undo back to legacy")
    func smoothnessSetterIsOneStep() throws {
        // A legacy vocal with a +50 c move on C, held ON the clip: storing it
        // through the pitch setter (as this fixture did) now updates it on
        // the way in (D4-1 (b)), and this test is about the legacy case.
        var legacy = slideTable(slope: 0)
        legacy.segments[2].pitchOffsetCents = 50
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let before = try storedSet(store)
        #expect(before.predatesNaturalTuning, "positive control: a legacy vocal")
        let depth = store.undoHistory().undo.count

        _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: nil)
        let defaulted = try storedSet(store)
        #expect(defaulted.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(defaulted.segments == before.segments && defaulted.formantCorrection == nil,
                "the explicit smoothness switched more than its own field")
        #expect(store.undoHistory().undo.count == depth + 1)

        #expect(refusal { _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: 0) }
                == PitchTransitionSentences.smoothnessZero)
        #expect(try storedSet(store) == defaulted && store.undoHistory().undo.count == depth + 1)

        _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: 6000)
        _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: 6000)
        #expect(try storedSet(store).transitionSlopeCentsPerSecond == 6000)
        #expect(store.undoHistory().undo.count == depth + 2, "a pick never coalesces; a repeat is a no-op")
        _ = try store.undo()
        _ = try store.undo()
        #expect(try storedSet(store) == before, "undo did not restore the legacy vocal")
    }

    @Test("NT-C C4: setClipNoteGlideFollow tilts a slide as ONE step; refuses a sound and a note with nothing to follow")
    func glideFollowSetterIsOneStep() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = slideTable()
        let b = seed.segments[1].id, s = seed.segments[3].id, d = seed.segments[4].id
        let depth = store.undoHistory().undo.count

        _ = try store.setClipNoteGlideFollow(clipId: clip.id, segmentId: b, amount: 1, seedIfAbsent: seed)
        let stored = try storedSet(store)
        #expect(stored.segments[1].glideFollow == 1)
        #expect(stored.segments.enumerated().allSatisfy { $0.offset == 1 || $0.element == seed.segments[$0.offset] })
        #expect(store.undoHistory().undo.count == depth + 1)
        // The tilt reaches the curve through the store: the slide starts at A's +3 st.
        let curve = PitchCorrectionCurve.make(editSet: stored)
        #expect(abs(curve.semitones(atSourceSecond: 1.0) - 3) < 1e-9)
        #expect(abs(curve.semitones(atSourceSecond: 1.5)) < 1e-9)

        #expect(refusal { _ = try store.setClipNoteGlideFollow(clipId: clip.id, segmentId: s, amount: 1) }
                == PitchTransitionSentences.soundCannotFollow(s))
        #expect(refusal { _ = try store.setClipNoteGlideFollow(clipId: clip.id, segmentId: d, amount: 1) }
                == PitchTransitionSentences.nothingToFollow(d))
        #expect(try storedSet(store) == stored && store.undoHistory().undo.count == depth + 1)
        _ = try store.undo()
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    /// G-SPLIT (§4.b.5): the LEFT half's join is new and interior (Δ = 0),
    /// so its width is Auto; the RIGHT half is the parent's rear join and
    /// keeps its width; both keep the follow; the set-level slope survives.
    @Test("NT-C C4 G-SPLIT: left half's width to Auto, right half keeps it, both keep the follow, the slope survives; undo restores")
    func splitRuleForSlides() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        var seed = slideTable(slope: 4500)
        seed.segments[1].transitionOutMs = 180
        seed.segments[1].glideFollow = 1
        let parent = seed.segments[1]
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [seed.segments[4].id],
                                          cleared: false, seedIfAbsent: seed)
        let before = try storedSet(store)
        let depth = store.undoHistory().undo.count

        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: parent.id, atSourceSecond: 1.25)
        let after = try storedSet(store)
        let left = try #require(after.segments.first { $0.id == parent.id })
        let right = try #require(after.segments.first { $0.startSeconds == 1.25 })
        #expect(left.transitionOutMs == 0, "the new interior join must be Auto")
        #expect(right.transitionOutMs == 180, "the rear join lost its width")
        #expect(left.glideFollow == 1 && right.glideFollow == 1, "a half stopped following")
        #expect(after.transitionSlopeCentsPerSecond == 4500, "the split dropped the slope")
        #expect(store.undoHistory().undo.count == depth + 1)
        _ = try store.undo()
        #expect(try storedSet(store) == before)
    }

    /// G-STAMP: presets seed the slope (R14) and read as untouched; a slide
    /// edit afterwards reads as a hand edit, so the next preset asks first.
    @Test("NT-C C4 G-STAMP: a preset's output carries the slope and reads untouched; a slide edit reads as hand-edited")
    func slideEditIsAHandEdit() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let preset = try storedSet(store)
        #expect(preset.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope,
                "R14: presets get the slope")
        #expect(preset.segments.allSatisfy { $0.glideFollow == 0 }, "R14: presets never tilt a slide")
        #expect(preset.hasHandEditsSinceAutoCorrect == false)
        _ = try store.setClipPitchTransitionSmoothness(clipId: clip.id, centsPerSecond: 6000)
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect == true,
                "a slide edit on a preset's output reads as untouched: the next preset would erase it")
    }

    // MARK: - Natural tuning §2 (NT-C C2): consonants keep their own pitch
    //
    // Design `docs/design/2026-09-25-natural-tuning.md` §2c, §2e, §2g G-C8.
    // Appended here, not in a new suite: the @MainActor suite cadence is full.
    // The pure mask, the reasons and the construction-site census are
    // `PitchConsonantMaskTests`.

    /// Four notes: A and B ABUT (a soft join, so a slide width and a follow
    /// can be written), then a 100 ms gap before C and D. `consonants` is the
    /// only thing that differs between the two runs of the carry gate.
    private func consonantCarryTable(consonants: Bool) -> PitchEditSet {
        var table = NaturalTuningFieldCarryTests.nonLegacy(PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.0, endSeconds: 0.4, detectedHz: 220, detectedConfidence: 0.9,
                        pitchOffsetCents: 100),
            NoteSegment(startSeconds: 0.4, endSeconds: 0.9, detectedHz: 240, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 1.0, endSeconds: 1.4, detectedHz: 260, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 1.5, endSeconds: 1.9, detectedHz: 280, detectedConfidence: 0.9),
        ]))
        table.keepsConsonantsUntuned = consonants
        return table
    }

    /// ⭐ G-C8's STORE HALF, for the flag specifically, BOTH WAYS: true in,
    /// true out, AND false in, false out (the negative control the
    /// all-fields carry test above cannot give: its seed is always true, so a
    /// writer that re-seeded the flag ON would pass it). Every DAWCore writer
    /// of a stored table, the C1/C4 set-level setters included; the split is
    /// the known rebuild.
    @Test("NT-C C2 G-C8: every note and set writer keeps the consonant setting: ON, OFF, and an OFF somebody chose")
    func consonantFlagSurvivesEveryWriter() throws {
        // NT-C2-F1 (W7-D2): the third state, a CHOSEN off, must survive every
        // writer as a chosen off, or the next preset re-seeds it ON.
        for state in PitchEditSet.ConsonantProtection.allCases {
            let flag = state == .on
            var seed = consonantCarryTable(consonants: flag)
            seed.consonantProtection = state
            let first = seed.segments[0].id
            let second = seed.segments[1].id
            let writers: [(String, (ProjectStore, UUID) throws -> Void)] = [
                ("setClipNotePitchOffset", { store, clip in
                    _ = try store.setClipNotePitchOffset(clipId: clip, segmentId: first,
                                                         offsetCents: 50, seedIfAbsent: seed) }),
                ("setClipNotePitchOffsets", { store, clip in
                    _ = try store.setClipNotePitchOffsets(
                        clipId: clip, offsets: [NotePitchOffset(segmentId: second, offsetCents: -50)],
                        seedIfAbsent: seed, undoKey: PitchCorrectionUndoKey.structuralKey) }),
                ("splitClipNoteSegment", { store, clip in
                    _ = try store.splitClipNoteSegment(clipId: clip, segmentId: first,
                                                       atSourceSecond: 0.2, seedIfAbsent: seed) }),
                ("setClipNotesCleared", { store, clip in
                    _ = try store.setClipNotesCleared(clipId: clip, segmentIds: [first],
                                                      cleared: true, seedIfAbsent: seed) }),
                ("setClipNoteGain", { store, clip in
                    _ = try store.setClipNoteGain(clipId: clip, segmentIds: [first],
                                                  gainDb: -6, seedIfAbsent: seed) }),
                ("setClipNoteVibrato", { store, clip in
                    _ = try store.setClipNoteVibrato(clipId: clip, segmentId: first,
                                                     edit: NoteVibratoEdit(vibratoRateHz: 5.5,
                                                                           vibratoDepthCents: 30),
                                                     seedIfAbsent: seed) }),
                ("setClipNoteFormant", { store, clip in
                    _ = try store.setClipNoteFormant(clipId: clip, segmentIds: [first],
                                                     semitones: -2, seedIfAbsent: seed) }),
                ("setClipFormantCorrection", { store, clip in
                    _ = try store.setClipFormantCorrection(clipId: clip, amount: 0.6,
                                                           seedIfAbsent: seed) }),
                ("setClipNoteTransition", { store, clip in
                    _ = try store.setClipNoteTransition(clipId: clip, segmentId: first,
                                                        widthMs: 200, seedIfAbsent: seed) }),
                ("setClipPitchTransitionSmoothness", { store, clip in
                    _ = try store.setClipPitchTransitionSmoothness(clipId: clip, centsPerSecond: 9000,
                                                                   seedIfAbsent: seed) }),
                ("setClipNoteGlideFollow", { store, clip in
                    _ = try store.setClipNoteGlideFollow(clipId: clip, segmentId: second,
                                                         amount: 0.25, seedIfAbsent: seed) }),
                // C5b-3a: the drawn pitch line.
                ("setClipNoteShapes", { store, clip in
                    _ = try store.setClipNoteShapes(
                        clipId: clip,
                        shapes: [first: NoteShapeSamples(
                            startIndex: NoteShapeSamples.gridSpan(of: seed.segments[0]).lowerBound + 5,
                            tenthsOfCents: [250, 400])],
                        seedIfAbsent: seed) }),
            ]
            for (name, write) in writers {
                let (store, engine, clip, url) = try audioStore()
                defer { try? FileManager.default.removeItem(at: url); _ = engine }
                try write(store, clip.id)
                let stored = try storedSet(store)
                #expect(stored != seed, "\(name) wrote nothing, so the carry below proves nothing")
                #expect(stored.keepsConsonantsUntuned == flag,
                        "\(name) turned consonant protection \(flag ? "OFF" : "ON") behind the user's back")
                #expect(stored.consonantProtection == state,
                        "\(name) turned a \(state) consonant setting into \(stored.consonantProtection)")
            }
        }
    }

    /// The setter (§2e): ONE undo step, the flag and nothing else (D4-1 on a
    /// LEGACY set: the voice size and the slides stay legacy), a no-op
    /// journals nothing, undo is exact, and it refuses in words.
    @Test("NT-C C2: setClipConsonantProtection writes the flag alone as ONE undo step, and refuses in words")
    func consonantProtectionSetter() throws {
        // A LEGACY tuned set, as a project saved before natural tuning reopens:
        // held ON the clip (`storeHolding`), because a hand-edit setter that
        // changes a note updates a legacy vocal on the way in (D4-1 (b)).
        var legacy = fourNoteTable()
        legacy.segments[1].pitchOffsetCents = 200
        legacy.retuneMs = 80
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let before = try storedSet(store)
        #expect(before.predatesNaturalTuning && !before.keepsConsonantsUntuned)
        let depth = store.undoHistory().undo.count

        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true)
        let after = try storedSet(store)
        #expect(after.keepsConsonantsUntuned)
        #expect(store.undoHistory().undo.count == depth + 1, "the switch must be exactly one undo step")
        #expect(store.undoHistory().undo.first == "Keep Consonants")
        // Nothing else moved: every other set-level field, and the notes.
        var others = NaturalTuningFieldCarryTests.setLevelFields(after)
        var expectedOthers = NaturalTuningFieldCarryTests.setLevelFields(before)
        others["consonantProtection"] = nil
        expectedOthers["consonantProtection"] = nil
        #expect(others == expectedOthers, "an explicit consonant switch upgraded other fields (D4-1)")
        #expect(after.segments == before.segments)
        #expect(after.formantCorrection == nil && after.transitionSlopeCentsPerSecond == 0)

        // A repeat is a no-op and journals nothing; off is its own step.
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true)
        #expect(store.undoHistory().undo.count == depth + 1)
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
        #expect(try storedSet(store).keepsConsonantsUntuned == false)
        #expect(store.undoHistory().undo.count == depth + 2)
        _ = try store.undo()
        _ = try store.undo()
        #expect(try storedSet(store) == before, "undo did not restore the set exactly")

        // Refusals: no tuning and no seed (in words, and nothing minted).
        let (bare, bareEngine, bareClip, bareURL) = try audioStore()
        defer { try? FileManager.default.removeItem(at: bareURL); _ = bareEngine }
        var message = ""
        do {
            _ = try bare.setClipConsonantProtection(clipId: bareClip.id, enabled: true)
            Issue.record("an untuned clip was given consonant protection")
        } catch let error as ProjectError {
            message = error.localizedDescription
        }
        #expect(message.contains(PitchConsonantSentences.noTuning), "\(message)")
        #expect(bare.tracks[0].clips[0].pitchEdits == nil)
        // An EMPTY seed is no tuning either.
        #expect(throws: ProjectError.self) {
            _ = try bare.setClipConsonantProtection(clipId: bareClip.id, enabled: true,
                                                    seedIfAbsent: .empty)
        }
        // With the editor's seed, the switch stores the seed with the flag set.
        let editorSeed = consonantCarryTable(consonants: true)
        _ = try bare.setClipConsonantProtection(clipId: bareClip.id, enabled: false,
                                                seedIfAbsent: editorSeed)
        #expect(try storedSet(bare).keepsConsonantsUntuned == false)
        #expect(try storedSet(bare).segments == editorSeed.segments)
        // A MIDI clip and an unknown clip.
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(throws: ProjectError.self) {
            _ = try midiStore.setClipConsonantProtection(clipId: midi.id, enabled: true)
        }
        #expect(throws: ProjectError.self) {
            _ = try store.setClipConsonantProtection(clipId: UUID(), enabled: true)
        }
    }

    /// §2b.5: a transposed clip still STORES the switch; the mix is then
    /// inactive and the one rule says why (the wire and the editor read it).
    @Test("NT-C C2: on a transposed clip the switch is stored, inactive, and says 'clip transposed'")
    func consonantProtectionOnATransposedClip() throws {
        let url = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let transposed = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                              pitchShiftSemitones: 2)
        let (store, engine, clip, spare) = try audioStore(clip: transposed)
        defer { try? FileManager.default.removeItem(at: spare); _ = engine }
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true,
                                                 seedIfAbsent: consonantCarryTable(consonants: false))
        let stored = try storedSet(store)
        let live = store.tracks[0].clips[0]
        #expect(stored.keepsConsonantsUntuned && stored.hasConsonantMix)
        #expect(stored.consonantMixInactiveReason(stretchRatio: live.stretchRatio,
                                                  clipSemitones: live.pitchShiftSemitones)
                == .clipTransposed)
        #expect(!stored.consonantMixIsActive(stretchRatio: live.stretchRatio,
                                             clipSemitones: live.pitchShiftSemitones))
    }

    // MARK: - NT-C2-F1 (W7-D2): a preset re-run keeps a CHOSEN consonant setting
    //
    // This superseded C2's "no carry" decision, which this block used to pin
    // (`autoCorrectSeedsConsonantsOn`) while it was an open question: a Bool
    // could not tell a legacy "off" from a picked "off". The stored state is
    // now `PitchEditSet.consonantProtection`; the pure half (bytes, the Bool
    // reading, the seed tripwire) is `ConsonantChoiceTests`.

    /// {legacy, natural} x {chosen ON, chosen OFF, never chosen}, plus the two
    /// shapes the orchestrator named as holes in an INFERRED rule: a legacy
    /// table switched ON then OFF (must stay off), and a legacy table given a
    /// voice size with consonants never chosen (must take the seed).
    @Test("NT-C2-F1 matrix: a preset re-run keeps a chosen consonant setting, ON or OFF, legacy or natural; only a never-chosen OFF takes the seed")
    func presetRerunKeepsAConsonantChoice() async throws {
        var legacy = fourNoteTable()
        legacy.segments[1].pitchOffsetCents = 200
        #expect(legacy.predatesNaturalTuning && legacy.consonantProtection == .offByDefault,
                "positive control: a vocal tuned before natural tuning, consonants never chosen")
        let natural = legacy.upgradedToNaturalTuning()
        #expect(!natural.predatesNaturalTuning && natural.consonantProtection == .on)

        enum Pick { case none, on, off, onThenOff, offThenOn, voiceSizeOnly }
        typealias State = PitchEditSet.ConsonantProtection
        let cells: [(name: String, table: PitchEditSet, pick: Pick, afterPick: State, afterPreset: State)] = [
            ("legacy, never chosen", legacy, .none, .offByDefault, .on),
            ("legacy, chosen ON", legacy, .on, .on, .on),
            ("legacy, chosen OFF (already off)", legacy, .off, .offByChoice, .offByChoice),
            ("legacy, ON then OFF", legacy, .onThenOff, .offByChoice, .offByChoice),
            ("legacy given a voice size only", legacy, .voiceSizeOnly, .offByDefault, .on),
            ("natural, never chosen (seeded ON)", natural, .none, .on, .on),
            ("natural, chosen ON (OFF then ON)", natural, .offThenOn, .on, .on),
            ("natural, chosen OFF", natural, .off, .offByChoice, .offByChoice),
        ]
        for cell in cells {
            let (store, engine, clip, url) = try storeHolding(cell.table)
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            switch cell.pick {
            case .none: break
            case .on: _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true)
            case .off: _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
            case .onThenOff:
                _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true)
                _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
            case .offThenOn:
                _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
                _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: true)
            case .voiceSizeOnly:
                _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.5)
                #expect(try !storedSet(store).predatesNaturalTuning, "control: the voice size made it natural")
            }
            #expect(try storedSet(store).consonantProtection == cell.afterPick, "\(cell.name): the pick")
            engine.stubResult = melodicResult()
            _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                     options: PitchCorrectionPreset.natural.options())
            let preset = try storedSet(store)
            #expect(preset.segments.count == 2, "control: \(cell.name) stored the preset's new notes")
            #expect(preset.consonantProtection == cell.afterPreset,
                    "\(cell.name): the preset re-run left consonants \(preset.consonantProtection)")
            #expect(preset.keepsConsonantsUntuned == (cell.afterPreset == .on))
            #expect(preset.hasHandEditsSinceAutoCorrect == false,
                    "\(cell.name): the kept setting was written after the stamp")
            if cell.pick == .voiceSizeOnly {
                #expect(preset.formantCorrection == 0.5, "the voice size was not carried")
            }
            // Comparing presets (Natural -> Tight) keeps it too.
            _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                     options: PitchCorrectionPreset.tight.options())
            #expect(try storedSet(store).consonantProtection == cell.afterPreset,
                    "\(cell.name): a second preset changed it")
        }
    }

    /// (c) and (d): the choice is ONE undo step, and picking OFF on an OFF
    /// nobody chose IS one (it records the choice: the next preset keeps the
    /// consonants off instead of switching them on). Undo gives back "never
    /// chosen" byte for byte; a pick of the state already stored journals
    /// nothing; the preset that kept the choice is a step of its own.
    @Test("NT-C2-F1 undo: OFF on a never-chosen OFF is one step, undo restores 'never chosen' exactly, and a same-state pick journals nothing")
    func consonantChoiceUndo() async throws {
        var legacy = fourNoteTable()
        legacy.segments[1].pitchOffsetCents = 200
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try storedSet(store)
        #expect(before.consonantProtection == .offByDefault)
        let depth = store.undoHistory().undo.count

        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
        let chosen = try storedSet(store)
        #expect(chosen.consonantProtection == .offByChoice)
        #expect(chosen.keepsConsonantsUntuned == before.keepsConsonantsUntuned, "a choice changed the sound")
        #expect(chosen.segments == before.segments)
        #expect(store.undoHistory().undo.count == depth + 1, "the choice was not journaled")
        #expect(store.undoHistory().undo.first == "Keep Consonants")
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
        #expect(store.undoHistory().undo.count == depth + 1, "a same-state pick journaled")

        _ = try store.undo()
        #expect(try storedSet(store) == before, "undo did not restore 'never chosen'")
        #expect(try encoder.encode(storedSet(store)) == encoder.encode(before))
        _ = try store.redo()
        #expect(try storedSet(store) == chosen)

        engine.stubResult = melodicResult()
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        #expect(try storedSet(store).consonantProtection == .offByChoice)
        #expect(store.undoHistory().undo.first == "Auto-Correct Pitch")
        _ = try store.undo()
        #expect(try storedSet(store) == chosen, "undoing the preset did not give back the chosen table")

        // ON on an ON (a new, seeded table) journals nothing.
        let (fresh, freshEngine, freshClip, freshURL) = try storeHolding(legacy.upgradedToNaturalTuning())
        defer { try? FileManager.default.removeItem(at: freshURL); _ = freshEngine }
        let freshDepth = fresh.undoHistory().undo.count
        _ = try fresh.setClipConsonantProtection(clipId: freshClip.id, enabled: true)
        #expect(fresh.undoHistory().undo.count == freshDepth, "ON on ON journaled")
        #expect(try storedSet(fresh).consonantProtection == .on)
    }

    /// NT-C2-F1 x D4-1: an old vocal whose consonants somebody switched OFF
    /// keeps them off through the natural-tuning update, by both doors (the
    /// first hand edit and the tap). The other fields update as X4 says; C4's
    /// slope rule is the precedent. Control: with no choice, the update still
    /// switches them on.
    @Test("NT-C2-F1 x D4-1: the natural-tuning update keeps a chosen consonant OFF, through a hand edit and through the tap")
    func updateKeepsAChosenConsonantOff() throws {
        let legacy = d41LegacyVocal()
        for door in ["hand edit", "tap"] {
            let (store, engine, clip, url) = try storeHolding(legacy)
            defer { try? FileManager.default.removeItem(at: url); _ = engine }
            _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
            #expect(try storedSet(store).predatesNaturalTuning, "the explicit switch updated the vocal")
            let depth = store.undoHistory().undo.count
            if door == "hand edit" {
                _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: legacy.segments[1].id,
                                                     offsetCents: 40)
            } else {
                _ = try store.upgradeToNaturalTuning(clipId: clip.id)
            }
            let updated = try storedSet(store)
            #expect(!updated.predatesNaturalTuning, "\(door): the vocal was not updated")
            #expect(updated.formantCorrection == PitchEditSet.newSetFormantCorrection
                        && updated.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
            #expect(updated.consonantProtection == .offByChoice,
                    "\(door): the update switched a chosen consonant OFF back on")
            #expect(store.undoHistory().undo.count == depth + 1, "\(door): not one undo step")
        }
        let (store, engine, clip, url) = try storeHolding(legacy)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        _ = try store.upgradeToNaturalTuning(clipId: clip.id)
        #expect(try storedSet(store).consonantProtection == .on, "control: an unchosen OFF is switched on (X4)")
    }

    // MARK: - m23-ap C5b-3a: the drawn pitch line (`setClipNoteShapes`)
    //
    // Design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`
    // §5.2/§5.3/§5.7. Appended here, not in a new suite: the @MainActor suite
    // cadence is full. The pure write rule (normalise, splice, halves, the set
    // transform) is `NoteShapeModelTests`. Every assertion reads the table
    // back out of the store.

    /// A (0.20-0.60) and B (0.70-1.10, tuned −15 c), sung; S (1.15-1.30), a
    /// SOUND. A NEW (natural-tuning) set, so "only the drawing changed" holds
    /// whichever way D4-1's switch stands; the legacy case has its own test.
    private func shapeTable() -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.2, endSeconds: 0.6, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 0.7, endSeconds: 1.1, detectedHz: 247, detectedConfidence: 0.9,
                        pitchOffsetCents: -15),
            NoteSegment(startSeconds: 1.15, endSeconds: 1.3, detectedHz: 247, detectedConfidence: 0.3,
                        origin: .unpitched),
        ]).upgradedToNaturalTuning()
    }

    /// `tenths` starting `offset` grid steps into `note`: a partial write.
    private func drawing(_ note: NoteSegment, offset: Int, _ tenths: [Int16]) -> NoteShapeSamples {
        NoteShapeSamples(startIndex: NoteShapeSamples.gridSpan(of: note).lowerBound + offset,
                         tenthsOfCents: tenths)
    }

    @Test("C5b-3a: setClipNoteShapes draws N notes as ONE 'Draw Pitch' step and ONE tracksDidChange, stores each normalised, moves nothing else, undo restores")
    func noteShapesSetterIsOneStep() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0], b = seed.segments[1]
        let depth = store.undoHistory().undo.count
        let pushes = engine.tracksDidChangeCalls

        _ = try store.setClipNoteShapes(clipId: clip.id,
                                        shapes: [a.id: drawing(a, offset: 10, [300, 600, 300]),
                                                 b.id: drawing(b, offset: 0, [-200])],
                                        seedIfAbsent: seed)

        #expect(store.undoHistory().undo.count == depth + 1, "two notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Draw Pitch")
        #expect(engine.tracksDidChangeCalls == pushes + 1, "one call must push the engine ONCE")
        let stored = try storedSet(store)
        let aSpan = NoteShapeSamples.gridSpan(of: a)
        // READ BACK: the note's whole grid span, zero-filled, the samples in place.
        #expect(stored.segments[0].shapeStartIndex == aSpan.lowerBound)
        try #require(stored.segments[0].shapeTenthsOfCents.count == aSpan.count,
                     "the write was not stored over the note's whole grid span")
        #expect(Array(stored.segments[0].shapeTenthsOfCents[10...12]) == [300, 600, 300])
        #expect(stored.segments[0].shapeTenthsOfCents.filter { $0 != 0 }.count == 3)
        #expect(stored.segments[1].shapeTenthsOfCents.first == -200)
        // ⭐ THE INVARIANCE CONTROL: every other field, and the sound, unmoved.
        for (before, after) in zip(seed.segments, stored.segments) {
            var bare = after
            bare.shapeStartIndex = 0
            bare.shapeTenthsOfCents = []
            #expect(bare == before, "a field other than the drawing moved on \(before.id)")
        }
        #expect(stored.segments[2] == seed.segments[2])
        #expect(stored.retuneMs == seed.retuneMs)
        // Undo brings the clip back exactly as it was: no table at all.
        _ = try store.undo()
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
    }

    @Test("C5b-3a: two strokes are two undo steps (structuralKey), and a write of what is already stored journals nothing")
    func noteShapesNeverCoalesceAndANoOpIsSilent() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0]
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 4, [100])],
                                        seedIfAbsent: seed)
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 4, [150])])
        #expect(store.undoHistory().undo.count == depth + 2,
                "two strokes inside the coalescing window must stay two steps, like two cuts")
        // The same drawing again, sent sparse or dense: normalised, it IS what
        // is stored, so nothing is journalled.
        let now = try storedSet(store)
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 4, [150])])
        _ = try store.setClipNoteShapes(clipId: clip.id,
                                        shapes: [a.id: NoteShapeSamples(storedIn: now.segments[0])])
        // A clear of an undrawn note stores what is there too.
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [seed.segments[1].id: .clear])
        #expect(store.undoHistory().undo.count == depth + 2, "a no-op journalled an undo step")
        #expect(try storedSet(store) == now)
    }

    /// ⛔ "REMOVE" EMPTIES THE ARRAY (the C5b-1 hand-off). An all-zero array is
    /// still a shape to the model (`hasShape`), and a clear that zeroed it
    /// would keep the note on the stretcher for a term of nothing.
    @Test("C5b-3a: a CLEAR empties the drawing, never zeroes it — 'Reset Drawn Shape', index 0, the note is identity again")
    func clearEmptiesTheDrawing() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0]
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 4, [100, 90])],
                                        seedIfAbsent: seed)
        #expect(try storedSet(store).segments[0].hasShape, "positive control: there is a drawing to remove")
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: .clear])
        #expect(store.undoHistory().undo.first == "Reset Drawn Shape")
        let cleared = try storedSet(store)
        #expect(cleared.segments[0].shapeTenthsOfCents.isEmpty, "a clear left samples behind")
        #expect(cleared.segments[0].shapeStartIndex == 0)
        #expect(!cleared.segments[0].hasShape)
        #expect(cleared.segments[0].isPitchIdentity, "a zeroed drawing keeps the note on the stretcher")
        #expect(cleared == seed)
        // Drawing ZEROS is the same removal (§5.2: all zero is stored empty).
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 4, [100])])
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: drawing(a, offset: 0, [0, 0, 0])])
        let zeroed = try storedSet(store)
        #expect(!zeroed.segments[0].hasShape && zeroed.segments[0].shapeStartIndex == 0)
    }

    @Test("C5b-3a: the store's write rule holds on read-back — clamped to ±1200 c, trimmed to the note, zero-filled, and the held ends stay home")
    func noteShapesClampTrimAndZeroFill() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0]
        let span = NoteShapeSamples.gridSpan(of: a)
        // Starts THREE samples before the note; one sample far past ±1200 c.
        _ = try store.setClipNoteShapes(
            clipId: clip.id,
            shapes: [a.id: NoteShapeSamples(startIndex: span.lowerBound - 3,
                                            tenthsOfCents: [7, 7, 7, 30_000, -500])],
            seedIfAbsent: seed)
        let stored = try storedSet(store)
        let note = stored.segments[0]
        #expect(note.shapeStartIndex == span.lowerBound, "samples before the note were kept")
        #expect(note.shapeTenthsOfCents.count == span.count, "the write was not zero-filled across the note")
        #expect(Array(note.shapeTenthsOfCents.prefix(3)) == [12_000, -500, 0])
        #expect(note.shapeTenthsOfCents.dropFirst(2).allSatisfy { $0 == 0 })
        // ⛔ THE HELD-ENDS TRAP, through the store and the render's curve: deep
        // in the note, past the write, the drawing plays nothing.
        let curve = PitchCorrectionCurve.make(editSet: stored)
        let late = NoteShapeSamples.seconds(atGridIndex: span.lowerBound + 20)
        #expect(curve.semitones(atSourceSecond: late) == 0,
                "the write's last sample was held across the rest of the note")
    }

    @Test("C5b-3a: refused in words and nothing written — no table, no notes, an unknown id (naming the count), a miss; unknown clip, MIDI, comp member")
    func noteShapesRefusals() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0]
        let draw = drawing(a, offset: 4, [100])
        // No stored table and no seed: the per-note setters' teaching text.
        #expect(refusal { _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: draw]) }
            .contains("no notes to edit yet"))
        // No notes named: refused BEFORE the seed is looked at; nothing stored.
        #expect(refusal { _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [:], seedIfAbsent: seed) }
                == NoteShapeSentences.nameAtLeastOneNote)
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        // An unknown id names how many notes the clip carries, and the GOOD
        // note beside it is not written either (all or nothing).
        let stranger = UUID()
        let unknown = refusal {
            _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: draw, stranger: draw],
                                            seedIfAbsent: seed)
        }
        #expect(unknown == "No note with id \(stranger) on clip \(clip.id). That clip carries 3 note(s); "
                + "read them back with `clip.getPitchEdits` before editing one.", "\(unknown)")
        #expect(try store.pitchEdits(forClipId: clip.id) == nil, "a refused call wrote the good note")
        // A write that reaches no part of its note.
        #expect(refusal {
            _ = try store.setClipNoteShapes(clipId: clip.id,
                                            shapes: [a.id: NoteShapeSamples(startIndex: 900, tenthsOfCents: [100])],
                                            seedIfAbsent: seed)
        } == NoteShapeSentences.drawingMissesTheNote(a))
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        // POSITIVE CONTROL: the same note alone is accepted.
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [a.id: draw], seedIfAbsent: seed)
        #expect(try storedSet(store).segments[0].hasShape)
        // An unknown clip, a MIDI clip, a take-group comp member.
        #expect(refusal { _ = try store.setClipNoteShapes(clipId: UUID(), shapes: [a.id: draw]) } != "NO REFUSAL")
        let midi = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let midiStore = ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [midi])])
        #expect(refusal {
            _ = try midiStore.setClipNoteShapes(clipId: midi.id, shapes: [a.id: draw], seedIfAbsent: seed)
        }.contains("MIDI"))
        var member = Clip(name: "Take 2", startBeat: 0, lengthBeats: 8,
                          audioFileURL: URL(fileURLWithPath: "/tmp/c5b3a-comp-member.wav"))
        member.takeGroupID = UUID()
        let memberStore = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [member])])
        #expect(refusal {
            _ = try memberStore.setClipNoteShapes(clipId: member.id, shapes: [a.id: draw], seedIfAbsent: seed)
        } != "NO REFUSAL")
        #expect(memberStore.tracks[0].clips[0].pitchEdits == nil)
    }

    /// ⭐ THE SOUND RULING (C5b-3a): REFUSE, like `setClipNoteFormant`. A breath
    /// or a consonant has no pitch line, so a drawing on one means nothing;
    /// a pitch MOVE (R21) does, which is why the pitch setters move sounds.
    @Test("C5b-3a sound ruling: drawing on a breath or consonant is REFUSED in words and writes nothing; its own hand-written drawing can be cleared")
    func noteShapesRefuseASound() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0], sound = seed.segments[2]
        try #require(sound.origin == .unpitched, "precondition: S is a sound")
        let depth = store.undoHistory().undo.count
        #expect(refusal {
            _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [sound.id: drawing(sound, offset: 2, [400])],
                                            seedIfAbsent: seed)
        } == NoteShapeSentences.soundHasNoPitchLine(sound.id))
        // Beside a sung note: all or nothing.
        #expect(refusal {
            _ = try store.setClipNoteShapes(clipId: clip.id,
                                            shapes: [a.id: drawing(a, offset: 2, [400]),
                                                     sound.id: drawing(sound, offset: 2, [400])],
                                            seedIfAbsent: seed)
        } == NoteShapeSentences.soundHasNoPitchLine(sound.id))
        #expect(try store.pitchEdits(forClipId: clip.id) == nil)
        #expect(store.undoHistory().undo.count == depth)
        // THE CLEANUP PATH: a sound carrying a hand-written drawing (only a
        // file can put one there) takes a clear, and comes back as it was.
        var handWritten = seed
        handWritten.segments[2].shapeStartIndex = NoteShapeSamples.gridSpan(of: sound).lowerBound
        handWritten.segments[2].shapeTenthsOfCents = [300, 300]
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [sound.id: .clear], seedIfAbsent: handWritten)
        #expect(try storedSet(store).segments[2] == sound)
        #expect(store.undoHistory().undo.first == "Reset Drawn Shape")
    }

    /// D4-1, WHICHEVER WAY THE ONE SWITCH STANDS
    /// (`PitchEditSet.handEditUpgradesLegacyVocal`; the user ruled Q-U1 = (b)
    /// on 2026-09-26, and the switch is ON): a drawing is a HAND edit, so
    /// the setter routes it through D4-1's home, `afterHandEdit(from:)`, like
    /// every other. Under (a) a legacy vocal stays legacy; under (b) it is
    /// upgraded in the SAME undo step. Either way a drawing that changes a
    /// note is exactly the drawing, then `afterHandEdit()`.
    @Test("C5b-3a D4-1: a drawing on a LEGACY vocal follows the one switch — (a) it stays legacy, (b) it is upgraded in the same step")
    func legacyVocalFollowsTheHandEditSwitch() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let legacy = slideTable(slope: 0)
        try #require(legacy.predatesNaturalTuning, "precondition: a tuned vocal from before the update")
        let first = legacy.segments[0]
        let write = drawing(first, offset: 6, [250])
        let depth = store.undoHistory().undo.count
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [first.id: write], seedIfAbsent: legacy)
        let stored = try storedSet(store)
        #expect(stored.segments[0].hasShape)
        #expect(store.undoHistory().undo.count == depth + 1, "the drawing and any upgrade are ONE step")
        if PitchEditSet.handEditUpgradesLegacyVocal {
            #expect(!stored.predatesNaturalTuning && stored.keepsConsonantsUntuned
                    && stored.formantCorrection != nil && stored.transitionSlopeCentsPerSecond > 0,
                    "(b): the drawing did not upgrade the legacy vocal")
        } else {
            #expect(stored.predatesNaturalTuning && stored.transitionSlopeCentsPerSecond == 0
                    && stored.formantCorrection == nil && !stored.keepsConsonantsUntuned,
                    "(a): a drawing switched a legacy vocal without the user's word")
        }
        var drawnOnly = legacy
        drawnOnly.segments[0] = write.applied(to: first)
        #expect(stored == drawnOnly.afterHandEdit(), "the setter is not the drawing then `afterHandEdit()`")
    }

    /// Provenance: the preset doors ask before replacing a set with hand
    /// edits, and a drawing must be one (`contentStamp` is the set's JSON).
    @Test("C5b-3a provenance: a drawing on a preset's output reads as hand-edited, so a preset asks before erasing it")
    func aDrawingIsAHandEditToThePresetDoors() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = longNoteResult(seconds: 1.0)
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let preset = try storedSet(store)
        #expect(!preset.hasHandEditsSinceAutoCorrect, "positive control: a preset's own output")
        let note = try #require(preset.segments.first { $0.origin != .unpitched })
        _ = try store.setClipNoteShapes(clipId: clip.id, shapes: [note.id: drawing(note, offset: 5, [120, 240])])
        #expect(try storedSet(store).hasHandEditsSinceAutoCorrect,
                "a drawing reads as the preset's output, so a preset would erase it silently")
    }

    /// ⭐ THE STORAGE GATE (design C5b-3's planted defect): a split that COPIED
    /// the whole drawing to both halves would SOUND right (on the global grid
    /// each half reads only inside its own gate), so a physics test stays
    /// green. Only storage can catch it.
    @Test("C5b-3a split STORAGE: each half holds exactly its own grid span of the drawing, and together exactly the parent's")
    func splitStoresEachHalfsOwnGridSpan() throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        let seed = shapeTable()
        let a = seed.segments[0]
        let span = NoteShapeSamples.gridSpan(of: a)
        let wiggle = span.map { Int16(($0 - span.lowerBound) % 17 * 40 - 300) }
        _ = try store.setClipNoteShapes(
            clipId: clip.id, shapes: [a.id: NoteShapeSamples(startIndex: span.lowerBound, tenthsOfCents: wiggle)],
            seedIfAbsent: seed)
        let parent = try storedSet(store).segments[0]
        try #require(parent.shapeTenthsOfCents == wiggle, "precondition: the drawing covers the whole note")
        let cut = 0.4567
        _ = try store.splitClipNoteSegment(clipId: clip.id, segmentId: a.id, atSourceSecond: cut)
        let stored = try storedSet(store)
        let left = try #require(stored.segments.first { $0.id == a.id })
        let right = try #require(stored.segments.first { $0.startSeconds == cut })
        let leftSpan = NoteShapeSamples.gridSpan(of: left)
        let rightSpan = NoteShapeSamples.gridSpan(of: right)
        try #require(leftSpan.lowerBound == span.lowerBound && leftSpan.upperBound == rightSpan.lowerBound
                        && rightSpan.upperBound == span.upperBound,
                     "precondition: the halves' grid spans tile the parent's")
        #expect(left.shapeStartIndex == leftSpan.lowerBound && left.shapeTenthsOfCents.count == leftSpan.count,
                "the left half holds \(left.shapeTenthsOfCents.count) samples from \(left.shapeStartIndex), not its own span \(leftSpan)")
        #expect(right.shapeStartIndex == rightSpan.lowerBound && right.shapeTenthsOfCents.count == rightSpan.count,
                "the right half holds \(right.shapeTenthsOfCents.count) samples from \(right.shapeStartIndex), not its own span \(rightSpan)")
        #expect(left.shapeTenthsOfCents + right.shapeTenthsOfCents == wiggle,
                "the halves together do not hold exactly the parent's samples, in order")
        // Undo brings the whole drawing back on the one note.
        _ = try store.undo()
        #expect(try storedSet(store).segments[0] == parent)
    }

    // MARK: - Natural tuning §1(e): auto-correct's voice-size override (W7-D2)
    //
    // `PitchAutoCorrectOptions.formantCorrection`: a number wins over the seed
    // AND the carry, clamped; nil is today's rule; a non-finite number is
    // refused in words before detection. Appended here, not in a new suite: the
    // @MainActor suite cadence is full. The pure policy, the options' bytes and
    // the digests are `VoiceSizeOverrideTests` / `ConsonantChoiceDigestTests`.

    @Test("§1(e) override: a named voice size beats the seed, is ONE undo step, and is written before the stamp")
    func voiceSizeOverrideBeatsTheSeed() async throws {
        let (store, engine, clip, url) = try audioStore()
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        let depth = store.undoHistory().undo.count
        var options = PitchCorrectionPreset.natural.options()
        options.formantCorrection = 0.3
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
        let stored = try storedSet(store)
        #expect(stored.formantCorrection == 0.3, "the override lost to the seed")
        #expect(stored.hasHandEditsSinceAutoCorrect == false,
                "the override was written after the stamp, so a preset's own output reads as hand-edited")
        #expect(store.undoHistory().undo.count == depth + 1)
        #expect(store.undoHistory().undo.first == "Auto-Correct Pitch")
        _ = try store.undo()
        #expect(store.tracks[0].clips[0].pitchEdits == nil, "one undo did not take the whole pass back")
        // Control: with no override the same pass takes the seed.
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        #expect(try storedSet(store).formantCorrection == PitchEditSet.newSetFormantCorrection)
    }

    @Test("§1(e) override: a named voice size beats the carried pick, clamped (0 is engaged, never legacy); nil still carries it")
    func voiceSizeOverrideBeatsTheCarry() async throws {
        var table = fourNoteTable().upgradedToNaturalTuning()
        table.segments[1].pitchOffsetCents = 200
        let (store, engine, clip, url) = try storeHolding(table)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.6)
        // Control: no override, so the preset CARRIES the pick (§1(c) D-F2).
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        #expect(try storedSet(store).formantCorrection == 0.6, "control: the carry did not hold")
        // Direct writes of the field (they bypass `init`'s clamp) must clamp in the store.
        for (named, expected) in [(0.2, 0.2), (1.7, 1.0), (-0.5, 0.0)] {
            var options = PitchCorrectionPreset.tight.options()
            options.formantCorrection = named
            _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options)
            let stored = try storedSet(store)
            #expect(stored.formantCorrection == expected, "\(named): the override lost to the carry, or was not clamped")
            #expect(!stored.predatesNaturalTuning, "\(named): an override stored legacy")
            #expect(stored.hasHandEditsSinceAutoCorrect == false)
        }
        // nil after an override: the carry reads the table as it is NOW (0.0).
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.gentle.options())
        #expect(try storedSet(store).formantCorrection == 0.0)
    }

    @Test("§1(e) refusal: NaN and ±infinity are refused in words before detection, ahead of replaceExisting; nothing stored, nothing journaled")
    func nonFiniteVoiceSizeIsRefusedBeforeDetection() async throws {
        // A hand-edited table (no stamp), so `replaceExisting: false` would
        // refuse too: the voice-size refusal must come FIRST (an argument
        // error before a state refusal).
        var table = fourNoteTable()
        table.segments[1].pitchOffsetCents = 200
        let (store, engine, clip, url) = try storeHolding(table)
        defer { try? FileManager.default.removeItem(at: url); _ = engine }
        engine.stubResult = melodicResult()
        try #require(table.hasHandEditsSinceAutoCorrect, "precondition: replaceExisting:false would refuse")
        let before = store.tracks[0].clips[0]
        let depth = store.undoHistory().undo.count
        for bad in [Double.nan, .infinity, -.infinity] {
            for viaInit in [false, true] {
                var options = PitchCorrectionPreset.natural.options()
                if viaInit {
                    options = PitchAutoCorrectOptions(scale: options.scale, strength: options.strength,
                                                      retuneMs: options.retuneMs,
                                                      preserveVibrato: options.preserveVibrato,
                                                      formantCorrection: bad)
                } else {
                    options.formantCorrection = bad
                }
                for replaceExisting in [true, false] {
                    var message = ""
                    do {
                        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: options,
                                                                 replaceExisting: replaceExisting)
                        Issue.record("\(bad): a voice size that is not a number was accepted")
                    } catch let error as ProjectError {
                        message = error.localizedDescription
                    }
                    #expect(message.contains("The voice-size amount has to be a number from 0 to 1"),
                            "\(bad), replaceExisting \(replaceExisting): \(message)")
                    #expect(message.contains("Nothing was changed"))
                    if bad.isNaN {
                        // The words, pinned once: the shape of
                        // `setClipFormantCorrection`'s own refusal, with this
                        // verb's alternative (leave it out) in the brackets.
                        #expect(message == "The voice-size amount has to be a number from 0 to 1 "
                                    + "(or left out to keep this clip's own amount); nan is not one. "
                                    + "Nothing was changed.")
                    }
                }
            }
        }
        #expect(engine.detectCalls == 0, "detection ran before the refusal")
        #expect(store.tracks[0].clips[0] == before, "a refused pass changed the clip")
        #expect(store.undoHistory().undo.count == depth, "a refused pass journaled")
        // Control: the same clip with a real number goes through.
        var fine = PitchCorrectionPreset.natural.options()
        fine.formantCorrection = 0.5
        _ = try await store.autoCorrectClipPitch(clipId: clip.id, options: fine)
        #expect(engine.detectCalls == 1)
        #expect(try storedSet(store).formantCorrection == 0.5)
    }
}
