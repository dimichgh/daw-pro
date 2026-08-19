import SwiftUI
import DAWCore
import DAWAppKit

/// The built-in SAMPLER editor card (m26-i's UI half) — the
/// `PolySynthEditorOverlay`'s twin pointed at the OTHER built-in instrument
/// with no plugin window: the sampler's globals, its zone map, and a per-zone
/// inspector, opened from the instrument picker's TUNE affordance (and
/// `debug.samplerEditor`). Another instance of the centered dark-glass modal
/// over a dimmed scrim — an in-window card, NEVER a popover or NSWindow, so
/// `debug.captureUI` snapshots it (the captureUI law).
///
/// NO VIOLET — standard instrument chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3): cyan lights only earned ACTIVE state (the
/// selected zone, the live loop mode, One Shot when it is on) and the
/// level-flavoured gain knobs; tune, pan and envelope knobs stay neutral white
/// (the `PanKnob` precedent). Amber is warning only — an interior gap in the
/// keymap, a store refusal, and the one-shot override note.
///
/// ## Three things here are NOT in the card this is cloned from
///
/// 1. **Knobs commit on RELEASE, not per frame** — `DeferredKnob`, whose type
///    doc carries the measured reason. The poly-synth card applies every tick
///    and that is free for it; a sampler apply re-opens every sample file in
///    the library and can force an engine rebuild.
/// 2. **The zone list is LAZY.** The poly synth deliberately has no ScrollView
///    because its schema is CLOSED — four fixed sections that hug their
///    content. A zone list is open-ended (46 zones for the user's saxophone,
///    309 for a large library), so it scrolls, and it builds rows lazily so a
///    300-zone map costs what a visible screenful costs.
/// 3. **`lastErrorMessage` is a REACHABLE state, not a theoretical one.** One
///    moved sample file makes the whole sampler read-only — the globals throw
///    too — so the inline error line is load-bearing here.
///
/// ⛔ `loopStart`/`loopEnd` get NO controls, by the user's ruling (2026-08-18).
/// They are SOURCE-FILE FRAMES: the right unit for a wire API and a meaningless
/// one on a knob, deriving seconds needs the file's own sample rate (main-actor
/// disk I/O, per zone), and hand-typing loop points with no waveform to drag
/// them on is not a real workflow — the importer already sets them. The model
/// exposes all three; this view renders `loopMode` only. **The reopening
/// trigger is a zone WAVEFORM view** — if one is ever built, loop points get
/// dragged on it rather than typed.
struct SamplerEditorOverlay: View {
    var model: SamplerEditorModel
    var onClose: () -> Void

    /// The vertical-strip width — the house 340 pt panel lineage
    /// (PolySynthEditorOverlay / EffectEditorOverlay / Sketchpad / ClipFix).
    private static let cardWidth: CGFloat = 340
    /// ⛔ THE VERTICAL BUDGET IS `DAWAppKit.SamplerCardLayout`, NOT A CONSTANT
    /// HERE — see that type for the defect this replaced. In one line: a fixed
    /// ceiling plus a flexible zone list made the list absorb the whole
    /// shortfall and collapse to ~1.7 rows the moment the inspector opened, in
    /// a window with ~280 pt to spare. The card is now window-responsive, the
    /// zone list takes a FIXED computed height (so its row count is a decision,
    /// not a leftover), and the inspector is the region that yields.
    ///
    /// One zone row's height, mirrored from the layout type so the drawn row
    /// and the budgeted row cannot drift.
    private static let zoneRowHeight = SamplerCardLayout.rowHeight
    private static let zoneRowGap = SamplerCardLayout.rowGap

    var body: some View {
        // The GeometryReader is what makes the card RESPONSIVE rather than a
        // fixed height: the ceiling comes from the room actually available, so
        // the card can neither overflow a short window nor leave a tall one
        // mostly empty. Still an IN-WINDOW card — never a popover or NSWindow —
        // so `debug.captureUI` snapshots it (the captureUI law).
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                // The card renders only while the target still plays the
                // built-in sampler — a wire instrument swap mid-open honestly
                // drops the card, never a stale ghost (the
                // PolySynthEditorOverlay rule).
                if model.targetIsSampler {
                    card(availableHeight: geo.size.height)
                        .frame(width: Self.cardWidth)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
    }

    private func card(availableHeight: CGFloat) -> some View {
        let rowCount = model.zoneRows.count
        let inspectorOpen = model.selectedZoneRow != nil
        let listHeight = SamplerCardLayout.zoneListHeight(
            rowCount: rowCount, inspectorOpen: inspectorOpen, availableHeight: availableHeight)
        let inspectorRoom = SamplerCardLayout.inspectorRoom(
            rowCount: rowCount, inspectorOpen: inspectorOpen, availableHeight: availableHeight)
        return cardBody(listHeight: listHeight, inspectorRoom: inspectorRoom)
    }

    private func cardBody(listHeight: CGFloat, inspectorRoom: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            coverageLine
            Divider().overlay(DAWTheme.hairline)
            globalsSection
            Divider().overlay(DAWTheme.hairline)
            zonesSection(listHeight: listHeight)
            Divider().overlay(DAWTheme.hairline)
            // The YIELDING region (the RESERVED CLUSTER law's mechanism, one
            // surface over): hugs its content when it fits and scrolls inside
            // `inspectorRoom` when it does not. `fixedSize` is the load-bearing
            // word — a bare `maxHeight` on a vertically GREEDY ScrollView would
            // stretch to whatever it is proposed and pad the card out to its
            // ceiling in every state.
            ScrollView(.vertical) { selectedZoneSection }
                .frame(maxHeight: inspectorRoom)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.lastErrorMessage {
                errorLine(error)
            }
            Text("Click a zone to tune it · drag a knob and let go to apply · double-click resets")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.samplerEditor)
    }

    // MARK: Header

    /// Title · the track it is tuning · the IMPORTED LIBRARY's name (m26-h
    /// provenance — "which bass is this?" was unanswerable without dumping a
    /// snapshot) · close.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("SAMPLER")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetLabel)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the sampler editor")
        }
    }

    /// The library provenance + coverage line.
    ///
    /// The headline comes from `SamplerCoverageSummary` VERBATIM — the same
    /// `DAWCore.SamplerZoneCoverage` arithmetic `instrument.describeSampler`
    /// reports, so this card and an AI agent asking the wire cannot disagree
    /// about whether a keymap has a hole in it. **Interior gaps must be
    /// VISIBLE**: a naive min/max reads "C1–C7, covered" over a silent octave
    /// in the middle, and the ⚠ badge plus the tooltip naming the missing keys
    /// is the whole reason that arithmetic exists.
    private var coverageLine: some View {
        let coverage = model.coverage
        let gapped = coverage.gapCount > 0
        return HStack(spacing: 6) {
            if let library = model.params.displayName {
                Text(library)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.params.sourcePath ?? library)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textFaint)
            }
            Text(coverage.headline)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(gapped ? DAWTheme.record : DAWTheme.textDim)
                .lineLimit(1)
                .help(Self.coverageTooltip(coverage))
            Spacer(minLength: 0)
        }
    }

    /// The coverage tooltip: the velocity envelope, and — the part a count
    /// cannot give you — WHICH keys and WHICH dynamics are silent, named.
    /// A bare "⚠ 1 gap" tells a user a hole exists but not where to point the
    /// repair.
    static func coverageTooltip(_ coverage: SamplerCoverageSummary) -> String {
        guard coverage.zoneCount > 0 else {
            return "This sampler has no zones yet — import a sample library to map one."
        }
        var lines: [String] = []
        if let pitch = coverage.pitchLabel { lines.append("Keys \(pitch)") }
        if let velocity = coverage.velocityLabel { lines.append("Velocity \(velocity)") }
        if let gaps = coverage.pitch?.gaps, !gaps.isEmpty {
            let named = gaps.map {
                SamplerEditorModel.pitchSpanLabel(min: $0.lowerBound, max: $0.upperBound)
            }
            lines.append("Silent keys: " + named.joined(separator: ", "))
        }
        if let gaps = coverage.velocity?.gaps, !gaps.isEmpty {
            let named = gaps.map {
                $0.lowerBound == $0.upperBound
                    ? "\($0.lowerBound)"
                    : "\($0.lowerBound)–\($0.upperBound)"
            }
            lines.append("Silent velocities: " + named.joined(separator: ", "))
        }
        return lines.joined(separator: " · ")
    }

    // MARK: GLOBALS

    private var globalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("GLOBALS")
            HStack(alignment: .top, spacing: 8) {
                ForEach(SamplerEditorModel.specs, id: \.name) { spec in
                    globalKnob(spec)
                }
                Spacer(minLength: 0)
                oneShotToggle
            }
        }
    }

    /// One global knob. `attack`/`release` here are the sampler's ANTI-CLICK
    /// ramps, not a musical envelope — the musical shaping is per-zone, which
    /// is why the help text says so rather than leaving two identically-named
    /// knobs on one card to be told apart by guesswork.
    private func globalKnob(_ spec: SamplerParamSpec) -> some View {
        let isLevel = SamplerEditorModel.isLevelParam(spec)
        return DeferredKnob(
            label: spec.label,
            fraction: model.fraction(for: spec),
            fillAnchor: SamplerEditorModel.isBipolar(spec) ? 0.5 : 0,
            accent: isLevel ? DAWTheme.playback : DAWTheme.textPrimary,
            glowsReadout: isLevel,
            readout: { fraction in
                SamplerEditorModel.readout(
                    value: SamplerEditorModel.value(forFraction: fraction, spec: spec),
                    spec: spec)
            },
            onCommit: { model.setFraction($0, for: spec) },
            onReset: { model.resetToDefault(spec) }
        )
        .frame(width: 70)
        .help(Self.globalHelp(spec))
    }

    static func globalHelp(_ spec: SamplerParamSpec) -> String {
        switch spec.name {
        case "attack":
            return "Attack — the whole sampler's fade-IN ramp, there to stop a click "
                 + "at the start of a sample. Per-zone envelopes do the musical shaping."
        case "release":
            return "Release — the whole sampler's fade-OUT ramp after a note ends, "
                 + "there to stop a click. Per-zone envelopes do the musical shaping."
        default:
            return "\(spec.label) — drag up or down and let go; double-click to reset."
        }
    }

    /// The one BOOLEAN global — a toggle, never a knob (the categorical rule
    /// that keeps the poly synth's waveform out of its knob table). The house
    /// state-chip idiom: cyan-lit = on (an earned active state), dim = off.
    private var oneShotToggle: some View {
        let spec = SamplerEditorModel.oneShotSpec
        let on = model.oneShot
        return VStack(spacing: 4) {
            Text(spec.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Button { model.setOneShot(!on) } label: {
                Text(on ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(on ? DAWTheme.playback : DAWTheme.textDim)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(on ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(
                        on ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
                    .glow(DAWTheme.playback, radius: 4, intensity: on ? 0.4 : 0)
            }
            .buttonStyle(.plain)
            .help(spec.detail)
            .accessibilityValue(on ? "on" : "off")
        }
        .frame(width: 62)
    }

    // MARK: ZONES

    /// The zone map. **Lazy by construction** — `LazyVStack` inside the
    /// scroller, fixed-height rows, and `SamplerZoneRow` read ONCE per body
    /// pass into a `let` so a 300-zone library is not re-mapped per row.
    private func zonesSection(listHeight: CGFloat) -> some View {
        let rows = model.zoneRows
        return VStack(alignment: .leading, spacing: 6) {
            sectionLabel("ZONES")
            if rows.isEmpty {
                Text("No zones yet — import a sample library onto this track.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textFaint)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: Self.zoneRowGap) {
                        ForEach(rows) { row in
                            zoneRow(row, selected: row.id == model.selectedZoneID)
                        }
                    }
                    .padding(.trailing, 4)
                }
                // ⛔ A FIXED height, deliberately — NOT `maxHeight`. The
                // defect this replaced was exactly a flexible list: as the only
                // compressible child it absorbed the card's whole shortfall and
                // fell to ~1.7 rows. `SamplerCardLayout` has already bounded
                // this by the rows present, by the state's cap and by a 4-row
                // FLOOR, so the number is a decision, and pinning it here is
                // what makes the inspector below the thing that yields.
                .frame(height: listHeight)
            }
        }
    }

    /// One zone row: file name, the keys it answers to, its velocity layer, and
    /// a loop tick. Selected = cyan-lit (earned active state).
    private func zoneRow(_ row: SamplerZoneRow, selected: Bool) -> some View {
        Button { model.select(zoneID: selected ? nil : row.id) } label: {
            HStack(spacing: 6) {
                Text(row.fileName)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if row.loopMode != nil {
                    Image(systemName: "repeat")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                Text(row.pitchSpanLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textDim)
                Text(row.velocitySpanLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(height: Self.zoneRowHeight)
            .background(selected ? DAWTheme.playback.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                selected ? DAWTheme.playback.opacity(0.45) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(Self.zoneTooltip(row))
        .accessibilityValue(selected ? "selected" : "not selected")
    }

    static func zoneTooltip(_ row: SamplerZoneRow) -> String {
        var text = "\(row.fileName) — root \(row.rootLabel), keys \(row.pitchSpanLabel), "
                 + "velocity \(row.velocitySpanLabel)"
        if row.group != 0 { text += ", layer group \(row.group)" }
        text += ". Click to tune this zone."
        return text
    }

    // MARK: SELECTED ZONE

    @ViewBuilder
    private var selectedZoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let row = model.selectedZoneRow {
                sectionLabel("ZONE — \(row.rootLabel) · \(row.fileName)")
                ForEach(Array(SamplerEditorModel.zoneGroups.enumerated()), id: \.offset) { _, group in
                    zoneGroupRow(group)
                }
                loopModeRow
                if model.selectedZoneLoopOverridesOneShot {
                    oneShotOverrideNote
                }
            } else {
                sectionLabel("ZONE")
                Text("Pick a zone above to tune its pitch, envelope, level and looping.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One per-zone knob group — PITCH · ENVELOPE · OUTPUT last (the SSL /
    /// Cubase / Pro-C3 strip rule the poly-synth card follows).
    private func zoneGroupRow(_ group: (title: String, names: [String])) -> some View {
        let specs = group.names.compactMap { name in
            SamplerEditorModel.zoneSpecs.first { $0.name == name }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textFaint)
            HStack(alignment: .top, spacing: 8) {
                ForEach(specs, id: \.name) { spec in
                    zoneKnob(spec, width: specs.count >= 4 ? 70 : 94)
                }
                if specs.count < 4 { Spacer(minLength: 0) }
            }
        }
    }

    /// One per-zone knob.
    ///
    /// ⚠️ An UNSET field's readout is DIMMED — the knob is showing an inherited
    /// or implicit value rather than one this zone chose, and "0 cents because
    /// nobody set it" and "0 cents because someone set it" look identical
    /// otherwise. `pan` is where that distinction has teeth: an unset pan keeps
    /// the legacy unity dual-mono gains while an explicit 0 sits at the pan
    /// law's centre, so touching a centred pan knob is an audible change that
    /// dragging back to 0 does NOT undo — only a double-click reset restores
    /// unset. The help text says so on that knob.
    private func zoneKnob(_ spec: SamplerParamSpec, width: CGFloat) -> some View {
        let isLevel = SamplerEditorModel.isLevelParam(spec)
        let unset = model.zoneParamIsUnset(spec.name)
        return DeferredKnob(
            label: spec.label,
            fraction: model.zoneFraction(for: spec),
            fillAnchor: SamplerEditorModel.isBipolar(spec) ? 0.5 : 0,
            accent: unset ? DAWTheme.textDim
                          : (isLevel ? DAWTheme.playback : DAWTheme.textPrimary),
            glowsReadout: isLevel && !unset,
            readout: { fraction in
                SamplerEditorModel.readout(
                    value: SamplerEditorModel.value(forFraction: fraction, spec: spec),
                    spec: spec)
            },
            onCommit: { model.setZoneFraction($0, for: spec) },
            onReset: { model.resetZoneParam(spec) }
        )
        .frame(width: width)
        .help(Self.zoneHelp(spec, unset: unset))
    }

    static func zoneHelp(_ spec: SamplerParamSpec, unset: Bool) -> String {
        var text: String
        switch spec.name {
        case "tuneCents":
            text = "Tune — nudges this zone's pitch up or down in cents "
                 + "(100 cents = one semitone)."
        case "pan":
            text = "Pan — places this zone in the stereo field. Touching a centred pan "
                 + "knob makes it explicit and is slightly quieter; double-click to go "
                 + "back to untouched."
        case "attack", "release":
            text = "\(spec.label) — this zone's own \(spec.label.lowercased()); "
                 + "left untouched it follows the sampler's global setting."
        case "sustain":
            text = "Sustain — the level a held note settles at after the decay."
        case "decay":
            text = "Decay — how long the note takes to fall from its peak to the "
                 + "sustain level."
        default:
            text = "\(spec.label) — this zone's own level."
        }
        text += unset ? " Not set on this zone yet — the knob shows what it inherits."
                      : " Drag up or down and let go; double-click resets it."
        return text
    }

    /// LOOP mode — a segmented picker, never a knob (three named states, a
    /// categorical choice). This is the control that makes a held note SUSTAIN
    /// instead of decaying through the end of its sample.
    private var loopModeRow: some View {
        let current = model.selectedZoneLoopMode
        return VStack(alignment: .leading, spacing: 4) {
            Text("LOOP")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textFaint)
            HStack(spacing: 6) {
                ForEach(Array(SamplerEditorModel.loopModes.enumerated()), id: \.offset) { _, mode in
                    loopModeChip(mode, on: mode == current)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func loopModeChip(_ mode: SamplerLoopMode?, on: Bool) -> some View {
        Button { model.setLoopMode(mode) } label: {
            Text(SamplerEditorModel.loopModeLabel(mode).uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(on ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(on ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(
                    on ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
                .glow(DAWTheme.playback, radius: 4, intensity: on ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .help(SamplerEditorModel.loopModeDetail(mode))
        .accessibilityValue(on ? "selected" : "not selected")
    }

    /// ⛔ LOOP MODE WINS OVER ONE SHOT — the engine forces a looping voice
    /// non-one-shot on trigger, beating both the per-zone override and the
    /// global. Said out loud rather than left to be discovered by ear: a
    /// toggle that is switched ON and does nothing for the zone in front of
    /// you is exactly the silent no-op this project keeps closing.
    private var oneShotOverrideNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.record)
            Text("One Shot is on, but this zone LOOPS — looping wins, so One Shot "
                 + "does nothing here. Set Loop to No Loop for it to take effect.")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.record)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(DAWTheme.textDim)
            .lineLimit(1)
    }

    /// The store's refusal, verbatim (the `EffectEditorOverlay` idiom). Amber:
    /// a teaching warning, never the destructive red.
    private func errorLine(_ error: String) -> some View {
        Text(error)
            .font(.system(size: 9))
            .foregroundStyle(DAWTheme.record)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
