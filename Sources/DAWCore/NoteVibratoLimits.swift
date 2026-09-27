import Foundation

// m23-ap C5a-2 (+ natural tuning §3, L2) — ONE NOTE'S WOBBLE EDIT, ITS LIMITS,
// AND THE ONE CLAMP.
//
// Design: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §10 (the
// setter, its limits, the refusals) and §11.1 (split);
// `docs/design/2026-09-25-natural-tuning.md` §3b (the batch twin, items
// ABSOLUTE) and §3g G5 (a read-back compares against THIS clamp, never against
// the setter's own return).
//
// ⭐ **ONE CLAMP FOR THE DRAG AND THE WIRE.** The Wobble and Drift tools call
// `NoteVibratoLimits.clamp` on every draft change, and the store calls the same
// function on commit (through `PitchEditSet.applyingNoteVibratos`, the
// `NotePitchDraft` one-home precedent). So a drag and a wire call can never
// disagree about how far is too far, and what a drag draws is what its release
// stores.
//
// ⛔ **A DIRECT FIELD ASSIGNMENT BYPASSES `NoteSegment.init`'s HEALING** (the
// `setNotePitchClamps` lesson, `ProjectStore+PitchNoteEdits.swift`'s banner).
// So nothing here writes a field that has not been through `clamp`: the only
// way to put a `NoteVibratoEdit` onto a segment is `NoteVibratoClamp.applied`,
// and the only way to get a `NoteVibratoClamp` is `clamp`.
//
// ⚠️ **A NON-FINITE VALUE IS REFUSED IN WORDS, NEVER HEALED.** `NoteSegment.init`
// turns a NaN into "inert" silently, which is right for a damaged FILE. A
// setter must not accept input it then ignores (design §10 item 2), so the
// clamp throws, naming the field. JSON cannot carry a NaN; the Swift API and a
// gesture that divides by a zero row height can.

/// ONE note's wobble edit: six optional fields, `nil` = "leave it as stored".
///
/// Units are the MODEL's (`NoteSegment`), which are also the wire's keys, so an
/// agent can read a segment with `clip.getPitchEdits` and write it back without
/// a translation table. ⚠️ `vibratoRateHz` is per SOURCE second: what a
/// listener hears is `vibratoRateHz ÷ clip.stretchRatio`.
///
/// Two mechanisms share this edit (the `NoteSegment` generator banner):
///  * `vibratoScale` / `driftScale` keep, narrow or widen the SINGER'S own
///    wobble and slow drift (1 = as sung, 0 = removed);
///  * `vibratoRateHz` / `vibratoDepthCents` / `vibratoOnsetSeconds` /
///    `vibratoPhaseAnchorSeconds` make a NEW sine wobble, ADDED on top
///    (depth 0 = none).
///
/// **Every value is ABSOLUTE, never a delta** (the `setClipNotePitchOffsets`
/// rule, natural tuning §3e): a dropped call and a call of 1 must read back
/// differently. A selection drag's "same Δ for every note" is computed by the
/// caller from each note's own mouse-down value; what arrives here is where
/// each note lands.
public struct NoteVibratoEdit: Sendable, Equatable, Hashable {
    public var vibratoRateHz: Double?
    public var vibratoDepthCents: Double?
    public var vibratoOnsetSeconds: Double?
    /// C5a-1's phase anchor, source seconds. `nil` leaves it where it is: the
    /// setter never invents an anchor (design §10 item 5). The UI passes one
    /// when it creates a wobble.
    public var vibratoPhaseAnchorSeconds: Double?
    public var vibratoScale: Double?
    public var driftScale: Double?

    public init(vibratoRateHz: Double? = nil,
                vibratoDepthCents: Double? = nil,
                vibratoOnsetSeconds: Double? = nil,
                vibratoPhaseAnchorSeconds: Double? = nil,
                vibratoScale: Double? = nil,
                driftScale: Double? = nil) {
        self.vibratoRateHz = vibratoRateHz
        self.vibratoDepthCents = vibratoDepthCents
        self.vibratoOnsetSeconds = vibratoOnsetSeconds
        self.vibratoPhaseAnchorSeconds = vibratoPhaseAnchorSeconds
        self.vibratoScale = vibratoScale
        self.driftScale = driftScale
    }

    /// All six fields exactly as `segment` stores them. The UI's commit
    /// carries all six (design §10 "The UI's commit"), so what it drew is what
    /// it submits.
    public init(storedIn segment: NoteSegment) {
        self.init(vibratoRateHz: segment.vibratoRateHz,
                  vibratoDepthCents: segment.vibratoDepthCents,
                  vibratoOnsetSeconds: segment.vibratoOnsetSeconds,
                  vibratoPhaseAnchorSeconds: segment.vibratoPhaseAnchorSeconds,
                  vibratoScale: segment.vibratoScale,
                  driftScale: segment.driftScale)
    }

    /// "Back to how it was sung": the six model defaults (keep 1, drift 1,
    /// rate 0, depth 0, onset 0, anchor 0), what `resetClipNoteVibrato`
    /// writes (design §10 item 8).
    public static let asSung = NoteVibratoEdit(
        vibratoRateHz: 0, vibratoDepthCents: 0, vibratoOnsetSeconds: 0,
        vibratoPhaseAnchorSeconds: 0, vibratoScale: 1, driftScale: 1)

    /// True when every field is `nil`: an edit that asks for nothing. The
    /// setters refuse it in words rather than succeeding silently.
    public var isEmpty: Bool {
        vibratoRateHz == nil && vibratoDepthCents == nil && vibratoOnsetSeconds == nil
            && vibratoPhaseAnchorSeconds == nil && vibratoScale == nil && driftScale == nil
    }

    /// True when the edit touches `driftScale` and nothing else: what the
    /// Drift tool (natural tuning §3b, C5a-5) sends. The store names its undo
    /// step "Change Drift" then, so the Edit menu never says "Wobble" for a
    /// change that left the wobble alone.
    public var isDriftOnly: Bool {
        driftScale != nil && vibratoRateHz == nil && vibratoDepthCents == nil
            && vibratoOnsetSeconds == nil && vibratoPhaseAnchorSeconds == nil
            && vibratoScale == nil
    }
}

/// A limit that bound a value in `NoteVibratoLimits.clamp`. The raw values are
/// wire-stable: the C5a-3 verb echoes them in `clamped`.
public enum NoteVibratoLimit: String, Sendable, Equatable, Hashable, CaseIterable {
    /// `vibratoRateHz` outside `NoteSegment.vibratoRateHzRange` (0…8 per
    /// source second) at a clip ratio of 1 or above.
    case rateRange
    /// `vibratoRateHz` above `8 × stretchRatio` on a clip that plays FASTER
    /// than recorded (ratio below 1): that stored rate would be HEARD above
    /// 8 per second, which the render cannot carry (design V5; C5a-1 measured
    /// the ceiling in OUTPUT time at ratios 1, 2 and 0.5).
    case heardRateCeiling
    /// `vibratoDepthCents` outside `NoteSegment.vibratoDepthCentsRange`.
    case depthRange
    /// `vibratoOnsetSeconds` outside `NoteSegment.vibratoOnsetSecondsRange`.
    case onsetRange
    /// `vibratoPhaseAnchorSeconds` outside
    /// `NoteSegment.vibratoPhaseAnchorSecondsRange`.
    case anchorRange
    /// `vibratoScale` outside `NoteSegment.shapeScaleRange`.
    case scaleRange
    /// `driftScale` outside `NoteSegment.shapeScaleRange`.
    case driftRange
}

/// ONE note's edit, as a batch names it (natural tuning §3b). A named pair,
/// the `NotePitchOffset` precedent: a dictionary would make a repeated id
/// unrepresentable and hide the one ambiguity the store refuses in words.
public struct NoteVibratoItem: Sendable, Equatable, Hashable {
    /// The note, by `NoteSegment.id`.
    public var segmentId: UUID
    /// Where the note's wobble fields land: ABSOLUTE, never a delta.
    public var edit: NoteVibratoEdit

    public init(segmentId: UUID, edit: NoteVibratoEdit) {
        self.segmentId = segmentId
        self.edit = edit
    }
}

/// What `NoteVibratoLimits.clamp` returns: the edit as it would be STORED, and
/// every limit that bound it. The only way to write an edit onto a segment is
/// `applied(to:)`, so an unclamped value cannot reach a note.
public struct NoteVibratoClamp: Sendable, Equatable {
    /// The edit with every supplied value inside its limit. A field that was
    /// `nil` stays `nil`.
    public let edit: NoteVibratoEdit
    /// Every limit that moved a value, AT MOST ONE PER FIELD (the limit that
    /// decided the stored value), in field order: rate, depth, onset, anchor,
    /// vibratoScale, driftScale. Empty when nothing bound. A clamp is never a
    /// refusal: a drag must never snap back (design §10 item 4).
    public let bound: [NoteVibratoLimit]

    /// `segment` with each supplied field written and every other field
    /// untouched. The values are already inside the model's ranges, so this
    /// direct write stores exactly what `init` would have kept.
    public func applied(to segment: NoteSegment) -> NoteSegment {
        var out = segment
        if let value = edit.vibratoRateHz { out.vibratoRateHz = value }
        if let value = edit.vibratoDepthCents { out.vibratoDepthCents = value }
        if let value = edit.vibratoOnsetSeconds { out.vibratoOnsetSeconds = value }
        if let value = edit.vibratoPhaseAnchorSeconds { out.vibratoPhaseAnchorSeconds = value }
        if let value = edit.vibratoScale { out.vibratoScale = value }
        if let value = edit.driftScale { out.driftScale = value }
        return out
    }
}

/// THE limits of a wobble edit, and the one clamp both doors call.
public enum NoteVibratoLimits {

    /// The fastest wobble a listener can be given, per OUTPUT second. It is
    /// the model's own rate ceiling (`NoteSegment.vibratoRateHzRange`, measured,
    /// not picked), read in output time: C5a-1 measured the render's heard rate
    /// as stored ÷ ratio at ratios 1, 2 and 0.5. ONE home: this aliases the
    /// model's range rather than restating 8.
    public static let heardRateCeilingHz: Double = NoteSegment.vibratoRateHzRange.upperBound

    /// The highest STORED rate a clip at `stretchRatio` can take:
    /// `min(model ceiling, heardRateCeilingHz × ratio)`. On a clip that plays
    /// faster than recorded (ratio 0.8) that is 6.4, which is heard at 8. On a
    /// slowed clip (ratio 1.25) the model's 8 binds, which is heard at 6.4:
    /// `NoteSegment` does not know its clip, so its range cannot scale (design
    /// §14 failure mode 8, said in the readout, not fixed here).
    public static func storedRateCeiling(stretchRatio: Double) -> Double {
        min(NoteSegment.vibratoRateHzRange.upperBound,
            heardRateCeilingHz * sanitisedRatio(stretchRatio))
    }

    /// Clamp every supplied value to its limit, and say which limits bound.
    ///
    /// Pure and total over finite input: it never refuses a finite number, it
    /// moves it to the nearest value the model can store and names the limit.
    /// Throws `ProjectError.invalidClipEdit` for a NaN or an infinity, naming
    /// the FIRST such field in field order, because a value that would be
    /// healed into something else is a value the caller did not get.
    ///
    /// - `vibratoRateHz` → `0…storedRateCeiling(stretchRatio:)`. Above the
    ///   ceiling it reports `.heardRateCeiling` when the RATIO decided the
    ///   stored value (ratio below 1) and `.rateRange` when the model's 8
    ///   did; below 0 it reports `.rateRange`. So rate 12 at ratio 0.8 stores
    ///   6.4 and reports ONE limit, `.heardRateCeiling`.
    /// - depth, onset, anchor and both scales → their `NoteSegment` ranges.
    /// - `-0.0` is stored as `+0.0`, so a default-valued edit writes exactly
    ///   the model's defaults and the table stays byte-identical.
    ///
    /// `stretchRatio` is the clip's `Clip.stretchRatio`. Every `Clip` holds a
    /// ratio inside `Clip.stretchRatioRange`, so for every real caller the
    /// sanitising below is the identity; a bare non-finite ratio reads as 1,
    /// and one outside the range as the nearest ratio a `Clip` could hold.
    public static func clamp(_ edit: NoteVibratoEdit,
                             stretchRatio: Double) throws -> NoteVibratoClamp {
        // Refuse before clamping anything, so a refusal names the value the
        // caller sent rather than one this function made up.
        for field in Field.allCases {
            if let value = field.value(in: edit), !value.isFinite {
                throw ProjectError.invalidClipEdit(field.notANumberSentence(value))
            }
        }
        var out = edit
        var bound: [NoteVibratoLimit] = []
        if let rate = edit.vibratoRateHz {
            let ceiling = storedRateCeiling(stretchRatio: stretchRatio)
            let floor = NoteSegment.vibratoRateHzRange.lowerBound
            if rate > ceiling {
                out.vibratoRateHz = ceiling
                bound.append(ceiling < NoteSegment.vibratoRateHzRange.upperBound
                             ? .heardRateCeiling : .rateRange)
            } else if rate < floor {
                out.vibratoRateHz = floor
                bound.append(.rateRange)
            } else {
                out.vibratoRateHz = positiveZero(rate)
            }
        }
        func clampField(_ value: Double?, _ range: ClosedRange<Double>,
                        _ limit: NoteVibratoLimit) -> Double? {
            guard let value else { return nil }
            let kept = value.clamped(to: range)
            if kept != value { bound.append(limit) }
            return positiveZero(kept)
        }
        out.vibratoDepthCents = clampField(edit.vibratoDepthCents,
                                           NoteSegment.vibratoDepthCentsRange, .depthRange)
        out.vibratoOnsetSeconds = clampField(edit.vibratoOnsetSeconds,
                                             NoteSegment.vibratoOnsetSecondsRange, .onsetRange)
        out.vibratoPhaseAnchorSeconds = clampField(edit.vibratoPhaseAnchorSeconds,
                                                   NoteSegment.vibratoPhaseAnchorSecondsRange,
                                                   .anchorRange)
        out.vibratoScale = clampField(edit.vibratoScale, NoteSegment.shapeScaleRange, .scaleRange)
        out.driftScale = clampField(edit.driftScale, NoteSegment.shapeScaleRange, .driftRange)
        return NoteVibratoClamp(edit: out, bound: bound)
    }

    // MARK: - The refusal sentences (C5a-3 / NT-L3 copy these to the wire)

    /// An edit with every field `nil` (design §10 item 1), verbatim.
    public static let nothingToChangeSentence =
        "Nothing to change: give at least one wobble setting."

    /// A sound (`.unpitched`) named on its own (unpitched-notes design §1.7),
    /// verbatim. The Wobble tool and the wire verbs refuse with it.
    public static let noPitchHereSentence =
        "No pitch here, so there is no wobble to change."

    /// A batch that names no note.
    public static let nameAtLeastOneNoteSentence =
        "Name at least one note to change the wobble of. Read the clip's note ids with "
            + "`clip.getPitchEdits` first."

    /// What a batch that skipped sounds says about them (never silent: the
    /// "silent inaudible success" class this tree has paid for).
    public static func skippedSoundsSentence(count: Int) -> String {
        count == 1
            ? "Left 1 sound alone: it is a breath or a consonant with no pitch, so there is no "
                + "wobble to change."
            : "Left \(count) sounds alone: they are breaths or consonants with no pitch, so there "
                + "is no wobble to change."
    }

    // MARK: - Private

    /// The ratio a `Clip` could hold for this input (see `clamp`).
    static func sanitisedRatio(_ stretchRatio: Double) -> Double {
        PitchCorrectionMath.finite(stretchRatio, default: 1).clamped(to: Clip.stretchRatioRange)
    }

    /// `-0.0` → `+0.0`, every other value unchanged. Stored defaults are `+0.0`,
    /// and the render's phase `t − anchor` is only bit-for-bit today's at `+0.0`.
    private static func positiveZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }

    /// The six fields in declaration order, for the NaN census and its words.
    private enum Field: CaseIterable {
        case rate, depth, onset, anchor, scale, drift

        func value(in edit: NoteVibratoEdit) -> Double? {
            switch self {
            case .rate: edit.vibratoRateHz
            case .depth: edit.vibratoDepthCents
            case .onset: edit.vibratoOnsetSeconds
            case .anchor: edit.vibratoPhaseAnchorSeconds
            case .scale: edit.vibratoScale
            case .drift: edit.driftScale
            }
        }

        /// "vibratoRateHz has to be a number from 0 to 8; nan is not one.
        /// Nothing was changed." The key is the wire's, the range the model's.
        func notANumberSentence(_ value: Double) -> String {
            let (key, range): (String, ClosedRange<Double>) = switch self {
            case .rate: ("vibratoRateHz", NoteSegment.vibratoRateHzRange)
            case .depth: ("vibratoDepthCents", NoteSegment.vibratoDepthCentsRange)
            case .onset: ("vibratoOnsetSeconds", NoteSegment.vibratoOnsetSecondsRange)
            case .anchor: ("vibratoPhaseAnchorSeconds", NoteSegment.vibratoPhaseAnchorSecondsRange)
            case .scale: ("vibratoScale", NoteSegment.shapeScaleRange)
            case .drift: ("driftScale", NoteSegment.shapeScaleRange)
            }
            return "\(key) has to be a number from \(Self.text(range.lowerBound)) to "
                + "\(Self.text(range.upperBound)); \(value) is not one. Nothing was changed."
        }

        private static func text(_ value: Double) -> String {
            String(format: "%g", value)
        }
    }
}

// MARK: - The batch transform: ONE home for the draft and the commit

/// ONE note's outcome in a wobble edit: what was asked, what is stored, and
/// which limits bound. Carries no `Clip`, on purpose: a select-all over a
/// 450-note table would otherwise copy the whole table once per note.
public struct NoteVibratoNoteReport: Sendable, Equatable {
    /// The edit exactly as the caller sent it (the wire's `requested`).
    public let requested: NoteVibratoEdit
    /// The note as STORED (or, for a draft, as it would be), after clamping.
    public let segment: NoteSegment
    /// The limits that bound this note's values (`NoteVibratoClamp.bound`).
    public let bound: [NoteVibratoLimit]
    /// The clip ratio the clamp used (`NoteVibratoLimits.sanitisedRatio`).
    public let stretchRatio: Double

    public init(requested: NoteVibratoEdit, segment: NoteSegment,
                bound: [NoteVibratoLimit], stretchRatio: Double) {
        self.requested = requested
        self.segment = segment
        self.bound = bound
        self.stretchRatio = stretchRatio
    }

    public var segmentId: UUID { segment.id }

    /// What a listener hears: stored ÷ the clip's ratio (C5a-1, output time).
    public var heardRateHz: Double { segment.vibratoRateHz / stretchRatio }

    /// A depth with no rate never moves (`sin(0) = 0`), yet the depth breaks
    /// `isIdentity`, so the clip is re-rendered for nothing. Said out loud,
    /// never refused: an agent may send depth and rate in two calls (design
    /// §10 item 10).
    public var silentWobble: Bool { segment.vibratoDepthCents > 0 && segment.vibratoRateHz == 0 }

    /// A rate with no depth: stored and inert, "no new wobble yet" (design
    /// §12.1's note). The Wobble tool parks a rate this way on purpose (§5.4).
    public var parkedRate: Bool { segment.vibratoRateHz > 0 && segment.vibratoDepthCents == 0 }
}

/// What `PitchEditSet.applyingNoteVibratos` returns.
public struct NoteVibratoApplication: Sendable, Equatable {
    /// The whole set with the edits written.
    public let set: PitchEditSet
    /// One report per note written, in the order the caller first named it.
    public let notes: [NoteVibratoNoteReport]
    /// The SOUNDS (`.unpitched`) the caller named, left untouched, in the order
    /// named. Never silent: `skippedSoundsSentence` says so in words.
    public let skippedSoundIds: [UUID]

    /// The sentence a caller shows for `skippedSoundIds`, or `nil` when none.
    public var skippedSoundsSentence: String? {
        skippedSoundIds.isEmpty ? nil
            : NoteVibratoLimits.skippedSoundsSentence(count: skippedSoundIds.count)
    }
}

extension PitchEditSet {

    /// This set with each named note's wobble fields written, exactly as
    /// `ProjectStore.setClipNotesVibrato` stores them. ⭐ **THE ONE HOME of the
    /// rule** (the `applyingNotePitchOffsets` precedent): the store's commit
    /// calls it, and a gesture's draft can call it, so a drag cannot play one
    /// wobble and its release store another.
    ///
    ///  * An empty list is refused (`nameAtLeastOneNoteSentence`).
    ///  * An item with every field `nil` is refused
    ///    (`nothingToChangeSentence`), and so is a NaN or an infinity, naming
    ///    the field (`NoteVibratoLimits.clamp`).
    ///  * Each item is clamped PER NOTE by `NoteVibratoLimits.clamp` at
    ///    `stretchRatio`, BEFORE anything else, so "the same edit twice" is
    ///    judged on what would be written: a repeated id with the same clamped
    ///    edit is folded, one with two different edits is refused in words.
    ///  * An unknown id is refused, naming how many notes the set carries.
    ///  * ⭐ **A SOUND (`.unpitched`) IS SKIPPED AND REPORTED, NOT WRITTEN.** A
    ///    breath or a consonant has no sung f0, so it has no wobble to keep,
    ///    and a generated one would reach the curve through `entersPitchCurve`
    ///    as a pitched warble on noise. When EVERY named note is a sound the
    ///    call is refused (`noPitchHereSentence`): a call that changes nothing
    ///    must not succeed. Why skip rather than refuse the whole batch, when
    ///    `setClipNoteFormant` refuses: natural tuning §3b's macro is "select
    ///    all, then Drift" and "agents send the batch verb with every id", and
    ///    every table the editor seeds carries its sounds (U-A), so a
    ///    refuse-all rule would fail that macro on any take with a breath in
    ///    it. The skip is reported in `skippedSoundIds` and in words.
    ///
    /// All or nothing for every refusal: a refusal returns no set. In a batch of
    /// more than one item, a per-note refusal starts with `Note <id>: `, so the
    /// caller knows which note to fix; a one-item call gets the sentence alone.
    /// `clipId` only words the refusals.
    ///
    /// The set it returns ends in `afterHandEdit(from: self)` (natural tuning
    /// D4-1 (b)): on a vocal that `predatesNaturalTuning` the first wobble or
    /// drift change also updates the whole vocal, draft and commit alike; an
    /// edit that changes no note (every value already stored) updates nothing.
    public func applyingNoteVibratos(_ items: [NoteVibratoItem],
                                     stretchRatio: Double,
                                     clipId: UUID) throws -> NoteVibratoApplication {
        guard !items.isEmpty else {
            throw ProjectError.invalidClipEdit(NoteVibratoLimits.nameAtLeastOneNoteSentence)
        }
        let batch = items.count > 1
        func sentence(_ text: String, for id: UUID) -> String {
            batch ? "Note \(id): \(text)" : text
        }
        var resolved: [(index: Int, requested: NoteVibratoEdit, clamp: NoteVibratoClamp)] = []
        var named: [UUID: NoteVibratoEdit] = [:]
        for item in items {
            guard !item.edit.isEmpty else {
                throw ProjectError.invalidClipEdit(
                    sentence(NoteVibratoLimits.nothingToChangeSentence, for: item.segmentId))
            }
            let clamp: NoteVibratoClamp
            do {
                clamp = try NoteVibratoLimits.clamp(item.edit, stretchRatio: stretchRatio)
            } catch ProjectError.invalidClipEdit(let message) {
                throw ProjectError.invalidClipEdit(sentence(message, for: item.segmentId))
            }
            if let earlier = named[item.segmentId] {
                guard earlier == clamp.edit else {
                    throw ProjectError.invalidClipEdit(
                        "Note \(item.segmentId) is named twice with two different wobble "
                            + "settings. Name each note once.")
                }
                continue
            }
            named[item.segmentId] = clamp.edit
            guard let index = segments.firstIndex(where: { $0.id == item.segmentId }) else {
                throw ProjectError.invalidClipEdit(
                    "No note with id \(item.segmentId) on clip \(clipId). That clip carries "
                        + "\(segments.count) note(s); read them back with "
                        + "`clip.getPitchEdits` before editing one.")
            }
            resolved.append((index, item.edit, clamp))
        }
        let sounds = resolved.filter { segments[$0.index].origin == .unpitched }
        guard sounds.count < resolved.count else {
            throw ProjectError.invalidClipEdit(
                resolved.count == 1
                    ? NoteVibratoLimits.noPitchHereSentence
                    : NoteVibratoLimits.noPitchHereSentence
                        + " Every note you named is a sound (a breath or a consonant). "
                        + "Nothing was changed.")
        }
        let ratio = NoteVibratoLimits.sanitisedRatio(stretchRatio)
        var table = self
        var notes: [NoteVibratoNoteReport] = []
        notes.reserveCapacity(resolved.count - sounds.count)
        for entry in resolved where segments[entry.index].origin != .unpitched {
            let written = entry.clamp.applied(to: segments[entry.index])
            table.segments[entry.index] = written
            notes.append(NoteVibratoNoteReport(requested: entry.requested, segment: written,
                                               bound: entry.clamp.bound, stretchRatio: ratio))
        }
        // Natural tuning D4-1 (b), the user's ruling of 2026-09-26: a wobble or
        // drift change is a HAND edit, so `afterHandEdit(from: self)` is the
        // last step, HERE, in the one home both wobble setters and the pitch
        // editor's draft (`PitchEditorDraftEdit.draftSet`) run: the line a
        // first wobble drag on an old vocal draws is the updated set its
        // release stores, and a no-op updates nothing in either. The per-note
        // reports above are the notes' own and do not move.
        return NoteVibratoApplication(set: table.afterHandEdit(from: self), notes: notes,
                                      skippedSoundIds: sounds.map { segments[$0.index].id })
    }
}
