import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

// Reusable console controls — all Canvas-drawn per the glass-cockpit language
// (flat dark caps, thin neon value tracks, glow follows magnitude). Each takes
// plain value inputs + an `onChange` closure so previews and the live app share
// them, and none allocate per frame (redraw is value-driven, not TimelineView).

/// Long-throw vertical volume fader. Dark groove, cyan level fill, a bright
/// unity ("0 dB") detent tick, and a flat cap with a neon center line. Grab-and-
/// drag anywhere (relative throw); hold ⌥ for fine control; double-click resets
/// to unity. Matches `MasterVolumeFader`'s cyan taper (unity at half travel).
struct VerticalFader: View {
    var gain: Double
    var range: ClosedRange<Double> = Track.volumeRange
    var accent: Color = DAWTheme.playback
    var onChange: (Double) -> Void

    /// Travel fraction captured at drag start, for relative (hardware-feel) drag.
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let fraction = MixerMath.fraction(forGain: gain, in: range)
            let unity = MixerMath.unityFraction(in: range)
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
            // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
            let accent = accent
            Canvas { @Sendable ctx, size in
                let inset: CGFloat = 6
                let travel = size.height - inset * 2
                let grooveW: CGFloat = 5
                let grooveX = (size.width - grooveW) / 2
                let groove = Path(roundedRect: CGRect(x: grooveX, y: inset, width: grooveW, height: travel), cornerRadius: 2.5)
                ctx.fill(groove, with: .color(DAWTheme.panelRaised))
                ctx.stroke(groove, with: .color(DAWTheme.hairline), lineWidth: 1)

                let handleY = inset + travel * (1 - CGFloat(fraction))
                // Level fill from the handle down to the groove bottom.
                var fillCtx = ctx
                fillCtx.clip(to: groove)
                fillCtx.fill(
                    Path(CGRect(x: grooveX, y: handleY, width: grooveW, height: inset + travel - handleY)),
                    with: .color(accent.opacity(0.85))
                )

                // Unity detent tick.
                let unityY = inset + travel * (1 - CGFloat(unity))
                ctx.fill(
                    Path(CGRect(x: size.width / 2 - 9, y: unityY - 0.5, width: 18, height: 1)),
                    with: .color(DAWTheme.textPrimary.opacity(0.4))
                )

                // Fader cap with a neon center line.
                let capW = min(size.width - 4, 30)
                let capH: CGFloat = 16
                let capRect = CGRect(x: (size.width - capW) / 2, y: handleY - capH / 2, width: capW, height: capH)
                let cap = Path(roundedRect: capRect, cornerRadius: 4)
                ctx.fill(cap, with: .color(DAWTheme.panel))
                ctx.stroke(cap, with: .color(DAWTheme.hairline), lineWidth: 1)
                ctx.fill(
                    Path(CGRect(x: capRect.minX + 4, y: handleY - 0.75, width: capW - 8, height: 1.5)),
                    with: .color(accent)
                )
            }
            .contentShape(Rectangle())
            // Vertical value drag → resizeUpDown (docs/DESIGN-LANGUAGE.md "Pointer
            // affordances"): a fader keeps its resize cursor, it never "grabs".
            .hoverCursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        DragCursor.set(.resizeUpDown)
                        let start = dragStart ?? fraction
                        if dragStart == nil { dragStart = start }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                        let moved = -Double(value.translation.height) * fine
                        let newFraction = MixerMath.adjustedFraction(
                            start: start, dragPoints: moved, throwPoints: Double(height - 12))
                        onChange(MixerMath.gain(forFraction: newFraction, in: range))
                    }
                    .onEnded { _ in dragStart = nil; DragCursor.clear() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(1.0) })
            .glow(accent, radius: 5, intensity: 0.15 + 0.4 * fraction)
        }
        .accessibilityLabel("Volume")
        .accessibilityValue("\(MixerFormat.dbString(forGain: gain)) decibels")
    }
}

/// Neon pan knob: dark cap, faint 270° track, a bright neutral value arc from
/// the center-up detent to the current position, plus a pointer. Vertical drag
/// changes it (⌥ fine); double-click re-centers. Neutral white so it never
/// claims a semantic accent (pan has no meaning color).
struct PanKnob: View {
    var pan: Double            // -1...1
    var onChange: (Double) -> Void

    @State private var dragStart: Double?

    private var fraction: Double { (pan + 1) / 2 }

    private nonisolated static func point(_ center: CGPoint, _ radius: CGFloat, _ f: Double) -> CGPoint {
        let radians = MixerMath.knobAngleDegrees(forFraction: f) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    private nonisolated static func arc(_ center: CGPoint, _ radius: CGFloat, from f0: Double, to f1: Double) -> Path {
        var path = Path()
        let steps = 20
        for i in 0...steps {
            let f = f0 + (f1 - f0) * Double(i) / Double(steps)
            let pt = point(center, radius, f)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let fraction = fraction
        return Canvas { @Sendable ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3
            let cap = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
            ctx.fill(cap, with: .color(DAWTheme.panelRaised))
            ctx.stroke(cap, with: .color(DAWTheme.hairline), lineWidth: 1)

            ctx.stroke(Self.arc(center, radius - 2, from: 0, to: 1),
                       with: .color(DAWTheme.textDim.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.stroke(Self.arc(center, radius - 2, from: 0.5, to: fraction),
                       with: .color(DAWTheme.textPrimary.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var pointer = Path()
            pointer.move(to: center)
            pointer.addLine(to: Self.point(center, radius - 3, fraction))
            ctx.stroke(pointer, with: .color(DAWTheme.textPrimary),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .contentShape(Circle())
        // A rotary knob is a vertical value drag → resizeUpDown (docs/DESIGN-
        // LANGUAGE.md "Pointer affordances"), same family as the faders.
        .hoverCursor(.resizeUpDown)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    DragCursor.set(.resizeUpDown)
                    let start = dragStart ?? fraction
                    if dragStart == nil { dragStart = start }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                    let moved = -Double(value.translation.height) * fine
                    let newFraction = MixerMath.adjustedFraction(
                        start: start, dragPoints: moved, throwPoints: 120)
                    onChange((newFraction * 2 - 1).clamped(to: Track.panRange))
                }
                .onEnded { _ in dragStart = nil; DragCursor.clear() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        .accessibilityLabel("Pan")
        .accessibilityValue(MixerFormat.panString(pan))
    }
}

/// Compact horizontal mini-fader for a send level. Neutral fill (secondary
/// level), unity tick, drag to set (absolute), double-click resets to unity.
struct SendMiniFader: View {
    var level: Double
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = MixerMath.fraction(forGain: level, in: Send.levelRange)
            let unity = MixerMath.unityFraction(in: Send.levelRange)
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
            // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
            Canvas { @Sendable ctx, size in
                let groove = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2)
                ctx.fill(groove, with: .color(DAWTheme.panelRaised))
                var fillCtx = ctx
                fillCtx.clip(to: groove)
                fillCtx.fill(Path(CGRect(x: 0, y: 0, width: size.width * CGFloat(fraction), height: size.height)),
                             with: .color(DAWTheme.textPrimary.opacity(0.5)))
                ctx.fill(Path(CGRect(x: size.width * CGFloat(unity) - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(DAWTheme.textPrimary.opacity(0.4)))
                ctx.stroke(groove, with: .color(DAWTheme.hairline), lineWidth: 1)
            }
            .contentShape(Rectangle())
            // Horizontal value drag → resizeLeftRight (docs/DESIGN-LANGUAGE.md
            // "Pointer affordances"): the send mini-fader is dragged left/right.
            .hoverCursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        DragCursor.set(.resizeLeftRight)
                        let f = (Double(value.location.x) / Double(width)).clamped(to: 0...1)
                        onChange(MixerMath.gain(forFraction: f, in: Send.levelRange))
                    }
                    .onEnded { _ in DragCursor.clear() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(1.0) })
        }
    }
}

/// A mute/solo/arm state button: glows in its accent when engaged. `pulse`
/// gives the armed state a slow record-color breathing halo (chrome that means
/// "hot"); off-state buttons never animate.
struct MixerStateButton: View {
    var label: String
    var isOn: Bool
    var color: Color
    var pulse: Bool = false
    var action: () -> Void

    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(isOn ? color : DAWTheme.textDim)
                .frame(maxWidth: .infinity, minHeight: 20)
                .background(isOn ? color.opacity(0.18) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? color.opacity(0.65) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(color, radius: 5, intensity: glowIntensity)
        }
        .buttonStyle(.plain)
        .onChange(of: isOn) { _, now in
            breathing = now && pulse
        }
        .onAppear { breathing = isOn && pulse }
        .animation(pulse ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                   value: breathing)
    }

    private var glowIntensity: Double {
        guard isOn else { return 0 }
        if pulse { return breathing ? 0.7 : 0.25 }
        return 0.5
    }
}

/// One insert-chain row: effect name + a bypass dot. The dot glows signal-green
/// while the effect is passing audio and dims when bypassed. Tap the dot to
/// toggle bypass; the row's context menu removes it.
struct InsertRow: View {
    /// The store + owning-track id let a keyable insert (compressor/gate) host
    /// the sidechain KEY picker, which drives `ProjectStore.setSidechain` — the
    /// SAME method the `fx.setSidechain` wire command calls (UI == wire).
    /// `trackID` is nil on the MASTER chain (m13-d): master effects are never
    /// keyable (the store rejects a master sidechain), so the key picker is
    /// hidden there — mirroring the wire's `fx.setSidechain {trackId:"master"}`
    /// rejection.
    var store: ProjectStore
    var trackID: UUID?
    var effect: EffectDescriptor
    var onToggleBypass: () -> Void
    var onRemove: () -> Void
    /// Non-nil ONLY for Audio Unit inserts (M3 vi-b): opens the plugin window.
    /// Always nil on the master chain (built-ins only, v1).
    var onOpenWindow: (() -> Void)?

    /// Built-in compressor/gate inserts take a sidechain key (m12-g). Hosted AUs
    /// and every other kind do NOT (the store rejects them with a teaching
    /// error) — so the picker only shows where a key is actually accepted. The
    /// MASTER chain (trackID nil) is never keyable (design §4).
    private var isKeyable: Bool {
        trackID != nil && (effect.kind == .compressor || effect.kind == .gate)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button(action: onToggleBypass) {
                    Circle()
                        .fill(effect.isBypassed ? DAWTheme.textDim.opacity(0.35) : DAWTheme.signal)
                        .frame(width: 7, height: 7)
                        .glow(DAWTheme.signal, radius: 4, intensity: effect.isBypassed ? 0 : 0.6)
                }
                .buttonStyle(.plain)
                .help(effect.isBypassed ? "Bypassed — click to enable" : "Active — click to bypass")

                Text(MixerFormat.effectDisplayName(effect))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(effect.isBypassed ? DAWTheme.textDim : DAWTheme.textPrimary)
                    .lineLimit(1)
                    .strikethrough(effect.isBypassed, color: DAWTheme.textDim)
                Spacer(minLength: 0)
                if let onOpenWindow {
                    PluginWindowButton(action: onOpenWindow)
                        .help("Open the effect plugin window")
                }
            }
            if isKeyable, let trackID {
                SidechainKeyControl(store: store, trackID: trackID, effect: effect)
                    .explainable(.sidechain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contextMenu {
            Button(effect.isBypassed ? "Enable" : "Bypass", action: onToggleBypass)
            if let onOpenWindow {
                Button("Open Plugin Window", action: onOpenWindow)
            }
            Button("Remove Insert", role: .destructive, action: onRemove)
        }
    }
}

/// The sidechain KEY picker for a compressor/gate insert row (m12-g S-4). A
/// keyed effect reacts to another track's post-fader signal (the kick→pad pump)
/// instead of its own. Binds a headless `SidechainKeyModel` (candidate filter +
/// injected `ProjectStore.setSidechain` apply) so the picker only ever offers a
/// source the store accepts and every choice is the SAME edit the wire's
/// `fx.setSidechain` makes — the view re-implements no validation; the store's
/// field-named teaching errors surface inline. Standard signal-routing chrome:
/// the earned active state wears the cyan playback accent, NEVER violet (violet
/// is AI identity only — docs/DESIGN-LANGUAGE.md Rule 3).
struct SidechainKeyControl: View {
    @State private var model: SidechainKeyModel

    init(store: ProjectStore, trackID: UUID, effect: EffectDescriptor) {
        let effectID = effect.id
        _model = State(initialValue: SidechainKeyModel(
            sources: { SidechainKeyPicker.eligibleSources(
                destinationTrackID: trackID, tracks: store.tracks) },
            current: {
                store.tracks.first(where: { $0.id == trackID })?
                    .effects.first(where: { $0.id == effectID })?.sidechainSourceTrackID
            },
            nameForTrack: { id in store.tracks.first(where: { $0.id == id })?.name },
            apply: { source in
                try store.setSidechain(trackID: trackID, effectID: effectID, sourceTrackID: source)
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Menu {
                    Button {
                        model.clear()
                    } label: {
                        if model.isKeyed { Text("No Key (self)") }
                        else { Label("No Key (self)", systemImage: "checkmark") }
                    }
                    Divider()
                    if model.candidates.isEmpty {
                        Text("No audio tracks to key from")
                    } else {
                        ForEach(model.candidates) { source in
                            Button {
                                model.setKey(source.id)
                            } label: {
                                if model.currentKeyID == source.id {
                                    Label(source.name, systemImage: "checkmark")
                                } else {
                                    Text(source.name)
                                }
                            }
                        }
                    }
                } label: {
                    keyBadge
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.isKeyed
                      ? "Sidechain key — this effect reacts to another track. Click to change or clear."
                      : "Sidechain key — make this effect react to another track (e.g. duck to a kick).")

                if model.isKeyed {
                    Button {
                        model.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(DAWTheme.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the sidechain key (return to self-keyed)")
                }
                Spacer(minLength: 0)
            }
            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.system(size: 8))
                    .foregroundStyle(DAWTheme.record)   // amber: a teaching warning
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The KEY chip: dim when self-keyed, a lit cyan "KEY ▸ ‹source›" when keyed.
    private var keyBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .bold))
            Text(model.isKeyed ? "KEY \u{25B8} \(model.currentKeyName ?? "?")" : "KEY")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(model.isKeyed ? DAWTheme.playback : DAWTheme.textDim)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background((model.isKeyed ? DAWTheme.playback : DAWTheme.textDim).opacity(model.isKeyed ? 0.14 : 0.06))
        .clipShape(Capsule())
        .glow(DAWTheme.playback, radius: 3, intensity: model.isKeyed ? 0.5 : 0)
    }
}

/// The small window glyph that opens an AU plugin window (M3 vi-b) — one shared
/// affordance for the mixer's AU effect rows and AU instrument header. Neutral
/// cyan hover accent (never violet — that is AI meaning).
struct PluginWindowButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "macwindow")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? DAWTheme.playback : DAWTheme.textDim)
                .frame(width: 16, height: 16)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small color-coded kind badge (dot + label). Violet is deliberately absent —
/// it is reserved for AI-generated content, flagged separately on the strip.
struct KindBadge: View {
    var kind: TrackKind

    private var color: Color {
        switch kind {
        case .audio: DAWTheme.signal        // audio = signal-green (timeline precedent)
        case .instrument: DAWTheme.playback // instrument/MIDI = playback-cyan (timeline precedent)
        case .bus: DAWTheme.textDim         // buses are neutral group summing
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(MixerFormat.kindBadge(kind))
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

/// A left-aligned section caption used to head the insert / send / output areas.
struct StripSectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(DAWTheme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
