import Foundation

/// Turns a melody clip's singing style (`Clip.singStyle`) into what the sung
/// take lands with (p2-sing-x5, DSP half; design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §5.4): pitch-editor edits on
/// the landed clip (vibrato and per-note level), and the spans the air layer
/// (`SungAirLayer`) fills.
///
/// Pure, nonisolated and offline: the sing job calls it in its detached
/// finishing task. Nothing here runs on the render thread; the vibrato plays
/// through the existing pitch renderer, and the edits stay ordinary
/// pitch-editor edits the user can change later without singing again.
///
/// ## THE ORDER x6 WIRES (design §5.4, fixed)
///
/// Inside `SingJobCoordinator.assembleAndLand`, in this order:
///
/// 1. **Sum.** `let take = SingTakeAssembly.assemble(placed, sampleRate: rate)`.
/// 2. **Detect, BEFORE any air.** SwiftF0 over `take` itself (the band noise
///    of step 3 would blur the pitch track that places the vibrato), then
///    `let detected = PitchNoteTable.detected(from: result)`. The timeline is
///    the landed file's, so the segment times stay valid for it.
///    ⚠️ Today the coordinator detects once, on the WRITTEN take
///    (`detectPitch(url)`, `[ClipPitchFrame]`); this needs a second SwiftF0
///    pass on the pre-air sum (a temp file, or a buffer seam), bridged into a
///    `PitchDetectionResult` (`frameRateHz` from the backend, 62.5 for
///    SwiftF0). Skip both when `SungExpressionPlanner.isNoOp(style:)` is true.
/// 3. **Plan and air.**
///    `let notes = SungExpressionPlanner.notes(planned: plan.notes,
///        windows: SingTakeAssembly.noteWindows(plan), velocities: …)`
///    (⚠️ NOT "unit offset + note start": `SingUnit.offsetSeconds` is where
///    the unit's AUDIO starts, `leadSeconds` before its first onset;
///    `noteWindows` is the one home of a note's landed time),
///    `let expression = try SungExpressionPlanner.plan(notes: notes,
///        style: clip.singStyle, detected: detected, clipID: plan.clipID)`,
///    `let aired = SungAirLayer.apply(expression.airSpans, to: take,
///        sampleRate: Double(rate), seed: job.status.seed)`.
/// 4. **Gain.** `ProjectStore.normalizeSungVocalTake` on `aired` (base §4.5
///    step 3), so the loudness stage sees the air.
/// 5. **Gates** L1-L4 on the WRITTEN bytes, as today.
/// 6. **Land** with `landSungVocal(…, pitchEdits: expression.table)` (nil is
///    exactly today's call) and `SungVocalProvenance.style` = the style the
///    job resolved (`SingStyle.resolved`, the clip's own with its default
///    vibrato filled in).
///
/// ## The rules (design §5.4; every number an [A] until listening round V)
///
/// * **Mapping.** A detected segment belongs to the planned note it overlaps
///   most, and only if that overlap is at least half the segment's own length
///   (`minimumOverlapFraction`); a tie goes to the earlier note.
/// * **Vibrato** (`edit(for:segment:)`), on `.detected` segments only: a
///   sound (`.unpitched`) or a slide (`.transition`) never gets one.
///   - As sung: no edit.
///   - Straight: `vibratoScale` 0 (the singer's wobble removed); `driftScale`
///     untouched, so the slow drift stays (design §5.4 "Why drift stays").
///     Every sung segment, any length.
///   - Gentle / Normal / Wide: `vibratoScale` 0, then a new wobble of
///     `newWobbleRateHz` at 25 / 45 / 70 cents, fading in over
///     `newWobbleOnsetSeconds`, phase-anchored at the segment's centre (the
///     Wobble tool's convention). ONLY on segments of at least
///     `newWobbleMinimumSegmentSeconds`; a shorter segment of such a note is
///     left as sung (no edit at all).
///   The edits go through `PitchEditSet.applyingNoteVibratos`, the store's own
///   pure function behind the one clamp (`NoteVibratoLimits.clamp`).
/// * **Level** (`levelDb(velocity:)`, only when the style follows velocity):
///   `20·log10(velocity / 100)`, clamped to −12…0 dB, written as the note's
///   `amplitudeDb` on EVERY segment mapped to the note (sounds and slides
///   too: a quieter note's consonants are quieter). It only ever turns a note
///   DOWN, so it cannot push the take past the −1 dBTP ceiling L3 checked.
/// * **Air** (`SungAirLayer.levelDb(forAir:)`): each planned note whose
///   resolved air is above 0 gives one span over the PLANNED note's own time.
/// * **As sung lands nothing.** The table is nil when no segment changed
///   (every note as sung and no level), so an as-sung style never seeds a
///   table and lands byte-identically to a take with no pass at all. Air
///   alone never makes a table. ⚠️ A nil style is NOT as sung: its vibrato
///   is `SingStyle.defaultVibrato` (Normal, the user's round-V pick).
public enum SungExpressionPlanner {

    /// One sung note, in the LANDED take's seconds.
    public struct Note: Sendable, Equatable {
        /// The melody note (`MIDINote.id`, `SingNote.noteID`): the key the
        /// style's per-note choices use.
        public var noteID: UUID
        public var startSeconds: Double
        public var endSeconds: Double
        /// The melody note's velocity (1…127).
        public var velocity: Int

        public init(noteID: UUID, startSeconds: Double, endSeconds: Double, velocity: Int) {
            self.noteID = noteID
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.velocity = velocity
        }
    }

    /// What the pass decided for one take.
    public struct Plan: Sendable, Equatable {
        /// The landed clip's pitch table: the detected table with this pass's
        /// edits, or nil when it would change no note (land with no table).
        public var table: PitchEditSet?
        /// Where the air layer goes (`SungAirLayer.apply`), in take seconds.
        public var airSpans: [SungAirLayer.Span]
        /// Segments given a vibrato edit / a level.
        public var vibratoSegments: Int
        public var levelSegments: Int
        /// Gentle/Normal/Wide segments shorter than
        /// `newWobbleMinimumSegmentSeconds`, left as sung.
        public var shortSegments: Int
        /// Segments that belong to no planned note (less than half inside one).
        public var unmappedSegments: Int

        public init(table: PitchEditSet?, airSpans: [SungAirLayer.Span], vibratoSegments: Int,
                    levelSegments: Int, shortSegments: Int, unmappedSegments: Int) {
            self.table = table
            self.airSpans = airSpans
            self.vibratoSegments = vibratoSegments
            self.levelSegments = levelSegments
            self.shortSegments = shortSegments
            self.unmappedSegments = unmappedSegments
        }

        /// True when the take lands exactly as sung: no table and no air.
        public var isNoOp: Bool { table == nil && airSpans.isEmpty }
    }

    // MARK: - The numbers [A: listening round V]

    /// A segment must lie at least this much inside its note to belong to it.
    public static let minimumOverlapFraction: Double = 0.5
    /// The new wobble's rate, Hz (per source second; a landed take plays at
    /// ratio 1, so this is also what is heard).
    public static let newWobbleRateHz: Double = 5.5
    /// The new wobble's fade-in, seconds from the segment's start.
    public static let newWobbleOnsetSeconds: Double = 0.25
    /// Gentle/Normal/Wide touch only segments at least this long, seconds.
    public static let newWobbleMinimumSegmentSeconds: Double = 0.45
    /// How much shorter than `newWobbleMinimumSegmentSeconds` a segment may
    /// read and still count (`1.45 − 1.0` is `0.44999999999999996`).
    static let lengthTolerance: Double = 1e-9
    /// The velocity that sings as sung; anything at or above it is 0 dB.
    public static let referenceVelocity: Double = 100
    /// The levels "follow note loudness" may give, dB.
    public static let velocityLevelRangeDb: ClosedRange<Double> = -12...0

    /// The new wobble's depth for a preset, cents, or nil for a preset that
    /// adds none (As sung, Straight).
    public static func newWobbleDepthCents(_ vibrato: SingStyle.Vibrato) -> Double? {
        switch vibrato {
        case .asSung, .straight: nil
        case .gentle: 25
        case .normal: 45
        case .wide: 70
        }
    }

    // MARK: - The rules, one function each

    /// True when `style` asks for nothing this pass does: every note as sung,
    /// no air anywhere, velocity not followed. An unnamed clip-wide vibrato is
    /// `SingStyle.defaultVibrato`, so a nil style is NOT a no-op. The
    /// coordinator skips the pre-air detection then; `plan` would return a
    /// no-op anyway.
    public static func isNoOp(style: SingStyle?) -> Bool {
        let style = SingStyle.normalized(style) ?? SingStyle()
        if style.followsVelocity { return false }
        if (style.vibrato ?? SingStyle.defaultVibrato) != .asSung { return false }
        if let air = style.air, air > 0 { return false }
        for choice in (style.notes ?? [:]).values {
            if let vibrato = choice.vibrato, vibrato != .asSung { return false }
            if let air = choice.air, air > 0 { return false }
        }
        return true
    }

    /// The level a note of `velocity` is sung at, dB: `20·log10(v / 100)`
    /// clamped to `velocityLevelRangeDb` (100 and above → 0; 64 → −3.88;
    /// 0 and below → −12).
    public static func levelDb(velocity: Int) -> Double {
        guard velocity > 0 else { return velocityLevelRangeDb.lowerBound }
        let db = 20 * log10(Double(velocity) / referenceVelocity)
        return min(max(db, velocityLevelRangeDb.lowerBound), velocityLevelRangeDb.upperBound)
    }

    /// The wobble edit `vibrato` asks of `segment`, or nil for none (As sung;
    /// a sound or a slide; Gentle/Normal/Wide on a segment shorter than
    /// `newWobbleMinimumSegmentSeconds`).
    public static func edit(for vibrato: SingStyle.Vibrato, segment: NoteSegment) -> NoteVibratoEdit? {
        guard segment.origin == .detected else { return nil }
        switch vibrato {
        case .asSung:
            return nil
        case .straight:
            return NoteVibratoEdit(vibratoScale: 0)
        case .gentle, .normal, .wide:
            guard let depth = newWobbleDepthCents(vibrato),
                  segment.durationSeconds >= newWobbleMinimumSegmentSeconds - lengthTolerance
            else { return nil }
            return NoteVibratoEdit(vibratoRateHz: newWobbleRateHz,
                                   vibratoDepthCents: depth,
                                   vibratoOnsetSeconds: newWobbleOnsetSeconds,
                                   vibratoPhaseAnchorSeconds: (segment.startSeconds + segment.endSeconds) / 2,
                                   vibratoScale: 0)
        }
    }

    /// The index in `notes` of the note `segment` belongs to: the one it
    /// overlaps most, if that overlap is at least `minimumOverlapFraction` of
    /// the segment; a tie goes to the earlier index. nil for none.
    public static func owner(of segment: NoteSegment, among notes: [Note]) -> Int? {
        let length = segment.durationSeconds
        guard length > 0 else { return nil }
        var best: (index: Int, overlap: Double)?
        for (index, note) in notes.enumerated() {
            guard note.startSeconds.isFinite, note.endSeconds.isFinite,
                  note.endSeconds > note.startSeconds else { continue }
            let overlap = min(segment.endSeconds, note.endSeconds) - max(segment.startSeconds, note.startSeconds)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap { best = (index, overlap) }
        }
        guard let best, best.overlap >= minimumOverlapFraction * length else { return nil }
        return best.index
    }

    /// The notes `plan` needs, from a sing plan's notes and their landed
    /// windows (`SingTakeAssembly.noteWindows(plan)`, the same order as
    /// `SingPlan.notes`) and the melody clip's velocities by note id. A note
    /// whose velocity is not given sings as sung (100). nil when the two lists
    /// differ in length.
    public static func notes(planned: [SingNote], windows: [(start: Double, end: Double)],
                             velocities: [UUID: Int]) -> [Note]? {
        guard planned.count == windows.count else { return nil }
        return zip(planned, windows).map { note, window in
            Note(noteID: note.noteID, startSeconds: window.start, endSeconds: window.end,
                 velocity: velocities[note.noteID] ?? Int(referenceVelocity))
        }
    }

    // MARK: - The pass

    /// The table and air spans `style` gives a take whose detected table is
    /// `detected` (`PitchNoteTable.detected(from:)` on the pre-air sum) and
    /// whose planned notes are `notes`. `stretchRatio` is the landed clip's
    /// (1 for a new take); `clipID` only words a refusal.
    ///
    /// Throws only what `PitchEditSet.applyingNoteVibratos` throws, which a
    /// table from `PitchNoteTable.detected` with this pass's edits never
    /// triggers (each segment is named once, never a sound, with finite
    /// values). A caller that catches one should land WITHOUT the style and
    /// say so, never land a half-styled take.
    public static func plan(notes: [Note], style: SingStyle?, detected: PitchEditSet,
                            stretchRatio: Double = 1, clipID: UUID) throws -> Plan {
        let style = SingStyle.normalized(style)
        // A non-finite start sorts last (it owns nothing anyway), keeping the
        // comparator a strict weak order.
        func key(_ note: Note) -> Double { note.startSeconds.isFinite ? note.startSeconds : .infinity }
        let ordered = notes.enumerated().sorted {
            (key($0.element), $0.offset) < (key($1.element), $1.offset)
        }.map(\.element)

        var items: [NoteVibratoItem] = []
        var levels: [(segmentId: UUID, db: Double)] = []
        var shortSegments = 0
        var unmapped = 0
        for segment in detected.segments {
            guard let ownerIndex = owner(of: segment, among: ordered) else {
                unmapped += 1
                continue
            }
            let note = ordered[ownerIndex]
            let vibrato = (style ?? SingStyle()).resolvedVibrato(forNote: note.noteID)
            if let wobble = edit(for: vibrato, segment: segment) {
                items.append(NoteVibratoItem(segmentId: segment.id, edit: wobble))
            } else if segment.origin == .detected, newWobbleDepthCents(vibrato) != nil {
                shortSegments += 1
            }
            if style?.followsVelocity == true {
                let db = levelDb(velocity: note.velocity)
                if db != 0 { levels.append((segment.id, db)) }
            }
        }

        var table = detected
        if !items.isEmpty {
            table = try detected.applyingNoteVibratos(items, stretchRatio: stretchRatio, clipId: clipID).set
        }
        if !levels.isEmpty {
            // `ProjectStore.setClipNoteGain`'s write, verbatim: clamp, write the
            // field, then D4-1's one home (`afterHandEdit(from:)`).
            let before = table
            let position = Dictionary(table.segments.enumerated().map { ($0.element.id, $0.offset) },
                                      uniquingKeysWith: { first, _ in first })
            for level in levels {
                guard let index = position[level.segmentId] else { continue }
                let clamped = PitchCorrectionMath.finite(level.db, default: 0).clamped(to: Clip.gainDbRange)
                table.segments[index].amplitudeDb = clamped
            }
            table = table.afterHandEdit(from: before)
        }

        var airSpans: [SungAirLayer.Span] = []
        if let style {
            for note in ordered {
                guard note.startSeconds.isFinite, note.endSeconds.isFinite,
                      note.endSeconds > note.startSeconds,
                      let db = SungAirLayer.levelDb(forAir: style.resolvedAir(forNote: note.noteID))
                else { continue }
                airSpans.append(SungAirLayer.Span(startSeconds: note.startSeconds, endSeconds: note.endSeconds,
                                                  levelDb: db))
            }
        }

        let changed = table.segments != detected.segments
        return Plan(table: changed ? table : nil, airSpans: airSpans,
                    vibratoSegments: changed ? items.count : 0,
                    levelSegments: changed ? levels.count : 0,
                    shortSegments: shortSegments, unmappedSegments: unmapped)
    }
}
