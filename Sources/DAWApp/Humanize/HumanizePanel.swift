import SwiftUI
import DAWCore
import DAWAppKit

/// The Humanize panel (m25-c): the face for the shipped `clip.humanize` engine,
/// which until now was reachable by MCP/Copilot and by NOTHING a human could
/// click. It presents as a centered dark-glass modal card over a dimmed scrim
/// (the Quantize / instrument-picker overlay idiom) — rendered INSIDE the main
/// window content rather than as a popover, which would live in its own window,
/// invisible to the `debug.captureUI` window cacheDisplay path.
///
/// ⚠️ THAT MAKES IT SNAPSHOT-ABLE, NOT YET SNAPSHOTTED. No staging seam OPENS
/// this panel: `debug.panelLayout` REPORTS `humanizePanelVisible` but cannot
/// set it, so in any headless flow that key reads `false` forever. The missing
/// half is a WRITE seam — a `debug.panelLayout {humanizePanel: "<clipId>"}`
/// param would close the gap and stay off `allCommands`/MCP like every
/// `debug.*` verb. Until then this panel's appearance is verifiable only by a
/// human looking at it (m23-g1: no gate here sees a pixel it cannot stage).
///
/// Reachable from the piano-roll header (a HUMANIZE chip, both densities) and
/// the arrange clip context menu (Pro only, sp-c — beside "Quantize…", and like
/// it, only on a MIDI clip). Thin over `HumanizeModel`: all state lives there;
/// the view routes Apply straight to `ProjectStore.humanizeClipNotes` — the SAME
/// method the `clip.humanize` wire uses. UI-ONLY: this item adds NO control
/// command and NO MCP tool, because the capability already has both (the
/// m10-c/sp-b pure-view rule — `allCommands` and MCP counts are unchanged).
///
/// **A TAKE-COMP MEMBER IS REFUSED HERE, IN PLACE, WITH THE REASON (m25-c-2).**
/// It used to be offered: `canApply` was blind to comp membership, so Apply fired,
/// `humanizeClipNotes` threw `clipInTakeGroup`, a `try?` ate it and this panel
/// closed having done nothing. The model now asks the store BEFORE the press
/// (`HumanizeModel.targetRefusal`), Apply is dark, `PanelRefusalLine` prints the
/// store's sentence, and the panel STAYS OPEN — the message and the surface it
/// sits on must survive the press together or the message is a flash at an empty
/// screen. The entry is NOT hidden the way an audio clip's is, because comp
/// membership is state the user can change and the piano-roll HUMANIZE chip is
/// ungated: hiding would have to happen in two places and would explain nothing.
///
/// **NO SIMPLE/PRO CHIP.** The panel is two amounts and one button in every
/// density — there is no Pro delta to expose, and `QuantizePanel` states the
/// rule for exactly this case: a chip whose modes coincide is a do-nothing
/// toggle (docs/DESIGN-LANGUAGE.md "Panels"). **NO RE-ROLL BUTTON either** —
/// `humanizeClipNotes` does not coalesce and a re-run COMPOUNDS the jitter, so
/// Apply is a single decisive action that closes the panel (the reasoning is on
/// `HumanizeModel`, and it is `applyQuantize`'s reasoning verbatim).
///
/// NO VIOLET anywhere — humanize is standard editing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3). Cyan marks only earned active state (the
/// SF Mono readouts, the Apply button).
struct HumanizePanel: View {
    @Bindable var model: HumanizeModel
    /// Applies the amounts + closes (wired to `ProjectStore.humanizeClipNotes`).
    var onApply: () -> Void
    var onClose: () -> Void

    /// The panel's stable id — the `QuantizePanel.panelID` idiom. There is no
    /// density store slot behind it (this panel has no Simple/Pro chip); it
    /// exists so captures and any future layout state have ONE name to use.
    static let panelID = "humanize"

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: 380)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    private var card: some View {
        // The card HUGS its content (no greedy outer ScrollView) — two rows and a
        // button should not render as a tall empty box (the QuantizePanel rule).
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(DAWTheme.hairline)
            if model.targetIsMIDI {
                blurb
                timingRow
                velocityRow
                applyButton
            } else {
                audioNote
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("HUMANIZE")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetClipName)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the humanize panel")
        }
    }

    /// One sentence saying what the panel DOES, in the beginner's words — the
    /// inverse of Quantize, which is the only reference point most users have.
    private var blurb: some View {
        Text("Nudges each note slightly off the grid and varies how hard it's played, so the part sounds played rather than programmed.")
            .font(.system(size: 10.5))
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Timing

    private var timingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("TIMING", trailing: AnyView(readout(model.timingReadout)))
            ValueSlider(value: model.timingBeats,
                        range: HumanizeModel.timingBounds,
                        onChange: { model.timingBeats = $0 })
            caption(model.timingDescription)
        }
    }

    // MARK: - Velocity

    private var velocityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("VELOCITY", trailing: AnyView(readout(model.velocityReadout)))
            // The store takes an INTEGER velocity spread, so the slider rounds on
            // the way in rather than letting the view hold a fractional value the
            // domain would silently truncate.
            ValueSlider(value: Double(model.velocityRange),
                        range: Double(HumanizeModel.velocityBounds.lowerBound)
                            ... Double(HumanizeModel.velocityBounds.upperBound),
                        onChange: { model.velocityRange = Int($0.rounded()) })
            caption(model.velocityDescription)
        }
    }

    // MARK: - Apply

    private var applyButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onApply) {
                Text("APPLY HUMANIZE")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(model.canApply ? DAWTheme.background : DAWTheme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(model.canApply ? DAWTheme.playback : DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .glow(DAWTheme.playback, radius: 6,
                          intensity: model.canApply ? 0.4 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!model.canApply)
            .help("Apply the human feel to this part (one undo step)")
            // WHY THE BUTTON IS DARK — one reason at a time, most fundamental
            // first (m25-c-2). A store refusal outranks the no-op caption because
            // raising a slider cannot help: the obstacle is the clip, not the
            // amounts, and printing both would send the user to do the useless
            // one. Amber (PanelRefusalLine) for an obstacle you must leave the
            // panel to clear; dim caption for one you can fix right here.
            if let refusal = model.refusalMessage {
                PanelRefusalLine(message: refusal)
            } else if model.isNoOp {
                // Both amounts at zero is a LEGAL no-op in the store — it would
                // spend an undo step and change nothing. Say why the button is
                // dark rather than letting it look broken.
                caption("Both amounts are zero — raise one to change anything.")
            }
        }
    }

    // MARK: - Audio note (unreachable target)

    /// Humanize is MIDI-only, and the arrange menu entry does not exist on an
    /// audio clip — so this is a backstop, not a normal path. It still explains
    /// rather than showing a dead panel, because `debug` staging and any future
    /// entry point can land here.
    private var audioNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12)).foregroundStyle(DAWTheme.signal)
            Text("Humanize shapes the notes of an instrument part. This is an audio recording, so it already has whatever feel was played.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Small helpers

    private func rowLabel(_ text: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            if let trailing { trailing }
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.playback)
    }

    /// Prose, not a number — SF Pro, dim, the panel's explanatory voice.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(DAWTheme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
