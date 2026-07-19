import SwiftUI
import DAWCore
import DAWAppKit
import AIServices

/// The "Convert to Voice…" sheet (m10-p-5): a centered dark-glass modal over
/// a dimmed scrim (the NAMED in-window pattern — Settings / Instrument Picker
/// / Quantize / Undo History / Effect Editor — so `debug.captureUI` snapshots
/// it), opened from an audio clip's context menu. VIOLET is the through-line:
/// picking a voice and converting produce AI-generated audio (Rule 3).
///
/// Conversion is BLOCKING seconds-class (m10-p-2: ~37x real time) — the sheet
/// shows a brief CONVERTING… busy state, not job-polling machinery (the
/// settled m10-p-5 difference from the ClipFix panel). The convert rides the
/// SAME store/client seams as the wire's `vc.convertVocals` clipId-form
/// (through `VoicePanelModel.convertClip`): one undoable edit, a new violet
/// AI track at the clip's own beat. After a "base" conversion the result
/// state carries the `realConversion:false` truth + the facade's note,
/// verbatim — never dressed up as a real voice conversion.
struct VoiceConvertSheet: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: VoicePanelModel
    /// The source audio clip (resolved by ContentView from the live store).
    var clipID: UUID
    var clipName: String
    var onClose: () -> Void

    @State private var selectedVoiceID: String?
    @State private var pitchSemitones = 0

    /// The facade's own pitch bounds (`[-24, 24]` — see `VoiceConvertRequest`).
    private static let pitchRange = -24...24

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { if !model.isConverting { onClose() } }
            card
                .frame(width: 400)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
        .task {
            // Fresh state + a live voice list on open; pre-pick the only
            // sensible default when exactly one voice exists.
            model.resetConvertState()
            await model.refreshSidecar()
            if model.sidecarStatus?.state == .healthy {
                await model.refreshVoices()
            }
            if selectedVoiceID == nil, model.voices.count == 1 {
                selectedVoiceID = model.voices.first?.id
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            if let outcome = model.lastConversion {
                resultView(outcome)
            } else {
                composer
            }
        }
        .padding(14)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)   // the AI surface's violet edge
        )
        .explainable(.voiceConvert)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
            Text("CONVERT TO VOICE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(clipName)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .disabled(model.isConverting)
            .help("Close without converting")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = model.banner { bannerStrip(banner) }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("VOICE")
                if model.voices.isEmpty {
                    Text(model.sidecarStatus?.state == .healthy
                         ? "No voices available yet."
                         : "Start the voice engine to load the voice list.")
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.textDim)
                } else {
                    VStack(spacing: 5) {
                        ForEach(model.voices, id: \.id) { descriptor in
                            voiceChoiceRow(descriptor)
                        }
                    }
                }
            }

            pitchRow

            Text(VoicePanelModel.policyLine)   // the standing policy, here too
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.convertError {
                errorStrip(error)
            }

            convertButton
        }
    }

    /// A selectable voice row — the AI parameter, so the picked row is
    /// VIOLET-lit (the ClipFix STRENGTH precedent; cyan stays reserved for
    /// playback/active state).
    private func voiceChoiceRow(_ descriptor: VoiceDescriptor) -> some View {
        let smoke = VoicePanelModel.isSmokeTarget(descriptor)
        let selected = selectedVoiceID == descriptor.id
        return Button {
            selectedVoiceID = descriptor.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? DAWTheme.ai : DAWTheme.textDim)
                    Text(descriptor.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .lineLimit(1)
                    if smoke {
                        Text("PIPELINE TEST")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(DAWTheme.textDim)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(DAWTheme.textDim.opacity(0.5), lineWidth: 1))
                    }
                    Spacer()
                }
                if smoke {
                    // Honesty up front, BEFORE converting: base proves the
                    // pipeline, it is not a real voice.
                    Text("Proves the pipeline works — the result is not a real voice conversion.")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(selected ? DAWTheme.ai.opacity(0.12) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isConverting)
    }

    /// Pitch shift in semitones — a numeric readout, so SF Mono cyan (the
    /// Sketchpad length-stepper rule: numbers are cyan, not violet).
    private var pitchRow: some View {
        HStack(spacing: 10) {
            fieldLabel("PITCH")
            Text("optional — shifts the voice up or down")
                .font(.system(size: 8.5))
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            stepButton("minus") { pitchSemitones = max(Self.pitchRange.lowerBound, pitchSemitones - 1) }
            Text(pitchSemitones > 0 ? "+\(pitchSemitones) st" : "\(pitchSemitones) st")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.5)
                .frame(width: 52)
            stepButton("plus") { pitchSemitones = min(Self.pitchRange.upperBound, pitchSemitones + 1) }
        }
        .disabled(model.isConverting)
    }

    private func stepButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textPrimary)
                .frame(width: 22, height: 20)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var canConvert: Bool {
        selectedVoiceID != nil && model.sidecarStatus?.state == .healthy && !model.isConverting
    }

    private var convertButton: some View {
        Button {
            guard let voiceID = selectedVoiceID else { return }
            Task {
                if await model.convertClip(
                    clipID: clipID, voiceID: voiceID, pitchSemitones: pitchSemitones) {
                    // Success keeps the sheet open on the honest result state
                    // (realConversion/note); the violet track already landed.
                }
            }
        } label: {
            HStack(spacing: 7) {
                if model.isConverting {
                    ProgressView().controlSize(.small).tint(DAWTheme.textDim)
                    Text("CONVERTING…")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                } else {
                    Image(systemName: "person.wave.2.fill")
                    Text("CONVERT")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                }
            }
            .foregroundStyle(canConvert ? Color.black : DAWTheme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(canConvert ? DAWTheme.ai : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .glow(canConvert ? DAWTheme.ai : .clear, radius: 8, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!canConvert)
        .help("Convert this clip's recording to the picked voice — a new track lands beside the original")
    }

    // MARK: - Result (the honest landing state)

    private func resultView(_ outcome: VoiceConvertOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 5, intensity: 0.6)
                Text("Converted → \"\(outcome.trackName)\"")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("The new track landed at the clip's own spot — one undo removes it.")
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !outcome.realConversion {
                // The base smoke target's truth, never hidden: amber honesty
                // strip + the facade's own note verbatim.
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.record)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not a real voice conversion")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DAWTheme.textPrimary)
                        if let note = outcome.note {
                            Text(note)
                                .font(.system(size: 9))
                                .foregroundStyle(DAWTheme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .background(DAWTheme.record.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(DAWTheme.record.opacity(0.35), lineWidth: 1))
            }
            Button { onClose() } label: {
                Text("DONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shared bits

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
    }

    private func bannerStrip(_ banner: VoicePanelBanner) -> some View {
        let tint: Color = switch banner.tone {
        case .neutral: DAWTheme.textDim
        case .warning: DAWTheme.record
        case .error: DAWTheme.clip
        case .progress: DAWTheme.playback
        }
        return HStack(spacing: 8) {
            if banner.tone == .progress {
                ProgressView().controlSize(.small).tint(tint)
            } else {
                Image(systemName: banner.tone == .error ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
            }
            Text(banner.message)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if banner.canStart, !model.isStartingSidecar {
                Button {
                    Task {
                        await model.startSidecar()
                        if selectedVoiceID == nil, model.voices.count == 1 {
                            selectedVoiceID = model.voices.first?.id
                        }
                    }
                } label: {
                    Text("START")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.record)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(DAWTheme.record.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if banner.tone == .progress || model.isStartingSidecar {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).tint(tint)
                    Text("STARTING…")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(10)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3), lineWidth: 1))
    }

    private func errorStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.clip)
            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(DAWTheme.clip.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1))
    }
}
