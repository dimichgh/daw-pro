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
        var parent = seed.segments[0]
        parent.pitchOffsetCents = -44
        parent.driftScale = 0.25
        parent.vibratoScale = 0.5
        parent.formantOffsetSemitones = 3
        parent.amplitudeDb = -2.5
        // I7a: a cleared note split in two is two cleared halves. The right
        // half is carried through the Codable round trip (`reidentified`).
        parent.isCleared = true
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
            #expect(half.formantOffsetSemitones == 3)
            #expect(half.amplitudeDb == -2.5)
            #expect(half.isCleared, "a split dropped the clear on one half")
            #expect(half.detectedHz == parent.detectedHz)
            #expect(half.detectedConfidence == parent.detectedConfidence)
        }
        #expect(left.id != right.id)

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
        let changeable: Set<String> = ["id", "startSeconds", "endSeconds"]
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
}
