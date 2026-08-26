import SwiftUI
import DAWCore
import DAWAppKit

/// The BREATH PAD panel (m28-p7) — the circle the user described: *"controller
/// with big circular knob where the dot is moving between different patterns
/// that are placed around the circle."*
///
/// A centred dark-glass card over a dimmed scrim, rendered INSIDE the main
/// window content rather than as a popover — a popover lives in its own window
/// and is invisible to `debug.captureUI`'s window `cacheDisplay` path, which is
/// the only instrument in this tree that can see a pixel.
///
/// Thin over `BreathPadModel`: every gesture rule, every readout string and the
/// whole air-gauge derivation live there. This file draws.
///
/// ## What the Canvas draws, and what it deliberately does not
///
/// The ring, the spokes, the trail and the dot are Canvas paths; the pattern
/// NAMES are ordinary `Text` views positioned over it. That split is not
/// cosmetic — `GraphicsContext.resolve(Text:)` builds a resolved text object at
/// every draw, so eight names inside the Canvas would allocate eight of them per
/// drag frame. Outside it they are laid out once and only their tint changes.
///
/// **No `TimelineView`, and that is a scope decision worth stating.** Nothing on
/// this pad animates between gestures: the dot moves only under the hand, so the
/// Canvas redraws on interaction and is idle otherwise. There is no continuous
/// redraw to profile and no per-frame allocation to hunt; the trail is a
/// fixed-capacity buffer (`BreathPadTrail`) written in place. A moving dot —
/// `DotPath.orbit` / `.drift`, which DAWCore already implements — would need one,
/// and that is the phase after this one.
///
/// ## Colour
///
/// NO VIOLET (docs/DESIGN-LANGUAGE.md Rule 3 — violet is AI identity, and a
/// breath gesture is performance, not generated content). Cyan for earned active
/// state: the dot glows while a gesture is open and sits unglowed at rest, the
/// knob-arc rule. Amber for the air warning — never red, because §9.6 guarantees
/// the budget can never silence a note and a destructive colour would overstate
/// what it did. Green for air the player still has.
///
/// **No Simple/Pro chip**: the circle, the switch and the button are the same in
/// both densities, and a toggle whose modes coincide is the do-nothing control
/// the design language forbids.
struct BreathPadView: View {
    @Bindable var model: BreathPadModel
    /// The hardware-mapping section's model (m28-knob-ui). **Holds no store and
    /// no engine** — see `BreathPadHardwareModel`: that is what makes "opening
    /// this panel does not touch the user's MIDI hardware" structural.
    @Bindable var hardware: BreathPadHardwareModel
    var onClose: () -> Void

    /// The panel's stable id — the `HumanizePanel.panelID` idiom.
    static let panelID = "breathPad"

    /// Live pointer state for the dial, kept in the LEAF that draws it rather
    /// than on the card: a `@State` write invalidates its owner, and the card
    /// owns the air strip and the warnings block.
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                    .onTapGesture(perform: closeSafely)
                card(available: proxy.size.height)
                    .frame(width: 420)
                    // ⭐ THE CARD REPORTS ITS OWN HEIGHT (m28-p7, added after the
                    // render). Every previous defect in this budget was found by
                    // measuring PIXELS and inferring the rest, and the last one
                    // did not converge: the card, the dial and the window each
                    // implied a different `available`. A view that states what it
                    // was given and what it drew turns that archaeology into a
                    // reading. Reported through a preference — writing model
                    // state during a body evaluation is the mutation-during-update
                    // bug — and REPORTED ONLY: nothing in the layout consults it.
                    .background(
                        GeometryReader { card in
                            Color.clear.preference(key: CardHeightKey.self,
                                                   value: card.size.height)
                        }
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
            .preference(key: AvailableHeightKey.self, value: proxy.size.height)
        }
        .onPreferenceChange(CardHeightKey.self) { [weak model] height in
            model?.measuredLayout.cardHeight = height
        }
        .onPreferenceChange(AvailableHeightKey.self) { [weak model] height in
            model?.measuredLayout.available = height
        }
        .onPreferenceChange(HardwareHeightKey.self) { [weak model] height in
            model?.measuredLayout.hardwareHeight = height
        }
        .transition(.opacity)
    }

    /// Dismissing with the pointer still down would otherwise leave the strip
    /// parked at the preview value until `PadPreviewController`'s 30 s ceiling
    /// fired. A gesture abandoned by a dismissal asked for no edit, so it ends
    /// WITHOUT committing.
    private func closeSafely() {
        model.endGestureWithoutCommitting()
        onClose()
    }

    /// ⚠️ The budget takes the OPTIONAL blocks as inputs, not just the window.
    /// A single chrome constant was measured to be 136 pt light once a warning
    /// and the recovery sentence were on screen — and the dial, which is the
    /// region that is supposed to yield, could not see either of them.
    ///
    /// ## The third step of the cascade, and why it had to exist
    ///
    /// The dial yields, then the warnings shed — and at the app's own window
    /// FLOOR (`WindowFloor.minHeight`, 640) both are at their floors and the card
    /// is still 97 pt too tall. A centred card that overhangs loses its first and
    /// last rows, and the last row here is **WRITE THE SHAPE**: MEASURED at the
    /// floor, the pad's primary action was clipped off the bottom of the window
    /// and the panel could not be used at all. Every test in the round was green,
    /// because they all consume `fixedChrome` and it was 53 pt light.
    ///
    /// So the cascade gains a final step: **when even the floors do not fit, the
    /// card SCROLLS instead of overhanging.** The header and the apply button
    /// stay pinned outside the scroller, so the two controls that must never be
    /// unreachable — dismiss and commit — never are. Nothing is dropped; the
    /// middle is deferred rather than lost, which is the same choice the warnings
    /// block already makes at its own scale.
    ///
    /// ⛔ **Exactly one scroller is live at a time.** While the card fits, the
    /// warnings block is the scroller and is bounded by its region. Once the card
    /// scrolls, the warnings block is given its full natural height and the outer
    /// scroller carries everything — nested vertical scrollers on macOS make the
    /// inner one a trap for the wheel. ⚠️ That is a claim about BOUNDS, which is
    /// all a capture can see; wheel ROUTING is not observable here.
    ///
    /// ⚠️⚠️ **UNVERIFIED, AND SAID SO RATHER THAN ASSUMED: the dial's
    /// `DragGesture` now has a `ScrollView` ancestor in this branch, and nothing
    /// in this tree has ever exercised that combination.** A structural sweep of
    /// `Sources/DAWApp` (positive-controlled — it finds the four `ScrollView`s
    /// that do contain a `Canvas`) returns **zero** places where a `DragGesture`
    /// ships inside a `ScrollView`, so there is no precedent to lean on. Every
    /// gesture this round exercised went through `debug.breathPad`, which drives
    /// the model directly and never touches the real pointer path — there is no
    /// pointer seam for the pad, and a human press is the only instrument. The
    /// branch only engages below a ~657 pt window; if dragging the dot there
    /// misbehaves, THIS is the line to suspect first.
    private func card(available: CGFloat) -> some View {
        let hasWarnings = !model.warnings.isEmpty
        let hasRecoveryNote = model.gauge.recoveryNote != nil
        // ⚠️ m28-knob-ui: the FOURTH input to this budget. Read from the ONE
        // place it lives (`BreathPadHardwareModel.isExpanded`) and handed
        // straight to the layout — a copy on the pad's model would be a second
        // home for a fact the card's height depends on.
        let hardwareExpanded = hardware.isExpanded
        let regions = BreathPadLayout.regions(
            available: available,
            hasWarnings: hasWarnings,
            hasRecoveryNote: hasRecoveryNote,
            hardwareExpanded: hardwareExpanded)
        let room = available - BreathPadLayout.windowMargin * 2
        let scrolls = available > 0 && BreathPadLayout.cardHeight(
            available: available,
            hasWarnings: hasWarnings,
            hasRecoveryNote: hasRecoveryNote,
            hardwareExpanded: hardwareExpanded) > room
        return VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            if model.targetIsMIDI {
                if scrolls {
                    // ⭐⭐ THE SCROLLER IS INSTRUMENTED, AND THAT IS NOT A LUXURY.
                    // On this machine's display the expanded card cannot fit at
                    // ANY window height, so the hardware section is always below
                    // the fold — and "captured: the whole section" was a capture
                    // of the section's absence. `debug.breathPad {scrollTo:
                    // "hardware"}` drives this anchor so the bottom of a
                    // scrolling card can be photographed on a screen too short to
                    // show it. m28-p7's lesson was that a UI phase is not done
                    // until someone has LOOKED at it; a card that can outgrow
                    // every available display needs a way to be looked at.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            shapingBody(regions: regions, scrolls: true)
                        }
                        .onChange(of: model.scrollToBottomRequest) {
                            withAnimation(.none) {
                                proxy.scrollTo(BreathPadView.bottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                } else {
                    shapingBody(regions: regions, scrolls: false)
                }
                applyButton
            } else {
                audioNote
            }
        }
        .padding(16)
        .frame(maxHeight: scrolls ? room : nil, alignment: .top)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// Everything between the header and the apply button — the part that
    /// scrolls when the card cannot fit.
    private func shapingBody(regions: (dial: CGFloat, warnings: CGFloat),
                             scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            blurb
            BreathPadDial(model: model, side: regions.dial)
                .frame(width: regions.dial, height: regions.dial)
                .frame(maxWidth: .infinity)
            controlRow
            gestureLine
            Divider().overlay(DAWTheme.hairline)
            airSection
            warningsBlock(room: scrolls ? .infinity : regions.warnings)
            Divider().overlay(DAWTheme.hairline)
            // ⭐ THE SECTION REPORTS ITS OWN HEIGHT (m28-knob-ui), for the
            // reason `MeasuredLayout.hardwareHeight` states: the card's own
            // report cannot supply `hardwareExpandedChrome`, because on a short
            // display the expanded card is CLAMPED by the scroll cascade and the
            // difference between two clamped cards is not the difference between
            // two sections. Reported through a preference — a model write during
            // a body evaluation is the mutation-during-update bug — and
            // REPORTED ONLY: no layout code reads it.
            BreathPadHardwareSection(hardware: hardware)
                .background(
                    GeometryReader { section in
                        Color.clear.preference(key: HardwareHeightKey.self,
                                               value: section.size.height)
                    }
                )
                // The anchor the scroll instrument targets. It is the LAST thing
                // on the card, so scrolling to it proves the card's bottom is
                // reachable — which is the property the m28-p7 clip violated.
                .id(BreathPadView.bottomAnchor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The id of the card's last row, for `ScrollViewReader`.
    fileprivate static let bottomAnchor = "breathPad.bottom"

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wind")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("BREATH PAD")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetClipName)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            Button(action: closeSafely) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the breath pad")
        }
    }

    /// One sentence, in the beginner's words, about what the circle IS.
    ///
    /// ⚠️ It says LOUDNESS and shape, never brightness or tone: on a sound-bank
    /// track — where the user's saxophone lives — CC 11 was MEASURED to be
    /// exactly a gain and to move no filter at all
    /// (`docs/research/measure-gm-sax-cc.md`). A panel promising timbre there
    /// would be describing a control the instrument does not have.
    private var blurb: some View {
        Text("Eight ways a wind player shapes a note sit around the circle. Drag the dot to blend the two nearest ones — how far out you go is how strongly it is shaped. You hear it while you drag; it is written into the part when you let go.")
            .font(.system(size: 10.5))
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Readouts and the precision knobs

    /// ANGLE and DEPTH as real knobs, EFFORT as the readout it has to stay
    /// (m28-knob-ui).
    ///
    /// ## Why knobs and not a second set of numbers
    ///
    /// The dial is a *gesture* control: it is the fastest way to find a shape
    /// and the worst way to land on 90.0° exactly. Two knobs beside it give the
    /// same two dimensions one at a time, with ⌥ for quarter-speed fine
    /// adjustment — the house knob contract — and they are the only route a
    /// player has to nudge ONE axis without disturbing the other.
    ///
    /// ⭐ **They REPLACE the ANGLE/DEPTH text readouts rather than joining
    /// them.** `KnobControl` already draws its label above and its SF Mono value
    /// below, so keeping both would have printed each number twice and cost the
    /// card a row it does not have — the pad's budget was already the tightest
    /// on any card in the app.
    ///
    /// EFFORT stays a readout because it is DERIVED (`effort` is a function of
    /// the blend, and the CC integer is `PadPreviewController`'s own mapping).
    /// A knob on a value you cannot set is the do-nothing control the design
    /// language forbids.
    ///
    /// ⛔ **Two-way with the dial and with the hardware, by construction.** The
    /// knobs render `model.angleFraction` / `model.radiusFraction`, so a
    /// hardware turn — which moves the same dot through `pumpExternalControl` —
    /// visibly moves these caps, and so does a drag on the dial. There is one
    /// dot and three ways to push it, not three copies of a position.
    private var controlRow: some View {
        HStack(alignment: .top, spacing: 14) {
            KnobControl(
                label: "ANGLE",
                fraction: model.angleFraction,
                readout: model.angleReadout,
                accent: DAWTheme.playback,
                onChange: { _ = model.knobMoved(angleFraction: $0) },
                // ⛔ ONE KNOB, ONE AXIS. Both of these once called a shared
                // `resetKnobs()`, so double-clicking DEPTH swung the ANGLE — a
                // control moving a parameter it does not name, against the
                // `KnobControl` contract every other knob in the app keeps.
                onReset: { model.resetAngle() },
                onCommit: { _ = model.knobReleased() })
            KnobControl(
                label: "DEPTH",
                fraction: model.radiusFraction,
                readout: model.radiusReadout,
                accent: DAWTheme.playback,
                onChange: { _ = model.knobMoved(radiusFraction: $0) },
                onReset: { model.resetDepth() },
                onCommit: { _ = model.knobReleased() })
            readout("EFFORT", model.effortReadout)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Which gestures the dot is actually blending, and what the nearest one
    /// means — the panel says what the value MEANS, not only what it is.
    private var gestureLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.blendReadout)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineLimit(1)
            // ⚠️ RESERVED, NOT FIXED. The eight summaries run 135–255
            // characters — two lines to four at this width — and a block that
            // changes height with the dot's angle is a height the card's budget
            // cannot see (`BreathPadLayout.summaryReservation` states the whole
            // reasoning). Reserving the worst case makes `fixedChrome` true for
            // every gesture; leaving it a MINIMUM means a longer sentence one
            // day wraps and pushes — the dial absorbs it — instead of being
            // silently truncated.
            Text(model.blendSummary)
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: BreathPadLayout.summaryReservation, alignment: .topLeading)
            if let refusal = model.previewRefusal {
                PanelRefusalLine(message: refusal)
            }
        }
    }

    // MARK: - Air

    /// Design §9.5: the switch is prominent and clearly labelled, because an air
    /// budget overrides what the composer wrote and a feature that does that is
    /// opted into once, visibly. It defaults OFF by user ruling.
    private var airSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            airSwitch
            BreathPadAirStrip(gauge: model.gauge)
                .frame(height: 44)
            Text(model.gauge.headline)
                .font(.system(size: 9.5))
                .foregroundStyle(model.gauge.hasReport && model.gauge.constrainedNoteCount > 0
                                 ? DAWTheme.record : DAWTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            if let note = model.gauge.recoveryNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // §9.4 layer 3: the committed lane is the durable artefact. The
            // panel closes; the curve in the controller lane does not.
            Text("Whatever this writes is drawn in the piano roll's CC 11 lane — that is where \"why did this get quiet?\" always has an answer.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A DRAWN switch, not a stock `Toggle`, and the reason is measured as well
    /// as stylistic. Stylistic: docs/DESIGN-LANGUAGE.md — no stock AppKit
    /// utility chrome, and a control this consequential should look like the
    /// rest of the cockpit. Measured: a `Toggle(.switch)` rendered through
    /// `debug.captureUI`'s window `cacheDisplay` path drew its knob in the OFF
    /// position while the model was ON — the label, the readout and the gauge
    /// beside it all said "enforced" and the switch did not. A control whose
    /// picture disagrees with its value is the silent-plausible failure this
    /// project keeps closing, and here it would be lying about the one setting
    /// that overrides what the composer wrote.
    ///
    /// Amber when on: the budget is a WARNING-class state, never red — §9.6
    /// guarantees it cannot silence a note, so a destructive colour would
    /// overstate it. Neutral when off (Rule 3: an off switch has earned no
    /// accent).
    private var airSwitch: some View {
        Button {
            model.airEnforced.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("RUN OUT OF AIR")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(model.airEnforced ? DAWTheme.record : DAWTheme.textSecondary)
                ZStack(alignment: model.airEnforced ? .trailing : .leading) {
                    Capsule()
                        .fill(model.airEnforced
                              ? DAWTheme.record.opacity(0.35) : DAWTheme.panelRaised)
                        .overlay(Capsule().stroke(model.airEnforced
                                                  ? DAWTheme.record.opacity(0.8)
                                                  : DAWTheme.hairline, lineWidth: 1))
                        .frame(width: 38, height: 20)
                    Circle()
                        .fill(model.airEnforced ? DAWTheme.record : DAWTheme.textFaint)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 3)
                        .glow(DAWTheme.record, radius: 5,
                              intensity: model.airEnforced ? 0.5 : 0)
                }
                .frame(width: 38, height: 20)
                Spacer(minLength: 0)
                Text(model.airEnforced ? "ENFORCED" : "OFF")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.airEnforced ? DAWTheme.record : DAWTheme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Let the simulated player run short of breath, and pull the notes down when he does")
    }

    /// The store's own warning sentences, verbatim. **Bounded and inflexible**:
    /// it hugs its content when it fits and scrolls inside its room when it does
    /// not, so it can never absorb the height the DIAL is meant to yield
    /// (docs/DESIGN-LANGUAGE.md, the m26-i card law — `fixedSize` is the
    /// load-bearing word).
    @ViewBuilder
    private func warningsBlock(room: CGFloat) -> some View {
        if !model.warnings.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // The COUNT is pinned outside the scroller (the mixer
                    // inserts' count-badge rule): a list that is scrolled — or
                    // shed to its floor at a small window — must never read as a
                    // shorter list than it is.
                    Text("\(model.warnings.count) NOTE\(model.warnings.count == 1 ? "" : "S")")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textFaint)
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 9))
                                .foregroundStyle(DAWTheme.record)
                            Text(warning)
                                .font(.system(size: 9.5))
                                .foregroundStyle(DAWTheme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: room)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Apply

    /// The button is a SECOND, equal route to the same edit — the drag already
    /// commits on release. It exists because flipping the air switch has to be
    /// re-runnable without faking a drag, and because a keyboard user has no
    /// release to commit on.
    private var applyButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { _ = model.commit() } label: {
                Text("WRITE THE SHAPE")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(model.canApply ? DAWTheme.background : DAWTheme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(model.canApply ? DAWTheme.playback : DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .glow(DAWTheme.playback, radius: 6, intensity: model.canApply ? 0.4 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!model.canApply)
            .help("Write this shape into the part's expression lane (one undo step)")
            if let refusal = model.applyRefusal {
                PanelRefusalLine(message: refusal)
            } else if !model.canApply {
                Text("The dot is in the middle, which means \"exactly as written\" — drag it outwards to shape the part.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DAWTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Audio backstop

    private var audioNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12)).foregroundStyle(DAWTheme.signal)
            Text("The breath pad shapes the notes of an instrument part. This is an audio recording, so it already carries whatever breath was played.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The dial

/// The circle itself: the ring, the eight gestures around it, the dot, and the
/// trail it left this gesture.
///
/// Every position comes from `BreathPadGeometry`, so the drawn dot and the
/// hit-tested dot cannot disagree — the failure mode where a control looks right
/// and responds somewhere else.
private struct BreathPadDial: View {
    @Bindable var model: BreathPadModel
    var side: CGFloat

    private var geometry: BreathPadGeometry { BreathPadGeometry(side: side) }

    /// Everything the renderer needs, as VALUES.
    ///
    /// The Canvas closure opens `@Sendable` — the m16-a canvas contract, pinned
    /// by `CanvasContractPinTests` — which makes it nonisolated and therefore
    /// unable to touch the `@MainActor` model at all. That is the point: the
    /// snapshot is read once per body evaluation, on the main actor, and the
    /// draw is a pure function of it. `trail` is passed as the BUFFER, not as an
    /// array: materialising one would allocate on every drag frame.
    private struct Drawing: Sendable {
        var geometry: BreathPadGeometry
        var dot: DotPosition
        var weights: [Double]
        var patternCount: Int
        var trail: BreathPadTrail
        var isDragging: Bool
    }

    var body: some View {
        let geo = geometry
        let drawing = Drawing(geometry: geo, dot: model.dot, weights: model.blend.weights,
                              patternCount: model.patternNames.count, trail: model.trail,
                              isDragging: model.gesture != nil)
        return ZStack {
            Canvas(rendersAsynchronously: false) { @Sendable context, _ in
                BreathPadDial.draw(context: context, drawing: drawing)
            }
            // Names OUTSIDE the Canvas — see the file header: resolving eight
            // Texts inside it would allocate eight resolved texts per frame.
            ForEach(Array(model.patternNames.enumerated()), id: \.offset) { index, name in
                let active = index == model.nearestPatternIndex
                Text(name.uppercased())
                    .font(.system(size: 8, weight: active ? .bold : .semibold))
                    .tracking(0.6)
                    .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(width: 78)
                    .position(geo.labelPoint(index: index, count: model.patternNames.count))
                    // ⚠️ NOT hit-testable, deliberately. A tappable label inside
                    // the pad's `DragGesture(minimumDistance: 0)` receives BOTH
                    // gestures: the drag opens and jumps the dot, the tap parks
                    // it again, and one click spends TWO undo steps. The press
                    // is resolved geometrically by `BreathPadGeometry.patternHit`
                    // inside the one gesture below.
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if model.gesture == nil {
                        model.beginDrag(at: value.location, geometry: geo)
                    } else {
                        model.drag(to: value.location, geometry: geo)
                    }
                }
                // The COMMIT lives here and only here: once, on release, gated
                // on the dot having actually moved. A plain click is a complete
                // drag with zero translation, so an ungated release would spend
                // an undo step and pay an engine rebuild for a stray press.
                .onEnded { _ in _ = model.endDrag() }
        )
        .accessibilityLabel("Breath pad")
        .accessibilityValue("\(model.blendReadout), depth \(model.radiusReadout)")
    }

    nonisolated private static func draw(context: GraphicsContext, drawing: Drawing) {
        let geo = drawing.geometry
        let center = geo.center
        let ringRadius = geo.ringRadius
        let count = max(1, drawing.patternCount)

        // The rim, and one inner guide at half depth so "how far out am I" is
        // readable without a number.
        for (fraction, opacity) in [(1.0, 0.16), (0.5, 0.08)] {
            let r = ringRadius * fraction
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                       width: r * 2, height: r * 2)),
                with: .color(Color.white.opacity(opacity)), lineWidth: 1)
        }

        // Spokes to each gesture; the two the dot is actually blending are lit.
        let weights = drawing.weights
        for index in 0..<count {
            let outer = geo.patternPoint(index: index, count: count)
            var path = Path()
            path.move(to: center)
            path.addLine(to: outer)
            let weight = index < weights.count ? weights[index] : 0
            let colour = weight > 0.005
                ? DAWTheme.playback.opacity(0.10 + 0.35 * weight)
                : Color.white.opacity(0.06)
            context.stroke(path, with: .color(colour), lineWidth: weight > 0.005 ? 1.5 : 1)
            // A tick at the rim marks the exact gesture position.
            let tick = CGRect(x: outer.x - 2.5, y: outer.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: tick),
                         with: .color(weight > 0.005
                                      ? DAWTheme.playback.opacity(0.5 + 0.5 * weight)
                                      : Color.white.opacity(0.18)))
        }

        // The centre: "exactly as written". Marked, because a user who drags to
        // the middle must not think they turned the part down — at radius 0 the
        // blend collapses to neutral, which is the part exactly as authored.
        let dotSize: CGFloat = 3
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - dotSize, y: center.y - dotSize,
                                   width: dotSize * 2, height: dotSize * 2)),
            with: .color(Color.white.opacity(0.22)))

        // The trail — oldest faintest. Drawn only while a gesture is open, and
        // read through the buffer's subscript so no array is built per frame.
        let trail = drawing.trail
        if trail.count > 1 {
            for i in 1..<trail.count {
                var segment = Path()
                segment.move(to: geo.point(of: trail[i - 1]))
                segment.addLine(to: geo.point(of: trail[i]))
                let age = Double(i) / Double(trail.count)
                context.stroke(segment,
                               with: .color(DAWTheme.playback.opacity(0.05 + 0.35 * age)),
                               lineWidth: 1.5)
            }
        }

        // The dot. The glow recipe — core + tight shadow + wide faint bloom —
        // and it is EARNED: at rest the dot is a plain cyan disc, and it blooms
        // only while a gesture is open (never glow static chrome).
        let p = geo.point(of: drawing.dot)
        let r = BreathPadGeometry.dotRadius
        if drawing.isDragging {
            for (scale, opacity) in [(3.4, 0.14), (1.9, 0.35)] {
                let rr = r * scale
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr,
                                           width: rr * 2, height: rr * 2)),
                    with: .color(DAWTheme.playback.opacity(opacity)))
            }
        }
        context.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .color(DAWTheme.playback))
        context.stroke(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .color(DAWTheme.background.opacity(0.7)), lineWidth: 1)
    }
}

// MARK: - The air strip

/// Design §9.4 layer 4, rendered: a breath mark at each detected breath and
/// shading where air fell below the reserve.
///
/// ⛔ It draws ONLY what `AirBudget.Report` said. Nothing here recomputes a
/// budget, and nothing here decides whether the budget applied — that word comes
/// from `BreathPadAirGauge`, which reads `Report.applied` on every sentence.
private struct BreathPadAirStrip: View {
    var gauge: BreathPadAirGauge

    var body: some View {
        // `@Sendable` per the m16-a canvas contract: the closure is nonisolated,
        // so it may capture only the `gauge` VALUE — which is all it needs, and
        // is exactly why the gauge is a `Sendable` struct rather than a read off
        // the model.
        Canvas(rendersAsynchronously: false) { @Sendable context, size in
            let frame = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: frame, cornerRadius: 6),
                         with: .color(DAWTheme.panelRaised))

            guard gauge.isDrawable else { return }

            // The reserve line: below this the player is running short.
            let reserveY = size.height * 0.7
            var reserve = Path()
            reserve.move(to: CGPoint(x: 0, y: reserveY))
            reserve.addLine(to: CGPoint(x: size.width, y: reserveY))
            context.stroke(reserve, with: .color(Color.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            for phrase in gauge.phrases {
                let x0 = CGFloat(gauge.position(ofBeat: phrase.startBeat)) * size.width
                let x1 = CGFloat(gauge.position(ofBeat: phrase.endBeat)) * size.width
                let width = max(2, x1 - x0)
                // Air is drawn as a band whose top edge is the air level: full
                // air fills the strip, an exhausted phrase sinks below the line.
                let yStart = size.height * (1 - CGFloat(phrase.airAtStart))
                let yEnd = size.height * (1 - CGFloat(phrase.airAtEnd))
                var band = Path()
                band.move(to: CGPoint(x: x0, y: yStart))
                band.addLine(to: CGPoint(x: x0 + width, y: yEnd))
                band.addLine(to: CGPoint(x: x0 + width, y: size.height))
                band.addLine(to: CGPoint(x: x0, y: size.height))
                band.closeSubpath()
                let tint = phrase.exhausted ? DAWTheme.record : DAWTheme.signal
                // ⭐ A COUNTERFACTUAL IS DRAWN DIMMER THAN A FACT. With
                // enforcement off nothing reached the lane, so the strip reads
                // as a prediction at a glance and not only in its sentence —
                // the "inert data earns no brightness" idiom the controller
                // strip's beyond-clip ghost already uses.
                let ink = gauge.applied ? 1.0 : 0.5
                context.fill(band,
                             with: .color(tint.opacity((phrase.exhausted ? 0.32 : 0.22) * ink)))
                var edge = Path()
                edge.move(to: CGPoint(x: x0, y: yStart))
                edge.addLine(to: CGPoint(x: x0 + width, y: yEnd))
                context.stroke(edge, with: .color(tint.opacity(0.9 * ink)),
                               style: StrokeStyle(lineWidth: 1.5,
                                                  dash: gauge.applied ? [] : [4, 3]))
            }

            // Breath marks: a full-height tick where the player got a breath,
            // and an amber one where the gap was too short to be one. Two marks,
            // because the two have opposite fixes.
            for breath in gauge.breaths {
                let x = CGFloat(gauge.position(ofBeat: breath.beat)) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 2))
                tick.addLine(to: CGPoint(x: x, y: size.height - 2))
                let colour = breath.taken ? DAWTheme.textSecondary : DAWTheme.record
                context.stroke(tick, with: .color(colour.opacity(breath.taken ? 0.55 : 0.9)),
                               style: StrokeStyle(lineWidth: 1,
                                                  dash: breath.taken ? [] : [2, 2]))
            }
        }
        .overlay(alignment: .leading) {
            if !gauge.isDrawable {
                Text(gauge.hasReport ? "NO PHRASES FOUND" : "NO AIR READING YET")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.textFaint)
                    .padding(.leading, 10)
            }
        }
        // The same distinction in a word, in the corner, so the strip carries it
        // whether or not the sentence below is read.
        .overlay(alignment: .topTrailing) {
            if gauge.isDrawable {
                Text(gauge.applied ? "APPLIED" : "PREDICTED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(gauge.applied ? DAWTheme.record : DAWTheme.textFaint)
                    .padding(.top, 3)
                    .padding(.trailing, 6)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }
}

// MARK: - The layout's own report

/// What the pad was GIVEN and what it DREW, published back to the model so the
/// debug echo can state both.
///
/// ⚠️ **REPORTED, NEVER CONSULTED.** Nothing in `BreathPadLayout` reads these —
/// a budget that fed back its own measurement would settle at whatever it drew
/// last, and the discrepancy this exists to expose would vanish into the loop.
private struct AvailableHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The HARDWARE section's drawn height (m28-knob-ui) — the one number
/// `hardwareExpandedChrome` is measured from.
private struct HardwareHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
