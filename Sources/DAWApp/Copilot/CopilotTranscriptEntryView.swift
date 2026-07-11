import SwiftUI
import DAWControl
import DAWAppKit

/// One transcript line in the copilot rail (M6 rail-d). A thin, value-driven view
/// over `CopilotEngine.TranscriptEntry`, styled per kind so the conversation reads
/// at a glance (docs/DESIGN-LANGUAGE.md):
///   - user      → a right-aligned neutral bubble (the human's turn).
///   - assistant → left, violet-tinted glass (AI prose — violet is the identity).
///   - toolCall  → a compact violet chip: the dotted command + a one-line arg
///                 summary (the copilot reaching for a tool).
///   - toolResult→ a chip with a semantic left edge — green when ok, red on error —
///                 so an outcome reads without parsing text.
///   - failure   → a red-tinted strip with the actionable, key-free message.
struct CopilotTranscriptEntryView: View {
    var entry: CopilotEngine.TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user(let text):
            userBubble(text)
        case .assistant(let text):
            assistantText(text)
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
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(DAWTheme.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
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
