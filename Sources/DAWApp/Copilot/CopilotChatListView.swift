import SwiftUI
import DAWAppKit
import DAWControl

/// The copilot rail's in-rail chat-history list (chat-persist design §8,
/// Phase D). Opened by the header's history glyph, it REPLACES the transcript
/// area while open — the model-picker in-rail expansion precedent: an
/// in-window list, never a popover or sheet, so `debug.captureUI` snapshots
/// it. Rows read the SAME engine/store state the wire's `ai.copilotChats`
/// serves (projected to plain `CopilotChatListFormat` values — never a
/// self-WebSocket call), sorted identically: newest `updatedAt` first, the
/// ACTIVE chat flagged.
///
/// Verbs, per the design's L5 ("non-destructive by default"):
///   - Click a row      → RESUME it (the current chat is archived first —
///                        honestly reflected: it becomes a row in this very
///                        list). Clicking the ACTIVE row just returns to the
///                        conversation. While a turn runs, a resume attempt
///                        is refused by the engine and the teaching error
///                        shows VERBATIM in the amber strip (the
///                        refusal-bubble one-vocabulary law).
///   - Hover affordances → RENAME (inline, the track-header rename idiom:
///                        dark-glass field, cyan focus border, Return /
///                        focus-loss commits via the shared `TrackRename`
///                        trim/empty-cancel/unchanged-no-op rule, Escape
///                        cancels) and DELETE — the one destructive verb,
///                        requiring an in-row confirm (house idiom, never a
///                        system alert).
///
/// Accents: the ACTIVE row is cyan-lit — an earned active state (the
/// instrument-picker current-selection idiom). NOT violet: a chat is a
/// session you navigate, not an AI parameter (unlike the model/voice picked
/// rows), and violet must keep meaning AI content only (Rule 3). Delete
/// confirm is red (destructive); refusals are amber; everything else is
/// quiet neutral chrome on the violet rail.
struct CopilotChatListView: View {
    var engine: CopilotEngine
    var ui: CopilotRailUIModel
    /// The derived rows (the rail projects store + engine state down).
    var rows: [CopilotChatListFormat.Row]
    var isRunning: Bool
    /// Returns the rail to the transcript (resume landed / active row clicked).
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listHeader
            if let error = ui.chatListError {
                refusalStrip(error)
            }
            ScrollView {
                // A plain VStack — the one scroller above owns the axis
                // (the m17-f side-panel corollary).
                VStack(alignment: .leading, spacing: 4) {
                    if rows.isEmpty {
                        emptyState
                    }
                    ForEach(rows) { row in
                        CopilotChatRowView(
                            engine: engine, ui: ui, row: row,
                            isRunning: isRunning, onDone: onDone)
                    }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The quiet honesty footer — where these conversations live.
            Text("Chats are saved inside this project file.")
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .explainable(.copilotChats)
    }

    private var listHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
            Text("CHATS")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
        }
    }

    /// A refused chat action — the engine's teaching error VERBATIM on the
    /// amber refusal treatment (never red: nothing broke, the gesture was
    /// refused with a way forward).
    private func refusalStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
            Text(message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DAWTheme.record)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.record.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DAWTheme.record.opacity(0.35), lineWidth: 1)
        )
    }

    /// Honest first-visit state — beginner-readable (Rule 6).
    private var emptyState: some View {
        Text("No saved chats yet. Starting a new chat files the current conversation here, ready to resume.")
            .font(.system(size: 10.5))
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
    }
}

/// One chat row. Its own view so hover / rename-focus state stays per-row.
private struct CopilotChatRowView: View {
    var engine: CopilotEngine
    var ui: CopilotRailUIModel
    var row: CopilotChatListFormat.Row
    var isRunning: Bool
    var onDone: () -> Void

    @State private var hovered = false
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { ui.renamingChatID == row.id }
    private var isConfirmingDelete: Bool { ui.confirmingDeleteChatID == row.id }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if isRenaming {
                renameField
            } else {
                titleBlock
                Spacer(minLength: 4)
                if isConfirmingDelete {
                    deleteConfirmCluster
                } else {
                    hoverAffordances
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(row.isActive ? DAWTheme.playback.opacity(0.28) : DAWTheme.hairline,
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { resume() }
        .onHover { hovered = $0 }
        .help(rowHelp)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: isConfirmingDelete)
    }

    private var rowBackground: Color {
        if row.isActive { return DAWTheme.playback.opacity(0.10) }
        return hovered || isRenaming || isConfirmingDelete
            ? DAWTheme.panelRaised.opacity(0.7) : .clear
    }

    private var rowHelp: String {
        if row.isActive { return "This is the conversation you are in — click to go back to it" }
        if isRunning {
            // The §6.2 teaching error, verbatim — the tooltip mirror of the
            // refusal the engine would (and will, on click) give.
            return "a copilot turn is already running — wait for it (poll ai.copilotState) "
                + "or ai.copilotReset to cancel and archive it first"
        }
        return "Resume this chat — the current conversation is archived first, never lost"
    }

    // MARK: - Title + subtitle

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(DAWTheme.playback)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .overlay(Capsule().stroke(DAWTheme.playback.opacity(0.45), lineWidth: 1))
                }
            }
            Text(CopilotChatListFormat.subtitle(item: row.item, now: Date()))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
        }
        // While running, a non-active row's resume is refused — read dim.
        .opacity(isRunning && !row.isActive ? 0.55 : 1)
    }

    // MARK: - Actions

    private func resume() {
        guard !isRenaming, !isConfirmingDelete else { return }   // editing rows are inert
        if row.isActive {
            onDone()   // selecting the active chat = just go back to it
            return
        }
        do {
            _ = try engine.resumeChat(id: row.id)
            onDone()
        } catch {
            // The engine's teaching error, verbatim (one vocabulary).
            ui.noteChatListError(error.localizedDescription)
        }
    }

    private func commitRename() {
        guard let title = ui.takeRenameCommit(currentTitle: row.item.title) else { return }
        do {
            try engine.renameChat(id: row.id, title: title)
        } catch {
            ui.noteChatListError(error.localizedDescription)
        }
    }

    private func confirmDelete() {
        ui.cancelDeleteConfirm()
        do {
            _ = try engine.deleteChat(id: row.id)
        } catch {
            ui.noteChatListError(error.localizedDescription)
        }
    }

    // MARK: - Inline rename (the track-header rename idiom)

    private var renameField: some View {
        TextField("", text: Binding(get: { ui.renameDraft }, set: { ui.renameDraft = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(DAWTheme.textPrimary)
            .focused($renameFocused)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(DAWTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DAWTheme.playback.opacity(0.5), lineWidth: 1)   // cyan focus border — prose field
            )
            .onSubmit { commitRename() }
            .onExitCommand { ui.cancelRename() }
            .onChange(of: renameFocused) { _, focused in
                // Focus loss commits (Return already committed and ended the
                // edit, so `isRenaming` guards a double commit).
                if !focused && isRenaming { commitRename() }
            }
            .onAppear { renameFocused = true }
    }

    // MARK: - Hover affordances (rename / delete)

    /// Quiet per-row verbs, hidden until the pointer is over the row (the
    /// transcript copy-glyph idiom): pencil = rename (cyan on hover), trash
    /// = delete (red on hover — destructive).
    private var hoverAffordances: some View {
        HStack(spacing: 4) {
            ChatRowGlyph(systemName: "pencil", hoverColor: DAWTheme.playback,
                         help: "Rename this chat") {
                ui.beginRename(row.id, currentTitle: row.item.title)
            }
            ChatRowGlyph(systemName: "trash", hoverColor: DAWTheme.clip,
                         help: "Delete this chat — permanent, asks to confirm") {
                ui.requestDeleteConfirm(row.id)
            }
        }
        .opacity(hovered ? 1 : 0)
        .allowsHitTesting(hovered)
    }

    /// The in-row delete confirmation — the one destructive verb (L5) asks
    /// twice, in place: a red DELETE chip beside a quiet cancel.
    private var deleteConfirmCluster: some View {
        HStack(spacing: 5) {
            Text("Delete?")
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textDim)
            Button(action: confirmDelete) {
                Text("DELETE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(DAWTheme.clip)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(DAWTheme.clip.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(DAWTheme.clip.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(row.isActive
                  ? "Permanently delete the conversation you are in — a fresh chat starts"
                  : "Permanently delete this chat")
            ChatRowGlyph(systemName: "xmark", hoverColor: DAWTheme.playback,
                         help: "Keep the chat") {
                ui.cancelDeleteConfirm()
            }
        }
    }
}

/// A small quiet glyph chip for chat-row verbs — the `CopilotCopyGlyph`
/// recipe (dim at rest, its accent earned on its own hover; never violet,
/// row verbs aren't AI content).
private struct ChatRowGlyph: View {
    var systemName: String
    var hoverColor: Color
    var help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(hovered ? hoverColor : DAWTheme.textDim)
                .frame(width: 17, height: 17)
                .background(DAWTheme.panelRaised.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(hovered ? hoverColor.opacity(0.4) : DAWTheme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
