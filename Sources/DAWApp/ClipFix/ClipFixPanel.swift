import SwiftUI
import DAWCore
import DAWAppKit

/// The clip vocal-fix panel (M6 v-b-2): opened by the violet FIX WITH AI
/// affordance on a selected audio clip, it docks as a fixed-width glass panel on
/// the right of the Arrange workspace — beside the timeline so the resulting
/// violet take LANE lands in view. The composer (region + prompt/lyrics + mode +
/// GO) submits a repaint of exactly the region; the jobs strip below tracks every
/// in-flight fix through its lifecycle.
///
/// VIOLET IS THE THROUGH-LINE: a fix is AI-generated content, so the header, the
/// mode picker, the GO button, and every job card carry `DAWTheme.ai` ("violet
/// always means AI-generated", docs/DESIGN-LANGUAGE.md). The beat fields are the
/// one exception — they are numeric readouts, so they read cyan (the Sketchpad
/// length-stepper rule).
///
/// All state + transitions live in the headless `ClipFixModel`
/// (Sources/DAWAppKit); this view is thin over it. It owns only the one thing the
/// model must not: the 1 s poll timer (a `.task` loop, active only while a job is
/// still running), and it re-seeds the composer as the selected clip changes.
struct ClipFixPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ClipFixModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Everything below the pinned header rides ONE vertical ScrollView so
            // the panel COMPRESSES to the workspace row's height (m17-f F4, the
            // SketchpadView fix): a rigid composer overflowed the whole window
            // layout when the bottom editor was open at a short window. The
            // header stays pinned (identity + close always reachable).
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    composer
                    Divider().overlay(DAWTheme.hairline)
                    jobsSection
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(DAWTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)   // a faint violet edge — this is the AI surface
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Poll loop: only fires while a job still needs polling; the model owns
        // each transition, the view owns the cadence (the Sketchpad precedent).
        .task {
            while !Task.isCancelled {
                if model.hasActiveJobs { await model.refresh() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
            Text("FIX WITH AI")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Spacer()
            Button { app.showClipFix = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the AI fix panel")
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if model.targetClipID != nil {
            VStack(alignment: .leading, spacing: 10) {
                // The clip being fixed, so the region reads in context.
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.signal)
                    Text(model.targetClipName.isEmpty ? "Audio clip" : model.targetClipName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("REGION TO FIX (BEATS)")
                    HStack(spacing: 8) {
                        beatField(label: "START", value: $model.regionStartBeat)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DAWTheme.textDim)
                        beatField(label: "END", value: $model.regionEndBeat)
                        Spacer(minLength: 0)
                    }
                }
                .explainable(.clipFixRegion)

                fieldLabel("WHAT TO FIX")
                editor(text: $model.prompt, height: 44,
                       placeholder: "e.g. clean up the pitch on the second line")

                HStack {
                    fieldLabel("LYRICS")
                    Spacer()
                    Text("optional — helps the vocal")
                        .font(.system(size: 8.5))
                        .foregroundStyle(DAWTheme.textDim)
                }
                editor(text: $model.lyrics, height: 60, placeholder: "[chorus]\n…")

                modePicker
                    .explainable(.clipFixStrength)
                goButton
                    .explainable(.clipFixGo)

                if let error = model.submitError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DAWTheme.clip)
                        Text(error)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DAWTheme.clip)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textDim)
                Text("Select an audio clip in the timeline to fix a region of it with AI.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(DAWTheme.textDim)
    }

    /// A cyan SF Mono editable beat field (numeric readout → cyan, not violet).
    private func beatField(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)
                .frame(width: 70)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(DAWTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
        }
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

    /// Regeneration intensity — a themed 3-segment chip row, the active half
    /// violet-lit (this is an AI parameter). Beginner-readable labels.
    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("STRENGTH")
            HStack(spacing: 0) {
                ForEach(ClipFixMode.allCases, id: \.self) { mode in
                    modeSegment(mode)
                }
            }
            .padding(2)
            .background(DAWTheme.panelRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
        }
    }

    private func modeSegment(_ mode: ClipFixMode) -> some View {
        let active = model.mode == mode
        return Button { model.mode = mode } label: {
            Text(Self.modeLabel(mode))
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(active ? DAWTheme.ai : DAWTheme.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(active ? DAWTheme.ai.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
                .glow(DAWTheme.ai, radius: 4, intensity: active ? 0.45 : 0)
        }
        .buttonStyle(.plain)
        .help(Self.modeHelp(mode))
    }

    private static func modeLabel(_ mode: ClipFixMode) -> String {
        switch mode {
        case .conservative: return "SUBTLE"
        case .balanced: return "BALANCED"
        case .aggressive: return "BOLD"
        }
    }
    private static func modeHelp(_ mode: ClipFixMode) -> String {
        switch mode {
        case .conservative: return "Subtle — stay very close to the original take"
        case .balanced: return "Balanced — the recommended middle ground"
        case .aggressive: return "Bold — regenerate the region more freely"
        }
    }

    private var goButton: some View {
        Button { Task { await model.submitCurrent() } } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                Text(model.isSubmitting ? "WORKING…" : "FIX THIS REGION")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.2)
            }
            .foregroundStyle(model.canSubmit ? Color.black : DAWTheme.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(model.canSubmit ? DAWTheme.ai : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .glow(model.canSubmit ? DAWTheme.ai : .clear, radius: 8, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSubmit)
        .help("Generate an AI fix for this region as a new violet take lane")
    }

    // MARK: - Jobs strip

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("AI FIXES")
            if model.cards.isEmpty {
                Text("Your AI fixes appear here. Each lands as a violet take lane comped in over just the region.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                // A plain VStack — the panel's ONE outer ScrollView (m17-f F4)
                // owns all vertical scrolling now, so the old 260 pt inner
                // scroll cap would just nest a second same-axis scroller.
                VStack(spacing: 8) {
                    // Newest on top — the fix you just asked for.
                    ForEach(model.cards.reversed()) { card in
                        ClipFixJobCard(
                            card: card,
                            onImport: { Task { await model.importFix(jobID: card.jobID) } },
                            onDismiss: { model.dismiss(jobID: card.jobID) }
                        )
                    }
                }
            }
        }
    }
}
