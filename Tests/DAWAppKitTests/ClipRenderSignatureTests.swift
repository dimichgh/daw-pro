import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

// p2-render-indicator — `ClipRenderSignature` is what `ContentView` watches to
// start the engine render-status poll, which is what makes the timeline
// shimmer a clip while its offline render is pending. Before this suite the
// signature looked only at ratio, semitones and formant, so a TUNING never
// started the poll: a tuned clip's render never shimmered, and a failed tuned
// render never showed.
//
// The legs drive the REAL store writers (the ones the app and the control port
// call) and compare the signature of `store.tracks` before and after, so each
// leg asks "does this edit, as the app performs it, move the signature?"
// rather than "does the function read this field?". Where no store writer
// exists (a clip rename; a raw field the engine keys on) the leg edits the
// value directly and says so.

/// `detectPitch` stub so the PRESET leg can run the real
/// `ProjectStore.autoCorrectClipPitch` — the `PitchCorrectionWriterTests`
/// fake (DAWCoreTests), copied because test targets cannot share a private
/// type.
@MainActor
private final class FakeDetectEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult: PitchDetectionResult
    var detectCalls = 0

    init(stubResult: PitchDetectionResult) { self.stubResult = stubResult }

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
@Suite("ClipRenderSignature — the timeline render light's trigger (p2-render-indicator)")
struct ClipRenderSignatureTests {

    /// Never opened: every writer used below except the preset resolves the
    /// clip by id and never stats its file (`locateEditableNoteClip`).
    private let vocalURL = URL(fileURLWithPath: "/tmp/p2ri-never-opened-vocal.wav")

    /// Three detected notes, the middle one pulled 35 cents flat — a set that
    /// bends the curve, so a clip carrying it renders
    /// (`Clip.hasPitchEdits`, `Clip.rendersThroughStretchCache`).
    private func tunedSet() -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.0, endSeconds: 0.5,
                        detectedHz: 220, detectedConfidence: 0.95),
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0,
                        detectedHz: 246.9, detectedConfidence: 0.95, pitchOffsetCents: -35),
            NoteSegment(startSeconds: 1.0, endSeconds: 1.5,
                        detectedHz: 261.6, detectedConfidence: 0.95),
        ])
    }

    /// The same three notes, detected and never edited: renders as nothing.
    private func untouchedSet() -> PitchEditSet {
        PitchEditSet(segments: tunedSet().segments.map {
            NoteSegment(id: $0.id, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                        detectedHz: $0.detectedHz, detectedConfidence: $0.detectedConfidence)
        })
    }

    private func vocal(stretchRatio: Double = 1, semitones: Double = 0,
                       pitchEdits: PitchEditSet? = nil) -> Clip {
        Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: vocalURL,
             stretchRatio: stretchRatio, pitchShiftSemitones: semitones,
             pitchEdits: pitchEdits)
    }

    /// One audio track holding `clips`. No engine attached: every writer used
    /// here reaches the engine only through `engine?.tracksDidChange`.
    private func makeStore(_ clips: Clip...) -> (store: ProjectStore, trackID: UUID) {
        let track = Track(name: "Vocals", kind: .audio, clips: clips)
        return (ProjectStore(tracks: [track]), track.id)
    }

    private func signature(_ store: ProjectStore) -> ClipRenderSignature {
        ClipRenderSignature(tracks: store.tracks)
    }

    // MARK: - The three stretch fields (these were covered before, and must stay so)

    @Test("stretch ratio: a time-stretch changes the signature")
    func ratioChangesSignature() throws {
        let clip = vocal()
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        try store.setClipStretch(trackId: trackID, clipId: clip.id, ratio: 1.5)
        #expect(store.tracks[0].clips[0].stretchRatio == 1.5)
        #expect(signature(store) != before)
    }

    @Test("pitch shift: a transpose changes the signature")
    func semitonesChangeSignature() throws {
        let clip = vocal()
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        try store.setClipStretch(trackId: trackID, clipId: clip.id, semitones: 3)
        #expect(store.tracks[0].clips[0].pitchShiftSemitones == 3)
        #expect(signature(store) != before)
    }

    @Test("formant: toggling formant keep on a transposed clip changes the signature")
    func formantChangesSignature() throws {
        let clip = vocal(semitones: 3)
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        try store.setClipStretch(trackId: trackID, clipId: clip.id, formantPreserve: true)
        #expect(store.tracks[0].clips[0].formantPreserve)
        #expect(signature(store) != before)
    }

    // MARK: - A tuning (the defect: none of these moved the old signature)

    @Test("tuning: applying a preset (clip.autoCorrectPitch) changes the signature")
    func presetChangesSignature() async throws {
        // A REAL file: the preset's detection checks `fileExists` first.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2ri-preset-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        let (store, _) = makeStore(clip)
        let engine = FakeDetectEngine(stubResult: Self.twoNotesOffPitch())
        store.engine = engine
        let before = signature(store)

        _ = try await store.autoCorrectClipPitch(
            clipId: clip.id,
            options: PitchAutoCorrectOptions(scale: .chromatic, strength: 1.0,
                                             retuneMs: PitchEditSet.engineMinimumRetuneMs,
                                             preserveVibrato: true))

        // The leg only means something if the preset really tuned the clip —
        // a signature that "did not change" because nothing was written would
        // pass the negative legs, not this one.
        #expect(engine.detectCalls == 1)
        #expect(store.tracks[0].clips[0].hasPitchEdits)
        #expect(signature(store) != before)
    }

    @Test("tuning: moving one note's pitch changes the signature")
    func noteOffsetChangesSignature() throws {
        let set = tunedSet()
        let clip = vocal(pitchEdits: set)
        let (store, _) = makeStore(clip)
        let before = signature(store)
        try store.setClipNotePitchOffset(clipId: clip.id, segmentId: set.segments[1].id,
                                         offsetCents: -20)
        #expect(store.tracks[0].clips[0].pitchEdits?.segments[1].pitchOffsetCents == -20)
        #expect(signature(store) != before)
    }

    @Test("tuning: splitting a note changes the signature")
    func noteSplitChangesSignature() throws {
        let set = tunedSet()
        let clip = vocal(pitchEdits: set)
        let (store, _) = makeStore(clip)
        let before = signature(store)
        try store.splitClipNoteSegment(clipId: clip.id, segmentId: set.segments[1].id,
                                       atSourceSecond: 0.75)
        #expect(store.tracks[0].clips[0].pitchEdits?.segments.count == 4)
        #expect(signature(store) != before)
    }

    @Test("tuning: clearing a clip's tuning changes the signature")
    func clearChangesSignature() throws {
        let clip = vocal(pitchEdits: tunedSet())
        let (store, _) = makeStore(clip)
        let before = signature(store)
        try store.clearClipPitchEdits(clipId: clip.id)
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
        #expect(signature(store) != before)
    }

    // MARK: - Edits that re-key no render must leave it alone

    @Test("unrelated: clip gain leaves the signature alone")
    func gainLeavesSignature() throws {
        let clip = vocal(stretchRatio: 1.5, semitones: 2, pitchEdits: tunedSet())
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        try store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: -6)
        #expect(store.tracks[0].clips[0].gainDb == -6)
        #expect(signature(store) == before)
    }

    @Test("unrelated: renaming a clip leaves the signature alone")
    func renameLeavesSignature() {
        // No store writer renames a clip, so the leg edits the value.
        let tracks = [Track(name: "Vocals", kind: .audio,
                            clips: [vocal(stretchRatio: 1.5, semitones: 2, pitchEdits: tunedSet())])]
        var renamed = tracks
        renamed[0].clips[0].name = "Lead vocal, take 3"
        #expect(ClipRenderSignature(tracks: renamed) == ClipRenderSignature(tracks: tracks))
    }

    @Test("unrelated: muting the track leaves the signature alone")
    func muteLeavesSignature() {
        let clip = vocal(stretchRatio: 1.5, semitones: 2, pitchEdits: tunedSet())
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        store.setTrackMute(id: trackID, muted: true)
        #expect(store.tracks[0].isMuted)
        #expect(signature(store) == before)
    }

    // MARK: - Exactness: the render key's own rules

    @Test("exact: a lone +0.0 to -0.0 flip in one note's offset changes the signature")
    func signedZeroFlipChangesSignature() throws {
        // `PitchEditSetDigest.hex` hashes BIT PATTERNS, so -0.0 cents re-keys
        // the render (new audio file, clip silent while it renders) although
        // `==` calls the two sets equal. The note is untouched (+0.0) and the
        // set still bends the curve through the middle note.
        let set = tunedSet()
        let clip = vocal(pitchEdits: set)
        let (store, _) = makeStore(clip)
        let before = signature(store)
        try store.setClipNotePitchOffset(clipId: clip.id, segmentId: set.segments[0].id,
                                         offsetCents: -0.0)
        let stored = try #require(store.tracks[0].clips[0].pitchEdits)
        #expect(stored.segments[0].pitchOffsetCents.sign == .minus,
                "precondition: the setter must store -0.0 for this leg to test anything")
        #expect(stored == set, "precondition: `==` must see no change")
        #expect(signature(store) != before)
    }

    @Test("exact: changing any one field of one note changes the signature")
    func everyNoteFieldIsCompared() {
        // A note using every feature, so each field is render material: with a
        // vibrato DEPTH set, the digest hashes the generator's rate and onset
        // too (`PitchEditSetDigest.hex`'s generator block).
        let n = NoteSegment(startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 246.9, detectedConfidence: 0.95,
                            pitchOffsetCents: -35, driftScale: 0.5, vibratoScale: 0.5,
                            vibratoRateHz: 5.5, vibratoDepthCents: 20, vibratoOnsetSeconds: 0.1,
                            formantOffsetSemitones: 1,
                            timeStartDeltaSeconds: 0.01, timeEndDeltaSeconds: -0.01,
                            amplitudeDb: -3)
        // The three `let` fields can only differ in a rebuilt note.
        func rebuilt(id: UUID? = nil, detectedHz: Double? = nil,
                     detectedConfidence: Double? = nil) -> NoteSegment {
            NoteSegment(id: id ?? n.id, startSeconds: n.startSeconds, endSeconds: n.endSeconds,
                        detectedHz: detectedHz ?? n.detectedHz,
                        detectedConfidence: detectedConfidence ?? n.detectedConfidence,
                        pitchOffsetCents: n.pitchOffsetCents, driftScale: n.driftScale,
                        vibratoScale: n.vibratoScale, vibratoRateHz: n.vibratoRateHz,
                        vibratoDepthCents: n.vibratoDepthCents,
                        vibratoOnsetSeconds: n.vibratoOnsetSeconds,
                        formantOffsetSemitones: n.formantOffsetSemitones,
                        timeStartDeltaSeconds: n.timeStartDeltaSeconds,
                        timeEndDeltaSeconds: n.timeEndDeltaSeconds, amplitudeDb: n.amplitudeDb)
        }
        var variants: [(field: String, note: NoteSegment)] = [
            ("id", rebuilt(id: UUID())),
            ("detectedHz", rebuilt(detectedHz: 247.5)),
            ("detectedConfidence", rebuilt(detectedConfidence: 0.9)),
        ]
        let nudges: [(String, WritableKeyPath<NoteSegment, Double>, Double)] = [
            ("startSeconds", \.startSeconds, 0.52),
            ("endSeconds", \.endSeconds, 0.98),
            ("pitchOffsetCents", \.pitchOffsetCents, -30),
            ("driftScale", \.driftScale, 0.25),
            ("vibratoScale", \.vibratoScale, 0.25),
            ("vibratoRateHz", \.vibratoRateHz, 6),
            ("vibratoDepthCents", \.vibratoDepthCents, 25),
            ("vibratoOnsetSeconds", \.vibratoOnsetSeconds, 0.2),
            ("formantOffsetSemitones", \.formantOffsetSemitones, 2),
            ("timeStartDeltaSeconds", \.timeStartDeltaSeconds, 0.02),
            ("timeEndDeltaSeconds", \.timeEndDeltaSeconds, -0.02),
            ("amplitudeDb", \.amplitudeDb, -6),
        ]
        for (field, path, value) in nudges {
            var changed = n
            changed[keyPath: path] = value
            variants.append((field, changed))
        }
        // Keeps this test's name true: a field added to `NoteSegment` is
        // compared by construction (the signature compares a note's bytes),
        // but this list has to grow by one line to PROVE it.
        #expect(variants.count == Mirror(reflecting: n).children.count,
                "NoteSegment gained a field — add a variant for it here")

        let base = [Track(name: "Vocals", kind: .audio,
                          clips: [vocal(pitchEdits: PitchEditSet(segments: [n]))])]
        let before = ClipRenderSignature(tracks: base)
        for (field, note) in variants {
            var edited = base
            edited[0].clips[0].pitchEdits?.segments = [note]
            #expect(ClipRenderSignature(tracks: edited) != before,
                    "a change to \(field) alone re-keys the render, so it must move the signature")
        }
    }

    @Test("exact: a note is a UUID followed by Doubles, so comparing its bytes compares its fields")
    func noteBytesAreExactlyItsFields() {
        // The premise of `ClipRenderSignature.Tuning.bitIdentical`, stated in
        // the type's doc. A field that is not a Double (a Bool, an enum, a
        // String) could add padding or a reference, so equal notes might read
        // unequal. That costs only a spare poll, but the doc would be wrong.
        let note = tunedSet().segments[0]
        let fields = Mirror(reflecting: note).children.count
        #expect(MemoryLayout<NoteSegment>.size
                    == MemoryLayout<UUID>.size + (fields - 1) * MemoryLayout<Double>.size,
                "NoteSegment is no longer a UUID followed by Doubles — revisit the byte comparison")
        #expect(MemoryLayout<NoteSegment>.size == MemoryLayout<NoteSegment>.stride)
    }

    @Test("exact: changing the retune speed or the analysis version changes the signature")
    func setLevelFieldsAreCompared() {
        let base = [Track(name: "Vocals", kind: .audio, clips: [vocal(pitchEdits: tunedSet())])]
        var slower = base
        slower[0].clips[0].pitchEdits?.retuneMs = 120
        var otherDetector = base
        otherDetector[0].clips[0].pitchEdits?.analysisVersion += 1
        #expect(ClipRenderSignature(tracks: slower) != ClipRenderSignature(tracks: base))
        #expect(ClipRenderSignature(tracks: otherDetector) != ClipRenderSignature(tracks: base))
    }

    @Test("exact: detecting notes nobody has edited leaves the signature alone")
    func untouchedNoteTableLeavesSignature() {
        // A detected-but-unedited table renders as nothing (identity bypass),
        // and the render key's digest is "" for it — the same key as no set.
        let tracks = [Track(name: "Vocals", kind: .audio, clips: [vocal()])]
        var detected = tracks
        detected[0].clips[0].pitchEdits = untouchedSet()
        #expect(detected[0].clips[0].pitchEdits != nil)
        #expect(!detected[0].clips[0].rendersThroughStretchCache)
        #expect(ClipRenderSignature(tracks: detected) == ClipRenderSignature(tracks: tracks))
    }

    @Test("exact: a preset's content stamp alone leaves the signature alone")
    func autoCorrectStampLeavesSignature() {
        // Not render material (PitchCorrection.swift, `autoCorrectStamp`):
        // two sets with the same notes render identically whoever wrote them.
        let tracks = [Track(name: "Vocals", kind: .audio,
                            clips: [vocal(pitchEdits: tunedSet())])]
        var stamped = tracks
        stamped[0].clips[0].pitchEdits?.autoCorrectStamp = "00000000deadbeef"
        #expect(stamped != tracks)
        #expect(ClipRenderSignature(tracks: stamped) == ClipRenderSignature(tracks: tracks))
    }

    @Test("exact: toggling formant keep on a clip that renders nothing leaves the signature alone")
    func formantOnIdentityClipLeavesSignature() throws {
        let clip = vocal()
        let (store, trackID) = makeStore(clip)
        let before = signature(store)
        try store.setClipStretch(trackId: trackID, clipId: clip.id, formantPreserve: true)
        #expect(store.tracks[0].clips[0].formantPreserve)
        #expect(!store.tracks[0].clips[0].rendersThroughStretchCache)
        #expect(signature(store) == before)
    }

    @Test("exact: moving and reordering clips leaves the signature alone")
    func clipGeometryLeavesSignature() {
        // A render covers the whole source file (StretchRenderCache banner),
        // so clip position never re-keys one.
        let a = vocal(stretchRatio: 1.5, pitchEdits: tunedSet())
        var b = vocal(semitones: -2)
        b.startBeat = 16
        let tracks = [Track(name: "Vocals", kind: .audio, clips: [a, b])]
        var moved = tracks
        moved[0].clips[0].startBeat = 32
        moved[0].clips.reverse()
        #expect(ClipRenderSignature(tracks: moved) == ClipRenderSignature(tracks: tracks))
    }

    @Test("exact: repointing a rendering clip at another source file changes the signature")
    func sourceRepointChangesSignature() {
        // `ProjectStore.save` rewrites `audioFileURL` in place when it copies
        // media into the bundle, and the source path is part of the render key.
        let tracks = [Track(name: "Vocals", kind: .audio,
                            clips: [vocal(stretchRatio: 1.5)])]
        var repointed = tracks
        repointed[0].clips[0].audioFileURL = URL(fileURLWithPath: "/tmp/p2ri-bundle/media/vocal.wav")
        #expect(ClipRenderSignature(tracks: repointed) != ClipRenderSignature(tracks: tracks))
    }

    @Test("exact: adding a clip that renders nothing leaves the signature alone; adding one that renders changes it")
    func onlyRenderingClipsCount() {
        let tracks = [Track(name: "Vocals", kind: .audio, clips: [vocal(stretchRatio: 1.5)])]
        var plusPlain = tracks
        plusPlain[0].clips.append(vocal())
        var plusTuned = tracks
        plusTuned[0].clips.append(vocal(pitchEdits: tunedSet()))
        #expect(ClipRenderSignature(tracks: plusPlain) == ClipRenderSignature(tracks: tracks))
        #expect(ClipRenderSignature(tracks: plusTuned) != ClipRenderSignature(tracks: tracks))
    }

    // MARK: - Fixture

    /// Two voiced runs off a chromatic centre (225 Hz, 250 Hz), the
    /// `PitchCorrectionWriterTests.melodicResult` fixture — enough for the
    /// preset to write a set that bends the curve.
    private static func twoNotesOffPitch() -> PitchDetectionResult {
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
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.15,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }
}
