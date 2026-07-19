import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DAWCore
import DAWAppKit
import AIServices

/// The Voice panel (m10-p-5): named local voice DATASETS (the user's own
/// training recordings), the voice-engine (RVC sidecar) banner, the facade
/// voice list, and the Train affordance — the third violet AI surface docked
/// on the RIGHT of the Arrange workspace (the Sketchpad/ClipFix idiom, 340 pt,
/// faint violet edge). Violet is correct everywhere here: a voice model is
/// AI-produced identity, and conversion output is AI-generated audio.
///
/// Follows the m17-f F4 compression law: pinned header + ONE internal
/// vertical scroller; content lists are plain stacks. **Density: COINCIDENT
/// by design** — the panel renders identically in Simple and Pro, so it
/// carries no SIMPLE/PRO chip (the "never a do-nothing toggle" rule).
///
/// All state lives headless in `DAWAppKit.VoicePanelModel` (the
/// `SketchpadModel` precedent); this view owns only the sidecar status-poll
/// cadence and the NSOpenPanel for sample imports. The panel speaks USER
/// copy (the model's banner mapping), never wire-speak, and carries the
/// standing own-voice-only policy lines verbatim.
struct VoicePanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: VoicePanelModel

    @State private var newVoiceName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let banner = model.banner { bannerView(banner) }
                    voicesSection
                    Divider().overlay(DAWTheme.hairline)
                    datasetsSection
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(DAWTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)   // the AI surface's violet edge
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .explainable(.voicePanel)
        // Sidecar health poll (the SketchpadView cadence): immediate on
        // appear, ~2 s while a boot is in progress so the truthful elapsed
        // count visibly ticks (M10-b), looser at rest.
        .task {
            var wasHealthy = false
            while !Task.isCancelled {
                await model.refreshSidecar()
                let isHealthy = model.sidecarStatus?.state == .healthy
                if isHealthy, !wasHealthy {
                    await model.refreshVoices()
                    model.rescanDatasets()
                }
                wasHealthy = isHealthy
                let starting = model.banner?.tone == .progress
                try? await Task.sleep(nanoseconds: starting ? 2_000_000_000 : 8_000_000_000)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
            Text("VOICE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer()
            Button { app.showVoicePanel = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the Voice panel")
        }
    }

    // MARK: - Sidecar banner (user copy — the model owns the mapping)

    private func bannerView(_ banner: VoicePanelBanner) -> some View {
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
                Button { Task { await model.startSidecar() } } label: {
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
                // The Start affordance's disabled in-progress twin (M10-b):
                // never re-offer a Start for a boot already in flight.
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

    // MARK: - Facade voice list

    private var voicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("VOICES")
            if let error = model.voicesError {
                errorStrip(error)
            }
            if model.voices.isEmpty {
                Text(model.sidecarStatus?.state == .healthy
                     ? "No voices yet — build one below, then train it."
                     : "Start the voice engine to see the available voices.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.voices, id: \.id) { descriptor in
                        voiceRow(descriptor)
                    }
                }
            }
        }
    }

    private func voiceRow(_ descriptor: VoiceDescriptor) -> some View {
        let smoke = VoicePanelModel.isSmokeTarget(descriptor)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: smoke ? "waveform.path" : "person.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(smoke ? DAWTheme.textDim : DAWTheme.ai)
                Text(descriptor.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                if smoke {
                    // The reserved "base" entry, labeled for what it is: the
                    // pipeline smoke target, never a real voice.
                    tag("PIPELINE TEST", color: DAWTheme.textDim)
                }
                Spacer()
                stateChip(descriptor.state)
            }
            if smoke, let note = descriptor.note {
                Text(note)   // the facade's own honesty note, verbatim
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func stateChip(_ state: String) -> some View {
        let (label, color): (String, Color) = switch state {
        case "ready": ("READY", DAWTheme.signal)
        case "needsConversion": ("NEEDS PREP", DAWTheme.record)
        default: ("INCOMPLETE", DAWTheme.textDim)
        }
        return tag(label, color: color)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Local datasets

    private var datasetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("MY VOICE DATA")
            policyBlock
            if let error = model.datasetError {
                errorStrip(error)
            }
            ForEach(model.localVoices) { dataset in
                datasetCard(dataset)
            }
            newVoiceRow
            Text(VoicePanelModel.recordHint)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The standing own-voice-only policy copy, verbatim (m10-p-5: a legal/
    /// policy constraint, not decoration). Neutral quiet chrome — policy text
    /// is not AI content, so no violet here (Rule 3).
    private var policyBlock: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(VoicePanelModel.policyLine)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(VoicePanelModel.policyDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func datasetCard(_ dataset: VoiceDataset) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.ai)
                Text(dataset.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Text("\(dataset.samples.count) \(dataset.samples.count == 1 ? "sample" : "samples")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                Spacer()
                Button { model.deleteVoice(named: dataset.name) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Remove this voice's recordings (a trained voice model is unaffected)")
            }

            if dataset.samples.isEmpty {
                Text("No recordings yet — add audio files, or add a selected clip.")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dataset.samples) { sample in
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 8))
                                .foregroundStyle(DAWTheme.signal)
                            Text(sample.name)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(DAWTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button { model.removeSample(named: sample.name, fromVoice: dataset.name) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(DAWTheme.textDim)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this sample from the set")
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                smallChipButton("plus", "ADD AUDIO…") { pickSamples(for: dataset.name) }
                    .help("Copy audio files into this voice's training set — the originals stay where they are")
                smallChipButton("waveform.badge.plus", "ADD SELECTED CLIP") {
                    if let sel = selectedAudioClipID {
                        model.addClipAsSample(clipID: sel, intoVoice: dataset.name)
                    }
                }
                .disabled(selectedAudioClipID == nil)
                .opacity(selectedAudioClipID == nil ? 0.45 : 1)
                .help(selectedAudioClipID == nil
                      ? "Select an audio clip in the timeline first (a MIDI clip has no recording to add)"
                      : "Copy the selected clip's recording into this voice's training set")
                Spacer()
            }

            trainAffordance(dataset)
        }
        .padding(9)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.ai.opacity(0.18), lineWidth: 1))
    }

    /// The Train affordance + its honest state machine. `.progress` renders
    /// indeterminate unless a real fraction is fed (m10-p-6) — never a fake
    /// percentage; `.comingSoon` is the designed 501 state.
    @ViewBuilder
    private func trainAffordance(_ dataset: VoiceDataset) -> some View {
        switch model.trainState(forVoice: dataset.name) {
        case .idle:
            let armed = !dataset.samples.isEmpty && model.sidecarStatus?.state == .healthy
            Button { Task { await model.train(voiceNamed: dataset.name) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("TRAIN")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                }
                .foregroundStyle(armed ? Color.black : DAWTheme.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(armed ? DAWTheme.ai : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(armed ? Color.clear : DAWTheme.hairline, lineWidth: 1))
                .glow(armed ? DAWTheme.ai : .clear, radius: 6, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!armed)
            .explainable(.voiceTrain)
            .help(armed ? "Train this voice from its recordings"
                        : "Add at least one recording and start the voice engine first")
        case .submitting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(DAWTheme.ai)
                Text("TRAINING…")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.ai)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        case .progress(let fraction, let detail):
            // The shipped-but-unfed progress slot (p-6 feeds it): a real
            // fraction renders a violet bar; nil renders honest indeterminate.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(DAWTheme.ai)
                    Text(detail?.uppercased() ?? "TRAINING — IN PROGRESS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.ai)
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(DAWTheme.ai)
                        .glow(DAWTheme.ai, radius: 4, intensity: 0.4)
                }
            }
        case .comingSoon(let message):
            // The designed honest 501 state: headline + the facade's teaching
            // message verbatim, on a violet wash (this IS an AI feature's
            // roadmap truth, not an error).
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.ai)
                VStack(alignment: .leading, spacing: 3) {
                    Text(VoicePanelModel.trainingComingSoonHeadline)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { model.dismissTrainState(forVoice: dataset.name) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(DAWTheme.ai.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.ai.opacity(0.3), lineWidth: 1))
        case .failed(let message):
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.clip)
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.dismissTrainState(forVoice: dataset.name) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(DAWTheme.clip.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1))
        }
    }

    private var newVoiceRow: some View {
        HStack(spacing: 6) {
            TextField("New voice name…", text: $newVoiceName)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(DAWTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
                .onSubmit { createVoice() }
            Button { createVoice() } label: {
                Text("+ NEW VOICE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Create a new named voice to collect training recordings for")
        }
    }

    // MARK: - Shared bits

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
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

    private func smallChipButton(
        _ systemName: String, _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func createVoice() {
        if model.createVoice(named: newVoiceName) {
            newVoiceName = ""
        }
    }

    /// The timeline's selected clip when it's a plain AUDIO clip (the
    /// ContentView `selectedAudioClip` rule) — the "+ ADD SELECTED CLIP"
    /// source. MIDI selections read nil, so the chip disables honestly.
    private var selectedAudioClipID: UUID? {
        guard let id = app.selectedClipID else { return nil }
        for track in app.store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }), !clip.isMIDI {
                return clip.id
            }
        }
        return nil
    }

    /// NSOpenPanel → copy-import into the named voice's dataset (the model's
    /// copy-never-move law; the exportSong NSSavePanel precedent).
    private func pickSamples(for voiceName: String) {
        let panel = NSOpenPanel()
        panel.title = "Add Voice Recordings"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        _ = model.importSamples(panel.urls, intoVoice: voiceName)
    }
}
