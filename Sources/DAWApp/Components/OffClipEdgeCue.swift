import SwiftUI
import DAWAppKit

/// The note editor's **off-clip edge cue** (m23-c1, docs/DESIGN-LANGUAGE.md
/// "Transport playhead + scrub"): what a band shows while the transport sits
/// OUTSIDE the edited clip and the cyan playhead line is therefore absent. It
/// goes in exactly the bands that carry the line — the note grid, plus the
/// velocity lane in Pro — and never in the Pro controller strip, which carries
/// neither (unchanged from m10-e).
///
/// A soft cyan wash bleeding in from the band's leading or trailing VIEWPORT
/// edge, under a small SF Mono direction pill (`◀ 8 BARS` / `2 BEATS ▶`).
///
/// **Why this is not the "parked at an edge" the honest-absence law forbids.**
/// The playhead is a TIMELINE object — its x IS its claim about where the
/// transport is, so a line clamped to the clip boundary is pixel-identical to a
/// truthful line at that beat and the user cannot tell the lie from the truth.
/// This cue is VIEWPORT furniture and makes no positional claim: it is anchored
/// to the scroll viewport (it does not move when the timeline scrolls — the
/// strongest available signal that it is not a timeline object), it is never a
/// hairline, it NEVER wears the glow recipe (the glow is the playhead's
/// signature), its wash is a gradient with no hard inward edge and a hard
/// opacity ceiling far under the line's, and its content is a direction plus a
/// distance, which is exactly true. The two objects are complementary by
/// construction: `PianoRollPlayhead.offClipCue` is nil precisely when
/// `lineX` is non-nil, so they never coexist or double-draw at the inclusive
/// clip edges.
///
/// Deliberately Canvas-free — plain `Rectangle`/`LinearGradient`/`Text`, so no
/// per-tick draw closure exists and the m16-a `@Sendable`-capture contract never
/// applies. Nothing here allocates beyond the label `String` SwiftUI would build
/// for any `Text`. Takes the cue as a plain value input, so a preview and the
/// real app share it (the `SimpleProToggle` idiom).
struct OffClipEdgeCue: View {
    /// The headless cue value — ONE instance feeds both drawing bands, which is
    /// why the note grid and the velocity lane can never disagree about the
    /// transport.
    var cue: PianoRollPlayhead.OffClipCue
    /// Inset from the band's top for the direction pill, so each band can clear
    /// whatever chrome is pinned above its content (the grid's frozen scrub
    /// strip; nothing in the velocity lane).
    var topInset: CGFloat = 6

    /// Width the wash fades across. Wide enough to read as a directional bleed
    /// rather than a line — a narrow bright band hard against the edge would be
    /// a parked edge indicator with extra steps.
    private static let washWidth: CGFloat = 28
    /// Opacity floor (far away) and CEILING (right at the edge). The ceiling is
    /// the guard rail on the proximity ramp: the cue must never approach the
    /// playhead line's brightness, however close the transport gets.
    private static let washFloor: Double = 0.10
    private static let washCeiling: Double = 0.28

    private var isBefore: Bool { cue.side == .before }

    private var washOpacity: Double {
        let ramp = min(1, max(0, cue.proximity))
        return Self.washFloor + (Self.washCeiling - Self.washFloor) * ramp
    }

    var body: some View {
        ZStack(alignment: isBefore ? .topLeading : .topTrailing) {
            Color.clear   // claims the band's full rect for the alignment
            wash
            pill
                .padding(.top, topInset)
                .padding(isBefore ? .leading : .trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }

    /// The directional bleed: full band height so the eye tracks the cue across
    /// the bands exactly as it tracks the line, fading to nothing inward.
    private var wash: some View {
        LinearGradient(
            colors: [DAWTheme.playback.opacity(washOpacity), DAWTheme.playback.opacity(0)],
            startPoint: isBefore ? .leading : .trailing,
            endPoint: isBefore ? .trailing : .leading
        )
        .frame(width: Self.washWidth)
        .frame(maxHeight: .infinity)
    }

    /// Direction + distance. SF Mono because it is a numeric readout, cyan
    /// because it reports transport state (cyan even for an AI clip whose notes
    /// are violet — Rule 3, the same call the playhead makes). `fixedSize` so the
    /// label can never truncate as the distance grows a glyph (the m22-g law).
    private var pill: some View {
        HStack(spacing: 4) {
            if isBefore { chevron }
            Text(cue.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
            if !isBefore { chevron }
        }
        .foregroundStyle(DAWTheme.playback)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(DAWTheme.panelRaised.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
        .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: isBefore ? "chevron.left" : "chevron.right")
            .font(.system(size: 8, weight: .bold))
    }
}
