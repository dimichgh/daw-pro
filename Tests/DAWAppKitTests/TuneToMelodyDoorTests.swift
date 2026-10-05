import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

// Tune to Melody, M3 (W7-TTM3): THE CARD'S DOOR AGAINST A REAL STORE. `TuneToMelodyDoor` opens
// the card, asks the preset doors' replace gate, makes the ONE store call
// (`ProjectStore.autoCorrectClipPitchReport(…, melody:)`) and lands the result on the card. These
// are SPY tests: the real store, the real gate, a detection stub, and every claim read back from
// the STORED table (an independent instrument), never from the door's own echo alone.
//
// An EXTENSION of the existing `@MainActor` suite `ClipRenderSignatureTests` (which already drives
// the real `autoCorrectClipPitch`), not a new suite: the @MainActor census
// (`MainActorOccupancySiteTests`, cap 394) has one slot left. Every name starts with
// `tuneToMelodyDoor`.
//
// The fixture (TTM2's, `PitchMelodyStoreTests`): 120 bpm, so a beat is 0.5 s; the vocal starts at
// beat 0 and plays its file from 0, ratio 1, so a timeline beat b is source second b/2.
//   sung    56.6 @ [0.2, 0.7)   59.6 @ [0.9, 1.4)   63.6 @ [1.6, 2.1)    (each 40 c flat)
//   melody  A3 57 beats 0.4-1.4 C4 60 beats 1.8-2.8 E4 64 beats 3.2-4.2  (= the same seconds)

/// The detection stub (TTM2's `MelodyWriterEngine`, copied: test files cannot share a private
/// type).
@MainActor
private final class DoorDetectEngine: AudioEngineControlling {
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

/// The fixture's numbers, one home.
private enum DoorFixture {
    static let frameRateHz = 62.5
    static let sung: [(start: Double, end: Double, midi: Double)] = [
        (0.2, 0.7, 56.6), (0.9, 1.4, 59.6), (1.6, 2.1, 63.6),
    ]
    static let melody: [(pitch: Int, start: Double, length: Double)] = [
        (57, 0.4, 1.0), (60, 1.8, 1.0), (64, 3.2, 1.0),
    ]

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    static func notes(_ spec: [(pitch: Int, start: Double, length: Double)] = melody) -> [MIDINote] {
        spec.map { MIDINote(pitch: $0.pitch, startBeat: $0.start, lengthBeats: $0.length) }
    }

    /// 62.5 fps frames over [0, 3.0): voiced inside a sung span, unvoiced elsewhere.
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

extension ClipRenderSignatureTests {

    /// A store at 120 bpm with a vocal (a real file for `detectClipPitch`'s existence check) and a
    /// "Lead" instrument track holding the melody.
    private func tuneToMelodyDoorStore(
        sung: [(start: Double, end: Double, midi: Double)] = DoorFixture.sung,
        melody: [(pitch: Int, start: Double, length: Double)] = DoorFixture.melody
    ) throws -> (store: ProjectStore, engine: DoorDetectEngine, vocal: Clip, lead: Track) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ttm3-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        let vocal = Clip(name: "Verse take", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        let lead = Track(name: "Lead", kind: .instrument, clips: [
            Clip(name: "Lead", startBeat: 0, lengthBeats: 24, notes: DoorFixture.notes(melody)),
        ])
        var transport = TransportState()
        transport.tempoBPM = 120
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [vocal]), lead],
                                 transport: transport)
        let engine = DoorDetectEngine(stubResult: DoorFixture.contour(sung))
        store.engine = engine
        return (store, engine, vocal, lead)
    }

    /// The STORED notes (sounds excluded), in time order: the independent instrument.
    private func tuneToMelodyDoorStoredNotes(_ store: ProjectStore) -> [NoteSegment] {
        (store.tracks[0].clips[0].pitchEdits?.segments ?? [])
            .filter { $0.origin != .unpitched }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    private func tuneToMelodyDoorOutcome(_ door: TuneToMelodyDoor) -> TuneToMelodyOutcome? {
        if case .finished(let outcome) = door.card?.phase { return outcome }
        return nil
    }

    @Test("tuneToMelodyDoor D1: Apply on an untuned vocal runs NOW, once; the notes land ON the melody at strength 1; the line is read off the store's report; ONE undo step")
    func tuneToMelodyDoorAppliesAndSaysWhatHappened() async throws {
        let f = try tuneToMelodyDoorStore()
        let door = TuneToMelodyDoor()
        let gate = PitchPresetReplaceGate()
        #expect(door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks,
                          tempoMap: f.store.transport.tempoMap))
        #expect(door.card?.choices.map(\.name) == ["Lead"])
        #expect(f.store.undoHistory().undo.isEmpty)

        let run = try #require(door.apply(gate: gate, store: f.store))
        #expect(gate.pending == nil, "an untuned vocal has nothing to lose: no question")
        #expect(door.card?.phase == .tuning)
        #expect(door.close() == false, "the card cannot close under a run in flight")
        #expect(run == TuneToMelodyRun(clipID: f.vocal.id, preset: .natural,
                                       melody: MelodyTuning(source: .track(f.lead.id))))
        #expect(f.engine.detectCalls == 0, "the decision is synchronous; the store has not run yet")

        await door.perform(run, store: f.store)
        #expect(f.engine.detectCalls == 1)
        let outcome = try #require(tuneToMelodyDoorOutcome(door))
        #expect(outcome == TuneToMelodyOutcome(melodyName: "Lead", melodyIsClip: false,
                                               foundSinging: true, tunedNotes: 3,
                                               untouchedNotes: 0, farMoves: 0, matchedOctave: true))
        #expect(TuneToMelodyCopy.summary(outcome) == "Tuned 3 notes to Lead.")
        #expect(TuneToMelodyCopy.farMoveNote(outcome) == nil)
        // THE STORE, read independently: each note moved +40 c (strength 1, rule 5), not
        // Natural's +34 c.
        let offsets = tuneToMelodyDoorStoredNotes(f.store).map(\.pitchOffsetCents)
        #expect(offsets.count == 3)
        for offset in offsets { #expect(abs(offset - 40) < 0.5, "stored \(offset) c") }
        // ONE undo step, and it takes the whole pass away.
        #expect(f.store.undoHistory().undo.count == 1)
        _ = try f.store.undo()
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
        #expect(door.close())
        #expect(door.card == nil)
    }

    /// The summary's second sentence comes from the REPORT's `unmatchedParts` (sung notes where
    /// the melody rests), not from `unsungNotes` (melody notes nobody sang): here one is 1 and
    /// the other 0, so a mapping that read the wrong one goes red. Instrument: the stored note
    /// left as sung (offset 0).
    @Test("tuneToMelodyDoor D2: a sung note where the melody rests is counted from the real report, says so, and is stored as sung")
    func tuneToMelodyDoorCountsUntouchedNotesFromTheReport() async throws {
        let f = try tuneToMelodyDoorStore(sung: DoorFixture.sung + [(2.3, 2.8, 66.6)])
        let door = TuneToMelodyDoor()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        let run = try #require(door.apply(gate: PitchPresetReplaceGate(), store: f.store))
        await door.perform(run, store: f.store)
        let outcome = try #require(tuneToMelodyDoorOutcome(door))
        #expect(outcome.tunedNotes == 3)
        #expect(outcome.untouchedNotes == 1)
        #expect(TuneToMelodyCopy.summary(outcome)
                == "Tuned 3 notes to Lead. 1 had no melody note under it and stayed as you sang it.")
        let stored = tuneToMelodyDoorStoredNotes(f.store)
        #expect(stored.count == 4)
        #expect(stored.filter { abs($0.pitchOffsetCents) < 0.5 }.count == 1,
                "exactly one stored note stayed as sung")
    }

    /// The melody sits an OCTAVE ABOVE the singing. Match octave ON (the default) folds it down:
    /// each note moves +40 c. OFF takes the notes as written: +1240 c, three far moves, and the
    /// far-move note with its Match octave tip. Instrument: the stored offsets.
    @Test("tuneToMelodyDoor D3: Match octave ON keeps a low voice in its range (+40 c); OFF follows the written octave (+1240 c, three far moves)")
    func tuneToMelodyDoorMatchOctaveSwitch() async throws {
        let up = DoorFixture.melody.map { (pitch: $0.pitch + 12, start: $0.start, length: $0.length) }
        let f = try tuneToMelodyDoorStore(melody: up)
        let door = TuneToMelodyDoor()
        let gate = PitchPresetReplaceGate()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        #expect(door.card?.matchOctave == true)
        await door.perform(try #require(door.apply(gate: gate, store: f.store)), store: f.store)
        let folded = try #require(tuneToMelodyDoorOutcome(door))
        #expect(folded.farMoves == 0 && folded.matchedOctave)
        for offset in tuneToMelodyDoorStoredNotes(f.store).map(\.pitchOffsetCents) {
            #expect(abs(offset - 40) < 0.5, "Match octave ON stored \(offset) c")
        }

        door.setMatchOctave(false)
        #expect(door.card?.phase == .choosing, "a changed setting clears the old line")
        // The table is the last pass's own output: switching applies with no question.
        await door.perform(try #require(door.apply(gate: gate, store: f.store)), store: f.store)
        #expect(gate.pending == nil)
        let written = try #require(tuneToMelodyDoorOutcome(door))
        #expect(written.farMoves == 3 && !written.matchedOctave)
        for offset in tuneToMelodyDoorStoredNotes(f.store).map(\.pitchOffsetCents) {
            #expect(abs(offset - 1240) < 0.5, "Match octave OFF stored \(offset) c")
        }
        #expect(TuneToMelodyCopy.farMoveNote(written)?.hasSuffix(TuneToMelodyCopy.octaveOffFarMoveTip) == true)
    }

    /// No second replace guard: with a note moved by hand, Apply raises the SAME gate's question
    /// and runs nothing; Cancel leaves the hand edit; "Replace my edits" runs exactly the held
    /// melody request, once.
    @Test("tuneToMelodyDoor D4: over a hand edit Apply asks the preset doors' gate and runs nothing; Cancel keeps the edit; Replace runs the held melody once")
    func tuneToMelodyDoorAsksBeforeReplacingHandEdits() async throws {
        let f = try tuneToMelodyDoorStore()
        let door = TuneToMelodyDoor()
        let gate = PitchPresetReplaceGate()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        await door.perform(try #require(door.apply(gate: gate, store: f.store)), store: f.store)
        #expect(f.engine.detectCalls == 1)
        // A note moved by hand.
        let first = try #require(tuneToMelodyDoorStoredNotes(f.store).first)
        _ = try f.store.setClipNotePitchOffset(clipId: f.vocal.id, segmentId: first.id, offsetCents: 100)

        #expect(door.apply(gate: gate, store: f.store) == nil, "the run must wait for the answer")
        let held = try #require(gate.pending)
        #expect(held.melody == door.card?.melodyTuning)
        #expect(held.clipID == f.vocal.id && held.preset == .natural)
        #expect(door.card?.phase == .waitingForAnswer)
        #expect(door.close() == false, "the card stays under its question")
        #expect(PitchPresetReplaceCopy(held).body.hasPrefix(
            "Tune to Melody tunes all of \u{201C}Verse take\u{201D} from scratch."))
        #expect(f.engine.detectCalls == 1, "nothing ran while the question is up")

        // Cancel: nothing applied, the hand edit stays.
        gate.cancel()
        door.replaceDeclined()
        #expect(door.card?.phase == .choosing)
        #expect(tuneToMelodyDoorStoredNotes(f.store).first?.pitchOffsetCents == 100)
        #expect(f.engine.detectCalls == 1)

        // Ask again, and say yes: the gate hands the held request back once, the door runs it.
        #expect(door.apply(gate: gate, store: f.store) == nil)
        let yes = try #require(gate.confirm())
        #expect(gate.confirm() == nil, "the answer is handed back exactly once")
        let run = try #require(door.confirmedRun(yes))
        #expect(run.melody == yes.melody && door.card?.phase == .tuning)
        await door.perform(run, store: f.store)
        #expect(f.engine.detectCalls == 2)
        #expect(abs((tuneToMelodyDoorStoredNotes(f.store).first?.pitchOffsetCents ?? 0) - 40) < 0.5,
                "the confirmed pass replaced the hand edit")
        // A preset door's request is not this door's.
        #expect(door.confirmedRun(PitchPresetReplaceRequest(clipID: f.vocal.id, clipName: "x",
                                                            preset: .tight)) == nil)
    }

    @Test("tuneToMelodyDoor D5: a melody moved away after the card opened is refused in the store's own words, nothing run or stored")
    func tuneToMelodyDoorShowsTheStoresRefusal() async throws {
        let f = try tuneToMelodyDoorStore()
        let door = TuneToMelodyDoor()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        _ = try f.store.moveClip(trackId: f.lead.id, clipId: f.lead.clips[0].id, toStartBeat: 64)
        let run = try #require(door.apply(gate: PitchPresetReplaceGate(), store: f.store))
        await door.perform(run, store: f.store)
        guard case .refused(let message) = door.card?.phase else {
            Issue.record("expected a refusal, got \(String(describing: door.card?.phase))")
            return
        }
        #expect(message.hasPrefix("No note of the melody \u{201C}Lead\u{201D} plays under the vocal"))
        #expect(message.hasSuffix("Nothing was changed."))
        #expect(f.engine.detectCalls == 0)
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
        #expect(door.card?.canApply == true && door.card?.canClose == true)
    }

    /// The premise the chips' melody-mode lines rest on: a melody pass runs EVERY offered preset
    /// at strength 1 (the store's rule 5), and what the chip still sends is its retune speed and
    /// its vibrato rule. If the store's rule moves, this goes red, not the card's words.
    @Test("tuneToMelodyDoor D6: every chip reaches the store at strength 1, keeping its own retune speed and vibrato rule")
    func tuneToMelodyDoorEveryChipRunsAtStrengthOne() async throws {
        let f = try tuneToMelodyDoorStore()
        var card = TuneToMelodyCard(vocal: f.vocal, vocalTrackName: "Vocals", tracks: f.store.tracks,
                                    tempoMap: f.store.transport.tempoMap)
        for preset in TuneToMelodyCard.presets {
            card.choosePreset(preset)
            let report = try await f.store.autoCorrectClipPitchReport(
                clipId: f.vocal.id, options: card.options, melody: card.melodyTuning)
            #expect(report.appliedOptions.strength == 1, "\(preset): \(report.appliedOptions.strength)")
            #expect(report.appliedOptions.retuneMs == preset.options().retuneMs)
            #expect(report.appliedOptions.preserveVibrato == preset.options().preserveVibrato)
        }
    }

    @Test("tuneToMelodyDoor D7: the card opens only on an audio clip, and not over a run in flight")
    func tuneToMelodyDoorOpensOnlyOnAudio() throws {
        let f = try tuneToMelodyDoorStore()
        let door = TuneToMelodyDoor()
        let map = f.store.transport.tempoMap
        #expect(door.open(vocalClipID: f.lead.clips[0].id, tracks: f.store.tracks, tempoMap: map) == false)
        #expect(door.open(vocalClipID: UUID(), tracks: f.store.tracks, tempoMap: map) == false)
        #expect(door.card == nil)
        #expect(door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: map))
        _ = door.apply(gate: PitchPresetReplaceGate(), store: f.store)
        #expect(door.card?.phase == .tuning)
        #expect(door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: map) == false)
        #expect(door.card?.phase == .tuning, "a reopen must not wipe a run in flight")
    }

    @Test("tuneToMelodyDoor D8: a take with no singing at all says so in a person's words, and stores nothing")
    func tuneToMelodyDoorFoundNoSinging() async throws {
        let f = try tuneToMelodyDoorStore(sung: [])
        let door = TuneToMelodyDoor()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        await door.perform(try #require(door.apply(gate: PitchPresetReplaceGate(), store: f.store)),
                           store: f.store)
        let outcome = try #require(tuneToMelodyDoorOutcome(door))
        #expect(!outcome.foundSinging)
        #expect(TuneToMelodyCopy.summary(outcome) == TuneToMelodyCopy.foundNoSinging)
        #expect(f.store.tracks[0].clips[0].pitchEdits == nil)
    }

    /// The report as the store gives it for the card's own request (Natural, Match octave on),
    /// on a FRESH fixture: the premise D9/D10 test the words against.
    private func tuneToMelodyDoorReport(
        sung: [(start: Double, end: Double, midi: Double)],
        melody: [(pitch: Int, start: Double, length: Double)]
    ) async throws -> PitchMelodyReport {
        let g = try tuneToMelodyDoorStore(sung: sung, melody: melody)
        let report = try await g.store.autoCorrectClipPitchReport(
            clipId: g.vocal.id, options: PitchCorrectionPreset.natural.options(),
            melody: MelodyTuning(source: .track(g.lead.id)))
        return try #require(report.melody)
    }

    /// A note held while the melody changes under it is CUT (rule 2) and each piece tuned to its
    /// own melody note: the report counts 3 tuned rows for 2 sung notes. A novice reads "notes"
    /// as the notes they sang, so the line says 2. Instrument: the stored rows (+40 c and +240 c
    /// on the held note's two pieces, +40 c on the other note).
    @Test("tuneToMelodyDoor D9: a sung note the melody changes under is cut into two rows, and the line still counts it as ONE sung note")
    func tuneToMelodyDoorCountsSungNotesNotPieces() async throws {
        let sung: [(start: Double, end: Double, midi: Double)] = [(0.2, 1.4, 56.6), (1.6, 2.1, 63.6)]
        let melody: [(pitch: Int, start: Double, length: Double)] = [(57, 0.4, 1.0), (59, 1.4, 1.4), (64, 3.2, 1.0)]
        // THE PREMISE: the report counts rows, and one cut joined two of them.
        let report = try await tuneToMelodyDoorReport(sung: sung, melody: melody)
        #expect(report.matchedParts == 3 && report.cutsAdded.count == 1,
                "matchedParts \(report.matchedParts), cuts \(report.cutsAdded.count)")
        #expect(report.cutsAdded.first?.segmentIds.count == 2)

        let f = try tuneToMelodyDoorStore(sung: sung, melody: melody)
        let door = TuneToMelodyDoor()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        await door.perform(try #require(door.apply(gate: PitchPresetReplaceGate(), store: f.store)),
                           store: f.store)
        let offsets = tuneToMelodyDoorStoredNotes(f.store).map(\.pitchOffsetCents)
        #expect(offsets.count == 3 && abs(offsets[0] - 40) < 0.5 && abs(offsets[1] - 240) < 0.5
                && abs(offsets[2] - 40) < 0.5, "stored \(offsets)")
        let outcome = try #require(tuneToMelodyDoorOutcome(door))
        #expect(outcome.tunedNotes == 2, "\(outcome.tunedNotes) — rows, not sung notes")
        #expect(outcome.untouchedNotes == 0 && outcome.farMoves == 0)
        #expect(TuneToMelodyCopy.summary(outcome) == "Tuned 2 notes to Lead.")
    }

    /// The same cut, with both pieces jumping more than `farMoveCents` (+440 c, +540 c): the
    /// report lists two far rows, the person sang one note.
    @Test("tuneToMelodyDoor D10: a held note cut in two whose BOTH pieces jump far is ONE note in the far-move line")
    func tuneToMelodyDoorCountsFarMovesBySungNote() async throws {
        let sung: [(start: Double, end: Double, midi: Double)] = [(0.2, 1.4, 56.6)]
        let melody: [(pitch: Int, start: Double, length: Double)] = [(61, 0.4, 1.0), (62, 1.4, 1.4)]
        let report = try await tuneToMelodyDoorReport(sung: sung, melody: melody)
        #expect(report.matchedParts == 2 && report.cutsAdded.count == 1 && report.farMoves.count == 2,
                "matchedParts \(report.matchedParts), cuts \(report.cutsAdded.count), far \(report.farMoves.count)")

        let f = try tuneToMelodyDoorStore(sung: sung, melody: melody)
        let door = TuneToMelodyDoor()
        door.open(vocalClipID: f.vocal.id, tracks: f.store.tracks, tempoMap: f.store.transport.tempoMap)
        await door.perform(try #require(door.apply(gate: PitchPresetReplaceGate(), store: f.store)),
                           store: f.store)
        let offsets = tuneToMelodyDoorStoredNotes(f.store).map(\.pitchOffsetCents)
        #expect(offsets.count == 2 && abs(offsets[0] - 440) < 0.5 && abs(offsets[1] - 540) < 0.5,
                "stored \(offsets)")
        let outcome = try #require(tuneToMelodyDoorOutcome(door))
        #expect(outcome.tunedNotes == 1 && outcome.farMoves == 1,
                "tuned \(outcome.tunedNotes), far \(outcome.farMoves)")
        #expect(TuneToMelodyCopy.summary(outcome) == "Tuned 1 note to Lead.")
        #expect(TuneToMelodyCopy.farMoveNote(outcome) == "1 note had to jump a long way to reach the melody. "
                + "A big jump can change how the voice sounds, so give it a listen.")
    }
}

