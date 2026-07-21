import CoreGraphics
import Foundation

/// Headless zoom math for the piano roll (m21-c): the horizontal
/// pixels-per-beat clamp + step ladder, the percent readout, and the
/// zoom-adaptive grid-density rules the note-grid Canvas reads (so a 1/64 grid
/// never becomes visual soup at a survey zoom). The `ArrangeZoom` sibling —
/// same idiom, one type per surface so each keeps its own default/readout
/// baseline. Pure functions so every rule is unit-testable without SwiftUI.
///
/// The LIVE zoom value itself is persisted app-side as a sticky PREFERENCE in
/// `PanelLayoutStore.pianoRollPPB` (the `arrangePPB` slot's sibling — never
/// project data, never undoable, never in the wire snapshot); this type owns
/// only the math. Everything here is nonisolated value math, callable from
/// `@Sendable` Canvas renderers.
public enum PianoRollZoom {

    // MARK: - Horizontal scale (pixels per beat)

    /// The historical fixed roll scale (docs/DESIGN-LANGUAGE.md "Piano roll":
    /// 32 pt/beat) — the default and the ⌘0 reset target. THE source of truth:
    /// `PianoRollModel.defaultPixelsPerBeat` reads this (the model type is
    /// `@MainActor`, so the constant lives here where `@Sendable` renderers
    /// can also reach it).
    public static let defaultPixelsPerBeat: CGFloat = 32
    /// Clamp bounds — the arrange timeline's proven range (m17-b): 4 pt/beat
    /// surveys a whole long AI-generated part, 200 pt/beat is detail-edit
    /// territory where even a 1/64 grid draws with room to click.
    public static let pixelsPerBeatRange: ClosedRange<CGFloat> = ArrangeZoom.pixelsPerBeatRange
    /// One ⌘+/⌘− (or header ±) step — the arrange ladder's multiplicative
    /// factor, so the two surfaces feel identical per press.
    public static let stepFactor: CGFloat = ArrangeZoom.stepFactor

    /// Tames any requested scale into the legal range.
    public static func clamp(_ pixelsPerBeat: CGFloat) -> CGFloat {
        pixelsPerBeat.clamped(to: pixelsPerBeatRange)
    }

    /// One ladder step in (⌘+ / header "+").
    public static func zoomedIn(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat * stepFactor)
    }

    /// One ladder step out (⌘− / header "−").
    public static func zoomedOut(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat / stepFactor)
    }

    /// The header's SF Mono zoom readout: percent of the roll's default scale
    /// ("100%" at 32 pt/beat, "13%" at the floor, "625%" at the ceiling).
    public static func percentLabel(pixelsPerBeat: CGFloat) -> String {
        let percent = (pixelsPerBeat / defaultPixelsPerBeat) * 100
        return "\(Int(percent.rounded()))%"
    }

    // MARK: - Grid density (sub-beat lines fade with zoom, never fork)

    /// Below this line spacing a sub-beat hairline is pure noise — it draws at
    /// zero opacity (and the painter skips the iteration entirely).
    public static let subBeatHiddenSpacing: CGFloat = 4
    /// At and above this spacing a sub-beat hairline draws at full strength —
    /// the arrange grid's 8 pt "useful line" threshold (m17-b). Between the two
    /// the line FADES linearly, so zooming never pops the grid in or out.
    public static let subBeatFullSpacing: CGFloat = 8

    /// Opacity multiplier for sub-beat grid lines at `step` beats apart drawn
    /// at `pixelsPerBeat`: 0 when the lines would sit closer than
    /// `subBeatHiddenSpacing`, 1 from `subBeatFullSpacing` up, a linear ramp
    /// between. Beat and bar lines never fade (they are the survey grid).
    public static func subBeatLineAlpha(step: Double, pixelsPerBeat: CGFloat) -> Double {
        guard step > 0 else { return 0 }
        let spacing = CGFloat(step) * pixelsPerBeat
        guard spacing > subBeatHiddenSpacing else { return 0 }
        guard spacing < subBeatFullSpacing else { return 1 }
        return Double((spacing - subBeatHiddenSpacing)
                      / (subBeatFullSpacing - subBeatHiddenSpacing))
    }

    /// How many sub-divisions of one beat a snap step implies (1/64 note =
    /// 0.0625 beat → 16; 1/8T = 1/3 beat → 3). 1 for beat-or-coarser steps.
    /// The painter iterates whole beats and then exact rational fractions
    /// (`beat + d/divisions`), so triplet lines never accumulate float drift.
    public static func divisionsPerBeat(step: Double) -> Int {
        guard step > 0, step < 1 else { return 1 }
        return max(1, Int((1.0 / step).rounded()))
    }
}
