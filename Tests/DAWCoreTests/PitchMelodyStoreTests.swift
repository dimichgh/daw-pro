import Foundation
import Testing
@testable import DAWCore

// Tune to Melody, M2 (W7-TTM2): `ProjectStore.autoCorrectClipPitchReport(…, melody:)`, the
// store's half (design `2026-09-24-unpitched-notes-presets-midi-targets.md` §3.2-§3.4, §3.6).
//
// An EXTENSION of the existing `@MainActor` suite `PitchCorrectionWriterTests`, not a new
// suite: the @MainActor suite census (`MainActorOccupancySiteTests`, cap 394) has one slot
// left, and W7-MODP's `extension PersistenceTests` is the precedent. Every test name starts
// with `tuneToMelody` so a filter isolates them.
//
// The fixture, used throughout (120 bpm, so a beat is 0.5 s; the vocal starts at beat 0 and
// plays its file from 0, ratio 1, so a timeline beat b is source second b/2):
//   sung    56.6 @ [0.2, 0.7)   59.6 @ [0.9, 1.4)   63.6 @ [1.6, 2.1)    (each 40 c flat)
//   melody  A3 57 beats 0.4-1.4 C4 60 beats 1.8-2.8 E4 64 beats 3.2-4.2  (= the same seconds)
// so at strength 1 every held note moves +40 c, and at Natural's 0.85 it would move +34 c.

/// The pitch-writer fake with a hook INSIDE the detection await (the C-F3 race precedent of
/// `FakePitchDetectionEngine.beforeReturning`), so a test can edit the melody while the store
/// is still detecting.
@MainActor
private final class MelodyWriterEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult: PitchDetectionResult
    var detectCalls = 0
    var tracksDidChangeCalls = 0
    var beforeReturning: (@MainActor () -> Void)?

    init(stubResult: PitchDetectionResult) { self.stubResult = stubResult }

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        detectCalls += 1
        beforeReturning?()
        return stubResult
    }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
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

/// The fixture's numbers, one home.
private enum MelodyFixture {
    static let frameRateHz = 62.5
    static let sung: [(start: Double, end: Double, midi: Double)] = [
        (0.2, 0.7, 56.6), (0.9, 1.4, 59.6), (1.6, 2.1, 63.6),
    ]
    /// (pitch, start beat, length beats), the melody over `sung`.
    static let melody: [(pitch: Int, start: Double, length: Double)] = [
        (57, 0.4, 1.0), (60, 1.8, 1.0), (64, 3.2, 1.0),
    ]

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    static func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    static func notes(_ spec: [(pitch: Int, start: Double, length: Double)] = melody) -> [MIDINote] {
        spec.map { MIDINote(pitch: $0.pitch, startBeat: $0.start, lengthBeats: $0.length) }
    }

    /// 62.5 fps frames over [0, 3.0): voiced (-12 dBFS) inside a sung span, unvoiced
    /// (-70 dBFS) elsewhere, so each sung note is its own voiced run.
    static func contour(_ sung: [(start: Double, end: Double, midi: Double)] = sung)
        -> PitchDetectionResult {
        let period = 1 / frameRateHz
        let count = Int((3.0 / period).rounded())
        let frames = (0..<count).map { i -> ClipPitchFrame in
            let t = Double(i) * period
            if let note = sung.first(where: { t >= $0.start && t < $0.end }) {
                return ClipPitchFrame(timeSeconds: t, frequencyHz: hz(note.midi), confidence: 0.97,
                                      levelDbfs: -12, absence: nil)
            }
            return ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.1,
                                  levelDbfs: -70, absence: .belowConfidence)
        }
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: frameRateHz, analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: 0, windowDurationSeconds: 3.0,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }
}

extension PitchCorrectionWriterTests {

    /// A store at 120 bpm with a vocal (audio, a real file for `detectClipPitch`'s existence
    /// check) and a lead track holding `leadClips` (default: one MIDI clip with the melody).
    private func melodyStore(
        sung: [(start: Double, end: Double, midi: Double)] = MelodyFixture.sung,
        leadClips: [Clip]? = nil, vocalShift: Double = 0
    ) throws -> (store: ProjectStore, engine: MelodyWriterEngine, vocal: Clip, lead: Track, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ttm2-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        let vocal = Clip(name: "Verse take", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                         pitchShiftSemitones: vocalShift)
        let clips = leadClips ?? [Clip(name: "Lead", startBeat: 0, lengthBeats: 24,
                                       notes: MelodyFixture.notes())]
        let lead = Track(name: "Lead", kind: .instrument, clips: clips)
        var transport = TransportState()
        transport.tempoBPM = 120
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [vocal]), lead],
                                 transport: transport)
        let engine = MelodyWriterEngine(stubResult: MelodyFixture.contour(sung))
        store.engine = engine
        return (store, engine, vocal, lead, url)
    }

    /// The stored NOTES (sounds excluded), in time order.
    private func storedNotes(_ store: ProjectStore) -> [NoteSegment] {
        (store.tracks[0].clips[0].pitchEdits?.segments ?? [])
            .filter { $0.origin != .unpitched }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private static var natural: PitchAutoCorrectOptions {
        PitchCorrectionPreset.natural.options(scale: .chromatic)
    }

    @Test("tuneToMelody S1: each sung note lands ON its melody note (+40 c), at strength 1 under Natural's 0.85")
    func tuneToMelodyLandsOnTheMelody() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let pushes = f.engine.tracksDidChangeCalls
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural,
            melody: MelodyTuning(source: .clip(f.lead.clips[0].id)))
        let melody = try #require(report.melody)
        #expect(melody.matchedParts == 3)
        #expect(melody.notesUsed == 3)
        #expect(melody.notesConsidered == 3)
        #expect(melody.unsungNotes.isEmpty && melody.unmatchedParts.isEmpty)
        #expect(melody.source == .clip(f.lead.clips[0].id))
        #expect(melody.sourceName == "Lead")
        #expect(report.appliedOptions.strength == 1, "rule 5: 1 unless sent")
        #expect(report.appliedOptions.retuneMs == Self.natural.retuneMs, "the preset still sets the rest")
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 40) < 0.01, "\(note.pitchOffsetCents)") }
        #expect(f.engine.tracksDidChangeCalls == pushes + 1)
        #expect(f.engine.detectCalls == 1)
    }

    @Test("tuneToMelody S2: a strength the caller SENT wins: 0.5 moves each note +20 c and is echoed")
    func tuneToMelodyStrengthSent() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural,
            melody: MelodyTuning(source: .clip(f.lead.clips[0].id), strength: 0.5))
        #expect(report.appliedOptions.strength == 0.5)
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 20) < 0.01, "\(note.pitchOffsetCents)") }
    }

    @Test("tuneToMelody S3: the melody is read AFTER detection: notes raised 2 semitones during the await move each note +240 c")
    func tuneToMelodyResolvesAfterTheAwait() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let leadID = f.lead.clips[0].id
        let raised = MelodyFixture.notes(MelodyFixture.melody.map { ($0.pitch + 2, $0.start, $0.length) })
        f.engine.beforeReturning = { [store = f.store] in
            _ = try? store.setClipNotes(clipID: leadID, notes: raised)
        }
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural, melody: MelodyTuning(source: .clip(leadID)))
        #expect(f.store.tracks[1].clips[0].notes?.map(\.pitch) == [59, 62, 66], "the edit landed")
        #expect(report.melody?.matchedParts == 3)
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 240) < 0.01, "\(note.pitchOffsetCents)") }
    }

    @Test("tuneToMelody S4: no melody note under the vocal is REFUSED in words naming both spans, before detection and after it")
    func tuneToMelodyRefusesWithoutOverlap() async throws {
        // Before: the notes sit at beats 16-20, the vocal at beats 0-8.
        let far = Clip(name: "Lead", startBeat: 0, lengthBeats: 24,
                       notes: MelodyFixture.notes([(57, 16, 2), (60, 18, 2)]))
        let f = try melodyStore(leadClips: [far])
        defer { try? FileManager.default.removeItem(at: f.url) }
        let undoBefore = f.store.undoHistory().undo
        do {
            _ = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: Self.natural, melody: MelodyTuning(source: .clip(far.id)))
            Issue.record("expected a refusal")
        } catch let error as ProjectError {
            let text = error.localizedDescription
            #expect(text.contains("Verse take") && text.contains("beats 0 to 8"), "\(text)")
            #expect(text.contains("from beat 16 to beat 20"), "\(text)")
        }
        #expect(f.engine.detectCalls == 0, "refused before the detection")
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
        #expect(f.store.undoHistory().undo == undoBefore)

        // After: overlapping at the call, moved away during the await -> refused on the FINAL state.
        let g = try melodyStore()
        defer { try? FileManager.default.removeItem(at: g.url) }
        let leadID = g.lead.clips[0].id
        g.engine.beforeReturning = { [store = g.store] in
            _ = try? store.setClipNotes(clipID: leadID,
                                        notes: MelodyFixture.notes([(57, 16, 2), (60, 18, 2)]))
        }
        let undoBeforeG = g.store.undoHistory().undo.count
        await #expect(throws: ProjectError.self) {
            _ = try await g.store.autoCorrectClipPitchReport(
                clipId: g.vocal.id, options: Self.natural, melody: MelodyTuning(source: .clip(leadID)))
        }
        #expect(g.engine.detectCalls == 1)
        #expect(g.store.tracks[0].clips[0].pitchEdits == nil, "nothing stored")
        #expect(g.store.undoHistory().undo.count == undoBeforeG + 1, "only the hook's own note edit")
    }

    @Test("tuneToMelody S5: a TRACK source uses every MIDI clip on it")
    func tuneToMelodyTrackSourceUsesEveryMIDIClip() async throws {
        // Clip one holds A3 and C4; clip two, at beat 3, holds E4 at its own beat 0.2 (= 3.2).
        let one = Clip(name: "Lead A", startBeat: 0, lengthBeats: 3,
                       notes: MelodyFixture.notes([(57, 0.4, 1), (60, 1.8, 1)]))
        let two = Clip(name: "Lead B", startBeat: 3, lengthBeats: 5,
                       notes: MelodyFixture.notes([(64, 0.2, 1)]))
        let f = try melodyStore(leadClips: [one, two])
        defer { try? FileManager.default.removeItem(at: f.url) }
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural, melody: MelodyTuning(source: .track(f.lead.id)))
        let melody = try #require(report.melody)
        #expect(melody.notesConsidered == 3 && melody.matchedParts == 3)
        #expect(melody.sourceName == "Lead" && melody.source == .track(f.lead.id))
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 40) < 0.01, "\(note.pitchOffsetCents)") }
    }

    @Test("tuneToMelody S6: one pass is ONE undo step, and Undo removes it")
    func tuneToMelodyIsOneUndoStep() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let before = f.store.undoHistory().undo
        _ = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural,
            melody: MelodyTuning(source: .clip(f.lead.clips[0].id)))
        let after = f.store.undoHistory().undo
        #expect(after.count == before.count + 1)
        #expect(after.first == "Auto-Correct Pitch")
        #expect(f.store.tracks[0].clips[0].pitchEdits != nil)
        _ = try f.store.undo()
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
    }

    @Test("tuneToMelody S7: the report names STORED segment ids and MIDI notes; a rest stays as sung or goes to the scale")
    func tuneToMelodyReportMapsIdsAndNotes() async throws {
        // + a 4th sung note (61.7, 30 c flat of D4) where the melody rests, and a melody note
        // at beats 6.0-6.8 (3.0-3.4 s) nobody sang.
        let sung = MelodyFixture.sung + [(2.4, 2.9, 61.7)]
        let unsung = MIDINote(pitch: 67, startBeat: 6.0, lengthBeats: 0.8)
        let lead = Clip(name: "Lead", startBeat: 0, lengthBeats: 24,
                        notes: MelodyFixture.notes() + [unsung])
        for policy in PitchMelodyTarget.Unmatched.allCases {
            let f = try melodyStore(sung: sung, leadClips: [lead])
            defer { try? FileManager.default.removeItem(at: f.url) }
            let report = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: Self.natural,
                melody: MelodyTuning(source: .clip(lead.id), unmatched: policy))
            let melody = try #require(report.melody)
            let notes = storedNotes(f.store)
            #expect(notes.count == 4)
            let rest = try #require(notes.first { abs(MelodyFixture.midi($0.detectedHz) - 61.7) < 0.01 })
            #expect(melody.unmatchedParts == [rest.id])
            #expect(melody.unmatched == policy)
            // asSung: identity. toScale: the chromatic pass at strength 1, 61.7 -> 62 = +30 c.
            let expected = policy == .asSung ? 0.0 : 30.0
            #expect(abs(rest.pitchOffsetCents - expected) < 0.01, "\(policy): \(rest.pitchOffsetCents)")
            #expect(melody.unsungNotes.map(\.noteId) == [unsung.id])
            #expect(melody.unsungNotes.first?.clipId == lead.id)
            #expect(melody.unsungNotes.first?.pitch == 67 && melody.unsungNotes.first?.startBeat == 6.0)
            #expect(melody.matchedParts == 3 && melody.notesUsed == 3 && melody.notesConsidered == 4)
            let stored = Set((f.store.tracks[0].clips[0].pitchEdits?.segments ?? []).map(\.id))
            #expect(Set(melody.unmatchedParts).isSubset(of: stored))
        }
    }

    @Test("tuneToMelody S8: a melody an octave up folds (nearestOctave) or is a far move (exact), each named by segment id")
    func tuneToMelodyOctaveFoldAndFarMove() async throws {
        let high = MelodyFixture.notes([(57, 0.4, 1), (60, 1.8, 1), (76, 3.2, 1)])
        for rule in PitchMelodyTarget.OctaveMatch.allCases {
            let lead = Clip(name: "Lead", startBeat: 0, lengthBeats: 24, notes: high)
            let f = try melodyStore(leadClips: [lead])
            defer { try? FileManager.default.removeItem(at: f.url) }
            let report = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: Self.natural,
                melody: MelodyTuning(source: .clip(lead.id), octaveMatch: rule))
            let melody = try #require(report.melody)
            let notes = storedNotes(f.store)
            let third = try #require(notes.last)
            #expect(melody.octaveMatch == rule)
            switch rule {
            case .nearestOctave:
                #expect(melody.octaveFolded == [PitchMelodyReport.OctaveFold(segmentId: third.id, octaves: -1)])
                #expect(melody.farMoves.isEmpty)
                #expect(abs(third.pitchOffsetCents - 40) < 0.01, "\(third.pitchOffsetCents)")
            case .exact:
                #expect(melody.octaveFolded.isEmpty)
                #expect(melody.farMoves.map(\.segmentId) == [third.id])
                #expect(abs((melody.farMoves.first?.cents ?? 0) - 1240) < 0.01)
                #expect(abs(third.pitchOffsetCents - 1240) < 0.01, "\(third.pitchOffsetCents)")
            }
        }
    }

    @Test("tuneToMelody S9: a missing source, an AUDIO source, a track with no MIDI and strength 0 are refused before detection")
    func tuneToMelodySourceRefusals() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let vocalTrackID = f.store.tracks[0].id
        let cases: [(String, MelodyTuning)] = [
            ("unknown clip", MelodyTuning(source: .clip(UUID()))),
            ("unknown track", MelodyTuning(source: .track(UUID()))),
            ("audio clip", MelodyTuning(source: .clip(f.vocal.id))),
            ("track with no MIDI", MelodyTuning(source: .track(vocalTrackID))),
            ("strength 0", MelodyTuning(source: .clip(f.lead.clips[0].id), strength: 0)),
        ]
        for (label, tuning) in cases {
            await #expect(throws: ProjectError.self, "\(label)") {
                _ = try await f.store.autoCorrectClipPitchReport(
                    clipId: f.vocal.id, options: Self.natural, melody: tuning)
            }
        }
        #expect(f.engine.detectCalls == 0)
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
        // The words, for the two a person is most likely to meet.
        do {
            _ = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: Self.natural,
                melody: MelodyTuning(source: .clip(f.vocal.id)))
        } catch {
            #expect(error.localizedDescription.contains("MIDI"), "\(error.localizedDescription)")
        }
        do {
            _ = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: Self.natural,
                melody: MelodyTuning(source: .clip(f.lead.clips[0].id), strength: 0))
        } catch {
            #expect(error.localizedDescription.contains("above 0"), "\(error.localizedDescription)")
        }
    }

    @Test("tuneToMelody S10: a kept detune is said against the MELODY in melody mode")
    func tuneToMelodyKeptDetuneSaysMelody() async throws {
        let f = try melodyStore(vocalShift: 0.3)
        defer { try? FileManager.default.removeItem(at: f.url) }
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural,
            melody: MelodyTuning(source: .clip(f.lead.clips[0].id)))
        let notice = try #require(report.keptDetuneNotice)
        #expect(notice.contains("sharp of the melody"), "\(notice)")
    }

    @Test("tuneToMelody S12: through the store, a vocal stretched 1.25x reads the melody at its own source seconds")
    func tuneToMelodyStretchedVocal() async throws {
        // Ratio 1.25: a source second plays for 1.25 timeline seconds, so the sung spans
        // [0.2,0.7) [0.9,1.4) [1.6,2.1) sit at timeline seconds x1.25 = beats x2.5:
        // [0.5,1.75) [2.25,3.5) [4.0,5.25). Read WITHOUT the ratio, the third note would
        // land at source [2.0,2.625) and the third sung part would take C4 by majority (-360 c).
        let lead = Clip(name: "Lead", startBeat: 0, lengthBeats: 24,
                        notes: MelodyFixture.notes([(57, 0.5, 1.25), (60, 2.25, 1.25), (64, 4.0, 1.25)]))
        let f = try melodyStore(leadClips: [lead])
        defer { try? FileManager.default.removeItem(at: f.url) }
        _ = try f.store.setClipStretch(trackId: f.store.tracks[0].id, clipId: f.vocal.id,
                                       ratio: 1.25, semitones: 0)
        #expect(f.store.tracks[0].clips[0].stretchRatio == 1.25)
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural, melody: MelodyTuning(source: .clip(lead.id)))
        #expect(report.melody?.matchedParts == 3)
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 40) < 0.01, "\(note.pitchOffsetCents)") }
    }

    @Test("tuneToMelody S13: through the store, a tempo change (120 then 60 bpm from beat 2) places the melody right")
    func tuneToMelodyAcrossATempoChange() async throws {
        // Beat 2 is 1.0 s; after it a beat is 1 s. Sung [0.2,0.7) = beats [0.4,1.4);
        // [0.9,1.4) = beats [1.8,2.4); [1.6,2.1) = beats [2.6,3.1). A constant-120 reading
        // would put the third note at 1.3-1.55 s, under nobody: that part would stay as sung.
        let lead = Clip(name: "Lead", startBeat: 0, lengthBeats: 24,
                        notes: MelodyFixture.notes([(57, 0.4, 1.0), (60, 1.8, 0.6), (64, 2.6, 0.5)]))
        let f = try melodyStore(leadClips: [lead])
        defer { try? FileManager.default.removeItem(at: f.url) }
        try f.store.setTempoMap(try TempoMap(segments: [TempoMap.Segment(startBeat: 0, bpm: 120),
                                                        TempoMap.Segment(startBeat: 2, bpm: 60)]))
        let report = try await f.store.autoCorrectClipPitchReport(
            clipId: f.vocal.id, options: Self.natural, melody: MelodyTuning(source: .clip(lead.id)))
        #expect(report.melody?.matchedParts == 3)
        #expect(report.melody?.unmatchedParts.isEmpty == true)
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 40) < 0.01, "\(note.pitchOffsetCents)") }
    }

    @Test("tuneToMelody S11: no melody is today's pass: no melody report, appliedOptions are the options, the same offsets")
    func tuneToMelodyNilIsUnchanged() async throws {
        let f = try melodyStore()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let report = try await f.store.autoCorrectClipPitchReport(clipId: f.vocal.id,
                                                                  options: Self.natural)
        #expect(report.melody == nil)
        #expect(report.appliedOptions == Self.natural)
        // Natural, chromatic, 0.85: each 40 c-flat note moves 0.85 · 40 = 34 c.
        let notes = storedNotes(f.store)
        #expect(notes.count == 3)
        for note in notes { #expect(abs(note.pitchOffsetCents - 34) < 0.01, "\(note.pitchOffsetCents)") }
        let notice = try melodyStore(vocalShift: 0.3)
        defer { try? FileManager.default.removeItem(at: notice.url) }
        let plain = try await notice.store.autoCorrectClipPitchReport(clipId: notice.vocal.id,
                                                                      options: Self.natural)
        #expect(plain.keptDetuneNotice?.contains("of the scale") == true)
    }
}
