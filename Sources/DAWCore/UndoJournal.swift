import Foundation

/// A read-only projection of the undo/redo journal's LABELS for the history panel
/// and the `edit.history` wire command (m11-b). LABELS ONLY — the internal
/// `UndoEntry` values (each captured `EditState`) never cross this boundary, and
/// nothing here mutates the journal (stepping still goes only through
/// `ProjectStore.undo()`/`redo()`).
///
/// Both lists are NEWEST-FIRST (the ordering contract the wire command states
/// verbatim):
///   - `undo[0]` is the label `ProjectStore.undo()` reverses NEXT (the undo
///     stack's top); `undo` then descends into progressively OLDER edits.
///   - `redo[0]` is the label `ProjectStore.redo()` reapplies NEXT (the redo
///     stack's top); `redo` then descends into edits undone EARLIER.
/// Empty arrays mean nothing to undo / redo — `canUndo`/`canRedo` mirror
/// `ProjectStore.canUndo`/`canRedo` exactly.
public struct UndoHistory: Equatable, Sendable {
    /// Undo labels, newest-first (`[0]` = next undo).
    public let undo: [String]
    /// Redo labels, newest-first (`[0]` = next redo).
    public let redo: [String]
    /// True when there is at least one undoable edit.
    public var canUndo: Bool { !undo.isEmpty }
    /// True when there is at least one redoable edit.
    public var canRedo: Bool { !redo.isEmpty }

    public init(undo: [String], redo: [String]) {
        self.undo = undo
        self.redo = redo
    }
}

/// A normalized snapshot of everything undo/redo restores: the track list, the
/// master gain, and the persistable transport fields. Transport TRANSIENCE
/// (`isPlaying`, `isRecording`, `positionBeats`) is normalized OUT here so that
/// pressing play, moving the playhead, or rolling a take can never masquerade
/// as an undoable edit.
struct EditState: Equatable {
    var tracks: [Track]
    var masterVolume: Double
    /// NORMALIZED: `isPlaying == false`, `isRecording == false`,
    /// `positionBeats == 0`. Only the document-shaped fields carry meaning.
    var transport: TransportState
    /// Project-level groove palette (M5 iii-g). Additive — undo covers groove
    /// add/remove. Defaults to `[]` so entries captured before this field existed
    /// still compare equal.
    var grooveTemplates: [GrooveTemplate] = []
    /// Session markers (m11-c). Additive — undo covers marker add/remove/rename/
    /// move. Defaults to `[]` so entries captured before this field existed still
    /// compare equal.
    var markers: [Marker] = []
    /// The MASTER insert chain (m13-d). Additive — undo covers every master
    /// chain mutation; the restore funnel pushes `masterEffectsChanged` when
    /// it moved (the masterVolume twin). Defaults to `[]` so entries captured
    /// before this field existed still compare equal.
    var masterEffects: [EffectDescriptor] = []
    /// MASTER volume automation (m15-c). Additive — undo covers every master
    /// lane mutation; the restore funnel pushes `masterAutomationChanged` when
    /// it moved (the masterEffects twin). Defaults to `[]` so entries captured
    /// before this field existed still compare equal.
    var masterAutomation: [AutomationLane] = []
}

/// One undo (or redo) record: the state captured BEFORE an edit, a
/// human-readable label for the menu, and an optional coalescing `key`. Entries
/// sharing a key that land inside `UndoJournal.coalescingWindow` fold into one
/// so a fader drag or tempo scrub is a single undo step.
struct UndoEntry {
    let label: String
    /// nil disables coalescing (structural edits stand alone). Inverse entries
    /// pushed by undo/redo always carry a nil key.
    let key: String?
    let before: EditState
    /// The instant this entry last absorbed a coalesced edit; the sliding
    /// window is measured from here.
    var lastMergedAt: ContinuousClock.Instant
}

/// The undo/redo stacks plus their coalescing policy. Pure value type, held and
/// mutated only on `ProjectStore`'s main actor. Internal (not private) so the
/// DAWCore test suite can inspect the stacks and inject a deterministic clock.
struct UndoJournal {
    /// Depth cap per stack; the oldest entry is evicted past this.
    static let defaultCap = 100
    /// Same-key edits within this window fold into the current top entry.
    static let coalescingWindow: Duration = .milliseconds(800)

    var cap = defaultCap
    /// Clock seam. Production reads the wall/continuous clock; tests inject a
    /// controllable now to exercise coalescing merge/expiry/sliding.
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    /// Set right after an undo/redo: the very next recorded edit must NOT
    /// coalesce onto the just-restored top (whose `before` predates the
    /// restore). Cleared the moment a fresh edit appends.
    private var coalescingBarrier = false

    /// Label of the operation `undo()` would reverse, for the menu; nil when
    /// there is nothing to undo.
    var undoLabel: String? { undoStack.last?.label }
    /// Label of the operation `redo()` would reapply; nil when redo is empty.
    var redoLabel: String? { redoStack.last?.label }

    /// The undo stack's labels NEWEST-FIRST (m11-b): `[0]` is the label `popUndo`
    /// would reverse next — the stack TOP — descending into progressively OLDER
    /// edits. Labels only; the entries' captured `EditState`s stay private. A pure
    /// read — no mutation. The undo history panel + `edit.history` project this.
    var undoLabels: [String] { undoStack.reversed().map(\.label) }
    /// The redo stack's labels NEWEST-FIRST (m11-b): `[0]` is the label `popRedo`
    /// would reapply next — the stack TOP — descending into edits undone EARLIER.
    /// Mirror of `undoLabels`; pure read.
    var redoLabels: [String] { redoStack.reversed().map(\.label) }

    /// Records a fresh edit. Any pending redo is discarded (a new edit forks
    /// history). The edit coalesces onto the current undo top IFF no barrier is
    /// pending, both keys are non-nil and equal, and the top last merged inside
    /// the (sliding) window — in which case only the timestamp advances and the
    /// original `before`/`label` are kept. Otherwise the barrier is cleared, the
    /// entry is appended, and the oldest entry is evicted past `cap`.
    mutating func recordEdit(label: String, key: String?, before: EditState) {
        redoStack.removeAll()
        let t = now()
        if !coalescingBarrier,
           let key,
           let top = undoStack.last,
           top.key == key,
           top.lastMergedAt.duration(to: t) <= Self.coalescingWindow {
            undoStack[undoStack.count - 1].lastMergedAt = t
            return
        }
        coalescingBarrier = false
        undoStack.append(UndoEntry(label: label, key: key, before: before, lastMergedAt: t))
        evict(&undoStack)
    }

    /// Pops the newest undo entry, records its inverse (the CURRENT state) onto
    /// the redo stack, and arms the coalescing barrier. Returns the popped
    /// entry (whose `before` the caller restores), or nil when nothing is
    /// undoable.
    mutating func popUndo(current: EditState) -> UndoEntry? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(UndoEntry(label: entry.label, key: nil, before: current, lastMergedAt: now()))
        evict(&redoStack)
        coalescingBarrier = true
        return entry
    }

    /// Mirror of `popUndo` for redo — pops the newest redo entry and records its
    /// inverse onto the undo stack — WITHOUT clearing redo (a redo must leave
    /// the rest of the redo chain intact).
    mutating func popRedo(current: EditState) -> UndoEntry? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(UndoEntry(label: entry.label, key: nil, before: current, lastMergedAt: now()))
        evict(&undoStack)
        coalescingBarrier = true
        return entry
    }

    /// Drops both stacks and the barrier — used at a load boundary (open/new)
    /// where prior history no longer applies to the swapped-in session.
    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        coalescingBarrier = false
    }

    /// Evicts oldest entries so `stack` holds at most `cap`.
    private func evict(_ stack: inout [UndoEntry]) {
        if stack.count > cap {
            stack.removeFirst(stack.count - cap)
        }
    }
}
