import SwiftUI
import DAWAppKit
import DAWCore

/// The pitch ruler down the left edge of the pitch editor (m23-ap p2-b, design
/// §5.6.6): one row per semitone, **every key named**, aligned row-for-row with
/// the surface beside it because both read the SAME `PitchEditorGeometry`.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ⛔ THIS IS A **DARK** SURFACE, AND THAT IS THE WHOLE REASON IT EXISTS
/// ═══════════════════════════════════════════════════════════════════════════
///
/// `KeyboardSidebar` — the piano roll's gutter — is NOT reusable here, on two
/// disqualifiers either of which alone would settle it (design §3.5):
///
///  1. **It takes `model: PianoRollModel` and maps INTEGER pitch to y.** A pitch
///     contour is continuous; `PitchEditorGeometry.y(forMidi:)` takes a `Double`,
///     and that axis divergence is the single largest reason `PianoRollView`
///     could not simply grow a mode (§3.3.1).
///  2. **It is an IVORY surface** — one of the app's two light ones — with a
///     whole dual-ink token set (`DAWTheme.…OnWhite`) that exists because
///     *"Reaching for `hairline`, `gridEmphasis`, `textDim` or `playback` on an
///     ivory row measures 1.0–2.2:1, i.e. invisible."* This ruler is drawn over
///     a dark waveform, so it is a DARK surface and takes the house dark
///     hierarchy. ⚠️ **It must not silently re-derive the light tokens**, and a
///     reader who "harmonises" the two files by pasting `keyWhite` in here has
///     inverted the measured ink for every label on it.
///
/// ⚠️ **A DELIBERATE DIVERGENCE FROM `docs/DESIGN-LANGUAGE.md`'s LIGHT-SURFACE
/// SENTENCE, STATED SO IT IS NOT READ AS A SLIP.** That document says a light
/// surface earns its own ink because *"an ivory piano key is the one object in a
/// DAW that is ivory in the world"*, and this IS a piano keyboard. It is drawn
/// dark anyway because it is not a keyboard you play — it is a RULER over a
/// waveform, and an ivory column down the left of a near-black editor would be
/// the brightest object on a surface whose subject is a faint grey contour. The
/// rule the design language actually states — *a light surface always earns its
/// own ink; it never borrows the dark hierarchy* — is untouched: this surface is
/// dark and takes dark ink. **What is copied from `KeyboardSidebar` is its
/// density decision (every key named, m25-i) and nothing else.**
///
/// CANVAS CONTRACT (m16-a): the renderer captures VALUES only — `geometry` is a
/// pure `Sendable` struct and `keys` a plain array, both snapshotted before the
/// closure. See `docs/research/design-m16a-canvas-crash.md`.
struct PitchRulerSidebar: View {
    /// The ONE coordinate home, shared with the surface beside it. Passing the
    /// whole value rather than a `rowHeight` scalar is deliberate: a second
    /// `index × rowHeight` mapping here could disagree with
    /// `PitchEditorGeometry.rowTopY(forMidi:)` the moment the window stops
    /// opening on integral bounds, and the two columns would drift a fraction of
    /// a row apart with nothing on screen to explain it.
    var geometry: PitchEditorGeometry
    var width: CGFloat = 52

    /// A natural's row — the LIGHTER of the two, `panelRaised` (#181C27).
    /// Lighter/darker rather than ivory/black: the alternation only has to read
    /// as a keyboard, and on a near-black editor it does that at this amplitude.
    private nonisolated static let naturalRow = DAWTheme.panelRaised
    /// An accidental's row — the app's base surface, so an accidental reads as a
    /// gap in the column rather than as a second object.
    private nonisolated static let accidentalRow = DAWTheme.background

    var body: some View {
        // CANVAS CONTRACT (m16-a): value captures only, computed before the closure.
        let geometry = geometry
        let keys = geometry.rulerKeys
        return Canvas { @Sendable context, size in
            for key in keys {
                let top = geometry.rowTopY(forMidi: Double(key.midi))
                let rect = CGRect(x: 0, y: top, width: size.width, height: geometry.rowHeight)
                context.fill(Path(rect),
                             with: .color(key.isBlack ? Self.accidentalRow : Self.naturalRow))
                // Row seam at this row's TOP, so it is the join with the row
                // above. Every row gets one: two adjacent naturals (the E|F and
                // B|C seams) have no colour change to read as a key gap.
                context.fill(
                    Path(CGRect(x: 0, y: top, width: size.width, height: 0.5)),
                    with: .color(DAWTheme.hairline))
                // The octave landmark at every C — brighter, the same
                // `gridEmphasis` strength the timeline and roll grids emphasise
                // at, so the three surfaces mark an octave identically.
                if key.isOctaveC {
                    context.fill(
                        Path(CGRect(x: 0, y: top, width: size.width, height: 1)),
                        with: .color(DAWTheme.gridEmphasis))
                }
                // The name, on EVERY key (the m25-i density decision, copied
                // deliberately — see this file's banner). SF Mono: a note name
                // is a readout, and the design language reserves SF Mono for
                // readouts. Naturals take the legible secondary tier, accidentals
                // the muted one — the same hierarchy `KeyboardSidebar` uses, with
                // its polarity the right way up for a dark surface.
                let label = Text(key.name)
                    .font(.system(size: 8, weight: key.isOctaveC ? .bold : .medium,
                                  design: .monospaced))
                    .foregroundColor(key.isOctaveC ? DAWTheme.textPrimary
                                     : (key.isBlack ? DAWTheme.textDim : DAWTheme.textSecondary))
                context.draw(label,
                             at: CGPoint(x: size.width - 5, y: top + geometry.rowHeight / 2),
                             anchor: .trailing)
            }
            // The ruler's right edge — one hairline for the whole column, which
            // `KeyboardSidebar` could not do (a single colour could only serve
            // one of its two key tones). A dark surface has no such problem.
            context.fill(
                Path(CGRect(x: size.width - 0.5, y: 0, width: 0.5, height: size.height)),
                with: .color(DAWTheme.hairline))
        }
        .frame(width: width, height: geometry.contentHeight)
        .allowsHitTesting(false)
    }
}
