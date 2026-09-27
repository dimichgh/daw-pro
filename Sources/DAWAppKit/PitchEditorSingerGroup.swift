import CoreGraphics
import Foundation
import DAWCore

// W7-NTU U1 — THE HEADER GROUP "SOUND LIKE THE SINGER", AS VALUES.
//
// Design: `docs/design/2026-09-25-natural-tuning.md` X9 (one group, three rows,
// no "Natural"), §1(f) (Keep voice size), §2f (Consonants), §4.f (Slides),
// R16 (`predatesNaturalTuning` is the ONE legacy test), R26 (the words).
//
// ⭐ **THE VIEW DRAWS `PitchEditorSingerGroup` VERBATIM AND DECIDES NOTHING.**
// `DAWApp` has no test target, so every rule the group follows lives here,
// headless: which face each row wears, which line sits under it, which step is
// lit, and where a pointer on the slider lands. The model turns a gesture into
// ONE commit (`PitchEditorModel`'s "Sound like the singer" section); the app's
// funnel writes it and reads it back (`PitchEditorSingerWrite`).

// MARK: - Slides: the four named steps (§4.f, 4.h, R26)

/// The Slides row's four steps (R26: Snappy / Quick / Smooth / Slow; the L2
/// listening page uses the same names), each ONE slide smoothness in cents per
/// second (`PitchEditSet.transitionSlopeCentsPerSecond`).
///
/// ⛔ **NONE OF THEM IS 0.** 0 is the legacy rule, the wire refuses it
/// (`PitchEditSet.applyingTransitionSmoothness`), and going back to it is
/// Undo's job, never a setting (§4.e). Snappy is the smoothness CEILING
/// (`transitionSlopeRange.upperBound`): every soft join at the engine's 30 ms
/// floor, which is how 4.h's "Snappy (today)" file stands for it.
public enum PitchEditorSlideStep: String, CaseIterable, Sendable, Equatable, Identifiable {
    case snappy
    case quick
    case smooth
    case slow

    public var id: String { rawValue }

    /// The smoothness this step writes. Quick / Smooth / Slow are 4.h's
    /// listened values (6000 / 3000 / 1500 c/s); Smooth is today's provisional
    /// default (`PitchEditSet.defaultTransitionSlope`). The L2 pick moves the
    /// DEFAULT to one of these steps, never a step's value.
    public var centsPerSecond: Double {
        switch self {
        case .snappy: return PitchEditSet.transitionSlopeRange.upperBound
        case .quick: return 6000
        case .smooth: return 3000
        case .slow: return 1500
        }
    }

    /// The step's drawn name (`PitchEditorFormantCopy`).
    public var label: String { PitchEditorFormantCopy.slideStepName(self) }

    /// The step whose smoothness is EXACTLY `centsPerSecond`, or nil. Exact on
    /// purpose: a smoothness between two steps is in force as itself, and
    /// lighting the nearest step would show a setting the render is not using.
    public static func step(atCentsPerSecond centsPerSecond: Double) -> PitchEditorSlideStep? {
        allCases.first { $0.centsPerSecond == centsPerSecond }
    }
}

// MARK: - Keep voice size: the slider's arithmetic (§1(f), 1(h))

/// Where a pointer on the "Keep voice size" slider lands, and what its readout
/// says. The slider spans `PitchEditSet.formantCorrectionRange` (0...1).
public enum PitchEditorVoiceSize {

    /// The detents: the four stops of the L1 listening page (1(h): 0, 50, 75,
    /// 100 %), so the value a person heard on the page is one they can land on
    /// exactly.
    public static let detents: [Double] = [0, 0.5, 0.75, 1]

    /// How close (as a fraction of the track) a pointer must come to a detent
    /// for the value to land ON it. A pick, bounded not measured: 3 % of a
    /// ~190 pt track is ~6 pt, a comfortable catch that never hides a whole
    /// percent step between two detents (the closest two are 25 % apart).
    public static let detentRadius: Double = 0.03

    /// The value's resolution: whole percent (1 / `stepsPerUnit`), the
    /// readout's own. A stored 0.374 would read "37%" while rendering 37.4 %,
    /// a readout that is not the value.
    public static let stepsPerUnit: Double = 100
    public static var resolution: Double { 1 / stepsPerUnit }

    /// The amount a pointer at `fraction` of the track asks for: clamped to
    /// 0...1, pulled onto a detent within `detentRadius` unless `fine` (⌥, the
    /// house fine-drag), and rounded to `resolution`. A non-finite fraction
    /// asks for the nearest end it cannot know, so it reads 0 (the rule is
    /// total, like `PitchEditorViewport.clamped`).
    public static func amount(atFraction fraction: Double, fine: Bool) -> Double {
        let clamped = fraction.isFinite ? fraction.clamped(to: 0...1) : 0
        if !fine, let detent = detents.first(where: { abs($0 - clamped) <= detentRadius }) {
            return detent
        }
        // ⚠️ DIVIDE by the step count, never multiply by 0.01: `k * 0.01` misses
        // the canonical double for 10 of the 101 percents (MEASURED: 57 → 0.5700000000000001),
        // and the store would then hold a value no readout or wire reader typed.
        return ((clamped * stepsPerUnit).rounded() / stepsPerUnit).clamped(to: 0...1)
    }
}

// MARK: - The group's metrics (drawn by the view, measured by the tests)

/// The header group's fixed metrics, in ONE home so the view draws with them
/// and `PitchEditorSingerGroupTests` measures every drawn string against them
/// with the real font (`DAWApp` has no test target).
///
/// ⚠️ **EVERY HEIGHT IS FIXED** — "CHROME THAT COMES AND GOES KEEPS ITS ROW'S
/// HEIGHT" (`docs/DESIGN-LANGUAGE.md`). A row's sub-line swaps between the
/// novice line, the update line, the paused line and the Slides state lines;
/// each is ONE line in a slot of `lineHeight`, so a swap never moves the note
/// surface under the header.
///
/// ⚠️ **THE HEADER GROWS BY THE GROUP, AND THAT IS REPORTED, NOT HIDDEN.** The
/// group is `groupHeight` (108 pt) tall beside a preset column MEASURED at
/// ~71 pt in the 1208 pt floor capture (`c5a4b-6-floor-1208`: the "TUNE THIS
/// VOCAL" row, a chip, two summary lines), so the header is ~37 pt taller
/// while the group is drawn. Three rows of a control over one drawn line is
/// X9's table (a novice line per row) and the dim law's drawn amber line;
/// the looked-at gate is where the cost is judged.
public enum PitchEditorSingerLayout {
    /// The group's width, the same at every window width, and the card width
    /// the dim law measured its 51-character line on.
    public static let groupWidth: CGFloat = 340
    /// The space between the preset chips and the group.
    public static let gapBeforeGroup: CGFloat = 16
    /// The title's row: the "TUNE THIS VOCAL" row's height, so the two
    /// captions share one band and the group's first row starts level with
    /// the chips.
    public static let titleRowHeight: CGFloat = 18
    /// Between the title row and the first row: the preset row's own gap
    /// between its caption row and its chips.
    public static let titleGap: CGFloat = 5
    /// The control line of a row (label, then control).
    public static let controlHeight: CGFloat = 16
    /// Between a control line and its sub-line.
    public static let lineGap: CGFloat = 0
    /// The sub-line under a row's control: ONE line of `lineFontSize` (its
    /// line height, measured by the group's tests, fits).
    public static let lineHeight: CGFloat = 11
    /// Between one row's sub-line and the next row's control line.
    public static let rowSpacing: CGFloat = 2
    /// The label column: wide enough for the longest label at
    /// `labelFontSize` medium (measured by the group's tests).
    public static let labelWidth: CGFloat = 88
    /// Between the label column and its control.
    public static let labelGap: CGFloat = 6
    public static let labelFontSize: CGFloat = 10
    public static let lineFontSize: CGFloat = 9
    /// The voice-size readout's fixed slot ("100%" at 10 pt semibold SF Mono,
    /// measured by the group's tests), so the track never moves as it reads.
    public static let readoutWidth: CGFloat = 34
    /// Between the voice-size track and its readout.
    public static let readoutGap: CGFloat = 6
    /// A Slides step chip's side padding, and the space between chips.
    public static let stepHorizontalPadding: CGFloat = 8
    public static let stepSpacing: CGFloat = 4
    /// A Slides step's font size (semibold).
    public static let stepFontSize: CGFloat = 9

    /// The width the voice-size track gets: what the row leaves after the
    /// label column and the readout.
    public static var voiceTrackWidth: CGFloat {
        groupWidth - labelWidth - labelGap - readoutGap - readoutWidth
    }

    /// The group's full drawn height: the title row, then three rows of a
    /// control line over one sub-line.
    public static var groupHeight: CGFloat {
        titleRowHeight + titleGap + 3 * (controlHeight + lineGap + lineHeight) + 2 * rowSpacing
    }

    // MARK: Beside the chips (they yield width), or below them

    /// Where the group sits in the header.
    public enum Placement: String, Sendable, Equatable {
        /// On the chips' row, after the four preset columns.
        case beside
        /// Under the chips, at the header's leading edge.
        case below
    }

    /// What the header's layout does at one width: where the group sits, and
    /// the width the preset columns are offered.
    public struct Fit: Sendable, Equatable {
        public var placement: Placement
        public var presetsWidth: CGFloat
    }

    /// The preset columns' width when the header has room: the preset row's
    /// own four columns at their 190 pt cap and its 10 pt gaps
    /// (`PitchEditorView.presetRow`), so beside the group they look exactly
    /// as they do without it.
    public static let presetsWidth: CGFloat = 4 * 190 + 3 * 10
    /// The narrowest the preset columns YIELD to before the group goes below
    /// them: 90 pt a column (a chip's name fits with room; its summary wraps
    /// to more lines, and the column stays shorter than the group — both
    /// measured by the group's tests) and the same gaps.
    public static let presetsMinWidth: CGFloat = 4 * 90 + 3 * 10
    /// Between the chips and the group when it sits below them.
    public static let belowGap: CGFloat = 8

    /// The narrowest header content that still holds the group BESIDE the
    /// chips, the chips yielding down to `presetsMinWidth`: 746 pt.
    public static var besideMinWidth: CGFloat { presetsMinWidth + gapBeforeGroup + groupWidth }

    /// ⭐ **THE ONE RULE**, pinned headlessly. The group always keeps its 340
    /// pt; the chips take the rest up to their own 790, and yield below it —
    /// a column that wraps its summary one line deeper costs nothing a
    /// 108 pt group has not already spent, while dropping the group BELOW the
    /// chips would add its whole height again. Only under `besideMinWidth`
    /// does it go below.
    ///
    /// The widths this app has (`WindowFloor`: a 1184 pt pane at the 1208 pt
    /// floor, 12 pt header padding each side): 1160 → beside, the chips at
    /// their full 790; with the Copilot rail open (360 pt + a 10 pt gap) →
    /// 790 → beside, the chips at 434. Total: +∞ (a size query with no bound)
    /// is beside at full width; NaN is below.
    ///
    /// ⚠️ A RULE, NEVER A `ViewThatFits` (`docs/DESIGN-LANGUAGE.md`: never
    /// wrap a stateful view in one — the group holds a drag in flight, and two
    /// branches would be two copies of it). The header's `Layout` calls this.
    public static func fit(headerContentWidth width: CGFloat) -> Fit {
        guard !width.isNaN else { return Fit(placement: .below, presetsWidth: 0) }
        let room = width - gapBeforeGroup - groupWidth
        if room >= presetsMinWidth {
            return Fit(placement: .beside, presetsWidth: min(presetsWidth, room))
        }
        return Fit(placement: .below, presetsWidth: max(0, width))
    }
}

// MARK: - The group's faces

/// What the header group draws, resolved ONCE per body from the note table in
/// force (`PitchEditorModel.noteTable`: the store's, else the editor's seed),
/// the clip's own stretch and transpose, and a live slider drag.
public struct PitchEditorSingerGroup: Sendable, Equatable {

    /// "Keep voice size".
    public struct VoiceRow: Sendable, Equatable {
        /// The amount the slider DRAWS: the live drag's while one is in flight,
        /// else the stored `formantCorrection`. `nil` = no setting (the thumb
        /// and fill are not drawn: nil has no position on the track).
        public var amount: Double?
        /// The SF Mono readout, `PitchEditorFormantCopy.voiceReadout(amount)`.
        public var readout: String
        /// ⭐ R16: the vocal `predatesNaturalTuning`. The slider draws DIM, the
        /// update line replaces the novice line, and EVERY press on the row is
        /// the update (`PitchEditorModel.releaseVoiceSize`), never a voice-size
        /// write — see `PitchEditorModel`'s section banner for why.
        public var needsUpdate: Bool
        /// A drag is in flight: the fill glows (glow earned by state, §1(f)).
        public var isDragging: Bool
        /// The line under the row: the update line, or the novice line.
        public var line: String
        /// The row's tooltip: the update's why, or the setting's.
        public var help: String
    }

    /// "Consonants".
    public struct ConsonantsRow: Sendable, Equatable {
        /// The STORED switch (`keepsConsonantsUntuned`).
        public var isOn: Bool
        /// Why the render does not run the mix although the switch is on
        /// (`PitchEditSet.consonantMixInactiveReason`, the ONE rule), or nil.
        /// Non-nil = the capsule goes DIM and the amber line says why (§2f).
        public var pausedReason: ConsonantMixInactiveReason?
        public var face: String
        public var line: String
        public var help: String
    }

    /// "Slides".
    public struct SlidesRow: Sendable, Equatable {
        /// What the stored smoothness is, in the row's terms.
        public enum Face: String, Sendable, Equatable {
            /// One of the four steps is in force; it is lit.
            case step
            /// 0: a vocal tuned before the update. No step is lit.
            case oldTuning
            /// A smoothness that is none of the steps. No step is lit.
            case custom
        }
        public var face: Face
        /// The lit step, or nil (`oldTuning`, `custom`).
        public var selected: PitchEditorSlideStep?
        public var line: String
        public var help: String
    }

    public var title: String
    public var voice: VoiceRow
    public var consonants: ConsonantsRow
    public var slides: SlidesRow

    /// The group for `table` on a clip at `stretchRatio` / `clipSemitones`,
    /// with a live slider drag at `voiceDraft` (nil = none).
    ///
    /// ⚠️ `stretchRatio` and `clipSemitones` are the CLIP's STORED fields
    /// (`Clip.stretchRatio`, `Clip.pitchShiftSemitones`), exactly what the
    /// render (`StretchCurvePlan.consonantMixInactiveReason`) and the wire
    /// (`clip.getPitchEdits`) hand the same predicate — never the editor
    /// geometry's DERIVED ratio (`outputSpan / sourceWindow`), which can miss
    /// 1 by a rounding step while the predicate compares `!= 1` exactly.
    public static func resolve(table: PitchEditSet, stretchRatio: Double,
                               clipSemitones: Double, voiceDraft: Double?) -> PitchEditorSingerGroup {
        typealias C = PitchEditorFormantCopy
        let needsUpdate = table.predatesNaturalTuning
        // A drag never runs on a vocal that needs the update (the model starts
        // no draft there), so the draft wins only on a live slider.
        let amount = needsUpdate ? nil : (voiceDraft ?? table.formantCorrection)
        let voice = VoiceRow(amount: amount,
                             readout: C.voiceReadout(amount),
                             needsUpdate: needsUpdate,
                             isDragging: voiceDraft != nil && !needsUpdate,
                             line: needsUpdate ? C.voiceUpdateLine : C.voiceLine,
                             help: needsUpdate ? C.voiceUpdateHelp : C.voiceHelp)

        let isOn = table.keepsConsonantsUntuned
        let paused = table.consonantMixInactiveReason(stretchRatio: stretchRatio,
                                                      clipSemitones: clipSemitones)
        let consonants = ConsonantsRow(isOn: isOn,
                                       pausedReason: paused,
                                       face: isOn ? C.switchOn : C.switchOff,
                                       line: paused.map(C.consonantsPaused) ?? C.consonantsLine,
                                       help: C.consonantsHelp)

        let slope = table.transitionSlopeCentsPerSecond
        let slides: SlidesRow
        if slope == 0 {
            slides = SlidesRow(face: .oldTuning, selected: nil,
                               line: C.slidesOldTuningLine, help: C.slidesHelp)
        } else if let step = PitchEditorSlideStep.step(atCentsPerSecond: slope) {
            slides = SlidesRow(face: .step, selected: step, line: C.slidesLine, help: C.slidesHelp)
        } else {
            slides = SlidesRow(face: .custom, selected: nil,
                               line: C.slidesCustomLine, help: C.slidesHelp)
        }
        return PitchEditorSingerGroup(title: C.groupTitle, voice: voice,
                                      consonants: consonants, slides: slides)
    }
}
