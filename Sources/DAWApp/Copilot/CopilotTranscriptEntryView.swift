import SwiftUI
import DAWControl
import DAWAppKit

/// One transcript line in the copilot rail (M6 rail-d). A thin, value-driven view
/// over `CopilotEngine.TranscriptEntry`, styled per kind so the conversation reads
/// at a glance (docs/DESIGN-LANGUAGE.md):
///   - user      → a right-aligned neutral bubble (the human's turn).
///   - assistant → left, violet-tinted glass (AI prose — violet is the identity).
///                 While `partial` (M10-p-6 live streaming) the text grows in
///                 place with a soft breathing violet dot beneath it — the
///                 streaming cue, removed on finalize (never a spinner).
///   - thinking  → a quiet, collapsed-by-default disclosure row (M10-p-6): the
///                 model's background reasoning, deliberately LOWER emphasis
///                 than assistant prose so it never reads as the answer. The
///                 collapsed row is a mono micro-label — a live "THINKING…"
///                 with a breathing dot plus a one-line tail preview while
///                 `partial`, a settled "REASONED" after — and the chevron
///                 expands the full summary (dim italic, live-growing while
///                 partial). Expansion is per-entry, user-toggled, owned by the
///                 rail's `CopilotRailUIModel` and passed in as plain values.
///   - toolCall  → a compact violet chip: the dotted command + a one-line arg
///                 summary (the copilot reaching for a tool).
///   - toolResult→ a chip with a semantic left edge — green when ok, red on error —
///                 so an outcome reads without parsing text.
///   - failure   → a red-tinted strip with the actionable, key-free message.
///
/// Assistant entries (and EXPANDED thinking entries) carry a quiet copy
/// affordance (the "make AI output copyable" user request): a small glyph in
/// the top-trailing corner, hidden until the pointer is over the entry, dim
/// at rest, cyan-lit + softly glowing on its own hover (the splitter
/// earn-by-state idiom), swapping to a green checkmark for the ~1.5 s
/// confirmation — no toast, no modal. Collapsed thinking has no copy path
/// (what you can't read, you can't copy); a partial entry copies its
/// current text. The copied state lives in `CopilotRailUIModel` and flows
/// in as plain values (the disclosure pattern).
struct CopilotTranscriptEntryView: View {
    var entry: CopilotEngine.TranscriptEntry
    /// Whether this entry's thinking body is expanded (thinking entries only).
    /// A plain value input — the rail owns the state — so previews stage it.
    var isThinkingExpanded: Bool = false
    /// Toggles this entry's thinking disclosure.
    var onToggleThinking: () -> Void = {}
    /// Whether this entry's copy affordance shows its "copied" confirmation.
    /// A plain value input — `CopilotRailUIModel` owns the state.
    var isCopied: Bool = false
    /// Copies this entry's text (nil = no copy affordance; the rail passes it
    /// for assistant and thinking entries only).
    var onCopy: (() -> Void)? = nil

    /// Pointer-over-entry state — pure hover presentation, so view-local.
    @State private var entryHovered = false

    var body: some View {
        switch entry.kind {
        case .user(let text):
            userBubble(text)
        case .assistant(let text):
            assistantText(text)
        case .thinking(let text):
            thinkingDisclosure(text)
        case .toolCall(let command, let argsSummary):
            toolCallChip(command: command, summary: argsSummary)
        case .toolResult(let command, let ok, let summary):
            toolResultChip(command: command, ok: ok, summary: summary)
        case .failure(let text):
            failureStrip(text)
        }
    }

    // MARK: - User

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 28)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(DAWTheme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
        }
    }

    // MARK: - Assistant

    private func assistantText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.ai)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.partial {
                    // The live-streaming cue: a soft breathing violet dot riding
                    // just under the growing text (glow earned — live AI state).
                    // Removed the moment the entry finalizes.
                    CopilotPulseDot(color: DAWTheme.ai, size: 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.ai.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DAWTheme.ai.opacity(0.22), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { copyAffordance(help: "Copy this reply") }
        .onHover { entryHovered = $0 }
    }

    // MARK: - Copy affordance

    /// The corner copy glyph, shown only while the pointer is over the entry
    /// (or while its confirmation is up, so the checkmark survives the
    /// pointer leaving). Rendered only when the rail passed an `onCopy`.
    @ViewBuilder
    private func copyAffordance(help: String) -> some View {
        if let onCopy {
            let visible = entryHovered || isCopied
            CopilotCopyGlyph(isCopied: isCopied, help: help, action: onCopy)
                .padding(4)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .animation(.easeOut(duration: 0.15), value: visible)
        }
    }

    // MARK: - Thinking

    /// The thinking disclosure (M10-p-6): background reasoning rendered
    /// deliberately QUIETER than assistant prose — a dimmed violet accent on a
    /// faded raised strip, small type, no glow on the chrome (only the live
    /// breathing dot earns it). Collapsed by default; the whole header row is
    /// the toggle. While `partial` and collapsed, a one-line head-truncated
    /// preview shows the newest words of the live summary — calm, one line,
    /// never the full stream.
    private func thinkingDisclosure(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggleThinking) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                        .rotationEffect(.degrees(isThinkingExpanded ? 90 : 0))
                    Image(systemName: "brain")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DAWTheme.ai.opacity(0.65))
                    Text(CopilotThinkingFormat.label(partial: entry.partial))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.ai.opacity(0.8))
                    if entry.partial {
                        CopilotPulseDot(color: DAWTheme.ai, size: 4)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isThinkingExpanded
                  ? "Hide the copilot's reasoning"
                  : "Show how the copilot reasoned through this step")

            if isThinkingExpanded {
                Text(text)
                    .font(.system(size: 10.5))
                    .italic()
                    .foregroundStyle(DAWTheme.textDim)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)   // aligns under the label, past the chevron
            } else if entry.partial {
                // Collapsed live preview: head-truncated so the NEWEST words
                // stay visible as the summary streams in.
                Text(CopilotThinkingFormat.collapsedPreview(text))
                    .font(.system(size: 9.5))
                    .italic()
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(DAWTheme.ai.opacity(0.13), lineWidth: 1)
        )
        // Copyable ONLY while expanded — what you can't read, you can't copy
        // (collapsed reasoning stays out of reach, and out of whole-reply
        // copies, by design).
        .overlay(alignment: .topTrailing) {
            if isThinkingExpanded { copyAffordance(help: "Copy this reasoning") }
        }
        .onHover { entryHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isThinkingExpanded)
    }

    // MARK: - Tool call

    private func toolCallChip(command: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(DAWTheme.ai)
                Text(command)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            let compact = CopilotSummaryFormat.compact(summary)
            if !compact.isEmpty {
                Text(compact)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.ai.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(DAWTheme.ai.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Tool result

    private func toolResultChip(command: String, ok: Bool, summary: String) -> some View {
        let accent = ok ? DAWTheme.signal : DAWTheme.clip
        return HStack(alignment: .top, spacing: 8) {
            // A semantic left edge — green ok / red error — the fastest read.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent)
                    Text(command)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                let compact = CopilotSummaryFormat.compact(summary)
                if !compact.isEmpty {
                    Text(compact)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(ok ? DAWTheme.textDim : DAWTheme.clip.opacity(0.9))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Failure

    private func failureStrip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.clip)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DAWTheme.clip)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.clip.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DAWTheme.clip.opacity(0.35), lineWidth: 1)
        )
    }
}

/// The quiet copy-to-clipboard glyph shared by the transcript's per-entry
/// affordances and the rail header's whole-reply action (the "make AI output
/// copyable" user request). Neutral chrome on a small raised backing so it
/// reads over bubble text: dim at rest, cyan-lit + softly glowing ONLY on
/// its own hover/press (the splitter earn-by-state idiom — never violet,
/// copying isn't AI content), and a green glowing checkmark while the
/// "copied" confirmation is up (green = success, the toolResult ok-edge
/// semantics). Ships ONE `.explainable(.copilotCopy)` id wherever it
/// renders (the shared-control rule).
struct CopilotCopyGlyph: View {
    var isCopied: Bool
    var help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(isCopied ? DAWTheme.signal
                                 : hovered ? DAWTheme.playback : DAWTheme.textDim)
                .glow(isCopied ? DAWTheme.signal : (hovered ? DAWTheme.playback : .clear),
                      radius: 4, intensity: 0.5)
                .frame(width: 17, height: 17)
                .background(DAWTheme.panelRaised.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(hovered && !isCopied ? DAWTheme.playback.opacity(0.4) : DAWTheme.hairline,
                                lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(isCopied ? "Copied" : help)
        .explainable(.copilotCopy)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: isCopied)
    }
}

/// A soft breathing dot — the transcript's live-streaming cue (M10-p-6), the
/// InstrumentChip `PendingDot` idiom in the rail's violet: a slow ease-in-out
/// opacity/glow breath, never a spinner (docs/DESIGN-LANGUAGE.md — the ARM
/// breathing-halo animation family; glow is earned here because the dot IS
/// live state, not static chrome).
struct CopilotPulseDot: View {
    var color: Color
    var size: CGFloat = 5
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .glow(color, radius: 4, intensity: dim ? 0.25 : 0.7)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
