import SwiftUI
import DAWCore
import DAWAppKit

/// **CHOP TO PADS (m39-pads)** — the door onto `clip.sliceToSampler`, which
/// until now had none: measured 2026-09-19, `grep -rli 'sliceToSampler'
/// Sources/DAWApp Sources/DAWAppKit` returned ZERO files. An AI agent could chop
/// a record into 53 playable pads over MCP and a human could not reach it at all.
///
/// A centered dark-glass card mounted in the WINDOW CONTENT rather than a
/// popover, so `debug.captureUI` can photograph it (the captureUI law) — the
/// `QuantizePanel` / `SamplerEditorOverlay` precedent, verbatim.
///
/// ## The density split
///
/// **Simple** = what the mode is, how finely, and the mute decision.
/// **Pro** adds the pad ceiling, where pad 1 sits, and the head.
///
/// ⚠️ **THE MUTE TOGGLE IS IN *SIMPLE*, AND THAT IS THE POINT OF PUTTING IT
/// THERE.** It is the only control on this card whose absence makes the FIRST
/// chop sound wrong (+6.0 LU and comb-filtered, measured), and Simple mode is
/// exactly where the user who has never chopped anything is standing. Hiding the
/// honesty control behind a Pro toggle would put the explanation on the far side
/// of the confusion it exists to prevent.
struct ChopToPadsPanel: View {
    var model: PadGridModel
    var densityStore: PanelDensityStore
    var onClose: () -> Void
    var onChop: () -> Void

    static let panelID = "chopToPads"

    private var isPro: Bool { densityStore.density(forPanel: Self.panelID) == .pro }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sourceLine
            modeRow
            amountRow
            if isPro { proRow }
            muteRow
            if let refusal = model.blockingRefusal, refusal != .busy {
                PanelRefusalLine(message: refusal.message)
            }
            // ⭐ THE STORE'S OWN SENTENCE, VERBATIM. The chop REFUSES rather
            // than truncating when a clip yields more boundaries than the
            // ceiling, and `SliceToSamplerPlan.validateSliceCount` already
            // writes a sentence NAMING BOTH NUMBERS ("would make 53 pads, over
            // the maxSlices limit of 32") and listing four ways out. Rewording
            // that into "Chop failed" would throw away the only two numbers the
            // user needs to act.
            if let stored = model.lastRefusalForHumans {
                PanelRefusalLine(message: stored)
            }
            footer
        }
        .padding(18)
        .frame(width: 430)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
        .explainable(.padGrid)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("CHOP TO PADS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer(minLength: 8)
            SimpleProToggle(
                store: densityStore, panelID: Self.panelID,
                help: "Simple picks where the cuts go. Pro sets the pad ceiling, "
                    + "where pad 1 sits, and whether the lead-in becomes a pad.")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close without chopping.")
        }
    }

    /// What is about to be cut up — named, because a chop replaces a keymap and
    /// the user must be able to see they picked the clip they meant.
    private var sourceLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(model.chopSource == nil ? DAWTheme.textFaint : DAWTheme.playback)
            Text(model.chopSource.map { "“\($0.clipName)” on \($0.trackName)" }
                 ?? "Nothing selected")
                .font(.system(size: 11))
                .foregroundStyle(model.chopSource == nil
                                 ? DAWTheme.textFaint : DAWTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Simple controls

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Where to cut")
            HStack(spacing: 0) {
                ForEach(SliceBoundaryMode.allCases, id: \.self) { mode in
                    let isOn = model.chop.mode == mode
                    Button { model.chop.mode = mode } label: {
                        Text(PadChopSettings.modeLabel(mode).uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(isOn ? DAWTheme.background : DAWTheme.textDim)
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                            .background(isOn ? DAWTheme.playback : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .help(PadChopSettings.modeHelp(mode))
                }
            }
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            Text(PadChopSettings.modeHelp(model.chop.mode))
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⭐ ONE ROW, THREE FACES — the control shown is the one the chosen mode
    /// actually reads. `SliceToSamplerSettings` ignores `sensitivity` outside
    /// `.transients` and `divisions` outside `.divisions`; drawing all three at
    /// once would invite the user to turn a knob the chop will not look at,
    /// which is the affordance-lies shape one row down from a refusal.
    @ViewBuilder
    private var amountRow: some View {
        switch model.chop.mode {
        case .transients:
            sliderRow(label: "How many hits to catch",
                      readout: String(format: "%.0f%%", model.chop.sensitivity * 100),
                      value: model.chop.sensitivity, range: 0...1,
                      help: "Higher finds quieter hits — and more pads.") {
                model.chop.sensitivity = $0
            }
        case .divisions:
            sliderRow(label: "Pieces",
                      readout: "\(model.chop.divisions)",
                      value: Double(model.chop.divisions),
                      range: Self.divisionsRange,
                      help: "The clip is cut into this many equal pieces.") {
                model.chop.divisions = Int($0.rounded())
            }
        case .grid:
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Cut every")
                HStack(spacing: 0) {
                    ForEach(Self.gridChoices, id: \.beats) { choice in
                        let isOn = abs(model.chop.gridBeats - choice.beats) < 0.0001
                        Button { model.chop.gridBeats = choice.beats } label: {
                            Text(choice.label)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(isOn ? DAWTheme.background : DAWTheme.textDim)
                                .frame(height: 22)
                                .frame(maxWidth: .infinity)
                                .background(isOn ? DAWTheme.playback : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            }
        }
    }

    /// ⚠️ Derived from `SliceToSamplerSettings.divisionsRange` — the domain's own
    /// clamp — so this slider cannot offer a value the settings init would
    /// silently pull back.
    private static let divisionsRange: ClosedRange<Double> =
        Double(SliceToSamplerSettings.divisionsRange.lowerBound)
            ... Double(SliceToSamplerSettings.divisionsRange.upperBound)

    private static let gridChoices: [(label: String, beats: Double)] = [
        ("1/16", 0.25), ("1/8", 0.5), ("1/4", 1), ("1/2", 2), ("BAR", 4),
    ]

    // MARK: - Pro controls

    private var proRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(label: "Most pads to make",
                      readout: "\(model.chop.maxSlices)",
                      value: Double(model.chop.maxSlices),
                      range: 1...Double(SliceToSamplerSettings.maxSlicesHardCap),
                      help: "The chop REFUSES rather than dropping slices when a clip "
                          + "needs more pads than this. \(SliceToSamplerSettings.maxSlicesHardCap) "
                          + "is the ceiling — six banks.") {
                model.chop.maxSlices = Int($0.rounded())
            }
            sliderRow(label: "Pad 1 plays note",
                      readout: Fundamental.noteName(midiNote: model.chop.baseNote),
                      value: Double(model.chop.baseNote), range: 0...111,
                      // ⚠️ NO OCTAVE LETTER IN THIS SENTENCE, ON PURPOSE. The
                      // readout above already names the note through the app's
                      // ONE namer (`Fundamental.noteName`, scientific pitch, so
                      // 36 reads "C2"), while the MPC world calls that same
                      // note C1. Writing a second octave name into prose is how
                      // a panel ends up disagreeing with its own readout.
                      help: "Note 36 is the MPC's own pad-1 note, and it is where every "
                          + "drum kit puts its kick. Move it only to sit beside an "
                          + "existing keymap.") {
                model.chop.baseNote = Int($0.rounded())
            }
            // ⭐ LIVE IN EVERY MODE, DIM WHERE IT CANNOT REACH THE CHOP (m33-d).
            // "Equal pieces" and "On the beat" always start pad 1 at the clip's
            // start, so the flag is inert there — but the wire still accepts it,
            // and "tick it, then switch to Every hit" must keep working, so it is
            // dimmed and explained rather than disabled or hidden (DESIGN-LANGUAGE,
            // "a setting that cannot reach the sound stays live, goes dim, and
            // says so"). Both read the domain's one rule via `leadInIsEffective`.
            checkRow(isOn: model.chop.includeHead,
                     label: PadChopSettings.leadInLabel,
                     help: model.chop.leadInHelp,
                     dimmed: !model.chop.leadInIsEffective) {
                model.chop.includeHead.toggle()
            }
            if let note = model.chop.leadInInertNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(model.chop.leadInHelp)
            }
        }
    }

    // MARK: - The mute decision

    /// ⭐⭐ **THE ONE CONTROL THIS CARD EXISTS TO MAKE VISIBLE.** See
    /// `PadGridModel.muteSourceTrack` for the three options and why this is the
    /// only honest one.
    private var muteRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            checkRow(isOn: model.muteSourceTrack, label: model.muteLabel,
                     help: PadGridModel.muteExplanation) {
                model.muteSourceTrack.toggle()
            }
            Text(PadGridModel.muteExplanation)
                .font(.system(size: 10))
                .foregroundStyle(model.muteSourceTrack ? DAWTheme.textDim : DAWTheme.record)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Undo puts everything back.")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textFaint)
            Spacer(minLength: 0)
            Button(action: onChop) {
                HStack(spacing: 6) {
                    if model.isChopping {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text(model.isChopping ? "CHOPPING…" : "CHOP")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(canChop ? DAWTheme.background : DAWTheme.textFaint)
                .frame(height: 26)
                .padding(.horizontal, 18)
                .background(canChop ? DAWTheme.playback : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(canChop ? Color.clear : DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canChop)
            .help(model.blockingRefusal?.message
                  ?? "Cut this recording into pads you can play.")
        }
    }

    private var canChop: Bool { model.blockingRefusal == nil }

    // MARK: - Shared bits

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(DAWTheme.textDim)
    }

    private func sliderRow(label: String, readout: String, value: Double,
                           range: ClosedRange<Double>, help: String,
                           onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                fieldLabel(label)
                Spacer(minLength: 8)
                // SF Mono for every numeric readout (Foundations).
                Text(readout)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
            }
            ValueSlider(value: value, range: range, onChange: onChange)
                .frame(height: 18)
        }
        .help(help)
    }

    /// `dimmed` draws the row in `textFaint` with no accent — still clickable.
    /// It is the "cannot reach the sound" state, not a disabled one.
    private func checkRow(isOn: Bool, label: String, help: String, dimmed: Bool = false,
                          action: @escaping () -> Void) -> some View {
        let accent = dimmed ? DAWTheme.textFaint : DAWTheme.playback
        return Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? accent : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(isOn ? accent : DAWTheme.textFaint, lineWidth: 1))
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(DAWTheme.background)
                        }
                    }
                    .frame(width: 13, height: 13)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(dimmed ? DAWTheme.textFaint : DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
