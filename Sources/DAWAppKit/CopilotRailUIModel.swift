import AIServices
import Foundation
import Observation

/// Headless presentation state + pure formatting for the copilot rail's
/// M10-p-6 UI phase (live-streaming transcript, thinking disclosures, the
/// model picker) — the `CopilotSummaryFormat`/`VoicePanelModel` precedent:
/// views stay thin, every stateful/derivable presentation decision lives
/// here so it is unit-tested and `debug.copilotSeed` can stage it.
///
/// The pieces, one file (they are one surface):
///   - `CopilotRailUIModel`   — the rail's session-only UI state (which
///     thinking entries are expanded; whether the model picker is open;
///     which copy affordance is confirming; the chat-history list's
///     open/rename/delete-confirm presentation, chat-persist Phase D).
///   - `CopilotThinkingFormat` — pure strings for the thinking disclosure
///     (collapsed label, one-line live preview).
///   - `CopilotChatListFormat` — the chat-history list's row derivation
///     (wire-identical ordering) + the header title / subtitle / truncation
///     banner strings (chat-persist design §8).
///   - `CopilotModelPickerFormat` — the curated model rows + display-name
///     resolution over `AnthropicModelCatalog` (one source of truth).
///   - `CopilotScrollFollow`  — the "auto-scroll pinned to bottom only when
///     the user is already at the bottom" state machine.
///   - `CopilotCopyFormat` + `CopilotPasteboarding` — the copy-to-clipboard
///     text rules and the pasteboard seam (the "make AI output copyable"
///     user request), so what lands on the clipboard is unit-tested and
///     tests never touch the real pasteboard.

// MARK: - Rail UI state

/// The copilot rail's transient presentation state (M10-p-6). Session-only —
/// NEVER persisted (unlike the model SETTING in `CopilotModelStore`): which
/// entries you had unfolded is a reading aid, not a preference. Owned by
/// AppModel (not rail-local `@State`) so `debug.copilotSeed` can stage every
/// visual state for captures/E2E — the `VoicePanelModel` staging precedent.
@MainActor
@Observable
public final class CopilotRailUIModel {
    /// Transcript-entry ids whose `.thinking` body is expanded. Default
    /// collapsed — reasoning is background material, opened per-entry by the
    /// user. Keyed by the entry's stable id, so streaming growth (the entry's
    /// text mutating in place) never disturbs the disclosure.
    public private(set) var expandedThinkingIDs: Set<UUID> = []

    /// Whether the in-rail model picker list is open (the MODEL chip's
    /// disclosure). Transient chrome state, closed by default.
    public var isModelPickerOpen = false

    /// One copy affordance's transient "copied" confirmation target — a
    /// transcript entry's own glyph or the header's whole-reply glyph. One
    /// target at a time: a fresh copy replaces the previous confirmation
    /// (only the newest copy is "what's on the clipboard", so only it may
    /// claim the checkmark).
    public enum CopyTarget: Hashable, Sendable {
        /// One transcript entry's affordance (assistant prose / expanded thinking).
        case entry(UUID)
        /// The header's whole-reply affordance, keyed by the copied turn.
        case reply(String)
    }

    /// The affordance currently showing its "copied" checkmark, nil when
    /// none. Set by the copy methods below; ended by `clearCopied(_:)` after
    /// the view's ~1.5 s confirmation window (the Settings copy-URL cadence
    /// — the view owns the timer, the model owns the state).
    public private(set) var copiedTarget: CopyTarget?

    public init() {}

    public func isCopied(_ target: CopyTarget) -> Bool {
        copiedTarget == target
    }

    /// Copies ONE entry's text (assistant prose, or an expanded thinking
    /// summary) — the raw text minus trailing whitespace, per
    /// `CopilotCopyFormat.entryText`. Returns whether anything was written:
    /// a whitespace-only entry writes nothing and shows no confirmation
    /// (never blank the user's clipboard for an empty copy).
    @discardableResult
    public func copyEntry(_ id: UUID, text: String, pasteboard: any CopilotPasteboarding) -> Bool {
        let copyText = CopilotCopyFormat.entryText(text)
        guard !copyText.isEmpty else { return false }
        pasteboard.write(copyText)
        copiedTarget = .entry(id)
        return true
    }

    /// Copies a turn's COMPLETE assistant output (its assistant text lines
    /// joined with blank lines — tool traffic and thinking never join; see
    /// `CopilotCopyFormat.wholeReply`). Returns whether anything was written.
    @discardableResult
    public func copyReply(turnID: String, lines: [CopilotCopyLine],
                          pasteboard: any CopilotPasteboarding) -> Bool {
        let joined = CopilotCopyFormat.wholeReply(turnID: turnID, lines: lines)
        guard !joined.isEmpty else { return false }
        pasteboard.write(joined)
        copiedTarget = .reply(turnID)
        return true
    }

    /// Ends one confirmation — ONLY if it is still the current one, so an
    /// older copy's expiry timer never cuts a newer copy's checkmark short.
    public func clearCopied(_ target: CopyTarget) {
        if copiedTarget == target { copiedTarget = nil }
    }

    /// Drops any confirmation unconditionally — the rail's reset (↺) /
    /// cleared-conversation path, the `collapseAllThinking` sibling.
    public func clearAllCopied() {
        copiedTarget = nil
    }

    public func isThinkingExpanded(_ id: UUID) -> Bool {
        expandedThinkingIDs.contains(id)
    }

    /// Toggles one entry's disclosure — per-entry, independent of every other.
    public func toggleThinking(_ id: UUID) {
        if expandedThinkingIDs.contains(id) {
            expandedThinkingIDs.remove(id)
        } else {
            expandedThinkingIDs.insert(id)
        }
    }

    /// Expands one entry (the `debug.copilotSeed {expandThinking}` staging path).
    public func expandThinking(_ id: UUID) {
        expandedThinkingIDs.insert(id)
    }

    /// Collapses everything — the rail's reset (↺) path, so a cleared
    /// conversation never leaks stale ids.
    public func collapseAllThinking() {
        expandedThinkingIDs = []
    }

    /// Drops expansion state for entries no longer in the transcript, so the
    /// set can never grow unbounded across conversations.
    public func pruneThinking(existing: Set<UUID>) {
        expandedThinkingIDs.formIntersection(existing)
    }

    // MARK: Chat-history list (chat-persist Phase D, design §8)

    /// Whether the in-rail chat-history list is open (the header history
    /// glyph's disclosure). While open the list REPLACES the transcript area
    /// — the model-picker in-rail expansion precedent, never a popover or
    /// sheet (an in-window list is capturable).
    public private(set) var isChatListOpen = false

    /// The chat row currently in inline rename, nil when none. One rename at
    /// a time; starting one cancels any pending delete confirmation.
    public private(set) var renamingChatID: UUID?

    /// The rename field's live draft (the view's TextField binds it).
    public var renameDraft = ""

    /// The chat row with a pending delete confirmation, nil when none — the
    /// one destructive verb requires an explicit second click (L5), rendered
    /// in-row (house idiom), never a system alert.
    public private(set) var confirmingDeleteChatID: UUID?

    /// A refused chat action's message — the engine's teaching error
    /// VERBATIM (the refusal-bubble one-vocabulary law: the same words an
    /// agent gets over the wire). Shown as an amber strip atop the list.
    public private(set) var chatListError: String?

    public func toggleChatList() {
        if isChatListOpen { closeChatList() } else { openChatList() }
    }

    /// Opens the list with a clean slate — no stale rename/confirm/error
    /// from a previous visit.
    public func openChatList() {
        isChatListOpen = true
        clearChatListSubstate()
    }

    /// Closes the list and drops every in-flight presentation sub-state (an
    /// abandoned half-typed rename never survives a close).
    public func closeChatList() {
        isChatListOpen = false
        clearChatListSubstate()
    }

    /// Starts an inline rename on one row, seeding the draft with the
    /// current title (the track-header rename idiom).
    public func beginRename(_ id: UUID, currentTitle: String) {
        renamingChatID = id
        renameDraft = currentTitle
        confirmingDeleteChatID = nil
        chatListError = nil
    }

    /// Abandons the in-progress rename (Escape / the cancel path).
    public func cancelRename() {
        renamingChatID = nil
        renameDraft = ""
    }

    /// Resolves the in-progress rename through the shared
    /// `TrackRename.committedName` trim / empty-cancel / unchanged-no-op
    /// commit rule, and ENDS the edit either way. Returns the title to
    /// store, or nil when the edit should be dropped without touching the
    /// engine (no stray rename, no pointless churn).
    public func takeRenameCommit(currentTitle: String) -> String? {
        defer { cancelRename() }
        guard renamingChatID != nil else { return nil }
        return TrackRename.committedName(draft: renameDraft, current: currentTitle)
    }

    /// Arms one row's delete confirmation (cancelling any in-progress
    /// rename — one presentation sub-state at a time).
    public func requestDeleteConfirm(_ id: UUID) {
        confirmingDeleteChatID = id
        renamingChatID = nil
        renameDraft = ""
        chatListError = nil
    }

    public func cancelDeleteConfirm() {
        confirmingDeleteChatID = nil
    }

    /// Surfaces a refused chat action's teaching error, verbatim.
    public func noteChatListError(_ message: String) {
        chatListError = message
    }

    public func clearChatListError() {
        chatListError = nil
    }

    private func clearChatListSubstate() {
        renamingChatID = nil
        renameDraft = ""
        confirmingDeleteChatID = nil
        chatListError = nil
    }
}

// MARK: - Thinking disclosure strings

/// Pure formatting for the transcript's `.thinking` disclosure row.
public enum CopilotThinkingFormat {
    /// The collapsed row's label: a live "Thinking…" while the summary is
    /// still streaming (`partial`), a settled "Reasoned" once finalized.
    /// Rendered as a mono micro-label (the rail's WORKING-row idiom), so the
    /// strings are already uppercase.
    public static func label(partial: Bool) -> String {
        partial ? "THINKING…" : "REASONED"
    }

    /// A one-line live preview of a still-streaming summary for the COLLAPSED
    /// row: whitespace/newlines flattened to single spaces, then capped to the
    /// TAIL (`cap` chars) — the newest words are what a live preview should
    /// show (the view head-truncates, so the tail stays visible as it grows).
    /// The cap bounds layout cost; it never changes which words render.
    public static func collapsedPreview(_ text: String, cap: Int = 160) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > cap else { return flattened }
        return String(flattened.suffix(cap))
    }
}

// MARK: - Chat-history list rows

/// Pure row derivation + strings for the in-rail chat-history list
/// (chat-persist design §8). Plain value inputs — the `CopilotCopyLine`
/// idiom: DAWAppKit never imports the store's `CopilotChatDocument`; the
/// rail projects archived documents and the engine's live chat down to
/// `Item` — so ordering, the honesty strings, and the header title are
/// unit-tested headless and can never drift from the wire's §6.1 semantics
/// (updatedAt-descending, active flagged, droppedEntries surfaced only
/// when > 0).
public enum CopilotChatListFormat {
    /// One chat projected down to what the list renders.
    public struct Item: Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var updatedAt: Date
        public var entryCount: Int
        /// L6 honesty counter — 0 when nothing was ever trimmed.
        public var droppedEntries: Int

        public init(id: UUID, title: String, updatedAt: Date,
                    entryCount: Int, droppedEntries: Int = 0) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.entryCount = entryCount
            self.droppedEntries = droppedEntries
        }
    }

    /// One rendered row: the item plus its active flag.
    public struct Row: Sendable, Equatable, Identifiable {
        public var item: Item
        public var isActive: Bool
        public var id: UUID { item.id }

        public init(item: Item, isActive: Bool) {
            self.item = item
            self.isActive = isActive
        }
    }

    /// The wire's §6.1 order: newest `updatedAt` first, the active chat
    /// joining the same sort (it is usually newest anyway). Ties break
    /// active-first, then by title, so the order is deterministic under
    /// test and rows never jitter across equal timestamps.
    public static func rows(archived: [Item], active: Item?) -> [Row] {
        var rows = archived.map { Row(item: $0, isActive: false) }
        if let active {
            rows.append(Row(item: active, isActive: true))
        }
        rows.sort { a, b in
            if a.item.updatedAt != b.item.updatedAt { return a.item.updatedAt > b.item.updatedAt }
            if a.isActive != b.isActive { return a.isActive }
            return a.item.title < b.item.title
        }
        return rows
    }

    /// A row's relative "when": coarse, calm buckets — a chat list is
    /// navigation, not a stopwatch. Injected `now` so it's deterministic
    /// under test. A future-dated timestamp (clock skew) reads "just now",
    /// never a negative count.
    public static func relativeUpdated(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(seconds / 86_400)
        if days < 7 { return "\(days)d ago" }
        return "\(days / 7)w ago"
    }

    /// A row's mono subtitle: "3m ago · 12 entries", plus " · N trimmed"
    /// ONLY when entries were dropped — truncation is always visible (L6)
    /// but never noise when it never happened.
    public static func subtitle(item: Item, now: Date) -> String {
        var parts = [
            relativeUpdated(item.updatedAt, now: now),
            item.entryCount == 1 ? "1 entry" : "\(item.entryCount) entries",
        ]
        if item.droppedEntries > 0 {
            parts.append("\(item.droppedEntries) trimmed")
        }
        return parts.joined(separator: " · ")
    }

    /// The rail header's current-chat line: the derived/renamed title once
    /// it exists, else "New chat" (§8.3 — a fresh empty chat reads as
    /// that, honestly). Whitespace-only titles fall back too.
    public static func headerTitle(_ chatTitle: String?) -> String {
        let trimmed = chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "New chat" : trimmed
    }

    /// The transcript-top truncation banner's honest line (§8.5 wording) —
    /// shown only when `droppedEntries > 0`, and it never pretends the
    /// transcript is complete (L6).
    public static func truncationBanner(droppedEntries: Int) -> String {
        "Earlier messages were trimmed (\(droppedEntries)) to keep the project file small."
    }
}

// MARK: - Model picker rows

/// The in-rail model picker's row derivation — a thin, pure projection of
/// `AnthropicModelCatalog.curated` (ONE source of truth: the same array
/// `ai.copilotSetModel` validates against and `CopilotModelStore` persists
/// from), so the picker can never drift from the wire surface.
public enum CopilotModelPickerFormat {
    public struct Row: Sendable, Equatable, Identifiable {
        /// The model id (`commit`/`setModel` input).
        public let id: String
        /// The friendly display name ("Sonnet 5").
        public let name: String
        /// The catalog's one-line note ("balanced — the default").
        public let note: String
        /// True for `AnthropicModelCatalog.defaultModelID` — the row the
        /// picker tags DEFAULT.
        public let isDefault: Bool
    }

    /// The curated rows in catalog display order. `name`/`note` are non-nil
    /// by construction for curated entries; the fallbacks are defensive.
    public static var rows: [Row] {
        AnthropicModelCatalog.curated.map { info in
            Row(id: info.id,
                name: info.name ?? info.id,
                note: info.note ?? "",
                isDefault: info.id == AnthropicModelCatalog.defaultModelID)
        }
    }

    /// Whether `current` (the engine's live model id) is this row's — matched
    /// by PREFIX, the catalog's own lookup rule, so a date-suffixed id
    /// ("claude-sonnet-5-20260115") still lights its row.
    public static func isCurrent(rowID: String, current: String) -> Bool {
        current.hasPrefix(rowID)
    }

    /// The friendly name for the MODEL chip ("Sonnet 5"), or the raw id when
    /// the catalog doesn't know it (honest fallback — never a guess).
    public static func displayName(for model: String) -> String {
        AnthropicModelCatalog.lookup(forModel: model)?.name ?? model
    }
}

// MARK: - Bottom-pinned auto-scroll

/// The transcript's follow-the-stream state machine (M10-p-6): auto-scroll
/// stays pinned to the bottom ONLY while the user is already there — a user
/// who scrolled up to re-read is never fought. Headless with injected `now`
/// values so the grace window is deterministic under test.
///
/// The subtlety this models: an auto-scroll ANIMATION passes through
/// not-at-bottom geometry on its way down. Treating those transient frames as
/// "the user scrolled away" would unpin mid-stream and strand the view, so a
/// short grace window after each auto-scroll keeps intermediate geometry from
/// unpinning; real user scrolls outside that window unpin immediately, and
/// scrolling back to the bottom re-pins.
@MainActor
@Observable
public final class CopilotScrollFollow {
    /// True while the transcript should chase new content to the bottom.
    public private(set) var isPinned = true

    @ObservationIgnored private var autoScrollDeadline: TimeInterval = 0

    /// How close (pt) to the true bottom still counts as "at the bottom" —
    /// generous so sub-line jitter never unpins.
    nonisolated public static let bottomTolerance: Double = 36
    /// How long after an auto-scroll not-at-bottom geometry is ignored
    /// (covers the 0.15 s ease-out plus frame slop).
    nonisolated public static let autoScrollGrace: TimeInterval = 0.45

    public init() {}

    /// Pure geometry: is the scroll position within `tolerance` of the
    /// content's bottom? `offsetY` is the scrolled distance from the top
    /// (`-contentFrame.minY` in the scroll's coordinate space). Content
    /// shorter than the viewport is always "at the bottom" (the gap is
    /// negative). Nonisolated — pure math, callable from anywhere.
    nonisolated public static func isNearBottom(
        contentHeight: Double, viewportHeight: Double, offsetY: Double,
        tolerance: Double = bottomTolerance
    ) -> Bool {
        (contentHeight - viewportHeight - offsetY) <= tolerance
    }

    /// Feed every geometry change here. At-bottom re-pins unconditionally
    /// (and ends any grace window); not-at-bottom unpins only OUTSIDE the
    /// grace window (inside it, it's our own animation in flight).
    public func updateGeometry(atBottom: Bool, now: TimeInterval) {
        if atBottom {
            isPinned = true
            autoScrollDeadline = 0
        } else if now >= autoScrollDeadline {
            isPinned = false
        }
    }

    /// Call when transcript content grows (new entry, streamed delta, the
    /// working row appearing). Returns whether the view should scroll to the
    /// bottom — true only while pinned — and, when true, opens the grace
    /// window for the scroll animation it triggers.
    @discardableResult
    public func noteContentGrew(now: TimeInterval) -> Bool {
        guard isPinned else { return false }
        autoScrollDeadline = now + Self.autoScrollGrace
        return true
    }

    /// Programmatic re-pin: the rail's OWN layout events (first appear, the
    /// model picker resizing the transcript viewport) re-land the transcript
    /// at the bottom regardless of what transient geometry reported — they
    /// are never a user scroll. Pins and opens the grace window so the
    /// follow-up scroll's in-flight frames don't immediately unpin.
    public func forceFollow(now: TimeInterval) {
        isPinned = true
        autoScrollDeadline = now + Self.autoScrollGrace
    }

    /// The transcript's change signature: any growth a follow should chase —
    /// a new entry, a streamed delta growing the tail entry's text, or the
    /// turn-status flip that adds/removes the WORKING row. `Equatable` so the
    /// view can watch ONE value instead of the whole transcript.
    public struct GrowthKey: Equatable, Sendable {
        public var entryCount: Int
        public var tailTextLength: Int
        public var isRunning: Bool

        public init(entryCount: Int, tailTextLength: Int, isRunning: Bool) {
            self.entryCount = entryCount
            self.tailTextLength = tailTextLength
            self.isRunning = isRunning
        }
    }
}

// MARK: - Copy to clipboard

/// The pasteboard seam behind the rail's copy affordances (the "make AI
/// output copyable" user request): the app injects an NSPasteboard-backed
/// adapter (DAWApp `GeneralPasteboard`); tests inject a recording fake, so
/// copy logic is fully covered without ever touching the real clipboard.
/// Write-only on purpose — the rail never reads the clipboard back.
@MainActor
public protocol CopilotPasteboarding {
    /// Replaces the pasteboard contents with `string` (the general
    /// pasteboard's clearContents + setString pair in the real adapter).
    func write(_ string: String)
}

/// One transcript line reduced to what whole-reply copy needs — plain values
/// (the `GrowthKey` idiom: DAWAppKit never imports the engine's entry type;
/// the view projects `CopilotEngine.TranscriptEntry` down to this).
public struct CopilotCopyLine: Sendable, Equatable {
    /// The turn this line belongs to (`TranscriptEntry.turnID`).
    public var turnID: String
    /// The line's assistant prose — nil for EVERY other kind (user, thinking,
    /// tool call/result, failure), which is what keeps tool traffic and
    /// collapsed thinking out of a whole-reply copy by construction.
    public var assistantText: String?

    public init(turnID: String, assistantText: String?) {
        self.turnID = turnID
        self.assistantText = assistantText
    }
}

/// Pure text rules for what lands on the clipboard: raw text (no markdown
/// reprocessing), no trailing whitespace, assistant-only joins. A partial
/// (still-streaming) entry copies its current text — no special casing.
public enum CopilotCopyFormat {
    /// A single entry's copy text: exactly the entry's text with trailing
    /// whitespace/newlines dropped. Leading/internal whitespace is preserved
    /// — the copy is the raw text, not a reflow.
    public static func entryText(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// A turn's complete assistant output: its assistant text lines in
    /// transcript order, each trailing-trimmed, whitespace-only ones dropped,
    /// joined with ONE blank line. Empty when the turn has no assistant prose
    /// (the affordance hides, and `copyReply` refuses to blank the clipboard).
    public static func wholeReply(turnID: String, lines: [CopilotCopyLine]) -> String {
        lines.filter { $0.turnID == turnID }
            .compactMap(\.assistantText)
            .map(entryText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The newest turn that has assistant prose — the header affordance's
    /// target ("copy the latest reply"); nil (affordance hidden) when no
    /// reply exists yet. Whitespace-only prose doesn't count as a reply.
    public static func latestReplyTurnID(lines: [CopilotCopyLine]) -> String? {
        lines.last { line in
            guard let text = line.assistantText else { return false }
            return !entryText(text).isEmpty
        }?.turnID
    }
}
