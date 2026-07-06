import Foundation

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
