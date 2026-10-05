import AppKit
import SwiftUI
import DAWAppKit
import DAWCore

// W7-NTU U1 — THE HEADER GROUP "SOUND LIKE THE SINGER" (natural tuning X9).
//
// Three rows beside the preset chips: Keep voice size (§1(f)), Consonants
// (§2f) and Slides (§4.f), with the words of R26. This file DRAWS
// `PitchEditorSingerGroup` verbatim and hands every gesture to the model
// (`PitchEditorModel`'s "Sound like the singer" section); it decides nothing
// and never calls the store (`DAWApp` has no test target — the reason, not a
// preference).
//
// ⚠️ **THE HEIGHTS ARE FIXED, AND THAT IS A LAW, NOT TIDINESS.** Each row is a
// control line over ONE sub-line, and the sub-line swaps between the novice
// line, the update line, the paused line and the Slides state lines. Every
// face is one line in a fixed slot, so a swap never moves the note surface
// under the header ("CHROME THAT COMES AND GOES KEEPS ITS ROW'S HEIGHT",
// `docs/DESIGN-LANGUAGE.md`). `PitchEditorSingerGroupTests` measures every
// sub-line against the group's width with the real font, so none truncates.

/// The group, drawn from its resolved faces.
struct PitchEditorSingerGroupView: View {
    typealias C = PitchEditorFormantCopy

    let group: PitchEditorSingerGroup
    /// A press or drag tick on the voice-size track, at a fraction of its
    /// width, with ⌥ (fine) as held.
    var onVoiceTrack: (_ fraction: Double, _ fine: Bool) -> Void
    /// The voice-size track released.
    var onVoiceRelease: () -> Void
    /// The update line tapped.
    var onUpdate: () -> Void
    /// The Consonants switch clicked.
    var onToggleConsonants: () -> Void
    /// A Slides step clicked.
    var onPickSlides: (PitchEditorSlideStep) -> Void

    /// The group's width, the same at every window width (the fit is argued
    /// on `PitchEditorSingerLayout.groupWidth`).
    static let width = PitchEditorSingerLayout.groupWidth

    var body: some View {
        VStack(alignment: .leading, spacing: PitchEditorSingerLayout.titleGap) {
            Text(group.title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .fixedSize()
                .frame(height: PitchEditorSingerLayout.titleRowHeight)
            VStack(alignment: .leading, spacing: PitchEditorSingerLayout.rowSpacing) {
                row(C.voiceLabel, dim: group.voice.needsUpdate) {
                    voiceControl
                } line: {
                    voiceLine
                }
                .help(group.voice.help)
                row(C.consonantsLabel, dim: false) {
                    consonantsControl
                } line: {
                    consonantsLine
                }
                .help(group.consonants.help)
                row(C.slidesLabel, dim: false) {
                    slidesControl
                } line: {
                    slidesLine
                }
                .help(group.slides.help)
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: One row

    /// A label and its control on one line, and ONE sub-line under them, each
    /// in a fixed-height slot.
    private func row<Control: View, Line: View>(_ label: String, dim: Bool,
                                                @ViewBuilder control: () -> Control,
                                                @ViewBuilder line: () -> Line) -> some View {
        VStack(alignment: .leading, spacing: PitchEditorSingerLayout.lineGap) {
            HStack(spacing: PitchEditorSingerLayout.labelGap) {
                // A control label never truncates (m22-g): pinned, and its
                // column is wide enough by measurement (the group's tests).
                Text(label)
                    .font(.system(size: PitchEditorSingerLayout.labelFontSize, weight: .medium))
                    .foregroundStyle(dim ? DAWTheme.textFaint : DAWTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: PitchEditorSingerLayout.labelWidth, alignment: .leading)
                control()
            }
            .frame(height: PitchEditorSingerLayout.controlHeight)
            line()
                .frame(height: PitchEditorSingerLayout.lineHeight, alignment: .leading)
        }
    }

    /// A sub-line: one line, never wrapped (a wrap would grow the header).
    private func lineText(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(.system(size: PitchEditorSingerLayout.lineFontSize))
            .foregroundStyle(ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: Keep voice size

    private var voiceControl: some View {
        HStack(spacing: PitchEditorSingerLayout.readoutGap) {
            PitchEditorVoiceSizeTrack(amount: group.voice.amount,
                                      needsUpdate: group.voice.needsUpdate,
                                      isDragging: group.voice.isDragging,
                                      onTrack: onVoiceTrack,
                                      onRelease: onVoiceRelease)
                .accessibilityElement()
                .accessibilityLabel(C.voiceLabel)
                .accessibilityValue(group.voice.readout)
                .accessibilityHint(group.voice.line)
            // SF Mono, and a fixed slot, so "100%" and "Off" never move the
            // track (a readout never scales or pushes).
            Text(group.voice.readout)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(voiceReadoutInk)
                .lineLimit(1)
                .frame(width: PitchEditorSingerLayout.readoutWidth, alignment: .trailing)
        }
    }

    /// Cyan only while dragging (glow earned by state, §1(f)); faint on a
    /// vocal that needs the update (the dim law).
    private var voiceReadoutInk: Color {
        if group.voice.needsUpdate { return DAWTheme.textFaint }
        return group.voice.isDragging ? DAWTheme.playback : DAWTheme.textPrimary
    }

    /// The novice line, or — on a vocal tuned before this update — the update
    /// line, which IS a button: tapping it is the update (X4's one path).
    @ViewBuilder
    private var voiceLine: some View {
        if group.voice.needsUpdate {
            Button(action: onUpdate) {
                lineText(group.voice.line, ink: DAWTheme.record)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.voice.help)
            .accessibilityLabel(group.voice.line)
        } else {
            lineText(group.voice.line, ink: DAWTheme.textDim)
        }
    }

    // MARK: Consonants

    /// The house ON/OFF capsule (`EffectEditorOverlay.toggleCell`'s look).
    /// ON glows cyan (an earned state); OFF is neutral chrome. While the render
    /// cannot run it (a paused reason), the capsule keeps saying what is
    /// STORED but goes faint with no glow, and the amber line says why (§2f,
    /// the dim law: live, dim, and says so).
    private var consonantsControl: some View {
        let on = group.consonants.isOn
        let paused = group.consonants.pausedReason != nil
        let ink: Color = paused ? DAWTheme.textFaint : (on ? DAWTheme.playback : DAWTheme.textDim)
        return Button(action: onToggleConsonants) {
            Text(group.consonants.face)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .frame(height: PitchEditorSingerLayout.controlHeight)
                .background(on && !paused ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised,
                            in: Capsule())
                .overlay(Capsule().stroke(on && !paused ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline,
                                          lineWidth: 1))
                .glow(DAWTheme.playback, radius: 4, intensity: on && !paused ? 0.4 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(C.consonantsLabel)
        .accessibilityValue(group.consonants.face)
    }

    private var consonantsLine: some View {
        lineText(group.consonants.line,
                 ink: group.consonants.pausedReason == nil ? DAWTheme.textDim : DAWTheme.record)
    }

    // MARK: Slides

    /// Four named steps; the step in force is lit (cyan, the SIMPLE/PRO chip's
    /// "active half" dress). On an old vocal or a custom smoothness none is lit,
    /// because none is in force (§4.f).
    private var slidesControl: some View {
        HStack(spacing: PitchEditorSingerLayout.stepSpacing) {
            ForEach(PitchEditorSlideStep.allCases) { step in
                let lit = group.slides.selected == step
                Button { onPickSlides(step) } label: {
                    Text(step.label)
                        .font(.system(size: PitchEditorSingerLayout.stepFontSize, weight: .semibold))
                        .foregroundStyle(lit ? DAWTheme.playback : DAWTheme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, PitchEditorSingerLayout.stepHorizontalPadding)
                        .frame(height: PitchEditorSingerLayout.controlHeight)
                        .background(lit ? DAWTheme.playback.opacity(0.16) : DAWTheme.panelRaised,
                                    in: Capsule())
                        .overlay(Capsule().stroke(lit ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline,
                                                  lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(C.slideStepHelp(step))
                .accessibilityLabel(step.label)
                .accessibilityAddTraits(lit ? .isSelected : [])
            }
        }
    }

    private var slidesLine: some View {
        lineText(group.slides.line,
                 ink: group.slides.face == .step ? DAWTheme.textDim : DAWTheme.textSecondary)
    }
}

// MARK: - The voice-size track

/// The "Keep voice size" track: a dark capsule, the four L1 stops as ticks, a
/// fill and a flat cap. Drawn with shapes (never a stock `Slider`, Rule 2).
/// Its gesture only REPORTS (a fraction of the width per tick, then a release);
/// the model decides what a press is and commits once, on release.
private struct PitchEditorVoiceSizeTrack: View {
    var amount: Double?
    var needsUpdate: Bool
    var isDragging: Bool
    var onTrack: (_ fraction: Double, _ fine: Bool) -> Void
    var onRelease: () -> Void

    private static let trackHeight: CGFloat = 4
    private static let thumbWidth: CGFloat = 8
    private static let thumbHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - Self.thumbWidth)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DAWTheme.panelRaised)
                    .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
                    .frame(height: Self.trackHeight)
                ForEach(PitchEditorVoiceSize.detents, id: \.self) { detent in
                    Rectangle()
                        .fill(needsUpdate ? DAWTheme.textFaint.opacity(0.5) : DAWTheme.textDim)
                        .frame(width: 1, height: 7)
                        .offset(x: CGFloat(detent) * usable + Self.thumbWidth / 2 - 0.5)
                }
                // nil has no place on the track: no fill and no cap are drawn
                // (a vocal tuned before this update, or no setting at all).
                if let amount {
                    let x = CGFloat(amount.clamped(to: 0...1)) * usable
                    Capsule()
                        .fill(isDragging ? DAWTheme.playback.opacity(0.85) : DAWTheme.textSecondary.opacity(0.7))
                        .frame(width: x + Self.thumbWidth / 2, height: Self.trackHeight)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDragging ? DAWTheme.playback : DAWTheme.textPrimary)
                        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                        .glow(DAWTheme.playback, radius: 4, intensity: isDragging ? 0.6 : 0)
                        .offset(x: x)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double((value.location.x - Self.thumbWidth / 2) / usable)
                        onTrack(fraction, NSEvent.modifierFlags.contains(.option))
                        if !needsUpdate { DragCursor.set(.resizeLeftRight) }
                    }
                    .onEnded { _ in
                        onRelease()
                        DragCursor.clear()
                    })
        }
        .frame(height: PitchEditorSingerLayout.controlHeight)
        // The house slider's hover cursor (`ValueSlider`), on the LIVE track
        // only: the dim track of an old vocal is a tap on the update, not a
        // value to drag, so it advertises nothing.
        .hoverCursor(resolve: { [needsUpdate] _ in needsUpdate ? nil : .resizeLeftRight })
    }
}

// MARK: - Beside the chips, or below them

/// The preset chips (first subview) and the "Sound like the singer" group
/// (second, when drawn), placed by `PitchEditorSingerLayout.fit(headerContentWidth:)`
/// — the one rule, pinned headlessly: the group BESIDE the chips, the chips
/// yielding width down to a floor, and only under that floor BELOW them.
///
/// ⚠️ **A `Layout`, NOT A `ViewThatFits`.** The group is stateful (a voice-size
/// drag in flight), and the design language forbids wrapping one in a
/// `ViewThatFits`: two branches are two copies of the subtree, and a width
/// change mid-drag would swap the copy under the pointer. Here both subviews
/// are the same views at every width; only their frames move.
struct PitchEditorPresetsAndSingerLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? PitchEditorSingerLayout.presetsWidth
            + PitchEditorSingerLayout.gapBeforeGroup + PitchEditorSingerLayout.groupWidth
        let fit = PitchEditorSingerLayout.fit(headerContentWidth: width)
        let reportedWidth = width.isFinite ? width
            : fit.presetsWidth + PitchEditorSingerLayout.gapBeforeGroup + PitchEditorSingerLayout.groupWidth
        guard subviews.count > 1 else {
            let presets = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
            return CGSize(width: reportedWidth, height: presets.height)
        }
        let group = subviews[1].sizeThatFits(
            ProposedViewSize(width: PitchEditorSingerLayout.groupWidth, height: nil))
        let presets = subviews[0].sizeThatFits(ProposedViewSize(width: fit.presetsWidth, height: nil))
        switch fit.placement {
        case .beside:
            return CGSize(width: reportedWidth, height: max(presets.height, group.height))
        case .below:
            return CGSize(width: reportedWidth,
                          height: presets.height + PitchEditorSingerLayout.belowGap + group.height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let presets = subviews.first else { return }
        guard subviews.count > 1 else {
            presets.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        let group = subviews[1]
        let fit = PitchEditorSingerLayout.fit(headerContentWidth: bounds.width)
        let presetsProposal = ProposedViewSize(width: fit.presetsWidth, height: nil)
        let groupProposal = ProposedViewSize(width: PitchEditorSingerLayout.groupWidth, height: nil)
        presets.place(at: bounds.origin, proposal: presetsProposal)
        switch fit.placement {
        case .beside:
            group.place(at: CGPoint(x: bounds.minX + fit.presetsWidth + PitchEditorSingerLayout.gapBeforeGroup,
                                    y: bounds.minY),
                        proposal: groupProposal)
        case .below:
            let presetsHeight = presets.sizeThatFits(presetsProposal).height
            group.place(at: CGPoint(x: bounds.minX,
                                    y: bounds.minY + presetsHeight + PitchEditorSingerLayout.belowGap),
                        proposal: groupProposal)
        }
    }
}
