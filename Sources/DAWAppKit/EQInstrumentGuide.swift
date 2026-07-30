import Foundation
import DAWCore

// m23-o2 — the EQ card's INSTRUMENT FREQUENCY GUIDE: m23-o1's cited reference
// table, drawn against the live EQ curve.
//
// EVERYTHING that decides or measures lives in THIS FILE, in DAWAppKit, and
// `Sources/DAWApp/Mixer/EQCurveEditor.swift` only draws what it is handed. That
// is structural, not taste: `DAWApp` is `Package.swift`'s sole
// `.executableTarget` and has NO test target, so an `if` written over there is
// permanently unpinned (the m23-r4 close-out filed exactly that gap for the
// three `owner: .ui` call sites). DAWAppKit has `DAWAppKitTests`.
//
// ⚠️ NO SECOND RESOLVER. `resolve(target:tracks:)` calls
// `InstrumentFamilyResolver.resolve` — DAWCore's ONE home — and adds no
// heuristic of its own. In particular there is NO track-name matching here
// either: the resolver's signature refuses a name (see its file header) and
// this file must not reintroduce sideways what that signature forbids.
//
// ⚠️ NO TIMELINEVIEW, AND THAT IS DELIBERATE. The guidance is static — a
// reference row does not change 60 times a second — so the layer that draws it
// is a plain `Canvas` that redraws on size/params change only. The m22-e poll
// discipline says every LIVE layer ticks in its own UNPAUSED `.periodic`
// timeline; it does not say every layer gets a timeline. Adding one "for
// symmetry" would burn a frame budget on a picture that never changes.

// MARK: - Layout metrics (ONE home; the view CONSUMES these, never restates them)

/// The EQ curve card's fixed metrics.
///
/// These live here rather than as literals in `EffectEditorOverlay` because the
/// LEGIBILITY leg of m23-o2's gate is a claim about how many characters fit on
/// the guidance row at the width the card actually gets — and a claim that
/// reads a constant the view does not use is a claim about nothing. The view
/// reads `cardWidth` / `cardPadding`; the tests read `contentWidth` and
/// `rowCharacterBudget` derived from the same two numbers.
public enum EQGuidanceLayout {
    /// The eq CURVE card's width (m22-b §6, formerly
    /// `EffectEditorOverlay.curveCardWidth`).
    public static let cardWidth: Double = 560
    /// The card's uniform inner padding.
    public static let cardPadding: Double = 16

    /// The card's content column — the plot's width AND the guidance row's.
    public static var contentWidth: Double { cardWidth - 2 * cardPadding }

    /// SF Mono's advance is exactly 0.6 em at every point size (a monospaced
    /// face has one advance by definition), so a character budget for a mono
    /// line is arithmetic rather than a guess.
    ///
    /// The HEADLINE line is SF Pro, which is proportional — but for ordinary
    /// mixed-case prose SF Pro's average advance is BELOW 0.6 em, so using the
    /// mono budget for it is a deliberate OVER-estimate of the width and
    /// therefore a conservative bound. It can be wrong only in the safe
    /// direction.
    public static let monoAdvanceEm: Double = 0.6

    /// The guidance row's font size (both lines).
    public static let rowFontSize: Double = 9
    /// The in-plot mark tag's font size — the grid layer's 8 pt, so the guide's
    /// numbers sit at the same weight as the axis numbers they annotate.
    public static let tagFontSize: Double = 8

    /// How many characters of a `rowFontSize` mono line fit in `contentWidth`.
    /// The legibility pin's whole basis.
    public static var rowCharacterBudget: Int {
        Int((contentWidth / (rowFontSize * monoAdvanceEm)).rounded(.down))
    }

    /// The guidance row's RESERVED height — two lines plus their spacing.
    ///
    /// Fixed on purpose (the footer's own law two views up: *"the row keeps its
    /// height so the card never reflows"*). A row that wrapped to three lines
    /// for one family and one for another would resize the card when the user
    /// retargets it, and the character budget above is what keeps every string
    /// inside two lines.
    public static let rowHeight: Double = 26

    /// The plot's two label lanes, in plot-space y. Both sit in the TOP strip,
    /// which is the only region of the plot that is reliably free: the bottom
    /// ~14 pt carries `EQGridLayer`'s frequency numbers (drawn at
    /// `y: height - 3`), and the vertical middle ±20 pt is where the six band
    /// handles live — HP and LP have `gainDb == 0` so they sit exactly at
    /// `height / 2`, with their tags 13 pt above that.
    public static let fundamentalLaneY: Double = 5
    public static let cornerLaneY: Double = 16
    /// Inset a lane label keeps from either plot edge.
    public static let labelEdgeInset: Double = 3

    /// The narrowest a fundamental SPAN is ever drawn. A real range whose two
    /// endpoints land within a point of each other would otherwise render as
    /// nothing at all; this floors the drawn width so the span stays visible.
    ///
    /// It is NOT a way to manufacture a range: it applies only to `.fundamental`
    /// marks, which exist only for `.pitched` rows. An `.inharmonic` row emits
    /// NO fundamental mark, so there is nothing here for the floor to widen —
    /// which is the difference between "no bracket" and "a zero-width bracket",
    /// and those two look identical on screen while meaning opposite things.
    public static let minimumSpanPoints: Double = 3
}

// MARK: - The state

/// What the open EQ card knows about its track's instrument — the whole input
/// to the guidance layer and the guidance row.
///
/// FOUR states, and the distinction between the first two is the one that
/// matters most:
///
/// - `.notApplicable` — a master or bus insert. There is no instrument identity
///   and there never can be, so the card draws NOTHING: no marks, no row. An
///   "empty state" here would be chrome explaining a question nobody asked,
///   with a remedy the user cannot act on.
/// - `.unknown` — a track that COULD have an instrument identity and does not
///   yet (an audio track, an instrument track with nothing chosen, an opaque
///   plug-in). This is the honest empty state the m23-o2 gate demands, and it
///   carries a remedy the user can actually perform.
/// - `.drumKit` — a GM percussion track, asked without a piece. It must NOT
///   pick a representative piece: a kick and a hi-hat differ by three octaves.
/// - `.family` — resolved, with the rung that resolved it.
public enum EQInstrumentGuide: Equatable, Sendable {
    case notApplicable
    case unknown(InstrumentFamilyResolution.Reason)
    case drumKit
    case family(InstrumentFamily, source: InstrumentFamilyResolution.Source)

    /// The state's wire/probe name — `debug.effectEditor` reports this.
    public var stateName: String {
        switch self {
        case .notApplicable: return "notApplicable"
        case .unknown: return "unknown"
        case .drumKit: return "drumKit"
        case .family: return "family"
        }
    }

    /// The resolved family, or nil.
    public var family: InstrumentFamily? {
        if case .family(let family, _) = self { return family }
        return nil
    }

    /// The row this state draws from, or nil. The ONLY path from a state to the
    /// table — no other member reaches for `InstrumentFrequencyTable`.
    public var reference: InstrumentFrequencyReference? {
        family.map(InstrumentFrequencyTable.reference(for:))
    }

    /// Whether the guidance ROW renders at all. False only for
    /// `.notApplicable` — see the case doc above.
    public var showsRow: Bool { self != .notApplicable }

    // MARK: - Resolution (ONE call into DAWCore's ONE resolver)

    /// Resolve the open card's target against the project's tracks.
    ///
    /// Takes plain values — a target and the track list — so the whole decision
    /// is reachable from a test with no store, no engine and no app. The app
    /// side is then one expression with no branches of its own.
    ///
    /// `percussionNote` is `nil` BY CONSTRUCTION: an EQ card is opened on a
    /// TRACK, and a GM percussion track plays every piece of the kit at once.
    /// There is no single note to pass and inventing one would pick a family.
    /// That is what makes `.drumKit` a real state here rather than a fallback.
    ///
    /// ⚠️ THE COST OF THAT NIL, MEASURED AND PINNED — read before trusting any
    /// per-family behaviour in this file. Because the note is always nil and
    /// `allowedGMCategories` is EMPTY for the six percussion rows and both vocal
    /// rows, only FIVE of the table's thirteen families can ever reach the
    /// pixels: piano, acousticGuitar, electricGuitar, uprightBass, electricBass.
    /// All five are `.pitched`, so the `.inharmonic` refusal in `marks` and the
    /// `(tuning-dependent)` qualifier in `detail` are correct, are tested, and
    /// CANNOT FIRE IN THE SHIPPING CARD — every inharmonic row is a cymbal and
    /// every tuning-dependent row is a drum. That is a recorded cost of refusing
    /// a track-name heuristic, not a defect to patch here; closing it needs
    /// either that heuristic or new per-track user-set state.
    /// `onlyFiveFamiliesAreReachableThroughTheCard` pins the set both ways.
    public static func resolve(target: EffectEditorTarget?,
                               tracks: [Track]) -> EQInstrumentGuide {
        // No card, or a MASTER insert (`trackID == nil`): the master bus carries
        // whatever is routed into it.
        guard let target, let trackID = target.trackID else { return .notApplicable }
        // A target whose track has vanished (a wire `track.remove` mid-open):
        // the card itself is about to drop, so guidance about nothing is worse
        // than none.
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            return .notApplicable
        }
        switch InstrumentFamilyResolver.resolve(trackKind: track.kind,
                                                instrument: track.instrument,
                                                percussionNote: nil) {
        case .resolved(let family, let source):
            return .family(family, source: source)
        case .drumKit:
            return .drumKit
        case .unresolved(let reason):
            // A BUS is `.notApplicable`, not an empty state — same reasoning as
            // the master above. Every OTHER reason is a track that could be
            // identified and is not yet, which is the honest empty state.
            return reason == .trackIsNotAnInstrumentOrAudioTrack
                ? .notApplicable : .unknown(reason)
        }
    }

    // MARK: - Marks (what the plot draws)

    /// One thing drawn on the plot: a fundamental SPAN or a filter CORNER.
    public struct Mark: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case fundamental, highPass, lowPass
        }

        public let kind: Kind
        /// For a corner, `lowHz == highHz`.
        public let lowHz: Double
        public let highHz: Double
        /// True when the SOURCE behind this fact is soft
        /// (`DAWCore.SourceStrength.isSoft`). The view draws every guidance
        /// mark softly; this drives the extra qualifier in the row's prose,
        /// which is where a soft claim can actually SAY it is soft.
        public let isSoft: Bool
        /// The compact SF Mono tag drawn in the plot's top strip.
        ///
        /// ⚠️ THE TAG SHARES NO VOCABULARY WITH THE BAND HANDLES, ON PURPOSE.
        /// `EQCurveEditorModel.tag(for:)` labels the six real handles HP·LS·1·2·
        /// HS·LP, in SF Mono, in the SAME plot. A guidance tag reading "HP 35 Hz"
        /// would be the same two letters, same face, same size, a few inches away
        /// from the user's ACTUAL high-pass handle — the dishonest-readout class,
        /// where reference ink is mistaken for a live readout of this track's
        /// settings. Neutral dashed ink alone does not carry that distinction:
        /// the STRING has to. So the tags are phrases a setting readout would
        /// never be — "CUT BELOW 35 Hz", "CUT ABOVE 6 kHz", "TYPICAL 49–92 Hz" —
        /// which are also plain language rather than jargon. Pinned in
        /// `guidanceTagsShareNoVocabularyWithTheBandHandles`, which reads
        /// `EQCurveEditorModel.tag(for:)` rather than a copied list.
        public let tag: String

        /// A span mark occupies an x RANGE; a corner is a single line.
        public var isSpan: Bool { kind == .fundamental }

        /// INTERNAL on purpose: the only production path to a `Mark` is `marks`,
        /// which derives `isSoft` from the table. A public init would let a call
        /// site mint a mark whose softness disagrees with its own row — the
        /// construction barrier this project uses for `ArrangeDropSnap`. Tests
        /// reach it through `@testable`, which is where synthetic marks belong.
        init(kind: Kind, lowHz: Double, highHz: Double,
             isSoft: Bool, tag: String) {
            self.kind = kind
            self.lowHz = lowHz
            self.highHz = highHz
            self.isSoft = isSoft
            self.tag = tag
        }
    }

    /// The marks this state draws — EMPTY for every state but `.family`.
    ///
    /// The three refusals here are the hazard list, in code:
    /// - an `.inharmonic` fundamental yields NO mark (never a zero-width one);
    /// - a `.noneRecommended` filter yields NO mark (never a corner at 0 or at
    ///   the axis edge);
    /// - a corner outside the plot's 20 Hz–20 kHz axis yields NO mark, because
    ///   `EQCurveGeometry.x` CLAMPS its input — so an off-axis corner would
    ///   otherwise draw a confident line exactly on the plot rim, at a frequency
    ///   it is not at.
    public var marks: [Mark] {
        guard let row = reference else { return [] }
        var marks: [Mark] = []
        if case .pitched = row.fundamental,
           let low = row.fundamental.lowestHz, let high = row.fundamental.highestHz,
           spanOverlapsAxis(lowHz: low, highHz: high) {
            marks.append(Mark(kind: .fundamental, lowHz: low, highHz: high,
                              isSoft: row.fundamentalStrength.isSoft,
                              tag: "TYPICAL " + Self.rangeText(lowHz: low,
                                                               highHz: high)))
        }
        if let hz = row.recommendedHighPass.cornerHz, Self.isOnAxis(hz) {
            marks.append(Mark(kind: .highPass, lowHz: hz, highHz: hz,
                              isSoft: row.highPassStrength.isSoft,
                              tag: "CUT BELOW " + Self.hzText(hz)))
        }
        if let hz = row.recommendedLowPass.cornerHz, Self.isOnAxis(hz) {
            marks.append(Mark(kind: .lowPass, lowHz: hz, highHz: hz,
                              // The table carries no per-LOW-pass strength
                              // field: the m23-o1 review flagged no low-pass
                              // corner as weak, and inventing a third strength
                              // field for a fact nobody questioned would be
                              // scaffolding. Soft-by-default ink still applies.
                              isSoft: false,
                              tag: "CUT ABOVE " + Self.hzText(hz)))
        }
        return marks
    }

    /// STRICTLY inside the plot axis. Strict on purpose: a corner sitting
    /// exactly on 20 Hz or 20 kHz draws at x = 0 or x = width — on the plot's
    /// own border, where it is indistinguishable from the frame.
    public static func isOnAxis(_ hz: Double) -> Bool {
        hz > EQCurveGeometry.frequencyRange.lowerBound
            && hz < EQCurveGeometry.frequencyRange.upperBound
    }

    /// A span is drawn when it OVERLAPS the axis — unlike a corner, a range
    /// genuinely may run past the plot edge and clamping it there is honest.
    private func spanOverlapsAxis(lowHz: Double, highHz: Double) -> Bool {
        highHz > EQCurveGeometry.frequencyRange.lowerBound
            && lowHz < EQCurveGeometry.frequencyRange.upperBound
    }

    // MARK: - Geometry (through the plot's ONE axis — never a second mapping)

    /// A span mark's x extent, floored at `minimumSpanPoints` so a very narrow
    /// real range still renders. nil for a corner.
    public static func spanX(_ mark: Mark, width: Double) -> (lo: Double, hi: Double)? {
        guard mark.isSpan else { return nil }
        let lo = EQCurveGeometry.x(forFrequency: mark.lowHz, in: width)
        let hi = EQCurveGeometry.x(forFrequency: mark.highHz, in: width)
        guard hi - lo < EQGuidanceLayout.minimumSpanPoints else { return (lo, hi) }
        let center = (lo + hi) / 2
        let half = EQGuidanceLayout.minimumSpanPoints / 2
        return (center - half, center + half)
    }

    /// A corner mark's x. nil for a span.
    public static func cornerX(_ mark: Mark, width: Double) -> Double? {
        guard !mark.isSpan else { return nil }
        return EQCurveGeometry.x(forFrequency: mark.lowHz, in: width)
    }

    /// One tag's placement in the plot's top strip.
    public struct Placement: Equatable, Sendable {
        public enum Anchor: String, Sendable { case leading, center, trailing }
        public let kind: Mark.Kind
        public let text: String
        public let x: Double
        public let y: Double
        public let anchor: Anchor
        public let isSoft: Bool
    }

    /// Where each mark's tag is drawn.
    ///
    /// TWO LANES, which is what makes collisions impossible without a layout
    /// solver: the fundamental's tag owns lane 1 and the corner tags own lane 2.
    /// Within lane 2, the HIGH-pass tag anchors LEADING at its line and the
    /// LOW-pass tag anchors TRAILING at its own, so the two grow away from each
    /// other rather than toward each other. Every box is then clamped inside
    /// the plot so a tag near either rim stays whole (the grid layer's own
    /// edge-label rule).
    public static func placements(_ marks: [Mark], width: Double) -> [Placement] {
        marks.compactMap { mark in
            switch mark.kind {
            case .fundamental:
                guard let span = spanX(mark, width: width) else { return nil }
                return placement(mark, x: (span.lo + span.hi) / 2,
                                 y: EQGuidanceLayout.fundamentalLaneY,
                                 anchor: .center, width: width)
            case .highPass:
                guard let x = cornerX(mark, width: width) else { return nil }
                return placement(mark, x: x + EQGuidanceLayout.labelEdgeInset,
                                 y: EQGuidanceLayout.cornerLaneY,
                                 anchor: .leading, width: width)
            case .lowPass:
                guard let x = cornerX(mark, width: width) else { return nil }
                return placement(mark, x: x - EQGuidanceLayout.labelEdgeInset,
                                 y: EQGuidanceLayout.cornerLaneY,
                                 anchor: .trailing, width: width)
            }
        }
    }

    /// Clamps a tag box inside the plot and returns its placement.
    private static func placement(_ mark: Mark, x: Double, y: Double,
                                  anchor: Placement.Anchor,
                                  width: Double) -> Placement {
        let textWidth = Double(mark.tag.count)
            * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm
        let inset = EQGuidanceLayout.labelEdgeInset
        var leading: Double
        switch anchor {
        case .leading: leading = x
        case .center: leading = x - textWidth / 2
        case .trailing: leading = x - textWidth
        }
        leading = min(max(leading, inset), max(inset, width - inset - textWidth))
        let anchored: Double
        switch anchor {
        case .leading: anchored = leading
        case .center: anchored = leading + textWidth / 2
        case .trailing: anchored = leading + textWidth
        }
        return Placement(kind: mark.kind, text: mark.tag, x: anchored, y: y,
                         anchor: anchor, isSoft: mark.isSoft)
    }

    // MARK: - The guidance row (the prose, drawn — never a tooltip)

    /// Line 1: what this row IS, in words.
    ///
    /// ⚠️ THE SOFTNESS LIVES IN THIS SENTENCE AND IN `detail`'s qualifiers, not
    /// in the ink. A dashed stroke at 8 pt cannot say "a drum's pitch is a
    /// tuning choice"; a sentence can. See the file's `detail` note.
    public var headline: String {
        switch self {
        case .notApplicable:
            return ""
        case .drumKit:
            return "Drum kit — each piece has its own range."
        case .unknown(let reason):
            return Self.userExplanation(reason)
        case .family:
            guard let row = reference else { return "" }
            return "\(row.displayName) — reference guidance, not a measurement of this track."
        }
    }

    /// Line 2: the numbers (SF Mono), or the REMEDY for an empty state.
    public var detail: String {
        switch self {
        case .notApplicable:
            return ""
        case .drumKit:
            return "The guide follows one instrument at a time — ask the Copilot about "
                + "the kick, snare or hats."
        case .unknown(let reason):
            return Self.userRemedy(reason)
        case .family:
            guard let row = reference else { return "" }
            return [Self.fundamentalPhrase(row),
                    Self.filterPhrase("High-pass", row.recommendedHighPass,
                                      isSoft: row.highPassStrength.isSoft),
                    Self.filterPhrase("Low-pass", row.recommendedLowPass, isSoft: false)]
                .joined(separator: " · ")
        }
    }

    /// The `Fundamental …` segment, including the `.inharmonic` statement —
    /// which is a real answer ("this instrument has no pitch"), never a blank.
    static func fundamentalPhrase(_ row: InstrumentFrequencyReference) -> String {
        switch row.fundamental {
        case .inharmonic:
            return "Fundamental none (no fixed pitch)"
        case .pitched:
            guard let low = row.fundamental.lowestHz,
                  let high = row.fundamental.highestHz else {
                return "Fundamental none (no fixed pitch)"
            }
            let soft = row.fundamentalStrength.isSoft ? " (tuning-dependent)" : ""
            return "Fundamental \(rangeText(lowHz: low, highHz: high))\(soft)"
        }
    }

    /// A `High-pass …` / `Low-pass …` segment. A `.noneRecommended` filter says
    /// WHY it recommends nothing — "none" alone would read as missing data.
    static func filterPhrase(_ name: String, _ recommendation: FilterRecommendation,
                             isSoft: Bool) -> String {
        switch recommendation {
        case .corner(let hz, _, _, _):
            return "\(name) \(hzText(hz))" + (isSoft ? " (soft source)" : "")
        case .noneRecommended(let reason, _):
            switch reason {
            case .notRecommendedForThisSource:
                return "\(name): not needed"
            case .belowHouseEQRange:
                return "\(name): below this EQ's range"
            }
        }
    }

    // MARK: - The empty state's words (USER-facing; NOT DAWCore's agent prose)

    /// ⚠️ THIS IS NOT A FORK OF `InstrumentFamilyResolution.Reason.explanation`.
    ///
    /// DAWCore's `explanation` / `remedy` pair is written for the COPILOT and
    /// names wire verbs — "measure it instead with fx.spectrum", "Call
    /// frequency.reference again with `family` set to one of the ids in
    /// `families` below". A person reading an EQ card cannot call
    /// `frequency.reference`, and a remedy nobody can perform is worse than
    /// silence. So the two pairs are AUDIENCE TRANSLATIONS of one enum, not two
    /// opinions about it.
    ///
    /// What keeps them from drifting is the shape, not the wording: both
    /// switches are EXHAUSTIVE with no `default:`, so a tenth `Reason` stops the
    /// build in both modules at once. `EQInstrumentGuideTests` additionally pins
    /// that every reason yields non-empty text and that no UI string leaks a
    /// wire verb.
    public static func userExplanation(_ reason: InstrumentFamilyResolution.Reason) -> String {
        switch reason {
        case .audioTrackHasNoInstrument:
            return "Recorded audio track — the app cannot know what was recorded."
        case .instrumentTrackHasNoInstrument:
            return "No instrument is chosen for this track yet."
        case .instrumentKindCarriesNoFamily:
            return "This is a synth or sampler patch, so it has no fixed range."
        case .hostedAudioUnitIsOpaque:
            return "A plug-in's name says nothing reliable about how it sounds."
        case .soundBankSelectionMissing:
            return "This track uses a sound bank, but no sound is chosen yet."
        case .soundBankIsNotGeneralMIDI:
            return "Imported sound banks carry no General MIDI instrument meaning."
        case .gmProgramNotCoveredInV1:
            return "The guide does not cover this instrument yet — a gap, not a verdict."
        case .percussionNoteNotCoveredInV1:
            return "The guide does not cover this drum piece yet — a gap, not a verdict."
        case .trackIsNotAnInstrumentOrAudioTrack:
            // `resolve` maps this to `.notApplicable`, so the row never draws
            // it — pinned by `EQInstrumentGuideTests`. Written anyway: an
            // exhaustive switch that answers a case it believes unreachable is
            // cheaper than one that traps.
            return "A bus carries whatever is routed into it, so it has no instrument."
        }
    }

    /// What the user can DO — every one of these is an action available in this
    /// app, not a wire call.
    public static func userRemedy(_ reason: InstrumentFamilyResolution.Reason) -> String {
        switch reason {
        case .audioTrackHasNoInstrument, .hostedAudioUnitIsOpaque,
             .soundBankIsNotGeneralMIDI:
            return "Ask the Copilot — \"this is a bass, what should I cut?\" — for a cited range."
        case .instrumentTrackHasNoInstrument, .soundBankSelectionMissing:
            return "Choose this track's instrument, then reopen this EQ."
        case .instrumentKindCarriesNoFamily:
            return "The green spectrum above shows what this patch really produces."
        case .gmProgramNotCoveredInV1, .percussionNoteNotCoveredInV1:
            return "Ask the Copilot about the instrument you are hearing for a cited range."
        case .trackIsNotAnInstrumentOrAudioTrack:
            return "Open the EQ on a track feeding this bus to see that instrument's guide."
        }
    }

    // MARK: - Number formatting (beginner-readable; the grid layer's dialect)

    /// A frequency as a person reads it: "35 Hz", "1.05 kHz", "4.19 kHz".
    /// Never scientific notation (the §5.1 beginner rule the grid already
    /// follows), and never more precision than the source has.
    public static func hzText(_ hz: Double) -> String {
        hz < 1000 ? "\(Int(hz.rounded())) Hz" : kHzText(hz)
    }

    private static func kHzText(_ hz: Double) -> String {
        let k = hz / 1000
        let text = k < 10
            ? String(format: "%.2f", k) : String(format: "%.1f", k)
        // Trim a trailing zero pair so 6000 reads "6 kHz", not "6.00 kHz".
        var trimmed = text
        while trimmed.contains("."), trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed + " kHz"
    }

    /// A range, with the unit printed ONCE when both ends share it: "49–92 Hz",
    /// "28 Hz – 4.19 kHz". Uses an en dash, the house range glyph.
    public static func rangeText(lowHz: Double, highHz: Double) -> String {
        if lowHz < 1000, highHz < 1000 {
            return "\(Int(lowHz.rounded()))\u{2013}\(Int(highHz.rounded())) Hz"
        }
        if lowHz >= 1000, highHz >= 1000 {
            let lo = kHzText(lowHz).replacingOccurrences(of: " kHz", with: "")
            return "\(lo)\u{2013}\(kHzText(highHz))"
        }
        return "\(hzText(lowHz)) \u{2013} \(hzText(highHz))"
    }

    // MARK: - The probe payload (debug.effectEditor)

    /// The guidance's full state as flat key/value pairs, for
    /// `debug.effectEditor`.
    ///
    /// Built from `self` — the SAME value the card is handed — so the probe
    /// cannot report a state the view is not in (the m23-r2a hand-assignment
    /// hole, and the m23-r3 `curveHelp` precedent it produced).
    ///
    /// Both Hz AND x are reported, deliberately: "the bracket is at the right
    /// frequency" and "the bracket is in the right place on this axis" are
    /// different claims, and a coordinate-space bug satisfies the first while
    /// failing the second. `width` is the plot width the positions are computed
    /// at, reported alongside so the reader never has to assume it.
    ///
    /// ABSENCE IS REPORTED AS ABSENCE. A missing fundamental comes back with
    /// `fundamentalHz` omitted and `fundamentalNone` naming WHY — never a
    /// zero-width span, which on screen is indistinguishable from a real
    /// bracket that happens to be narrow.
    /// Where the `width` the probe computes positions at came from.
    ///
    /// ⚠️ THIS EXISTS BECAUSE THE PROBE IS THE ONLY INSTRUMENT THAT CAN SEE THE
    /// `DAWApp` SIDE. `DAWApp` is `Package.swift`'s sole `.executableTarget` and
    /// has no test target, so no Swift test can reach the drawing call site. If
    /// the probe reported positions derived from `EQGuidanceLayout.contentWidth`
    /// while the Canvas drew from its measured `size.width`, a staging gate
    /// asserting "x is consistent with the width the probe names" would be
    /// SELF-CONSISTENT AND BLIND — it would certify a card that had drifted to a
    /// different frame. Naming the provenance makes the fallback assertable: a
    /// gate can require `.measured` and redden the moment the view stops
    /// reporting its real geometry.
    public enum WidthSource: String, Sendable, CaseIterable {
        /// The guidance plot's own `GeometryReader` width — what was DRAWN.
        case measured
        /// The card has not laid out yet, so positions fall back to the layout
        /// constant. Honest, and visibly distinguishable from `measured`.
        case layoutConstant
    }

    public func probeFields(width: Double,
                            widthSource: WidthSource) -> [(String, ProbeValue)] {
        var fields: [(String, ProbeValue)] = [
            ("state", .string(stateName)),
            ("width", .number(width)),
            ("widthSource", .string(widthSource.rawValue)),
            // ⚠️ REPORTED EXPLICITLY BECAUSE AN EMPTY STRING IS AMBIGUOUS.
            // `.notApplicable` returns "" for both `headline` and `detail`, so a
            // gate reading only those cannot tell "the row is deliberately not
            // drawn" from "the row is drawn and its copy went missing" — the
            // same absence-vs-zero confusion the `.inharmonic` and
            // `.noneRecommended` cases are reported by NAME to avoid. This is
            // the view's OWN decision (`EQCurveEditor` renders the row `if
            // guide.showsRow`), not a second computation that happens to agree.
            // Found by the live probe smoke run, which could not assert it.
            ("showsRow", .bool(showsRow)),
            ("headline", .string(headline)),
            ("detail", .string(detail)),
        ]
        switch self {
        case .family(let family, let source):
            fields.append(("family", .string(family.rawValue)))
            fields.append(("resolvedFrom", .string(source.rawValue)))
        case .unknown(let reason):
            fields.append(("reason", .string(reason.rawValue)))
        case .drumKit, .notApplicable:
            break
        }
        if let row = reference {
            fields.append(("fundamentalSource", .string(row.fundamentalStrength.rawValue)))
            fields.append(("highPassSource", .string(row.highPassStrength.rawValue)))
            if case .inharmonic(let reason) = row.fundamental {
                fields.append(("fundamentalNone", .string(reason)))
            }
            if case .noneRecommended(let reason, _) = row.recommendedHighPass {
                fields.append(("highPassNone", .string(reason.rawValue)))
            }
            if case .noneRecommended(let reason, _) = row.recommendedLowPass {
                fields.append(("lowPassNone", .string(reason.rawValue)))
            }
        }
        let all = marks
        for mark in all {
            let key = mark.kind.rawValue
            if let span = Self.spanX(mark, width: width) {
                fields.append(("\(key)Hz", .numbers([mark.lowHz, mark.highHz])))
                fields.append(("\(key)X", .numbers([span.lo, span.hi])))
            } else if let x = Self.cornerX(mark, width: width) {
                fields.append(("\(key)Hz", .number(mark.lowHz)))
                fields.append(("\(key)X", .number(x)))
            }
            fields.append(("\(key)Soft", .bool(mark.isSoft)))
        }
        fields.append(("markCount", .number(Double(all.count))))
        fields.append(("tags", .strings(Self.placements(all, width: width).map(\.text))))
        return fields
    }

    /// A tiny transport type so this file stays free of `DAWControl`'s
    /// `JSONValue` — DAWAppKit must not depend on the control module. The app
    /// maps these one-for-one when it builds the probe response.
    public enum ProbeValue: Equatable, Sendable {
        case string(String)
        case strings([String])
        case number(Double)
        case numbers([Double])
        case bool(Bool)
    }
}
