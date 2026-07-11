import SwiftUI
import DAWControl

/// The in-app AI Copilot chat rail (M6 rail-d; see
/// docs/research/design-rail-a-copilot.md §9). A right-docked (~360 pt),
/// violet-edged dark-glass rail over the app-level `CopilotEngine` (rail-c):
/// it is the most AI-identified surface in the app, so violet is the through-line
/// — the header identity dot, the assistant text, the tool-call chips and the
/// send button all carry `DAWTheme.ai` ("violet always means AI", per
/// docs/DESIGN-LANGUAGE.md). The one exception is tool RESULTS, which read the
/// semantic outcome color (green ok / red error), so a glance down the transcript
/// tells you what worked.
///
/// The engine owns all conversation state (transcript, status, the turn loop);
/// this view is thin over it — the ClipFixPanel precedent. It owns only the two
/// things the engine must not: the local draft text and the transient send error
/// (a synchronous `send()` throw, e.g. "no AI provider configured"), which never
/// belongs in the shared transcript.
struct CopilotRailView: View {
    /// The app-level copilot engine (retained on AppModel). Observed directly —
    /// `@Observable`, so transcript/status changes redraw the rail.
    var engine: CopilotEngine
    /// A pending draft to load into the input (M8 ex-a "Ask the Copilot" hand-off).
    /// When non-nil the rail moves it into `draft` and calls `onConsumeDraftPrefill`
    /// to clear it — it is a DRAFT only, never auto-sent (works key-or-no-key). nil in
    /// normal use, so a plain open of the rail never clobbers what you were typing.
    var draftPrefill: String? = nil
    /// Clears the pending prefill once loaded (so it isn't re-applied on redraw).
    var onConsumeDraftPrefill: () -> Void = {}
    /// Closes the rail (clears `AppModel.showCopilot`); the conversation survives.
    var onClose: () -> Void

    @State private var draft: String = ""
    /// A synchronous `send()` failure (no provider / already running). Shown as a
    /// red strip above the input — it is UI-local, never part of the transcript.
    @State private var sendError: String?

    private var isRunning: Bool { engine.status == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcript
            Divider().overlay(DAWTheme.hairline)
            inputArea
        }
        .padding(14)
        .frame(width: 360)
        .background(DAWTheme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.ai.opacity(0.28), lineWidth: 1)   // the AI surface — a violet edge
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // The explain hand-off prefills a draft, then opens the rail: consume it on
        // appear (fresh open) and on change (rail already open when handed off).
        .onAppear(perform: consumeDraftPrefill)
        .onChange(of: draftPrefill) { _, _ in consumeDraftPrefill() }
    }

    /// Loads a pending hand-off draft into the input and clears the source, so it is
    /// applied exactly once. A deliberate hand-off owns the draft (it replaces any
    /// in-progress text); a plain open passes nil, so nothing is touched.
    private func consumeDraftPrefill() {
        guard let prefill = draftPrefill, !prefill.isEmpty else { return }
        draft = prefill
        onConsumeDraftPrefill()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 7, height: 7)
                .glow(DAWTheme.ai, radius: 5, intensity: 0.85)
            Text("COPILOT")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text("AI")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.ai.opacity(0.9))
            Spacer()
            if !engine.transcript.isEmpty {
                Button { engine.reset(); sendError = nil } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Clear the conversation and start over")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the copilot")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if engine.transcript.isEmpty && !isRunning {
                        idleHint
                    }
                    ForEach(engine.transcript) { entry in
                        CopilotTranscriptEntryView(entry: entry)
                            .id(entry.id)
                    }
                    if isRunning {
                        CopilotThinkingRow()
                            .id(Self.thinkingAnchor)
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: engine.transcript.count) { _, _ in scrollToNewest(proxy) }
            .onChange(of: engine.status) { _, _ in scrollToNewest(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Auto-scroll target: the thinking shimmer while a turn runs, else the last
    /// transcript entry. Animated so a new round eases into view.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        let anchor: AnyHashable
        if isRunning {
            anchor = AnyHashable(Self.thinkingAnchor)
        } else if let last = engine.transcript.last?.id {
            anchor = AnyHashable(last)
        } else {
            anchor = AnyHashable(Self.thinkingAnchor)
        }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private static let thinkingAnchor = "copilot-thinking"

    /// First-use guidance, beginner-readable (the design-language "Simple by
    /// default" rule — a newcomer must understand the panel without a manual).
    private var idleHint: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.ai)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                Text("Ask the copilot")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
            }
            Text("Tell it what you want in plain language and it works the project for you — one undoable step at a time.")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                exampleLine("Add a punchy drum track")
                exampleLine("Set the tempo to 120")
                exampleLine("Mute the bass and pan the keys left")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.ai.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(DAWTheme.ai.opacity(0.16), lineWidth: 1)
        )
    }

    private func exampleLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DAWTheme.ai.opacity(0.7))
            Text("\u{201C}\(text)\u{201D}")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sendError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DAWTheme.clip)
                    Text(sendError)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DAWTheme.clip)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                inputField
                    .explainable(.copilotInput)
                if isRunning { cancelButton } else { sendButton }
            }
        }
    }

    private var inputField: some View {
        TextField("", text: $draft, prompt: Text(isRunning ? "Working\u{2026}" : "Ask the copilot to do something\u{2026}")
            .foregroundColor(DAWTheme.textFaint))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(DAWTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
            .disabled(isRunning)
            .onSubmit(submit)
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSend ? Color.black : DAWTheme.textDim)
                .frame(width: 30, height: 30)
                .background(canSend ? DAWTheme.ai : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .glow(canSend ? DAWTheme.ai : .clear, radius: 6, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send to the copilot")
    }

    private var cancelButton: some View {
        Button { engine.cancel() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DAWTheme.clip)
                .frame(width: 30, height: 30)
                .background(DAWTheme.clip.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.clip.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Stop the copilot — work already applied stays (each step is undoable)")
    }

    private var canSend: Bool {
        !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        do {
            try engine.send(text)
            draft = ""
            sendError = nil
        } catch {
            // A synchronous throw (no provider / already running) — actionable,
            // key-free. Surface it locally; it is not a transcript entry.
            sendError = error.localizedDescription
        }
    }
}

/// The copilot's "thinking" cue while a turn runs — a violet shimmer bar per
/// round (the SketchpadShimmer recipe: a slow diagonal sweep, never a spinner).
/// The rail shows one at the tail of the transcript whenever `status == .running`.
struct CopilotThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DAWTheme.ai)
                .frame(width: 5, height: 5)
                .glow(DAWTheme.ai, radius: 4, intensity: 0.8)
            Text("WORKING")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.ai)
            RoundedRectangle(cornerRadius: 4)
                .fill(DAWTheme.ai.opacity(0.12))
                .frame(height: 10)
                .overlay {
                    SketchpadShimmer(tint: DAWTheme.ai)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.ai.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)
        )
    }
}
