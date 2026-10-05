import Foundation
import Testing
@testable import DAWAppKit

/// m34-i — THE SEQUENCE-POSITION PLAYER, on its own.
///
/// ⭐ **THIS SUITE EXISTS BECAUSE THE PLAYER IS THE HALF THAT OUTLIVES THE
/// ITEM.** m34-i drives it at length 4 with a hand-authored progression; Playbox
/// (m34-g) drives the same object with a generated sequence and exposes all
/// three advance modes as a runtime choice. So `.onBeat` and `.free` — which
/// nothing calls yet — are pinned here, deliberately, so the advance rule is
/// **one parameter** rather than three code paths that drift.
@Suite("Chord sequence player (m34-i)")
struct ChordSequencePlayerTests {

    /// I–V–vi–IV: the Four Chords, in degrees.
    private let fourChords = [1, 5, 6, 4]

    // MARK: - Where the cursor starts

    @Test("a fresh sequence points at its FIRST chord, not at nothing")
    func startsOnStepOne() {
        let player = ChordSequencePlayer(steps: fourChords)
        #expect(player.position == 0)
        #expect(player.nextStep == 1)
        #expect(player.nextDegree == 1)
        #expect(player.count == 4)
        #expect(!player.isEmpty)
        // ⚠️ THE VALUE TYPE'S OWN DEFAULT IS UNCHANGED AT m34-g. The *controller*
        // now defaults to `.free` (the mode the user was told would lead), and
        // it passes its choice in explicitly — see
        // `MusicalTypingController.advanceMode`. Leaving this default alone
        // keeps every assertion below reading as written.
        #expect(player.advanceMode == .onMatch, "the value type's default, passed explicitly by the controller")
    }

    @Test("an empty sequence cues nothing and cannot be advanced into a crash")
    func emptySequenceIsInert() {
        var player = ChordSequencePlayer(steps: [])
        #expect(player.isEmpty)
        #expect(player.nextDegree == nil)
        #expect(player.nextStep == nil)
        player.advance()
        #expect(player.position == 0)
        #expect(player.played(degree: 1) == false)
        #expect(player.beat() == false)
    }

    // MARK: - Following the lights

    @Test("playing the cued chord moves the cursor to the next one")
    func matchAdvances() {
        var player = ChordSequencePlayer(steps: fourChords)
        #expect(player.played(degree: 1) == true)
        #expect(player.nextDegree == 5)
        #expect(player.nextStep == 2)
        #expect(player.played(degree: 5) == true)
        #expect(player.nextDegree == 6)
        #expect(player.played(degree: 6) == true)
        #expect(player.nextDegree == 4)
    }

    /// ⛔⛔ **THE ASSERTION THE WHOLE ITEM WOULD BE WRONG WITHOUT.** The lights are
    /// a CUE, never a GATE — the entire promise of the lit-preset design is that
    /// you can wander off it. Playing some other chord neither moves the cue nor
    /// is refused; there is no refusal to make, because nothing here is on the
    /// sounding path at all.
    @Test("⛔ playing a chord that is NOT the cued one leaves the cursor exactly where it was")
    func nonMatchDoesNotAdvance() {
        var player = ChordSequencePlayer(steps: fourChords)
        #expect(player.played(degree: 2) == false, "ii is not the cue")
        #expect(player.played(degree: 7) == false)
        #expect(player.played(degree: 4) == false, "IV IS in the progression — but not YET")
        #expect(player.nextStep == 1, "…and none of that moved the cursor")
        #expect(player.nextDegree == 1)
        // And the cue still works after wandering.
        #expect(player.played(degree: 1) == true)
        #expect(player.nextStep == 2)
    }

    @Test("the sequence WRAPS — a four-chord loop is a loop")
    func wrapsAtTheEnd() {
        var player = ChordSequencePlayer(steps: fourChords)
        for degree in fourChords { #expect(player.played(degree: degree) == true) }
        #expect(player.position == 0, "back to the top after the fourth chord")
        #expect(player.nextDegree == 1)
        // Round two behaves identically.
        #expect(player.played(degree: 1) == true)
        #expect(player.nextDegree == 5)
    }

    @Test("a repeated degree is matched by POSITION, not by first appearance")
    func repeatedDegreesAreMatchedPositionally() {
        // No shipped preset repeats a degree, so this pins the player rather than
        // the library — Playbox generates sequences and will.
        var player = ChordSequencePlayer(steps: [1, 5, 1, 4])
        #expect(player.played(degree: 1) == true)
        #expect(player.nextStep == 2)
        #expect(player.played(degree: 1) == false, "step 2 is V, even though I recurs later")
        #expect(player.played(degree: 5) == true)
        #expect(player.nextStep == 3)
        #expect(player.nextDegree == 1, "…and step 3 is the SECOND I")
    }

    @Test("rewind puts the cursor back on the first chord")
    func rewindReturnsToTheTop() {
        var player = ChordSequencePlayer(steps: fourChords)
        player.played(degree: 1)
        player.played(degree: 5)
        #expect(player.nextStep == 3)
        player.rewind()
        #expect(player.nextStep == 1)
        #expect(player.nextDegree == 1)
    }

    // MARK: - The advance mode is ONE parameter (m34-g's, arriving early)

    /// ⛔⛔ **THE MODE IS A PARAMETER OF ONE PLAYER, NOT THREE CODE PATHS.** The
    /// user chose all three advance models for Playbox; if `.onBeat` and `.free`
    /// were left unwritten until then, they would arrive as a fork of this logic.
    @Test("⛔ on-the-beat mode ignores note-ons and advances on the BEAT")
    func onBeatModeAdvancesOnTheBeat() {
        var player = ChordSequencePlayer(steps: fourChords, advanceMode: .onBeat)
        #expect(player.played(degree: 1) == false,
                "playing the cued chord must not move an on-the-beat cursor")
        #expect(player.nextStep == 1)
        #expect(player.beat() == true)
        #expect(player.nextDegree == 5, "the beat moved it, and it kept up on its own")
        #expect(player.beat() == true)
        #expect(player.beat() == true)
        #expect(player.beat() == true)
        #expect(player.nextStep == 1, "…and it wraps through the same advance()")
    }

    /// ⛔⛔ **RE-PURPOSED AT m34-g WITH ITS ASSERTIONS INVERTED, AND THE OLD
    /// BEHAVIOUR WAS WRONG RATHER THAN MERELY DIFFERENT.** It used to assert
    /// that `.free` ignored a played chord entirely. But the look-ahead queue
    /// ships in EVERY mode (it is what tells Four Chords from Doo-Wop at rest),
    /// so a `.free` that advanced on a match only would be behaviourally
    /// identical to `.onMatch` — and a three-position switch with two identical
    /// positions is a UI that lies about having three modes. `.free` is *"lights
    /// run ahead, timing is yours"*: **every chord you sound consumes one
    /// suggestion**, matched or not, because you are writing and what you played
    /// IS the take.
    @Test("⛔ free mode consumes a step on ANY chord — matched or not — and the beat does not touch it")
    func freeModeConsumesAStepOnAnyChord() {
        var player = ChordSequencePlayer(steps: fourChords, advanceMode: .free)
        #expect(player.nextDegree == 1)
        #expect(player.played(degree: 2) == true, "ii is not the cue — and it still consumes a step")
        #expect(player.nextStep == 2)
        #expect(player.played(degree: 5) == true, "…and so does the cued chord")
        #expect(player.nextStep == 3)
        // ⛔ THE CLICK DOES NOT DRIVE THIS MODE. Only playing does.
        #expect(player.beat() == false)
        #expect(player.nextStep == 3)
        // The explicit consumer still works — it is the one cursor move.
        player.advance()
        #expect(player.nextStep == 4)
    }

    /// ⛔ **THE CONTROL FOR THE TEST ABOVE.** If `.free`'s change had leaked into
    /// `.onMatch`, wait-for-you would stop waiting — which is the entire point of
    /// that mode.
    @Test("⛔ the free-mode rule does NOT leak into wait-for-you")
    func onMatchStillRefusesToAdvanceOnAWrongChord() {
        var player = ChordSequencePlayer(steps: fourChords, advanceMode: .onMatch)
        #expect(player.played(degree: 2) == false)
        #expect(player.played(degree: 6) == false)
        #expect(player.nextStep == 1, "wait-for-you waits")
    }

    /// ⛔ On-the-beat is driven by the click and by NOTHING ELSE — a note-on must
    /// not race the metronome, or the lights run away from the thing driving
    /// them.
    @Test("⛔ on-the-beat ignores a played chord in BOTH directions")
    func onBeatIgnoresPlaying() {
        var player = ChordSequencePlayer(steps: fourChords, advanceMode: .onBeat)
        #expect(player.played(degree: 1) == false, "even the CUED chord")
        #expect(player.played(degree: 3) == false, "and any other")
        #expect(player.nextStep == 1)
    }

    // MARK: - The look-ahead queue (m34-g)

    /// ⭐⭐ **THE ASSERTION THIS ITEM EXISTS FOR.** m34-i's own close recorded the
    /// limit it could not fix: Four Chords `[1,5,6,4]` and Doo-Wop `[1,6,4,5]`
    /// light the same four degrees AND both open on I, so with only a cue they
    /// are indistinguishable until the first chord is played. The queue is what
    /// separates them before a note is struck.
    @Test("⭐ the queue tells Four Chords from Doo-Wop AT REST, which a cue alone cannot")
    func queueSeparatesTwoRotationsOfTheSameChords() {
        let four = ChordSequencePlayer(steps: [1, 5, 6, 4])
        let dooWop = ChordSequencePlayer(steps: [1, 6, 4, 5])
        // The cue is identical — this is the defect, restated as an assertion.
        #expect(four.nextDegree == dooWop.nextDegree)
        // The queue is not.
        #expect(four.upcomingDegrees(depth: 3) == [5, 6, 4])
        #expect(dooWop.upcomingDegrees(depth: 3) == [6, 4, 5])
        #expect(four.upcomingDegrees(depth: 3) != dooWop.upcomingDegrees(depth: 3),
                "…and that difference is what the row finally paints")
        #expect(four.rankByDegree(depth: 3) == [1: 0, 5: 1, 6: 2, 4: 3])
        #expect(dooWop.rankByDegree(depth: 3) == [1: 0, 6: 1, 4: 2, 5: 3])
    }

    @Test("the queue MOVES with the cursor and wraps with it")
    func queueFollowsTheCursor() {
        var player = ChordSequencePlayer(steps: [1, 5, 6, 4])
        player.played(degree: 1)
        #expect(player.upcomingDegrees(depth: 3) == [6, 4, 1], "…wrapping onto the loop's top")
        player.played(degree: 5)
        #expect(player.upcomingDegrees(depth: 3) == [4, 1, 5])
    }

    /// ⚠️ A queue that wrapped onto its own cue would paint a "coming up" light
    /// on the chord it is simultaneously telling you to play right now.
    @Test("⚠️ a SHORT loop never shows the cue twice — ii–V–I queues two, not three")
    func shortLoopDoesNotRepeatTheCue() {
        let player = ChordSequencePlayer(steps: [2, 5, 1])
        #expect(player.upcomingDegrees(depth: 3) == [5, 1], "three asked for, two available")
        #expect(player.rankByDegree(depth: 3) == [2: 0, 5: 1, 1: 2])
        let single = ChordSequencePlayer(steps: [1])
        #expect(single.upcomingDegrees(depth: 3).isEmpty)
        #expect(single.rankByDegree(depth: 3) == [1: 0])
    }

    /// ⚠️ ONE degree is ONE cell on the chord row, so a repeated degree cannot be
    /// painted twice. The honest answer is its SOONEST rank; the cost is that
    /// such a sequence marks fewer cells than it has steps, and that is pinned
    /// rather than glossed.
    @Test("⚠️ a repeated degree resolves to its SOONEST rank")
    func repeatedDegreeTakesItsSoonestRank() {
        let player = ChordSequencePlayer(steps: [1, 5, 1, 4])
        #expect(player.rankByDegree(depth: 3) == [1: 0, 5: 1, 4: 3],
                "the second I is rank 2 and is dropped — I already reads as rank 0")
        #expect(player.rankByDegree(depth: 3).count == 3, "three marks for four steps")
    }

    @Test("an empty sequence has an empty queue, and depth 0 asks for nothing")
    func queueDegenerateCases() {
        let empty = ChordSequencePlayer(steps: [])
        #expect(empty.upcomingDegrees(depth: 3).isEmpty)
        #expect(empty.rankByDegree(depth: 3).isEmpty)
        let player = ChordSequencePlayer(steps: [1, 5, 6, 4])
        #expect(player.upcomingDegrees(depth: 0).isEmpty)
        #expect(player.rankByDegree(depth: 0) == [1: 0], "depth 0 is the cue and nothing else")
        #expect(player.upcomingDegrees(depth: -5).isEmpty, "a negative depth is not a crash")
    }

    /// ⛔ The queue is a PROJECTION. Reading it must not move anything — a view
    /// that redrew the cue would otherwise advance the performance.
    @Test("⛔ reading the queue does not move the cursor")
    func queueIsPure() {
        let player = ChordSequencePlayer(steps: [1, 5, 6, 4])
        _ = player.upcomingDegrees(depth: 3)
        _ = player.rankByDegree(depth: 3)
        #expect(player.position == 0)
        #expect(player.nextStep == 1)
    }

    @Test("every advance mode moves the cursor through the SAME advance(), wrapping identically")
    func allModesShareOneCursorMove() {
        for mode in ChordSequenceAdvanceMode.allCases {
            var player = ChordSequencePlayer(steps: fourChords, advanceMode: mode)
            for _ in 0..<4 { player.advance() }
            #expect(player.position == 0, "\(mode.rawValue) must wrap like every other mode")
        }
        #expect(ChordSequenceAdvanceMode.allCases.count == 3,
                "wait-for-you, on-the-beat and lights-run-ahead — the user chose all three")
    }
}
