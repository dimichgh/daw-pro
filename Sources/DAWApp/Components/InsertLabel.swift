import SwiftUI
import DAWAppKit

/// The coordinate space an `InsertRow`'s name line establishes, so the label can
/// report its own frame relative to the line it sits on. One named space, one
/// definition — a second string literal is a second home for a name.
enum InsertRowCoordinateSpace {
    static let name = "dawInsertRowLine"
}

/// An insert row's NAME — the mixer's smallest control label, and the surface
/// m23-s exists for.
///
/// ## The classification this component encodes
///
/// `MixerFormat.effectDisplayName` returns a **closed vocabulary of ten strings**
/// for the built-in kinds (Gain, EQ, Compressor, Limiter, Reverb, Delay,
/// Saturator, Gate, Chorus, Bass Enhancer). Only `.audioUnit` yields arbitrary
/// vendor text. DESIGN-LANGUAGE's m22-g law says a shared control component pins
/// its own width and **a control label never truncates**; the same entry keeps
/// exactly one soft name truncating beside it, because a track name is user data
/// and losing characters there is honest. A closed vocabulary is the first thing;
/// a plugin's vendor string is the second.
///
/// m22-e classified all of them as the second — the GR mini-bar was seated right
/// of "the soft insert name, which truncates first" — and that single call is the
/// whole defect. On a 132 pt channel strip it drew `Lim…`, `Compr…` and
/// `Bass Enh…` at the app's DEFAULT window.
///
/// So: `pinned == true` for the ten built-ins, `false` for an AU.
///
/// ## Why the pin is safe here and was not before
///
/// A `fixedSize` label that does not fit does not truncate — it OVERFLOWS, and
/// the mixer strip's `clipShape` then cuts it mid-glyph with no ellipsis, which
/// is strictly worse than `Lim…` and invisible to any "is there an ellipsis"
/// check. The pin is therefore only half the fix; the other half is the width.
/// m23-s took the 24 pt gain-reduction bar out of the horizontal flow (it draws
/// as a full-width underline in the row's existing bottom padding now) and the
/// 16 pt editor glyph off built-in rows, taking the budget from 33/63 pt to
/// **85 pt** on a channel against a widest name of 72.6 pt.
/// `MixerStripLayout.insertLabelWidth` is the arithmetic; `InsertLabelSweepTests`
/// pins the vocabulary against it headlessly; the staging gate proves the real
/// layout agrees.
///
/// ## The probe
///
/// `onMetrics` reports what was DRAWN, never a re-derivation (the m23-p2 law).
/// The string it publishes is the `text` the `Text` was built from, the pin flag
/// is the argument handed to `.fixedSize(horizontal:)`, the drawn width is that
/// `Text`'s own measured frame, and the intrinsic width comes from a hidden twin
/// built by the SAME `styled(_:)` builder from the SAME string — so a pinned
/// label must report `drawn == intrinsic`, and if the twin ever drifts from the
/// drawn label's type that equality breaks and the gate says so.
///
/// Plain value inputs + one optional closure, so previews and the app share it.
struct InsertLabel: View {
    /// The resolved display name — the ONE string, used for the drawn `Text` and
    /// for everything reported about it.
    var text: String
    /// True = a control label from the closed built-in vocabulary (pinned, never
    /// truncates). False = an AU's soft name (truncates, tail).
    var pinned: Bool
    var isBypassed: Bool
    /// Reports the DRAWN label: the string the `Text` was built from and that
    /// `Text`'s own frame in the row's named space. nil in previews.
    var onDrawn: ((_ label: String, _ frame: CGRect) -> Void)?
    /// Reports the argument handed to `.fixedSize(horizontal:)`. **A separate
    /// closure on purpose** — the pin is produced at a different modifier than
    /// the string and the frame, and one report describing three modifiers can
    /// survive a mutation to any one of them. nil in previews.
    var onPin: ((Bool) -> Void)?
    /// Reports the hidden twin's width — the same string's single-line ideal.
    /// Separate for the same reason, and because carrying it through `@State`
    /// into the drawn label's reporter would publish a stale value for one
    /// layout pass. nil in previews.
    var onIntrinsic: ((_ width: CGFloat) -> Void)?

    /// The label's face, in ONE place. Both the drawn `Text` and the measurement
    /// twin come through here, so they cannot disagree about type — and
    /// `lineLimit(1)` is inside it on purpose: without it "Bass Enhancer" has a
    /// two-line ideal and the twin would report a narrower intrinsic than the
    /// single-line label actually needs.
    private func styled(_ string: String) -> some View {
        Text(string)
            .font(.system(size: MixerStripLayout.insertLabelFontSize, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        styled(text)
            .foregroundStyle(isBypassed ? DAWTheme.textDim : DAWTheme.textPrimary)
            .strikethrough(isBypassed, color: DAWTheme.textDim)
            .fixedSize(horizontal: reportedPin(pinned), vertical: false)
            .background(alignment: .leading) {
                // The measurement twin. `.hidden()` keeps layout and draws
                // nothing, and because it hangs in a `.background` it can never
                // influence the drawn label's own size.
                styled(text)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(GeometryReader { twin in
                        report(intrinsic: twin.size.width)
                    })
            }
            .background(GeometryReader { geo in
                // ONE read: origin AND size of the drawn Text, in the row's own
                // named space. A second reader for the origin would be the
                // m23-o2 coordinate-space hole in miniature.
                report(frame: geo.frame(in: .named(InsertRowCoordinateSpace.name)))
            })
    }

    /// Reports the pin flag and RETURNS it, so the value handed to
    /// `.fixedSize(horizontal:)` IS the value published — the m23-p2
    /// `reportedInk` shape. Pinning built-ins while AU names keep truncating is
    /// the whole m23-s classification, so this is the one boolean a mutation
    /// would flip, and reporting it from anywhere else would let that mutation
    /// through green.
    private func reportedPin(_ value: Bool) -> Bool {
        onPin?(value)
        return value
    }

    /// Publishes the twin's ideal width and returns a transparent view.
    private func report(intrinsic width: CGFloat) -> some View {
        onIntrinsic?(width)
        return Color.clear
    }

    /// Publishes the drawn label's string and frame, and returns a transparent
    /// view — the reporter sits inside the modifier's argument, so the values
    /// published are the ones the view was built from.
    private func report(frame: CGRect) -> some View {
        onDrawn?(text, frame)
        return Color.clear
    }
}

#Preview("Insert labels — pinned built-in vs soft AU name") {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(["Gain", "EQ", "Compressor", "Bass Enhancer"], id: \.self) { name in
            HStack(spacing: MixerStripLayout.insertRowContentSpacing) {
                Circle().fill(DAWTheme.signal)
                    .frame(width: MixerStripLayout.insertBypassDotWidth,
                           height: MixerStripLayout.insertBypassDotWidth)
                InsertLabel(text: name, pinned: true, isBypassed: false)
                Spacer(minLength: 0)
            }
            .frame(height: MixerStripLayout.insertRowContentHeight)
            .padding(.horizontal, MixerStripLayout.insertRowHorizontalPadding)
            .padding(.vertical, MixerStripLayout.insertRowVerticalPadding)
            .background(DAWTheme.panelRaised.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        HStack(spacing: MixerStripLayout.insertRowContentSpacing) {
            Circle().fill(DAWTheme.signal)
                .frame(width: MixerStripLayout.insertBypassDotWidth,
                       height: MixerStripLayout.insertBypassDotWidth)
            InsertLabel(text: "FabFilter Pro-Q 3", pinned: false, isBypassed: false)
            Spacer(minLength: 0)
            PluginWindowButton(action: {})
        }
        .frame(height: MixerStripLayout.insertRowContentHeight)
        .padding(.horizontal, MixerStripLayout.insertRowHorizontalPadding)
        .padding(.vertical, MixerStripLayout.insertRowVerticalPadding)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
    .frame(width: MixerStripLayout.channelInsertRowWidth)
    .padding(MixerStripLayout.channelStripHorizontalPadding)
    .background(DAWTheme.panel)
}
