import AIServices
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for the copilot rail's M10-p-6 presentation layer:
/// per-entry thinking disclosures (collapsed by default), the thinking
/// label/preview strings, the model-picker row derivation over
/// `AnthropicModelCatalog` (one source of truth with the wire), the
/// bottom-pinned auto-scroll state machine ("never fight a user who
/// scrolled up"), and the copy-to-clipboard rules (the "make AI output
/// copyable" user request) against a fake pasteboard — the
/// `CopilotSummaryFormat`/`CopilotModelStore` idiom: everything pinned here
/// without a running app, and never a real clipboard touch.
@Suite("CopilotRailUIModel — rail presentation (M10-p-6)")
struct CopilotRailUIModelTests {

    /// The pasteboard seam's recording fake — copy tests read what WOULD
    /// have landed on the clipboard without ever touching the real one.
    @MainActor
    final class FakePasteboard: CopilotPasteboarding {
        var written: [String] = []
        func write(_ string: String) { written.append(string) }
    }

    // MARK: - Thinking disclosure state

    @MainActor
    @Test("thinking entries default collapsed and toggle per-entry, independently")
    func thinkingDisclosureDefaultsAndToggles() {
        let ui = CopilotRailUIModel()
        let a = UUID(), b = UUID()
        #expect(ui.isThinkingExpanded(a) == false)   // collapsed by default
        #expect(ui.isThinkingExpanded(b) == false)

        ui.toggleThinking(a)
        #expect(ui.isThinkingExpanded(a) == true)
        #expect(ui.isThinkingExpanded(b) == false)   // per-entry independence

        ui.toggleThinking(a)
        #expect(ui.isThinkingExpanded(a) == false)   // toggles back

        ui.expandThinking(b)                          // the debug staging path
        #expect(ui.isThinkingExpanded(b) == true)
        ui.expandThinking(b)                          // idempotent
        #expect(ui.isThinkingExpanded(b) == true)
    }

    @MainActor
    @Test("collapseAll clears everything; prune drops ids no longer in the transcript")
    func thinkingDisclosureClearAndPrune() {
        let ui = CopilotRailUIModel()
        let kept = UUID(), gone = UUID()
        ui.expandThinking(kept)
        ui.expandThinking(gone)

        ui.pruneThinking(existing: [kept])
        #expect(ui.isThinkingExpanded(kept) == true)
        #expect(ui.isThinkingExpanded(gone) == false)   // stale id dropped

        ui.collapseAllThinking()
        #expect(ui.isThinkingExpanded(kept) == false)
        #expect(ui.expandedThinkingIDs.isEmpty)
    }

    @MainActor
    @Test("the model picker starts closed")
    func modelPickerStartsClosed() {
        #expect(CopilotRailUIModel().isModelPickerOpen == false)
    }

    // MARK: - Thinking strings

    @Test("the collapsed label is a live THINKING… while partial, a settled REASONED after")
    func thinkingLabel() {
        #expect(CopilotThinkingFormat.label(partial: true) == "THINKING…")
        #expect(CopilotThinkingFormat.label(partial: false) == "REASONED")
    }

    @Test("the live preview flattens whitespace to one line and keeps the TAIL under the cap")
    func thinkingPreview() {
        #expect(CopilotThinkingFormat.collapsedPreview("") == "")
        #expect(CopilotThinkingFormat.collapsedPreview("  one\n line \n\n of thought ")
                == "one line of thought")
        // Over the cap, the TAIL survives — a live preview shows the newest words.
        let long = Array(repeating: "word", count: 60).joined(separator: " ") + " newest"
        let preview = CopilotThinkingFormat.collapsedPreview(long, cap: 40)
        #expect(preview.count == 40)
        #expect(preview.hasSuffix("newest"))
        #expect(!preview.contains("\n"))
    }

    // MARK: - Model picker rows

    @Test("rows mirror the curated catalog exactly — names, notes, order, and the one default")
    func modelPickerRows() {
        let rows = CopilotModelPickerFormat.rows
        #expect(rows.count == AnthropicModelCatalog.curated.count)
        #expect(rows.map(\.id) == AnthropicModelCatalog.curated.map(\.id))   // display order preserved
        for row in rows {
            #expect(!row.name.isEmpty)
            #expect(!row.note.isEmpty)   // every curated entry carries its one-line note
        }
        // Exactly ONE row is tagged default, and it is the catalog's default id.
        let defaults = rows.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.id == AnthropicModelCatalog.defaultModelID)
        #expect(defaults.first?.id == "claude-sonnet-5")
    }

    @Test("current-row matching is by prefix (a date-suffixed id still lights its row)")
    func modelPickerCurrentMatch() {
        #expect(CopilotModelPickerFormat.isCurrent(rowID: "claude-sonnet-5", current: "claude-sonnet-5"))
        #expect(CopilotModelPickerFormat.isCurrent(rowID: "claude-sonnet-5", current: "claude-sonnet-5-20260115"))
        #expect(!CopilotModelPickerFormat.isCurrent(rowID: "claude-opus-4-8", current: "claude-opus-4-7"))
        // No curated id is a prefix of another — the prefix rule is unambiguous.
        let ids = CopilotModelPickerFormat.rows.map(\.id)
        for a in ids {
            for b in ids where a != b {
                #expect(!a.hasPrefix(b), "\(a) is prefixed by \(b) — prefix matching would double-light")
            }
        }
    }

    @Test("displayName resolves the friendly catalog name, raw id for an unknown model")
    func modelPickerDisplayName() {
        #expect(CopilotModelPickerFormat.displayName(for: "claude-sonnet-5") == "Sonnet 5")
        #expect(CopilotModelPickerFormat.displayName(for: "claude-haiku-4-5-20251001") == "Haiku 4.5")
        // A lookup-only (uncurated) row has no friendly name — honest raw id.
        #expect(CopilotModelPickerFormat.displayName(for: "claude-mythos-5") == "claude-mythos-5")
        #expect(CopilotModelPickerFormat.displayName(for: "claude-unknown-9") == "claude-unknown-9")
    }

    // MARK: - Bottom-pinned auto-scroll

    @Test("isNearBottom: short content, exact bottom, and the tolerance band all pin; beyond it doesn't")
    func nearBottomGeometry() {
        // Content shorter than the viewport — always at the bottom.
        #expect(CopilotScrollFollow.isNearBottom(contentHeight: 100, viewportHeight: 400, offsetY: 0))
        // Exactly at the bottom.
        #expect(CopilotScrollFollow.isNearBottom(contentHeight: 1000, viewportHeight: 400, offsetY: 600))
        // Within tolerance of the bottom.
        #expect(CopilotScrollFollow.isNearBottom(
            contentHeight: 1000, viewportHeight: 400,
            offsetY: 600 - CopilotScrollFollow.bottomTolerance))
        // Beyond tolerance — the user has scrolled up.
        #expect(!CopilotScrollFollow.isNearBottom(
            contentHeight: 1000, viewportHeight: 400,
            offsetY: 600 - CopilotScrollFollow.bottomTolerance - 1))
    }

    @MainActor
    @Test("starts pinned and follows growth; a user scroll up unpins and growth stops following")
    func followPinsAndUnpins() {
        let follow = CopilotScrollFollow()
        #expect(follow.isPinned)                            // a fresh rail follows
        #expect(follow.noteContentGrew(now: 0) == true)     // pinned → scroll

        // The user scrolls up, well past the grace window: unpinned.
        follow.updateGeometry(atBottom: false, now: 10)
        #expect(!follow.isPinned)
        #expect(follow.noteContentGrew(now: 11) == false)   // growth never fights the user

        // Scrolling back to the bottom re-pins; growth follows again.
        follow.updateGeometry(atBottom: true, now: 12)
        #expect(follow.isPinned)
        #expect(follow.noteContentGrew(now: 13) == true)
    }

    @MainActor
    @Test("an auto-scroll's own in-flight geometry never unpins (grace window), then expires")
    func followGraceWindow() {
        let follow = CopilotScrollFollow()
        #expect(follow.noteContentGrew(now: 100) == true)   // opens the grace window

        // Mid-animation frames report not-at-bottom — ignored inside the window.
        follow.updateGeometry(atBottom: false, now: 100.1)
        follow.updateGeometry(atBottom: false, now: 100.4)
        #expect(follow.isPinned)

        // Landing at the bottom ends the window and stays pinned.
        follow.updateGeometry(atBottom: true, now: 100.5)
        #expect(follow.isPinned)

        // A NOT-at-bottom report after the window (no new auto-scroll) is a
        // real user scroll — unpins.
        follow.updateGeometry(atBottom: false, now: 101.5)
        #expect(!follow.isPinned)
    }

    @MainActor
    @Test("forceFollow re-pins after a rail layout change (picker resize / first appear) and honors the grace window")
    func followForcedRepin() {
        let follow = CopilotScrollFollow()
        follow.updateGeometry(atBottom: false, now: 5)   // user scrolled up
        #expect(!follow.isPinned)

        // A rail layout event (picker toggled) re-pins programmatically…
        follow.forceFollow(now: 6)
        #expect(follow.isPinned)
        #expect(follow.noteContentGrew(now: 6.1) == true)
        // …and its grace window shields the resize's in-flight geometry…
        follow.updateGeometry(atBottom: false, now: 6.2)
        #expect(follow.isPinned)
        // …until it expires, when a real user scroll unpins again.
        follow.updateGeometry(atBottom: false, now: 8)
        #expect(!follow.isPinned)
    }

    @Test("GrowthKey changes on any growth axis — entry count, tail text, or the running flip")
    func growthKeyAxes() {
        let base = CopilotScrollFollow.GrowthKey(entryCount: 3, tailTextLength: 40, isRunning: true)
        #expect(base == CopilotScrollFollow.GrowthKey(entryCount: 3, tailTextLength: 40, isRunning: true))
        #expect(base != CopilotScrollFollow.GrowthKey(entryCount: 4, tailTextLength: 40, isRunning: true))
        #expect(base != CopilotScrollFollow.GrowthKey(entryCount: 3, tailTextLength: 41, isRunning: true))
        #expect(base != CopilotScrollFollow.GrowthKey(entryCount: 3, tailTextLength: 40, isRunning: false))
    }

    // MARK: - Copy text rules

    @Test("entryText is the raw text minus trailing whitespace — leading/internal preserved, no reflow")
    func copyEntryTextRules() {
        #expect(CopilotCopyFormat.entryText("Done. Tempo is 120.") == "Done. Tempo is 120.")
        #expect(CopilotCopyFormat.entryText("Done.  \n\n") == "Done.")
        #expect(CopilotCopyFormat.entryText("  indented\n  lines kept  \n") == "  indented\n  lines kept")
        // No markdown reprocessing — the text copies verbatim.
        #expect(CopilotCopyFormat.entryText("**bold** and `code`") == "**bold** and `code`")
        #expect(CopilotCopyFormat.entryText("   \n\t") == "")
        #expect(CopilotCopyFormat.entryText("") == "")
    }

    @Test("wholeReply joins ONE turn's assistant lines with blank lines — tool traffic, thinking, and other turns never join")
    func wholeReplyJoins() {
        let lines = [
            CopilotCopyLine(turnID: "t1", assistantText: "Old reply."),
            CopilotCopyLine(turnID: "t2", assistantText: nil),            // user
            CopilotCopyLine(turnID: "t2", assistantText: "First part.\n"),
            CopilotCopyLine(turnID: "t2", assistantText: nil),            // toolCall
            CopilotCopyLine(turnID: "t2", assistantText: nil),            // toolResult
            CopilotCopyLine(turnID: "t2", assistantText: "   "),          // whitespace-only — dropped
            CopilotCopyLine(turnID: "t2", assistantText: "Second part."),
        ]
        #expect(CopilotCopyFormat.wholeReply(turnID: "t2", lines: lines)
                == "First part.\n\nSecond part.")
        #expect(CopilotCopyFormat.wholeReply(turnID: "t1", lines: lines) == "Old reply.")
        #expect(CopilotCopyFormat.wholeReply(turnID: "t9", lines: lines) == "")   // unknown turn
        #expect(CopilotCopyFormat.wholeReply(turnID: "t2", lines: []) == "")      // empty transcript
    }

    @Test("latestReplyTurnID is the newest turn with real assistant prose — nil before any reply")
    func latestReplyTurn() {
        #expect(CopilotCopyFormat.latestReplyTurnID(lines: []) == nil)
        // A turn with only user/tool lines is not a reply.
        let noProse = [CopilotCopyLine(turnID: "t1", assistantText: nil),
                       CopilotCopyLine(turnID: "t1", assistantText: "  \n")]
        #expect(CopilotCopyFormat.latestReplyTurnID(lines: noProse) == nil)
        // The NEWEST replying turn wins, even when a later turn has no prose yet.
        let lines = [CopilotCopyLine(turnID: "t1", assistantText: "Old."),
                     CopilotCopyLine(turnID: "t2", assistantText: "New."),
                     CopilotCopyLine(turnID: "t3", assistantText: nil)]
        #expect(CopilotCopyFormat.latestReplyTurnID(lines: lines) == "t2")
    }

    // MARK: - Copy state + pasteboard seam

    @MainActor
    @Test("copyEntry writes the trimmed text and confirms; a whitespace-only entry never blanks the clipboard")
    func copyEntryWritesAndConfirms() {
        let ui = CopilotRailUIModel()
        let pasteboard = FakePasteboard()
        let id = UUID()
        #expect(ui.copiedTarget == nil)   // no confirmation at rest

        #expect(ui.copyEntry(id, text: "Reply text.\n", pasteboard: pasteboard) == true)
        #expect(pasteboard.written == ["Reply text."])
        #expect(ui.isCopied(.entry(id)) == true)
        #expect(ui.isCopied(.entry(UUID())) == false)   // per-target confirmation

        // Whitespace-only: nothing written, nothing confirmed.
        let empty = UUID()
        #expect(ui.copyEntry(empty, text: "  \n", pasteboard: pasteboard) == false)
        #expect(pasteboard.written == ["Reply text."])
        #expect(ui.isCopied(.entry(empty)) == false)
        #expect(ui.isCopied(.entry(id)) == true)        // the real copy's confirm survives
    }

    @MainActor
    @Test("copyReply writes the joined turn output and confirms; a prose-less turn is a no-op")
    func copyReplyWritesAndConfirms() {
        let ui = CopilotRailUIModel()
        let pasteboard = FakePasteboard()
        let lines = [CopilotCopyLine(turnID: "t1", assistantText: "One."),
                     CopilotCopyLine(turnID: "t1", assistantText: nil),
                     CopilotCopyLine(turnID: "t1", assistantText: "Two.")]

        #expect(ui.copyReply(turnID: "t1", lines: lines, pasteboard: pasteboard) == true)
        #expect(pasteboard.written == ["One.\n\nTwo."])
        #expect(ui.isCopied(.reply("t1")) == true)

        #expect(ui.copyReply(turnID: "t2", lines: lines, pasteboard: pasteboard) == false)
        #expect(pasteboard.written == ["One.\n\nTwo."])   // nothing more written
        #expect(ui.isCopied(.reply("t1")) == true)        // prior confirm untouched
    }

    @MainActor
    @Test("one confirmation at a time: a newer copy replaces it, and a stale clear never cuts the newer one short")
    func copyConfirmationLifecycle() {
        let ui = CopilotRailUIModel()
        let pasteboard = FakePasteboard()
        let a = UUID(), b = UUID()

        ui.copyEntry(a, text: "A", pasteboard: pasteboard)
        ui.copyEntry(b, text: "B", pasteboard: pasteboard)
        #expect(ui.isCopied(.entry(a)) == false)   // replaced by the newer copy
        #expect(ui.isCopied(.entry(b)) == true)

        // Entry A's expiry timer fires late — it must not clobber B's confirm.
        ui.clearCopied(.entry(a))
        #expect(ui.isCopied(.entry(b)) == true)

        // B's own expiry ends it.
        ui.clearCopied(.entry(b))
        #expect(ui.copiedTarget == nil)

        // The reset path drops any confirmation unconditionally.
        ui.copyEntry(a, text: "A", pasteboard: pasteboard)
        ui.clearAllCopied()
        #expect(ui.copiedTarget == nil)
    }

    // MARK: - Chat-history list state (chat-persist Phase D)

    @MainActor
    @Test("the chat list starts closed and open/close/toggle clear every sub-state")
    func chatListOpenCloseClearsSubstate() {
        let ui = CopilotRailUIModel()
        #expect(ui.isChatListOpen == false)

        // Stage every sub-state, then close: nothing survives.
        ui.openChatList()
        ui.beginRename(UUID(), currentTitle: "old title")
        ui.noteChatListError("a copilot turn is already running — wait")
        ui.closeChatList()
        #expect(ui.isChatListOpen == false)
        #expect(ui.renamingChatID == nil)
        #expect(ui.renameDraft.isEmpty)
        #expect(ui.chatListError == nil)

        // Re-opening starts clean too (no stale confirm from a prior visit).
        ui.requestDeleteConfirm(UUID())
        ui.openChatList()
        #expect(ui.confirmingDeleteChatID == nil)

        ui.toggleChatList()
        #expect(ui.isChatListOpen == false)
        ui.toggleChatList()
        #expect(ui.isChatListOpen == true)
    }

    @MainActor
    @Test("rename and delete-confirm are mutually exclusive — one presentation sub-state at a time")
    func chatListRenameDeleteExclusive() {
        let ui = CopilotRailUIModel()
        let a = UUID(), b = UUID()

        ui.beginRename(a, currentTitle: "add a bassline")
        #expect(ui.renamingChatID == a)
        #expect(ui.renameDraft == "add a bassline")   // draft seeds from the current title

        ui.requestDeleteConfirm(b)                    // arming delete cancels the rename
        #expect(ui.confirmingDeleteChatID == b)
        #expect(ui.renamingChatID == nil)
        #expect(ui.renameDraft.isEmpty)

        ui.beginRename(a, currentTitle: "add a bassline")   // and vice versa
        #expect(ui.confirmingDeleteChatID == nil)
        #expect(ui.renamingChatID == a)

        ui.cancelDeleteConfirm()
        ui.cancelRename()
        #expect(ui.renamingChatID == nil)
        #expect(ui.confirmingDeleteChatID == nil)
    }

    @MainActor
    @Test("takeRenameCommit applies the TrackRename rules and always ends the edit")
    func chatListRenameCommitRules() {
        let ui = CopilotRailUIModel()
        let id = UUID()

        // Changed → the trimmed new title.
        ui.beginRename(id, currentTitle: "old")
        ui.renameDraft = "  fresh name  "
        #expect(ui.takeRenameCommit(currentTitle: "old") == "fresh name")
        #expect(ui.renamingChatID == nil)   // the edit ended

        // Empty / whitespace-only → nil (cancel; never wipes a title).
        ui.beginRename(id, currentTitle: "old")
        ui.renameDraft = "   "
        #expect(ui.takeRenameCommit(currentTitle: "old") == nil)
        #expect(ui.renamingChatID == nil)

        // Unchanged (modulo trim) → nil (no pointless engine churn).
        ui.beginRename(id, currentTitle: "old")
        ui.renameDraft = " old "
        #expect(ui.takeRenameCommit(currentTitle: "old") == nil)

        // No rename in progress → nil (the focus-loss double-commit guard).
        ui.renameDraft = "stray"
        #expect(ui.takeRenameCommit(currentTitle: "old") == nil)
    }

    @MainActor
    @Test("a chat-list refusal surfaces verbatim and clears explicitly or on open/close")
    func chatListErrorLifecycle() {
        let ui = CopilotRailUIModel()
        let teaching = "a copilot turn is already running — wait for it (poll ai.copilotState) "
            + "or ai.copilotReset to cancel and archive it first"
        ui.noteChatListError(teaching)
        #expect(ui.chatListError == teaching)   // verbatim — one vocabulary
        ui.clearChatListError()
        #expect(ui.chatListError == nil)

        ui.noteChatListError(teaching)
        ui.beginRename(UUID(), currentTitle: "x")   // starting a fresh action clears the stale refusal
        #expect(ui.chatListError == nil)
    }

    // MARK: - Chat-history list rows + strings (CopilotChatListFormat)

    private func item(_ title: String, updatedAt: Date, entries: Int = 4,
                      dropped: Int = 0) -> CopilotChatListFormat.Item {
        CopilotChatListFormat.Item(
            id: UUID(), title: title, updatedAt: updatedAt,
            entryCount: entries, droppedEntries: dropped)
    }

    @Test("rows sort newest-updatedAt first with the active chat flagged — the wire's §6.1 order")
    func chatRowsSortLikeTheWire() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oldest = item("oldest", updatedAt: now.addingTimeInterval(-7200))
        let newest = item("newest", updatedAt: now.addingTimeInterval(-60))
        let active = item("active chat", updatedAt: now.addingTimeInterval(-600))

        let rows = CopilotChatListFormat.rows(archived: [oldest, newest], active: active)
        #expect(rows.map(\.item.title) == ["newest", "active chat", "oldest"])
        #expect(rows.map(\.isActive) == [false, true, false])

        // No active chat (fresh empty conversation) — archived only.
        let noActive = CopilotChatListFormat.rows(archived: [oldest, newest], active: nil)
        #expect(noActive.map(\.item.title) == ["newest", "oldest"])
        #expect(noActive.allSatisfy { !$0.isActive })

        // Equal timestamps: active first, then title — deterministic, never jitter.
        let tied = item("b tied", updatedAt: now)
        let tiedActive = item("a tied", updatedAt: now)
        let tiedRows = CopilotChatListFormat.rows(archived: [tied], active: tiedActive)
        #expect(tiedRows.map(\.item.title) == ["a tied", "b tied"])
    }

    @Test("relative time reads in calm buckets and never goes negative")
    func chatRowRelativeTime() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func rel(_ seconds: TimeInterval) -> String {
            CopilotChatListFormat.relativeUpdated(now.addingTimeInterval(-seconds), now: now)
        }
        #expect(rel(5) == "just now")
        #expect(rel(59) == "just now")
        #expect(rel(60) == "1m ago")
        #expect(rel(59 * 60) == "59m ago")
        #expect(rel(60 * 60) == "1h ago")
        #expect(rel(23 * 3600) == "23h ago")
        #expect(rel(24 * 3600) == "1d ago")
        #expect(rel(6 * 86_400) == "6d ago")
        #expect(rel(7 * 86_400) == "1w ago")
        #expect(rel(30 * 86_400) == "4w ago")
        #expect(rel(-120) == "just now")   // clock skew → never "-2m ago"
    }

    @Test("the subtitle carries time + entry count, and 'trimmed' only when true (L6, never noise)")
    func chatRowSubtitle() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plain = item("a", updatedAt: now.addingTimeInterval(-180), entries: 12)
        #expect(CopilotChatListFormat.subtitle(item: plain, now: now) == "3m ago · 12 entries")

        let single = item("b", updatedAt: now.addingTimeInterval(-30), entries: 1)
        #expect(CopilotChatListFormat.subtitle(item: single, now: now) == "just now · 1 entry")

        let trimmed = item("c", updatedAt: now.addingTimeInterval(-3600), entries: 40, dropped: 25)
        #expect(CopilotChatListFormat.subtitle(item: trimmed, now: now)
                == "1h ago · 40 entries · 25 trimmed")
    }

    @Test("the header title falls back to 'New chat' for a fresh conversation (§8.3)")
    func chatHeaderTitleFallback() {
        #expect(CopilotChatListFormat.headerTitle(nil) == "New chat")
        #expect(CopilotChatListFormat.headerTitle("   ") == "New chat")
        #expect(CopilotChatListFormat.headerTitle("add a funky bassline") == "add a funky bassline")
        #expect(CopilotChatListFormat.headerTitle("  padded  ") == "padded")
    }

    @Test("the truncation banner says exactly what happened, with the count (§8.5 wording)")
    func truncationBannerWording() {
        #expect(CopilotChatListFormat.truncationBanner(droppedEntries: 40)
                == "Earlier messages were trimmed (40) to keep the project file small.")
        #expect(CopilotChatListFormat.truncationBanner(droppedEntries: 1)
                == "Earlier messages were trimmed (1) to keep the project file small.")
    }
}
