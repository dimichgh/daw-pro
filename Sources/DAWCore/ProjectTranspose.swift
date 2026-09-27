import Foundation

// MARK: - project.transpose (p2-sing-k), the DAWCore half
//
// THE ONLY WAY THE WHOLE SONG CHANGES KEY (design
// `docs/design/2026-09-27-p2-sing-integration.md` §3.6). Real singers choose
// the song's key for their voice, so a sung vocal moves by whole octaves on its
// own and by any other amount only when EVERYTHING moves with it. This file is
// the pure planner: it reads `[Track]`, decides every change and every refusal,
// and returns the new tracks with a report. `ProjectStore+Transpose.swift` is
// the thin store door that applies it as ONE undo step.
//
// ⭐ THE CENSUS (2026-09-27, lane W7-PK). Every stored field reachable from the
// saved and undoable project (`EditState`, `ProjectDocument`) that carries a
// pitch, a key, a root or a semitone offset, and what this move does with it.
// The same list is the report's `fields`, so the wire echoes it verbatim:
//
//   MOVES (+t)
//    * `MIDINote.pitch` — every note on a pitched track.
//    * `Clip.pitchShiftSemitones` — every audio clip on a moved track.
//    * `TakeGroup.lanes[].clip` — the same two fields on the takes a comp is
//      built from. `CompFlattener.flatten` COPIES `notes` and
//      `pitchShiftSemitones` from these into the comp members on the timeline,
//      so moving only the members would be undone, silently, by the next comp
//      edit. Both move, and `flatten(new lanes) == new members` (ids aside).
//
//   KEPT, ON PURPOSE
//    * `Clip.pitchEdits` — a tuned vocal's per-note edits. ⛔ **THE DESIGN SAID
//      THE CORRECTION'S TONIC MUST MOVE; THE RENDER ORDER SAYS OTHERWISE.**
//      Nothing stores a tonic: `PitchCorrectionScale` is only an ARGUMENT of
//      `clip.autoCorrectPitch`. What a pass stores is
//      `NoteSegment.pitchOffsetCents`, measured from the pitch detected in the
//      SOURCE FILE (`detectClipPitch` reads the file; the clip's shift is only
//      echoed), and the render plays `clipPitchShiftSemitones + correction`
//      (`PitchCorrectionCurve.semitones`, fed `Params.semitones` by
//      `StretchCurvePlan.make`). So the shift alone carries a tuned vocal to the
//      new key, note for note. Re-snapping the recording with a MOVED tonic
//      would pull each sung note onto the new key's scale while the recording
//      is still in the old one, and the shift would then move it again: wrong
//      notes. `ProjectTransposeRenderTests` (DAWEngineTests) proves both by
//      tracked pitch.
//    * `NoteSegment.detectedHz` — what was sung, a fact, never edited.
//    * `SamplerZone.rootPitch/minPitch/maxPitch/tuneCents` — an instrument's
//      key map (which key plays which sample). The notes already moved; moving
//      the map too would cancel the move.
//    * `SamplerParams.bendRangeSemitones`, `PolySynthParams.subOctave` /
//      `unisonDetuneCents`, `DrumVoiceParams.tune` — sound design, measured
//      from the note being played.
//    * `MIDIControllerLane` `.pitchBend` points — a bend is relative to the
//      note it bends.
//    * `VoiceProvenance.pitchSemitones` — a record of how a converted vocal was
//      made; its own doc says it "drives nothing".
//
//   SKIPPED
//    * every note on a DRUM track (`isDrumTrack`): a note there picks a drum
//      sound, not a pitch;
//    * every note on a SLICE KIT (`isSliceKitTrack`, round 2, PK-F2): Chop to
//      Sampler maps one slice of a recording to each key, so a note there
//      picks a slice, and moving it plays a different slice (or silence). Read
//      from a STORED marker (`SamplerParams.isSliceKit`), never guessed from the
//      zone shapes: a chromatic one-sample-per-key sampler looks the same and
//      must move;
//    * every track in `excludeTrackIds`;
//    * `Track.sungVocalProvenance` (W7-SD2, landing): the octave and key in
//      force when a sung vocal was rendered, a historical fact like
//      `VoiceProvenance`, so it is never moved (in-place edits leave it alone).
//
//   NOT PITCHES (checked, nothing to do): effect parameters (the 22 kinds carry
//   filter and EQ frequencies, never a key; a hosted plug-in's state is
//   opaque), automation and modulation targets (volume, pan, sends, effect and
//   synth parameters), groove templates (timing), markers, tempo and meter maps,
//   the reference slot (loudness analysis of someone else's master).
//
//   NOT IN THE SONG (session state, never saved): Musical Typing's chord key
//   (`MusicalTypingController.chordKey`, DAWAppKit), which also seeds Playbox;
//   the pitch editor's `snapScale`; the step sequencer's rows (derived from the
//   clip's own notes). And the looper's `LoopLayer.cycle` copies, which is why
//   a key change is REFUSED while a looper layer sits on a track it would move
//   (`ProjectStore+LoopDeck.materializeDeckLayers` rewrites each layer's clip
//   from its cycle on the next pass and would put the old key back).
//
// ⚠️ EVERY CHANGE IS MADE IN PLACE (`note.pitch += t`,
// `clip.pitchShiftSemitones += t`), NEVER BY REBUILDING A `Clip` OR A
// `MIDINote` THROUGH `init`. A rebuild enumerates fields, and a field a later
// lane adds (`Clip.lyrics` is landing now) would silently take its default. In
// place, every other field rides along — the `ProjectStore.moveClips`
// precedent named in `Clip.pitchEdits`' carry-site banner. A uniform shift
// keeps the notes' canonical order, so nothing is re-sorted.

// MARK: - Refusals

/// Why a key change was refused. Nothing is written when one is thrown.
///
/// `message` is the sentence for a person; `code` is the wire's refusal name
/// (design §6 row 17), so the wire can echo both without deciding anything.
/// Conforms to `LocalizedError` so the router's generic branch already surfaces
/// the words verbatim.
public struct TransposeRefusal: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        /// |semitones| > 12, or not a whole number.
        case transposeOutOfRange
        /// A note would leave MIDI 0…127. Names the clip and the note.
        case transposeNoteOutOfRange
        /// An audio clip would go past ±24 semitones
        /// (`Clip.pitchShiftSemitonesRange`). Names the clip.
        case transposeAudioShiftOutOfRange
        /// A looper layer sits on a track the key change would move (an
        /// addition to §3.6: see the banner).
        case transposeLooperOpen
    }

    public let code: Code
    public let message: String
    /// The track the refusal is about, when it is about one.
    public let trackId: UUID?
    public let trackName: String?
    /// The clip (a timeline clip or a take) the refusal is about.
    public let clipId: UUID?
    public let clipName: String?
    /// The note, for `transposeNoteOutOfRange`.
    public let noteId: UUID?
    /// The value that would have been written: the MIDI note number, or the
    /// clip's pitch shift in semitones.
    public let wouldBe: Double?

    public var errorDescription: String? { message }

    init(code: Code, message: String, trackId: UUID? = nil, trackName: String? = nil,
         clipId: UUID? = nil, clipName: String? = nil, noteId: UUID? = nil,
         wouldBe: Double? = nil) {
        self.code = code
        self.message = message
        self.trackId = trackId
        self.trackName = trackName
        self.clipId = clipId
        self.clipName = clipName
        self.noteId = noteId
        self.wouldBe = wouldBe
    }
}

// MARK: - The report

/// What a key change moved, what it left alone and why, and what to watch out
/// for — the shape the wire echoes verbatim (`project.transpose`).
public struct TransposeReport: Codable, Sendable, Equatable {
    /// The move asked for, in semitones (−12…12).
    public var semitones: Int
    /// True when nothing was written because the caller asked for a preview.
    public var dryRun: Bool
    /// True only when the project was changed: not a dry run, and something
    /// moved.
    public var applied: Bool
    /// One plain sentence: what happened, or what would.
    public var summary: String
    /// Every note moved, on the timeline and in takes.
    public var notesMoved: Int
    /// MIDI clips with at least one note moved, on the timeline and in takes.
    public var midiClipsMoved: Int
    /// Audio clips whose pitch shift changed, on the timeline and in takes.
    public var audioClipsShifted: Int
    /// How many of the clips above are TAKES (inside a take group).
    public var takeClipsMoved: Int
    /// One entry per track, in project order.
    public var tracks: [TrackResult]
    /// The census: every stored field that carries a pitch or a key, and what
    /// this move did with it.
    public var fields: [FieldResult]
    public var warnings: [Warning]

    public struct TrackResult: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable, CaseIterable {
            case moved
            case skippedDrums
            /// A slice kit made by Chop to Sampler (round 2, PK-F2).
            case skippedSliceKit
            case skippedExcluded
            case nothingToMove
        }
        public var trackId: UUID
        public var name: String
        public var outcome: Outcome
        /// Why a track was skipped or had nothing to move; nil when it moved.
        public var reason: String?
        /// Every clip that moved (or would), timeline clips first, then takes.
        public var clips: [ClipResult]
    }

    public struct ClipResult: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case midi, audio }
        /// Where the clip lives: on the timeline (a comp's members included),
        /// or as one of the takes a comp is built from.
        public enum Place: String, Codable, Sendable { case timeline, take }
        public var clipId: UUID
        public var name: String
        public var kind: Kind
        public var place: Place
        /// MIDI: how many notes moved.
        public var notesMoved: Int?
        /// Audio: the pitch shift before and after, in semitones.
        public var shiftBefore: Double?
        public var shiftAfter: Double?
        /// Audio: true when the clip is tuned and its tuning is kept as it is
        /// (the shift carries it to the new key).
        public var keepsTuning: Bool?
    }

    public struct FieldResult: Codable, Sendable, Equatable {
        public enum Verdict: String, Codable, Sendable {
            case moved
            case kept
            case skipped
            case notStored
        }
        /// The stored field, as the model names it.
        public var field: String
        public var verdict: Verdict
        /// How many values this move changed, kept or skipped in this project;
        /// nil where a count would mean nothing.
        public var count: Int?
        public var reason: String
    }

    public struct Warning: Codable, Sendable, Equatable {
        public enum Code: String, Codable, Sendable, CaseIterable {
            /// A recorded or generated audio track will be pitch-shifted.
            case audioWillBePitchShifted
            /// A tuned clip keeps breaths and consonants out of its tuning; that
            /// stops while the whole clip is shifted
            /// (`ConsonantMixInactiveReason.clipTransposed`).
            case consonantProtectionStops
        }
        public enum Source: String, Codable, Sendable { case recorded, generated }
        public var code: Code
        public var trackId: UUID
        public var trackName: String
        /// The clips the warning is about.
        public var clipIds: [UUID]
        /// For `audioWillBePitchShifted`: where the audio came from.
        public var source: Source?
        public var message: String
    }
}

/// A planned key change: the tracks as they will be, and the report.
public struct ProjectTransposePlan: Sendable, Equatable {
    public let tracks: [Track]
    public let report: TransposeReport

    /// True when applying the plan changes the project. With a non-zero move
    /// this is exactly "a note moved or an audio clip shifted".
    public var changesAnything: Bool {
        report.notesMoved > 0 || report.audioClipsShifted > 0
    }
}

// MARK: - The planner

public enum ProjectTranspose {
    /// A key change moves the song by at most one octave either way (design
    /// §3.6). A larger move is refused rather than clamped.
    public static let semitoneRange: ClosedRange<Int> = -12...12

    /// The wire's door for a JSON number: a whole number of semitones inside
    /// `semitoneRange`, or `transposeOutOfRange` in words. A key change is
    /// whole semitones by definition, so 2.5 is refused, never rounded.
    public static func validatedSemitones(_ value: Double) throws -> Int {
        guard value.isFinite, value.rounded() == value, let whole = Int(exactly: value),
              semitoneRange.contains(whole) else {
            throw outOfRange(describing: value)
        }
        return whole
    }

    /// Is this a drum track, whose notes pick drum sounds rather than pitches?
    ///
    /// Composed from the tree's two homes, not restated: our own drum machine
    /// (`.drumSynth`, which `InstrumentFamilyResolver` deliberately gives no GM
    /// family) and a percussion sound bank (`SMFProjectExporter.isDrumKit`, the
    /// ONE home the step sequencer also asks; kind-gated, and not gated on a GM
    /// source, because an SF2 on bank 120 is a drum kit too). Only an
    /// INSTRUMENT track can be one: an audio track's stale descriptor never
    /// turns its audio into drums.
    public static func isDrumTrack(_ track: Track) -> Bool {
        guard track.kind == .instrument else { return false }
        if track.instrument?.kind == .drumSynth { return true }
        return SMFProjectExporter.isDrumKit(track)
    }

    /// Is this a slice kit (the pads `clip.sliceToSampler` makes), whose notes
    /// pick slices of a recording rather than pitches?
    ///
    /// Read from the STORED marker only (the coordinator's ruling for PK-F2):
    /// a chop writes one-key zones, but so can a hand-built one-sample-per-key
    /// instrument that should move, so the zone shapes decide nothing. Only an
    /// instrument track whose instrument IS the sampler counts; a stale sampler
    /// payload under another instrument kind does not.
    public static func isSliceKitTrack(_ track: Track) -> Bool {
        guard track.kind == .instrument, let instrument = track.instrument,
              instrument.kind == .sampler else { return false }
        return instrument.resolvedSampler.isSliceKit
    }

    /// The undo label for a move of `semitones`: "Move Song Up 3 Semitones".
    public static func undoLabel(semitones: Int) -> String {
        let n = abs(semitones)
        return "Move Song \(direction(semitones)) \(n) \(n == 1 ? "Semitone" : "Semitones")"
    }

    /// Plans a key change of `semitones` over `tracks`. Pure: same inputs, same
    /// answer, nothing written anywhere.
    ///
    /// - Parameters:
    ///   - excludeTrackIds: tracks to leave as they are, such as a vocal that
    ///     already sits right. An id no track has is refused
    ///     (`ProjectError.trackNotFound`), because a typo would otherwise move
    ///     the very track the caller meant to keep.
    ///   - loopLayerTrackIds: the tracks an open looper session has a layer (or
    ///     a pass in flight) on. A move that would touch one is refused.
    ///   - dryRun: only the report's wording depends on it.
    ///   - sliceKit: which tracks are slice kits. Production always takes the
    ///     default, `isSliceKitTrack` (the stored marker); a test passes its own
    ///     so the skip is testable while the marker is not stored yet.
    /// - Throws: `TransposeRefusal` (range, a note leaving 0…127, an audio clip
    ///   past ±24, an open looper) or `ProjectError.trackNotFound`.
    public static func plan(tracks: [Track], semitones: Int,
                            excludeTrackIds: Set<UUID> = [],
                            loopLayerTrackIds: Set<UUID> = [],
                            dryRun: Bool = false,
                            sliceKit: (Track) -> Bool = isSliceKitTrack) throws -> ProjectTransposePlan {
        guard semitoneRange.contains(semitones) else {
            throw outOfRange(describing: Double(semitones))
        }
        let known = Set(tracks.map(\.id))
        if let unknown = excludeTrackIds.subtracting(known)
            .sorted(by: { $0.uuidString < $1.uuidString }).first {
            throw ProjectError.trackNotFound(unknown)
        }

        // Which tracks move. Excluded wins over drums and slice kits: it is the
        // caller's word.
        enum Decision { case move, drums, sliceKit, excluded }
        let decisions: [Decision] = tracks.map { track in
            if excludeTrackIds.contains(track.id) { return .excluded }
            if isDrumTrack(track) { return .drums }
            if sliceKit(track) { return .sliceKit }
            return .move
        }

        if semitones != 0,
           let index = tracks.indices.first(where: {
               decisions[$0] == .move && loopLayerTrackIds.contains(tracks[$0].id)
           }) {
            throw looperOpen(track: tracks[index], semitones: semitones)
        }

        // Refusals first, over everything that would move, so a refused call
        // builds nothing. Notes, then audio, each in project order.
        if semitones != 0 {
            try refuseNotesOutOfRange(tracks: tracks, decisions: decisions.map { $0 == .move },
                                      semitones: semitones)
            try refuseAudioOutOfRange(tracks: tracks, decisions: decisions.map { $0 == .move },
                                      semitones: semitones)
        }

        var newTracks = tracks
        var results: [TransposeReport.TrackResult] = []
        var warnings: [TransposeReport.Warning] = []
        var tally = Tally()

        for (index, track) in tracks.enumerated() {
            switch decisions[index] {
            case .excluded:
                tally.excludedTracks += 1
                results.append(.init(trackId: track.id, name: track.name, outcome: .skippedExcluded,
                                     reason: "Left as it is, as you asked.", clips: []))
                continue
            case .drums:
                tally.drumTracks += 1
                results.append(.init(trackId: track.id, name: track.name, outcome: .skippedDrums,
                                     reason: "A drum track: each note picks a drum sound, not a pitch.",
                                     clips: []))
                continue
            case .sliceKit:
                tally.sliceKitTracks += 1
                results.append(.init(trackId: track.id, name: track.name, outcome: .skippedSliceKit,
                                     reason: "A chopped loop: each note plays one slice of the "
                                        + "recording, not a pitch, so moving it would play a "
                                        + "different slice.",
                                     clips: []))
                continue
            case .move:
                break
            }
            guard semitones != 0 else {
                results.append(.init(trackId: track.id, name: track.name, outcome: .nothingToMove,
                                     reason: "A move of 0 semitones keeps every note where it is.",
                                     clips: []))
                continue
            }

            var moved = track
            var clipResults: [TransposeReport.ClipResult] = []
            var shiftedAudio: [Clip] = []
            for c in moved.clips.indices {
                let before = moved.clips[c]
                if let result = transpose(&moved.clips[c], by: semitones, place: .timeline,
                                          tally: &tally) {
                    clipResults.append(result)
                    if !before.isMIDI { shiftedAudio.append(before) }
                }
            }
            for g in moved.takeGroups.indices {
                for l in moved.takeGroups[g].lanes.indices {
                    let before = moved.takeGroups[g].lanes[l].clip
                    if let result = transpose(&moved.takeGroups[g].lanes[l].clip, by: semitones,
                                              place: .take, tally: &tally) {
                        clipResults.append(result)
                        if !before.isMIDI { shiftedAudio.append(before) }
                    }
                }
            }

            if clipResults.isEmpty {
                results.append(.init(trackId: track.id, name: track.name, outcome: .nothingToMove,
                                     reason: "No notes or audio clips to move.", clips: []))
                continue
            }
            // The kept fields' counts, over the tracks that actually moved.
            if track.kind == .instrument, track.instrument?.kind == .sampler {
                tally.samplerZonesKept += track.instrument?.sampler?.zones.count ?? 0
            }
            if track.voiceProvenance != nil { tally.provenanceKept += 1 }
            newTracks[index] = moved
            results.append(.init(trackId: track.id, name: track.name, outcome: .moved,
                                 reason: nil, clips: clipResults))
            warnings.append(contentsOf: audioWarnings(track: track, shifted: shiftedAudio,
                                                      semitones: semitones))
        }

        let changes = tally.notesMoved > 0 || tally.audioClipsShifted > 0
        let report = TransposeReport(
            semitones: semitones, dryRun: dryRun, applied: !dryRun && changes,
            summary: summary(semitones: semitones, dryRun: dryRun, tally: tally,
                             movedTracks: results.filter { $0.outcome == .moved }),
            notesMoved: tally.notesMoved, midiClipsMoved: tally.midiClipsMoved,
            audioClipsShifted: tally.audioClipsShifted, takeClipsMoved: tally.takeClipsMoved,
            tracks: results, fields: fields(tally: tally), warnings: warnings)
        return ProjectTransposePlan(tracks: changes ? newTracks : tracks, report: report)
    }

    // MARK: Moving one clip

    /// What a plan counts as it goes.
    struct Tally {
        var notesMoved = 0
        var midiClipsMoved = 0
        var audioClipsShifted = 0
        var takeClipsMoved = 0
        var tunedClipsKept = 0
        var pitchBendLanesKept = 0
        var samplerZonesKept = 0
        var provenanceKept = 0
        var drumTracks = 0
        var sliceKitTracks = 0
        var excludedTracks = 0
    }

    /// Moves one clip IN PLACE (see the banner) and describes it, or returns
    /// nil when there was nothing in it to move (a MIDI clip with no notes).
    /// Range checks have already run; this never clamps.
    static func transpose(_ clip: inout Clip, by semitones: Int,
                          place: TransposeReport.ClipResult.Place,
                          tally: inout Tally) -> TransposeReport.ClipResult? {
        if clip.isMIDI {
            let count = clip.notes?.count ?? 0
            guard count > 0 else { return nil }
            for n in clip.notes!.indices { clip.notes![n].pitch += semitones }
            tally.notesMoved += count
            tally.midiClipsMoved += 1
            if place == .take { tally.takeClipsMoved += 1 }
            tally.pitchBendLanesKept += clip.controllerLanes.filter { $0.type == .pitchBend }.count
            return .init(clipId: clip.id, name: clip.name, kind: .midi, place: place,
                         notesMoved: count, shiftBefore: nil, shiftAfter: nil, keepsTuning: nil)
        }
        let before = clip.pitchShiftSemitones
        clip.pitchShiftSemitones += Double(semitones)
        tally.audioClipsShifted += 1
        if place == .take { tally.takeClipsMoved += 1 }
        let tuned = clip.pitchEdits != nil
        if tuned { tally.tunedClipsKept += 1 }
        return .init(clipId: clip.id, name: clip.name, kind: .audio, place: place,
                     notesMoved: nil, shiftBefore: before, shiftAfter: clip.pitchShiftSemitones,
                     keepsTuning: tuned)
    }

    // MARK: Refusals

    static func outOfRange(describing value: Double) -> TransposeRefusal {
        let shown = value.isFinite ? ClampNotice.number(value) : "that value"
        return TransposeRefusal(
            code: .transposeOutOfRange,
            message: "A key change moves the song by a whole number of semitones, from 12 down "
                + "to 12 up (one octave either way); \(shown) is not one of those. "
                + "Nothing was changed.",
            wouldBe: value.isFinite ? value : nil)
    }

    static func looperOpen(track: Track, semitones: Int) -> TransposeRefusal {
        TransposeRefusal(
            code: .transposeLooperOpen,
            message: "The looper has a layer on '\(track.name)', and it would put that "
                + "layer's old notes back on its next pass. Close the looper, then move the "
                + "song \(direction(semitones).lowercased()) \(amount(semitones)). "
                + "Nothing was changed.",
            trackId: track.id, trackName: track.name)
    }

    /// Every clip that would move, timeline first then takes, in project order.
    private static func movingClips(_ tracks: [Track], _ moves: [Bool])
        -> [(track: Track, clip: Clip, isTake: Bool)] {
        var out: [(track: Track, clip: Clip, isTake: Bool)] = []
        for (index, track) in tracks.enumerated() where moves[index] {
            for clip in track.clips { out.append((track, clip, false)) }
            for group in track.takeGroups {
                for lane in group.lanes { out.append((track, lane.clip, true)) }
            }
        }
        return out
    }

    private static func refuseNotesOutOfRange(tracks: [Track], decisions moves: [Bool],
                                              semitones: Int) throws {
        var first: (track: Track, clip: Clip, isTake: Bool, note: MIDINote)?
        var count = 0
        for (track, clip, isTake) in movingClips(tracks, moves) {
            for note in clip.notes ?? [] where !MIDINote.pitchRange.contains(note.pitch + semitones) {
                count += 1
                if first == nil { first = (track, clip, isTake, note) }
            }
        }
        guard let first else { return }
        let target = first.note.pitch + semitones
        let edge = semitones > 0
            ? "above the highest note MIDI can play (\(Fundamental.noteName(midiNote: 127)), 127)"
            : "below the lowest note MIDI can play (\(Fundamental.noteName(midiNote: 0)), 0)"
        let others = count > 1 ? " \(count - 1) other \(count - 1 == 1 ? "note" : "notes") "
            + "would go out of range too." : ""
        throw TransposeRefusal(
            code: .transposeNoteOutOfRange,
            message: "Moving the song \(direction(semitones).lowercased()) \(amount(semitones)) "
                + "would push a note in \(describe(first.clip, isTake: first.isTake, on: first.track)) "
                + "from \(Fundamental.noteName(midiNote: first.note.pitch)) to MIDI \(target), "
                + "\(edge).\(others) Nothing was changed. Try a smaller move, or leave that "
                + "track out.",
            trackId: first.track.id, trackName: first.track.name,
            clipId: first.clip.id, clipName: first.clip.name,
            noteId: first.note.id, wouldBe: Double(target))
    }

    private static func refuseAudioOutOfRange(tracks: [Track], decisions moves: [Bool],
                                              semitones: Int) throws {
        let range = Clip.pitchShiftSemitonesRange
        let offenders = movingClips(tracks, moves).filter {
            !$0.clip.isMIDI && !range.contains($0.clip.pitchShiftSemitones + Double(semitones))
        }
        guard let first = offenders.first else { return }
        let target = first.clip.pitchShiftSemitones + Double(semitones)
        let others = offenders.count > 1
            ? " \(offenders.count - 1) other audio \(offenders.count - 1 == 1 ? "clip" : "clips") "
                + "would go past it too." : ""
        throw TransposeRefusal(
            code: .transposeAudioShiftOutOfRange,
            message: "Moving the song \(direction(semitones).lowercased()) \(amount(semitones)) "
                + "would shift the audio in \(describe(first.clip, isTake: first.isTake, on: first.track)) "
                + "to \(signed(target)) semitones, past the limit of "
                + "\(ClampNotice.number(range.upperBound)) either way (two octaves).\(others) "
                + "Nothing was changed. Try a smaller move, or leave that track out.",
            trackId: first.track.id, trackName: first.track.name,
            clipId: first.clip.id, clipName: first.clip.name, wouldBe: target)
    }

    // MARK: Warnings

    private static func audioWarnings(track: Track, shifted: [Clip],
                                      semitones: Int) -> [TransposeReport.Warning] {
        guard !shifted.isEmpty else { return [] }
        let generated = track.isAIGenerated || track.voiceProvenance != nil
            || shifted.contains(where: \.isAIGenerated)
        let what = generated ? "generated audio" : "recorded audio"
        let clips = shifted.count == 1 ? "1 clip" : "\(shifted.count) clips"
        var out = [TransposeReport.Warning(
            code: .audioWillBePitchShifted, trackId: track.id, trackName: track.name,
            clipIds: shifted.map(\.id), source: generated ? .generated : .recorded,
            message: "This key change shifts the \(what) on '\(track.name)' "
                + "\(direction(semitones).lowercased()) \(amount(semitones)) (\(clips)). Shifted "
                + "audio can sound less natural; to keep this track as it is, leave it out of "
                + "the key change.")]
        // ⭐ THE ONE RULE, asked twice (before and after), never a local
        // `semitones != 0`: `PitchEditSet.consonantMixIsActive`.
        for clip in shifted {
            guard let set = clip.pitchEdits,
                  set.consonantMixIsActive(stretchRatio: clip.stretchRatio,
                                           clipSemitones: clip.pitchShiftSemitones),
                  !set.consonantMixIsActive(stretchRatio: clip.stretchRatio,
                                            clipSemitones: clip.pitchShiftSemitones
                                                + Double(semitones))
            else { continue }
            out.append(.init(
                code: .consonantProtectionStops, trackId: track.id, trackName: track.name,
                clipIds: [clip.id], source: nil,
                message: "'\(clip.name)' keeps its breaths and S or T sounds out of its tuning. "
                    + "That stops while the whole clip is shifted, so those sounds move with "
                    + "the new key too."))
        }
        return out
    }

    // MARK: The census, as the report carries it

    static func fields(tally: Tally) -> [TransposeReport.FieldResult] {
        [
            .init(field: "MIDINote.pitch", verdict: .moved, count: tally.notesMoved,
                  reason: "Every note on a pitched track moves by the same number of semitones."),
            .init(field: "Clip.pitchShiftSemitones", verdict: .moved,
                  count: tally.audioClipsShifted,
                  reason: "Each audio clip's pitch shift changes by the same amount, so recorded "
                    + "and generated audio follows the song."),
            .init(field: "TakeGroup.lanes[].clip", verdict: .moved, count: tally.takeClipsMoved,
                  reason: "The takes a comp is built from move too, so choosing a different take "
                    + "later keeps the new key."),
            .init(field: "Clip.pitchEdits", verdict: .kept, count: tally.tunedClipsKept,
                  reason: "A tuned clip's corrections are measured from the recording itself, "
                    + "and the clip's pitch shift is added on top when it plays, so the shift "
                    + "alone carries the tuned notes to the new key. Changing them would tune "
                    + "every note to the wrong pitch."),
            .init(field: "NoteSegment.detectedHz", verdict: .kept, count: nil,
                  reason: "What the singer actually sang: a fact about the recording, never "
                    + "edited."),
            .init(field: "PitchCorrectionScale.tonicPitchClass", verdict: .notStored, count: nil,
                  reason: "The scale is only an input to Auto-Correct Pitch; each tuned note "
                    + "stores its own correction instead, so there is no key to move."),
            .init(field: "SamplerZone.rootPitch", verdict: .kept, count: tally.samplerZonesKept,
                  reason: "A sampler's key map says which key plays which sample. The notes "
                    + "already moved; moving the map too would cancel the move."),
            .init(field: "MIDIControllerLane.pitchBend", verdict: .kept,
                  count: tally.pitchBendLanesKept,
                  reason: "A pitch bend is measured from the note it bends."),
            .init(field: "Instrument pitch settings", verdict: .kept, count: nil,
                  reason: "Bend range, sub-oscillator octave, detune and drum tuning are sound "
                    + "design measured from the note being played."),
            .init(field: "VoiceProvenance.pitchSemitones", verdict: .kept,
                  count: tally.provenanceKept,
                  reason: "A record of how a converted vocal was made; nothing plays from it."),
            .init(field: "Drum track notes", verdict: .skipped, count: tally.drumTracks,
                  reason: "On a drum track each note picks a drum sound, not a pitch."),
            .init(field: "Slice kit notes", verdict: .skipped, count: tally.sliceKitTracks,
                  reason: "On a chopped loop (Chop to Sampler) each note plays one slice of the "
                    + "recording; moving it would play a different slice, so these notes stay."),
            .init(field: "Excluded tracks", verdict: .skipped, count: tally.excludedTracks,
                  reason: "Left as they are, as you asked."),
            .init(field: "Musical Typing chord key", verdict: .notStored, count: nil,
                  reason: "The key the chord keys light up in is a playing setting, not part of "
                    + "the song. Set it to the new key in Musical Typing."),
        ]
    }

    // MARK: Words

    private static func summary(semitones: Int, dryRun: Bool, tally: Tally,
                                movedTracks: [TransposeReport.TrackResult]) -> String {
        guard semitones != 0 else {
            return "A move of 0 semitones keeps the song in its key. Nothing was changed."
        }
        var skipped: [String] = []
        if tally.drumTracks > 0 {
            skipped.append(tally.drumTracks == 1 ? "1 drum track" : "\(tally.drumTracks) drum tracks")
        }
        if tally.sliceKitTracks > 0 {
            skipped.append(tally.sliceKitTracks == 1
                ? "1 chopped loop" : "\(tally.sliceKitTracks) chopped loops")
        }
        if tally.excludedTracks > 0 {
            skipped.append(tally.excludedTracks == 1
                ? "1 track you left out" : "\(tally.excludedTracks) tracks you left out")
        }
        let skippedSentence = skipped.isEmpty ? "" : " Skipped " + listed(skipped) + "."
        guard tally.notesMoved > 0 || tally.audioClipsShifted > 0 else {
            return "Nothing to move: no track has notes or audio clips that follow the key."
                + skippedSentence
        }
        var parts: [String] = []
        if tally.notesMoved > 0 {
            parts.append(plural(tally.notesMoved, "note") + " in "
                         + plural(tally.midiClipsMoved, "MIDI clip"))
        }
        if tally.audioClipsShifted > 0 {
            parts.append(plural(tally.audioClipsShifted, "audio clip"))
        }
        let verb = dryRun ? "Would move" : "Moved"
        return "\(verb) the song \(direction(semitones).lowercased()) \(amount(semitones)): "
            + parts.joined(separator: " and ") + " on " + plural(movedTracks.count, "track") + "."
            + skippedSentence
    }

    private static func describe(_ clip: Clip, isTake: Bool, on track: Track) -> String {
        (isTake ? "the take '\(clip.name)'" : "'\(clip.name)'") + " on track '\(track.name)'"
    }

    static func direction(_ semitones: Int) -> String { semitones < 0 ? "Down" : "Up" }

    static func amount(_ semitones: Int) -> String {
        let n = abs(semitones)
        return n == 1 ? "1 semitone" : "\(n) semitones"
    }

    private static func plural(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// "a", "a and b", "a, b and c".
    private static func listed(_ items: [String]) -> String {
        guard items.count > 2 else { return items.joined(separator: " and ") }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "") + ClampNotice.number(value)
    }
}

// MARK: - The slice-kit marker (round 2, PK-F2)

// ⚠️ INTERIM. The marker is STORED as `SamplerParams.sliceKit: Bool?` (absent
// means "not a kit", so every existing project decodes unchanged), but that
// field lives in `Model.swift` + `SamplerDocument`, which W7-SD2 holds right
// now; the orchestrator installs the drafted patch after SD2 releases them.
// The patch adds the field and flips the two bodies below:
//   isSliceKit      → `sliceKit == true`
//   markSliceKit()  → `sliceKit = true`
// Until it lands, no sampler reads as a slice kit and marking one does
// nothing, so a key change still moves a chop's notes (PK-F2 stays open,
// pinned as a known issue). Every reader and writer already goes through
// these two, so the call sites do not change when the field arrives.
extension SamplerParams {
    /// True when these zones are a chopped loop made by `clip.sliceToSampler`:
    /// each key plays one slice of a recording, so a note is a trigger, not a
    /// pitch.
    public var isSliceKit: Bool { false }

    /// Marks these zones as a chopped loop. `sliceClipToSampler` is the only
    /// writer: a library import or a fresh instrument starts unmarked.
    public mutating func markSliceKit() {}
}
