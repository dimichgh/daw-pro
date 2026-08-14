import Foundation
import Testing
@testable import DAWAppKit

/// m25-o — ⌘-click on empty grid positions the playhead, and the three shipped
/// arms beside it do not move.
///
/// ⚠️ **THREE OF THESE FIVE ARMS ARE PRE-EXISTING BEHAVIOUR THIS ITEM COULD HAVE
/// BROKEN**, and one of them — plain click on empty grid deselects — is m25-m, a
/// fix a human confirmed by hand days before this item was written. That is why
/// the resolver returns an enum rather than a `Bool`: a `placesPlayhead` predicate
/// would leave the other arms testable only through source-text site pins, and
/// this repo has already shipped two site pins that a different symbol satisfied
/// as a prefix. Here every arm is a value, and a mutation to any one of them
/// reddens a real assertion.
@Suite("PianoRollGridPress — the grid-release truth table (m25-o)")
struct PianoRollGridReleaseTests {

    private static let note = UUID()

    // MARK: - The four arms the user's request turns on

    @Test("⌘-click on EMPTY grid positions the playhead — the one new arm")
    func commandOnEmptyPositionsPlayhead() {
        #expect(PianoRollGridPress.release(noteID: nil, modifiers: [.command])
                == .positionPlayhead)
        // And the derived predicate the CURSOR asks agrees, because it is the
        // same function. A cursor promising a playhead over a release that
        // deselects is the exact failure this pairing exists to prevent.
        #expect(PianoRollGridPress.placesPlayhead(noteID: nil, modifiers: [.command]))
    }

    @Test("⌘-click on a NOTE still TOGGLES it — the conflict the user anticipated")
    func commandOnNoteStillToggles() {
        // ⌘ already means add/remove-from-selection here. A bare "⌘ ⇒ playhead"
        // rule would have destroyed additive selection silently; the hit test is
        // the extra term that keeps it.
        #expect(PianoRollGridPress.release(noteID: Self.note, modifiers: [.command])
                == .toggle(Self.note))
        #expect(PianoRollGridPress.placesPlayhead(noteID: Self.note,
                                                  modifiers: [.command]) == false)
    }

    @Test("plain click on EMPTY grid still deselects — m25-m, confirmed by hand")
    func plainOnEmptyStillDeselects() {
        #expect(PianoRollGridPress.release(noteID: nil, modifiers: []) == .deselect)
        #expect(PianoRollGridPress.placesPlayhead(noteID: nil, modifiers: []) == false)
    }

    @Test("plain click on a NOTE still selects only it")
    func plainOnNoteStillSelectsOnly() {
        #expect(PianoRollGridPress.release(noteID: Self.note, modifiers: [])
                == .selectOnly(Self.note))
    }

    // MARK: - The arm this item deliberately did NOT change

    @Test("⇧ on empty grid still does NOTHING — the intent table is not the gate")
    func shiftOnEmptyDoesNothing() {
        // `ArrangeClickIntent` maps ⇧ and ⌘ both to `.toggle`, so keying the new
        // arm on the INTENT would have given ⇧-click-on-empty a transport jump
        // too — a chord the user never asked about and holds constantly for other
        // reasons. This is the ONE place the roll reads `.command` specifically,
        // and this assertion is what that decision costs if someone "simplifies"
        // it back to the shared intent.
        #expect(ArrangeClickIntent.intent(for: [.shift]) == .toggle,
                "premise check — if ⇧ stopped meaning toggle, this test's point moved")
        #expect(PianoRollGridPress.release(noteID: nil, modifiers: [.shift]) == .doNothing)
        #expect(PianoRollGridPress.placesPlayhead(noteID: nil, modifiers: [.shift]) == false)
    }

    @Test("⇧ on a NOTE still toggles it, exactly as ⌘ does")
    func shiftOnNoteToggles() {
        #expect(PianoRollGridPress.release(noteID: Self.note, modifiers: [.shift])
                == .toggle(Self.note))
    }

    @Test("⇧⌘ on empty grid DOES place the playhead — the rule is '⌘ is present'")
    func shiftCommandOnEmptyPositionsPlayhead() {
        // Stated as a test because the alternative reading ("⌘ ALONE") is the
        // natural one and is not what the code does. A user holding ⇧ from a
        // previous gesture must not find ⌘ silently disabled.
        #expect(PianoRollGridPress.release(noteID: nil, modifiers: [.shift, .command])
                == .positionPlayhead)
    }

    // MARK: - Totality

    @Test("every chord × hit combination resolves, and empty/note never collide")
    func tableIsTotalAndDisjoint() {
        let chords: [ArrangeClickModifiers] = [[], [.shift], [.command], [.shift, .command]]
        for chord in chords {
            // A note is under the pointer: the playhead arm is unreachable for
            // EVERY chord. This is the invariant the user's "avoid conflicts"
            // request reduces to, asserted over the whole chord space rather than
            // at the two points a hand-picked example would cover.
            let onNote = PianoRollGridPress.release(noteID: Self.note, modifiers: chord)
            #expect(onNote != .positionPlayhead,
                    "a press on a note must never move the transport (chord \(chord.rawValue))")
            #expect(onNote != .deselect)
            #expect(onNote != .doNothing)
            // Empty grid: never a note-scoped outcome.
            let onEmpty = PianoRollGridPress.release(noteID: nil, modifiers: chord)
            #expect(onEmpty != .selectOnly(Self.note))
            #expect(onEmpty != .toggle(Self.note))
        }
    }
}

/// m25-o — the clip-local → project hand-off, and the clamp that keeps a
/// placement inside the edited clip.
@Suite("PianoRollPlayhead.projectBeat — placement mapping (m25-o)")
struct PianoRollPlayheadPlacementTests {

    @Test("a clip-local beat is offset onto the project timeline")
    func offsetsOntoTimeline() {
        // Clip starts at project beat 8; local beat 2 is project beat 10.
        #expect(PianoRollPlayhead.projectBeat(localBeat: 2, clipStartBeat: 8,
                                              lengthBeats: 16) == 10)
    }

    @Test("⭐ the result is a PROJECT beat, which is why the arrange playhead follows for free")
    func resultIsProjectSpace() {
        // The user asked that positioning in the roll "also reposition the same
        // playhead in track area". There is ONE transport position, so this is
        // not a mirroring feature — it is the same number. Pinned because the
        // tempting "fix" for a future bug here is to add a sync path, and a
        // second writer to the transport is how the two surfaces start to
        // disagree.
        let projectBeat = PianoRollPlayhead.projectBeat(localBeat: 3, clipStartBeat: 100,
                                                        lengthBeats: 16)
        #expect(projectBeat == 103)
        // And it round-trips through the renderer's own local mapping, so the
        // line lands where the click asked.
        #expect(PianoRollPlayhead.localBeat(position: projectBeat, clipStartBeat: 100) == 3)
    }

    @Test("placement is clamped to the clip span at BOTH ends")
    func clampsToClip() {
        // Past the end -> the clip's end, never beyond: a placement gesture must
        // not walk the transport out of the editor's own span.
        #expect(PianoRollPlayhead.projectBeat(localBeat: 99, clipStartBeat: 8,
                                              lengthBeats: 16) == 24)
        // Before the start -> the clip's start.
        #expect(PianoRollPlayhead.projectBeat(localBeat: -5, clipStartBeat: 8,
                                              lengthBeats: 16) == 8)
    }

    @Test("a degenerate clip length collapses to the clip start rather than going negative")
    func degenerateLengthIsSafe() {
        #expect(PianoRollPlayhead.projectBeat(localBeat: 4, clipStartBeat: 8,
                                              lengthBeats: -3) == 8)
    }

    @Test("the free scrub still maps exactly as it did — the refactor is behaviour-neutral")
    func scrubUnchanged() {
        // `scrubProjectBeat` now delegates its clamp+offset to `projectBeat`.
        // This pins that the delegation did not change the shipped answer, which
        // is the whole risk of extracting a helper out from under a live gesture.
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 64, clipStartBeat: 8,
                                                   lengthBeats: 16, pixelsPerBeat: 32) == 10)
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: -20, clipStartBeat: 8,
                                                   lengthBeats: 16, pixelsPerBeat: 32) == 8)
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 9999, clipStartBeat: 8,
                                                   lengthBeats: 16, pixelsPerBeat: 32) == 24)
        // Zero scale must not divide by zero.
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 50, clipStartBeat: 8,
                                                   lengthBeats: 16, pixelsPerBeat: 0) == 8)
    }
}

/// m25-o — SNAP. The user's ruling is that one snap model governs playhead
/// positioning: *"snap it to the position of the grid when snap is on, and
/// anywhere in clip when it is [off]."*
@Suite("Playhead placement respects the snap model (m25-o)")
@MainActor
struct PianoRollPlacementSnapTests {

    private func model() -> PianoRollModel {
        PianoRollModel(clipLengthBeats: 16, pixelsPerBeat: 32)
    }

    @Test("snap ON rounds the placement to the nearest grid line")
    func snapOnRounds() {
        let m = model()
        // x 70 at 32 px/beat is local beat 2.1875 -> nearest beat is 2.
        let raw = m.beat(forX: 70)
        #expect(m.snap(beat: raw, resolution: .beat) == 2)
        #expect(PianoRollPlayhead.projectBeat(localBeat: m.snap(beat: raw, resolution: .beat),
                                              clipStartBeat: 8, lengthBeats: 16) == 10)
    }

    @Test("snap OFF lands anywhere in the clip — free placement, the user's other mode")
    func snapOffIsFree() {
        let m = model()
        let raw = m.beat(forX: 70)
        #expect(m.snap(beat: raw, resolution: .off) == raw)
        #expect(raw != 2, "premise — if x 70 were already on a grid line this test proves nothing")
    }

    @Test("⚠️ the snap is applied in CLIP-LOCAL space, so an off-grid clip start cannot shift it")
    func snapIsClipLocal() {
        // THE BUG THIS PREVENTS: snapping the PROJECT beat instead would land the
        // playhead on the ARRANGE's grid, which is a different set of lines
        // whenever `clipStartBeat` is not a multiple of the meter — i.e. visibly
        // off the line the user aimed at, in exactly the case snapping exists for.
        // The roll's grid, bar emphasis and ruler labels are all clip-local
        // (`PianoRollScrubRuler`'s axis note), so clip-local is what the user sees.
        let m = model()
        let offGridClipStart = 8.25
        let local = m.snap(beat: m.beat(forX: 70), resolution: .beat)
        let placed = PianoRollPlayhead.projectBeat(localBeat: local,
                                                   clipStartBeat: offGridClipStart,
                                                   lengthBeats: 16)
        // Lands on the CLIP's beat 2 — which is project 10.25, deliberately NOT a
        // whole project beat.
        #expect(placed == 10.25)
        #expect(PianoRollPlayhead.localBeat(position: placed,
                                            clipStartBeat: offGridClipStart) == 2)
    }

    @Test("a snapped placement past the clip end is clamped, not snapped outside")
    func snapThenClampOrder() {
        // Order matters: snap FIRST (in clip-local space), clamp SECOND. Clamping
        // first would let the snap push the result back outside the clip.
        let m = model()
        let local = m.snap(beat: m.beat(forX: 32 * 20), resolution: .bar)
        #expect(local > 16, "premise — the snapped beat must exceed the clip length")
        #expect(PianoRollPlayhead.projectBeat(localBeat: local, clipStartBeat: 8,
                                              lengthBeats: 16) == 24)
    }
}
