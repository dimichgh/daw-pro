import AVFoundation
import SwiftUI
import DAWCore
import DAWAppKit

/// The AI Sketchpad panel (M6 iii-b): the prompt/lyrics composer, the duration
/// stepper, the sidecar banner, and the candidate list with per-candidate
/// status/shimmer/preview/import. Docked on the right of the Arrange workspace
/// so an imported take's new violet clip is visible in the timeline beside it.
///
/// VIOLET IS THE THROUGH-LINE: everything here is AI-generated, so the header,
/// the Generate button, every candidate accent, and the imported badge all carry
/// `DAWTheme.ai` ("violet always means AI-generated", docs/DESIGN-LANGUAGE.md).
///
/// All state + transitions live in the headless `SketchpadModel`
/// (Sources/DAWAppKit); this view is thin over it. It owns only the two things
/// the model must not: the 1 s poll timer (a `.task` loop, active only while a
/// candidate is still generating) and the audio PREVIEW player (an
/// `AVAudioPlayer`, off the engine).
struct SketchpadView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SketchpadModel

    @State private var preview = SketchpadPreview()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = model.banner { bannerView(banner) }
            composer
            Divider().overlay(DAWTheme.hairline)
            candidatesSection
        }
        .padding(14)
        .frame(width: 340)
        .background(DAWTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)   // a faint violet edge — this is the AI surface
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Sidecar health poll: fires immediately on appear (so the banner +
        // Generate gate are live right away), then keeps polling — tightened
        // to ~2s while a boot is in progress (M10-b: so elapsed/phase tick
        // visibly instead of the panel looking stuck) and a looser cadence
        // otherwise, since the sidecar rarely flips state on its own once
        // settled.
        .task {
            while !Task.isCancelled {
                await app.refreshSketchpadSidecar()
                let starting = model.banner?.isInProgress == true
                try? await Task.sleep(nanoseconds: starting ? 2_000_000_000 : 8_000_000_000)
            }
        }
        // Poll loop: only fires while a candidate still needs polling; the model
        // owns each transition, the view owns the cadence.
        .task {
            while !Task.isCancelled {
                if model.hasActiveCandidates { await model.refresh() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // A row vanishing (dismiss/import) must not leave a preview playing.
        .onChange(of: model.candidates.map(\.id)) { _, ids in
            if let playing = preview.playingID, !ids.contains(playing) { preview.stop() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.8)
            Text("AI SKETCHPAD")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer()
            Button { app.showSketchpad = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the Sketchpad")
        }
    }

    private func bannerView(_ banner: SketchpadBanner) -> some View {
        // `.progress` (M10-b, the "starting" boot) is cyan — DESIGN-LANGUAGE's
        // active-state accent — never violet: this banner is infrastructure
        // status, not an AI-identity surface.
        let tint: Color = switch banner.tone {
        case .neutral: DAWTheme.textDim
        case .warning: DAWTheme.record
        case .error: DAWTheme.clip
        case .progress: DAWTheme.playback
        }
        return HStack(spacing: 8) {
            if banner.isInProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
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
            if banner.canStartSidecar {
                Button { Task { await app.startSketchpadSidecar() } } label: {
                    Text("START")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.record)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.record.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if banner.isInProgress {
                // The Start affordance's disabled, in-progress twin — same
                // slot in the layout, but a spinner + STARTING… instead of a
                // clickable button (a boot already in flight is never
                // re-offered a Start).
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
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

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("STYLE")
                editor(text: $model.prompt, height: 54,
                       placeholder: "e.g. 80s synth-pop, anthemic, driving bass")
            }
            .explainable(.sketchpadStyle)

            // The AI Lyrics Workshop — writes/refines bracketed lyrics tied to the
            // project key/tempo, then applies them into the lyrics editor below.
            LyricsWorkshopView(model: app.lyricsWorkshop,
                               expanded: Bindable(app).showLyricsWorkshop)
                .explainable(.lyricsWorkshop)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    fieldLabel("LYRICS")
                    Spacer()
                    Text("optional — blank = instrumental")
                        .font(.system(size: 8.5))
                        .foregroundStyle(DAWTheme.textDim)
                }
                SketchpadSectionButtons { section in
                    // SwiftUI's TextEditor doesn't surface its caret; the helper
                    // appends the tag at the end (the common flow). The model still
                    // supports arbitrary cursors (headless tests cover them).
                    model.lyricsCursor = model.lyrics.count
                    model.insertSection(section)
                }
                editor(text: $model.lyrics, height: 92,
                       placeholder: "[verse]\n…\n[chorus]\n…")
            }
            .explainable(.sketchpadLyrics)

            durationStepper
                .explainable(.sketchpadLength)
            generateButton
                .explainable(.sketchpadGenerate)
            templateButton
                .explainable(.sketchpadTemplate)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
    }

    private func editor(text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .frame(height: height)
        .background(DAWTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private var durationStepper: some View {
        HStack(spacing: 10) {
            fieldLabel("LENGTH")
            Spacer()
            stepButton("minus") { model.nudgeDuration(by: -SketchpadModel.durationStep) }
            Text("\(Int(model.durationSeconds))s")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .glow(DAWTheme.playback, radius: 4, intensity: 0.5)
                .frame(width: 42)
            stepButton("plus") { model.nudgeDuration(by: SketchpadModel.durationStep) }
        }
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

    private var generateButton: some View {
        Button { Task { await model.generate() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                Text("GENERATE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.5)
            }
            .foregroundStyle(model.canGenerate ? Color.black : DAWTheme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(model.canGenerate ? DAWTheme.ai : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .glow(model.canGenerate ? DAWTheme.ai : .clear, radius: 8, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!model.canGenerate)
    }

    /// The instant, keyless fallback beside GENERATE — subordinate (neutral, not
    /// violet: a song SCAFFOLD is not AI-generated audio) and quieter. Applies a
    /// default-genre `applySongSkeleton`, which flips the project to having content
    /// (so the onboarding `generate` step advances via `projectGainedContent`) with
    /// no wait and no key. The Sketchpad lives in the Arrange workspace, so the new
    /// tracks land in view beside the panel.
    private var templateButton: some View {
        Button { _ = try? app.store.applySongSkeleton(genre: "pop") } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("USE A TEMPLATE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .foregroundStyle(DAWTheme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Start instantly from a template — no waiting, no key needed")
    }

    // MARK: - Candidates

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("CANDIDATES")
            if model.candidates.isEmpty {
                Text("Generated takes appear here. Preview, then import the one you want.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        // Newest on top — the take you just asked for.
                        ForEach(model.candidates.reversed()) { candidate in
                            SketchpadCandidateRow(
                                candidate: candidate,
                                isPlaying: preview.playingID == candidate.id,
                                onPlayToggle: { path in preview.toggle(id: candidate.id, path: path) },
                                onImport: { Task { await model.importCandidate(candidate.id) } },
                                onDismiss: { preview.stopIf(candidate.id); model.dismissCandidate(candidate.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The [Verse] [Chorus] [Bridge] [Outro] insert row for the lyrics editor.
private struct SketchpadSectionButtons: View {
    var onInsert: (SketchpadSection) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(SketchpadSection.allCases, id: \.self) { section in
                Button { onInsert(section) } label: {
                    Text(section.label)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.ai)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DAWTheme.ai.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.ai.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Insert a \(section.label) section tag")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Preview player

/// AVAudioPlayer wrapper for one-at-a-time candidate preview — deliberately in
/// the app layer and OFF the audio engine (the scope's rule). Tracks which
/// candidate is playing so a row shows the right play/stop glyph, and resets on
/// finish. Loopback file only.
@MainActor
@Observable
final class SketchpadPreview: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: UUID?
    private var player: AVAudioPlayer?

    /// Toggles preview for `id`: stops if it's the one playing, otherwise stops
    /// any current preview and starts this file.
    func toggle(id: UUID, path: String) {
        if playingID == id { stop(); return }
        stop()
        guard !path.isEmpty else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = self
            p.play()
            player = p
            playingID = id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    /// Stops only if `id` is the one currently previewing (used before a row is
    /// removed).
    func stopIf(_ id: UUID) { if playingID == id { stop() } }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
