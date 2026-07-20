import SwiftUI
import DAWAppKit
import DAWControl
import DAWCore

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
    /// The project store — read ONLY for `copilotChats` (the archived-chat
    /// list, chat-persist Phase D): the chat-history list renders the same
    /// state the wire's `ai.copilotChats` serves, never a self-WebSocket
    /// call. `@Observable`, so archive/delete/rename redraw the list live.
    var store: ProjectStore
    /// The rail's presentation state (M10-p-6): per-entry thinking disclosures
    /// + the model-picker open flag. Retained on AppModel (not rail-local
    /// `@State`) so `debug.copilotSeed` can stage every visual state.
    var ui: CopilotRailUIModel
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
    /// The real clipboard behind the copy affordances — the one NSPasteboard
    /// adapter (tests exercise `ui`'s copy logic against a fake instead).
    private static let pasteboard = GeneralPasteboard()
    /// The bottom-pinned auto-scroll state machine (M10-p-6): the transcript
    /// chases streamed growth ONLY while the user is already at the bottom —
    /// a user who scrolled up to re-read is never fought. Rail-local (it is
    /// pure scroll-geometry state), headless in DAWAppKit.
    @State private var follow = CopilotScrollFollow()

    private var isRunning: Bool { engine.status == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                header
                chatTitleLine
            }
            if ui.isChatListOpen {
                chatList
            } else {
                transcript
            }
            Divider().overlay(DAWTheme.hairline)
            modelPickerSection
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
            copyReplyButton
            historyButton
            if !engine.transcript.isEmpty {
                // Reset means NEW CHAT now (chat-persist §8.4): it archives
                // the conversation into the project's chat history — never
                // destroys (L5) — and starts fresh. Glyph + help say so.
                Button {
                    engine.reset()
                    sendError = nil
                    ui.collapseAllThinking()
                    ui.clearAllCopied()
                    ui.closeChatList()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Archive this conversation and start a new chat")
                .explainable(.copilotNewChat)
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

    /// The chat-history toggle (chat-persist §8.1): quiet at rest, cyan-lit
    /// + softly glowing while the list is open — an earned active state
    /// (the splitter idiom), never violet (navigation chrome, not AI
    /// content). Always visible, so history is discoverable even before
    /// anything is archived.
    private var historyButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { ui.toggleChatList() }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ui.isChatListOpen ? DAWTheme.playback : DAWTheme.textDim)
                .glow(ui.isChatListOpen ? DAWTheme.playback : .clear, radius: 4, intensity: 0.5)
        }
        .buttonStyle(.plain)
        .help(ui.isChatListOpen
              ? "Back to the conversation"
              : "Chat history — resume, rename, or delete a saved chat")
        .explainable(.copilotChats)
    }

    /// The current-chat line (chat-persist §8.3): the derived/renamed title,
    /// quiet and tail-truncating under the identity row — never fighting the
    /// MODEL chip. A fresh empty chat honestly reads "New chat"; rename
    /// lives in the chat-history list.
    private var chatTitleLine: some View {
        let title = CopilotChatListFormat.headerTitle(engine.chatTitle)
        return Text(title)
            .font(.system(size: 9.5))
            .foregroundStyle(DAWTheme.textDim)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 15)   // aligns under COPILOT, past the identity dot
            .help(title)
    }

    // MARK: - Chat history (chat-persist Phase D)

    /// The in-rail session list — swapped into the transcript's slot while
    /// open (the in-rail expansion precedent; the transcript re-lands at its
    /// bottom on return via its own `onAppear`).
    private var chatList: some View {
        CopilotChatListView(
            engine: engine, ui: ui, rows: chatRows, isRunning: isRunning,
            onDone: {
                withAnimation(.easeOut(duration: 0.15)) { ui.closeChatList() }
            })
    }

    /// The list's rows: archived chats from the store plus the ACTIVE
    /// conversation — projected to plain `CopilotChatListFormat` values and
    /// sorted by the SAME rule as the wire's `ai.copilotChats` (§6.1). The
    /// active chat joins only once it holds a finalized entry (a fresh empty
    /// chat is not noise-listed), from cheap live engine values — never a
    /// full persistence snapshot per redraw.
    private var chatRows: [CopilotChatListFormat.Row] {
        let archived = store.copilotChats.map { chat in
            CopilotChatListFormat.Item(
                id: chat.id, title: chat.title, updatedAt: chat.updatedAt,
                entryCount: chat.transcript.count,
                droppedEntries: chat.droppedEntries ?? 0)
        }
        let finalizedCount = engine.transcript.lazy.filter { !$0.partial }.count
        var active: CopilotChatListFormat.Item?
        if finalizedCount > 0 {
            active = CopilotChatListFormat.Item(
                id: engine.currentChatID,
                title: CopilotChatListFormat.headerTitle(engine.chatTitle),
                updatedAt: engine.chatUpdatedAt,
                entryCount: finalizedCount,
                droppedEntries: engine.chatDroppedEntries)
        }
        return CopilotChatListFormat.rows(archived: archived, active: active)
    }

    // MARK: - Copy to clipboard

    /// The header's whole-reply copy (the "make AI output copyable" user
    /// request): copies the LATEST turn's complete assistant output —
    /// assistant text entries joined with blank lines; tool traffic and
    /// thinking never join (`CopilotCopyFormat.wholeReply`). Styled as the
    /// reset/close buttons' quiet sibling, swapping to a green checkmark for
    /// the ~1.5 s confirmation. Hidden until a reply exists; older replies
    /// stay reachable through each entry's own hover glyph.
    @ViewBuilder
    private var copyReplyButton: some View {
        if let replyTurn = CopilotCopyFormat.latestReplyTurnID(lines: copyLines) {
            let copied = ui.isCopied(.reply(replyTurn))
            Button {
                if ui.copyReply(turnID: replyTurn, lines: copyLines, pasteboard: Self.pasteboard) {
                    scheduleCopyClear(.reply(replyTurn))
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(copied ? DAWTheme.signal : DAWTheme.textDim)
                    .glow(copied ? DAWTheme.signal : .clear, radius: 4, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy the copilot's latest reply")
            .explainable(.copilotCopy)
        }
    }

    /// The transcript projected down to what copy logic needs — plain values
    /// (the `GrowthKey` idiom): only assistant prose carries text, so the
    /// headless join can never pick up tool traffic or thinking.
    private var copyLines: [CopilotCopyLine] {
        engine.transcript.map { entry in
            if case .assistant(let text) = entry.kind {
                return CopilotCopyLine(turnID: entry.turnID, assistantText: text)
            }
            return CopilotCopyLine(turnID: entry.turnID, assistantText: nil)
        }
    }

    /// The per-entry copy action — assistant prose and thinking summaries
    /// only (tool chips and failure strips carry no copy affordance). nil
    /// hides the glyph; the entry view gates thinking behind its disclosure.
    private func copyAction(for entry: CopilotEngine.TranscriptEntry) -> (() -> Void)? {
        switch entry.kind {
        case .assistant(let text), .thinking(let text):
            return {
                if ui.copyEntry(entry.id, text: text, pasteboard: Self.pasteboard) {
                    scheduleCopyClear(.entry(entry.id))
                }
            }
        case .user, .toolCall, .toolResult, .failure:
            return nil
        }
    }

    /// Ends a copy confirmation after ~1.5 s (the Settings copy-URL cadence).
    /// The model clears only if the target is still current, so an older
    /// timer never cuts a newer copy's checkmark short.
    private func scheduleCopyClear(_ target: CopilotRailUIModel.CopyTarget) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.2)) { ui.clearCopied(target) }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if engine.chatDroppedEntries > 0 {
                            truncationBanner
                        }
                        if engine.transcript.isEmpty && !isRunning {
                            idleHint
                        }
                        ForEach(engine.transcript) { entry in
                            CopilotTranscriptEntryView(
                                entry: entry,
                                isThinkingExpanded: ui.isThinkingExpanded(entry.id),
                                onToggleThinking: { ui.toggleThinking(entry.id) },
                                isCopied: ui.isCopied(.entry(entry.id)),
                                onCopy: copyAction(for: entry)
                            )
                            .id(entry.id)
                        }
                        if isRunning {
                            CopilotThinkingRow()
                                .id(Self.thinkingAnchor)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Reports content height + scroll offset up so the follow
                    // model knows whether the user is at the bottom.
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: CopilotTranscriptGeometryKey.self,
                                value: CopilotTranscriptGeometry(
                                    contentHeight: content.size.height,
                                    offsetY: -content.frame(in: .named(Self.scrollSpace)).minY,
                                    viewportHeight: viewport.size.height))
                        })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(CopilotTranscriptGeometryKey.self) { geo in
                    follow.updateGeometry(
                        atBottom: CopilotScrollFollow.isNearBottom(
                            contentHeight: geo.contentHeight,
                            viewportHeight: geo.viewportHeight,
                            offsetY: geo.offsetY),
                        now: Date.timeIntervalSinceReferenceDate)
                }
                // ONE watched value covers every growth axis — a new entry, a
                // streamed delta growing the tail entry in place (M10-p-6), or
                // the working row appearing/leaving — and the follow model
                // gates the scroll so a user who scrolled up is never fought.
                .onChange(of: growthKey) { _, _ in
                    if engine.transcript.isEmpty { ui.collapseAllThinking(); ui.clearAllCopied() }
                    if follow.noteContentGrew(now: Date.timeIntervalSinceReferenceDate) {
                        scrollToNewest(proxy)
                    }
                }
                // The model picker opening/closing resizes the transcript's
                // viewport — that is OUR layout change, not a user scroll, so
                // the transcript re-lands at the bottom instead of reading the
                // shrink as "the user scrolled away" and unpinning. The scroll
                // waits out the 0.15 s expansion ease (scrolling against the
                // still-shrinking viewport would land short).
                .onChange(of: ui.isModelPickerOpen) { _, _ in
                    follow.forceFollow(now: Date.timeIntervalSinceReferenceDate)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        follow.forceFollow(now: Date.timeIntervalSinceReferenceDate)
                        scrollToNewest(proxy)
                    }
                }
                .onAppear {
                    // A reopened rail with history starts at the newest entry.
                    if !engine.transcript.isEmpty || isRunning {
                        follow.forceFollow(now: Date.timeIntervalSinceReferenceDate)
                        scrollToNewest(proxy, animated: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The transcript's growth signature (headless: `CopilotScrollFollow.GrowthKey`).
    private var growthKey: CopilotScrollFollow.GrowthKey {
        CopilotScrollFollow.GrowthKey(
            entryCount: engine.transcript.count,
            tailTextLength: Self.textLength(of: engine.transcript.last),
            isRunning: isRunning)
    }

    /// A cheap per-kind text length for the growth signature — streamed deltas
    /// only ever grow the TAIL entry (blocks stream sequentially), so watching
    /// the last entry's length catches every delta.
    private static func textLength(of entry: CopilotEngine.TranscriptEntry?) -> Int {
        guard let entry else { return 0 }
        switch entry.kind {
        case .user(let text), .assistant(let text), .thinking(let text), .failure(let text):
            return text.count
        case .toolCall(let command, let summary):
            return command.count + summary.count
        case .toolResult(let command, _, let summary):
            return command.count + summary.count
        }
    }

    /// Auto-scroll target: the thinking shimmer while a turn runs, else the last
    /// transcript entry. Animated so a new round eases into view (unanimated on
    /// first appear, so a reopened rail lands instantly).
    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let anchor: AnyHashable
        if isRunning {
            anchor = AnyHashable(Self.thinkingAnchor)
        } else if let last = engine.transcript.last?.id {
            anchor = AnyHashable(last)
        } else {
            anchor = AnyHashable(Self.thinkingAnchor)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    private static let thinkingAnchor = "copilot-thinking"
    private static let scrollSpace = "copilotTranscriptScroll"

    /// The L6 truncation banner (chat-persist §8.5): a resumed chat whose
    /// oldest entries were cap-trimmed says so at the transcript top — a
    /// quiet, honest, non-dismissable line on neutral chrome (no accent, no
    /// glow: status, not a warning; nothing here needs fixing).
    private var truncationBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
            Text(CopilotChatListFormat.truncationBanner(droppedEntries: engine.chatDroppedEntries))
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DAWTheme.hairline, lineWidth: 1)
        )
        .explainable(.copilotTrimmed)
    }

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

    // MARK: - Model picker (M10-p-6)

    /// The in-rail model picker: a compact MODEL chip above the input (the
    /// snap-chip idiom, violet-accented because the model is an AI parameter —
    /// the ClipFix STRENGTH / voice-picker precedent), expanding an in-window
    /// list of the curated `AnthropicModelCatalog` rows — friendly name, the
    /// one-line note, a DEFAULT tag, the CURRENT row violet-lit — rather than
    /// a stock popup (Rule 2; and an in-window list is capturable, a menu is
    /// not). Selection commits through `engine.setModel` — the exact API the
    /// wire's `ai.copilotSetModel` persists through — and applies from the
    /// NEXT message, which the list's footer says quietly.
    private var modelPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ui.isModelPickerOpen {
                modelList
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            modelChip
        }
    }

    private var modelChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { ui.isModelPickerOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 8.5))
                    .foregroundStyle(DAWTheme.ai.opacity(0.85))
                Text("MODEL")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.textDim)
                Text(CopilotModelPickerFormat.displayName(for: engine.currentModel))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .rotationEffect(.degrees(ui.isModelPickerOpen ? 180 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(ui.isModelPickerOpen ? DAWTheme.ai.opacity(0.35) : DAWTheme.hairline,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose which AI model powers the copilot — a change applies from your next message")
        .explainable(.copilotModel)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(CopilotModelPickerFormat.rows) { row in
                modelRow(row)
            }
            Text("A change applies from your next message.")
                .font(.system(size: 9.5))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.top, 4).padding(.horizontal, 4)
        }
        .padding(6)
        .background(DAWTheme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(DAWTheme.ai.opacity(0.18), lineWidth: 1)
        )
    }

    private func modelRow(_ row: CopilotModelPickerFormat.Row) -> some View {
        let isCurrent = CopilotModelPickerFormat.isCurrent(rowID: row.id, current: engine.currentModel)
        return Button {
            engine.setModel(row.id)
            withAnimation(.easeOut(duration: 0.15)) { ui.isModelPickerOpen = false }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DAWTheme.ai)
                    .opacity(isCurrent ? 1 : 0)   // reserved column — rows never shift
                    .frame(width: 10)
                    .padding(.top, 2.5)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DAWTheme.textPrimary)
                        if row.isDefault {
                            Text("DEFAULT")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(DAWTheme.textDim)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .overlay(Capsule().stroke(DAWTheme.gridEmphasis, lineWidth: 1))
                        }
                    }
                    Text(row.note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(DAWTheme.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? DAWTheme.ai.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isCurrent ? DAWTheme.ai.opacity(0.30) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.name) — \(row.note)")
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

/// The transcript's scroll geometry, reported up by preference so the
/// `CopilotScrollFollow` model can tell whether the user is at the bottom
/// (M10-p-6). Plain values only.
private struct CopilotTranscriptGeometry: Equatable, Sendable {
    var contentHeight: Double = 0
    var offsetY: Double = 0
    var viewportHeight: Double = 0
}

private struct CopilotTranscriptGeometryKey: PreferenceKey {
    static let defaultValue = CopilotTranscriptGeometry()
    static func reduce(value: inout CopilotTranscriptGeometry, nextValue: () -> CopilotTranscriptGeometry) {
        value = nextValue()
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
