import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// m23-aj-3 — the VERTICAL (↑/↓) half of the arrange arrow-key nudge.
///
/// SCOPE, and why it is narrower than `ArrangeNudgeTests`. The horizontal rule
/// has four competing magnitude sources and a grid to read, so its suite has to
/// compose `ArrangeNudge.step` with `ProjectStore.moveClips` to see a weld or a
/// clamp. The vertical rule has ONE magnitude (±1 lane, always) and no grid, so
/// everything decidable here is decidable from the pure function; the store-side
/// behaviour it feeds — the whole-group top/bottom clamp, the kind refusal, the
/// manufactured-collision refusal — is already proven by
/// `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift` against the verb itself,
/// and re-asserting it through a keyboard fixture here would be a second, weaker
/// copy of that suite.
///
/// WHAT THESE TESTS CANNOT REACH, stated rather than implied: `DAWApp` has no
/// test target, so `AppModel.handleArrangeNudgeKey`'s six guards, the
/// `ArrangeNudgeAxisKey` routing, and the vertical CONSUME rule (a `.store`
/// refusal returns `handled: true` on this axis and `false` on the horizontal
/// one) are UNREACHABLE from here. That half is proven by
/// `scripts/gates/m23aj-cross-track-move.mjs` against a real app on staging.
///
/// EVERY MODIFIER LEG IS A CONTROLLED PAIR. A leg that only asserts nil for ⇧
/// passes against a `verticalStep` that returns nil for everything, including a
/// bare press — i.e. against a completely dead key. So each one strips the
/// modifier and asserts the SAME call then answers.
@Suite("Arrange vertical arrow-key nudge (m23-aj-3)")
struct ArrangeVerticalNudgeTests {

    /// The four chord modifiers, singly. Named so a failure says WHICH.
    private static let singles: [(String, TransportKeyModifiers)] = [
        ("⌘", .command), ("⌃", .control), ("⇧", .shift), ("⌥", .option),
    ]

    // MARK: - The direction enum

    @Test("trackSign is the ONE home for a vertical arrow's sign, and the two are exact opposites")
    func trackSignIsOpposite() {
        #expect(ArrangeVerticalNudgeDirection.up.trackSign == -1)
        #expect(ArrangeVerticalNudgeDirection.down.trackSign == 1)
        // Not merely "one is negative": the pair must be exact opposites, which
        // is what makes ↑ then ↓ a round trip rather than two unrelated moves.
        #expect(ArrangeVerticalNudgeDirection.up.trackSign
                == -ArrangeVerticalNudgeDirection.down.trackSign)
    }

    /// ⚠️ THIS LEG IS A TRIPWIRE, NOT A COUNT. `ArrangeVerticalNudgeDirection`
    /// exists precisely so that `ArrangeNudgeDirection` keeps exactly two cases
    /// (design §10.1: a third case there would force `sign: Double`,
    /// `magnitudeBeats` and `source` to lie). If someone later adds `.up`/`.down`
    /// to the HORIZONTAL enum and deletes this one, this leg is what notices.
    @Test("the vertical enum has exactly two cases, and each round-trips its own sign")
    func allCasesRoundTrip() {
        #expect(ArrangeVerticalNudgeDirection.allCases.count == 2)
        for direction in ArrangeVerticalNudgeDirection.allCases {
            let step = ArrangeNudge.verticalStep(direction: direction, modifiers: [])
            #expect(step?.direction == direction)
            // The step's delta may not be a SECOND opinion about the sign — it
            // must be `trackSign` itself, or the enum stops being the one home.
            #expect(step?.trackDelta == direction.trackSign)
            #expect(abs(step?.trackDelta ?? 0) == 1)
        }
    }

    // MARK: - The bare press

    @Test("a bare ↑ steps exactly one lane UP, a bare ↓ exactly one lane DOWN")
    func barePressStepsOneLane() {
        let up = ArrangeNudge.verticalStep(direction: .up, modifiers: [])
        let down = ArrangeNudge.verticalStep(direction: .down, modifiers: [])
        #expect(up?.trackDelta == -1)
        #expect(down?.trackDelta == 1)
        #expect(up?.direction == .up)
        #expect(down?.direction == .down)
    }

    /// There is no coarse/fine variant on this axis — a lane is a lane. This
    /// pins that the magnitude is a CONSTANT ±1 and not, say, something that
    /// grows with a grid the way the horizontal step does.
    @Test("the magnitude is always exactly one lane, in both directions")
    func magnitudeIsAlwaysOne() {
        for direction in ArrangeVerticalNudgeDirection.allCases {
            #expect(abs(ArrangeNudge.verticalStep(direction: direction,
                                                  modifiers: [])?.trackDelta ?? 0) == 1)
        }
    }

    // MARK: - Modifier policy: BARE PRESS ONLY (each a controlled pair)

    @Test("⌘ / ⌃ / ⇧ / ⌥ each PASS THROUGH — and the same call answers without them",
          arguments: ArrangeVerticalNudgeDirection.allCases)
    func everySingleModifierPassesThrough(direction: ArrangeVerticalNudgeDirection) {
        for (name, modifier) in Self.singles {
            #expect(ArrangeNudge.verticalStep(direction: direction, modifiers: modifier) == nil,
                    "\(name)\(direction.rawValue) must pass through, not nudge")
            // THE CONTROLLED HALF. Without it this leg passes against a
            // `verticalStep` that returns nil unconditionally, i.e. a dead key.
            #expect(ArrangeNudge.verticalStep(direction: direction, modifiers: []) != nil,
                    "the bare press must still answer (else the \(name) leg is vacuous)")
        }
    }

    /// ⇧ AND ⌥ ARE THE DECISION, not an accident of copying the horizontal rule
    /// — there they carry meaning (⇧ = one bar, ⌥ = the fine step). Here they are
    /// RESERVED for extend-selection and duplicate-down, so this leg is the
    /// regression guard against someone "fixing" the asymmetry by making ⇧↓ nudge.
    @Test("⇧ and ⌥ pass through on this axis even though they MEAN something on the other one")
    func reservedModifiersDifferFromTheHorizontalAxis() {
        // Horizontal: both answer, with DIFFERENT magnitudes — so the vertical
        // nil below is a real difference in policy, not the same rule twice.
        let horizontalShift = ArrangeNudge.step(direction: .right, modifiers: .shift,
                                                snap: .sixteenth, beatsPerBar: 4)
        let horizontalOption = ArrangeNudge.step(direction: .right, modifiers: .option,
                                                 snap: .sixteenth, beatsPerBar: 4)
        #expect(horizontalShift?.source == .bar)
        #expect(horizontalOption?.source == .fine)
        #expect(horizontalShift?.magnitudeBeats != horizontalOption?.magnitudeBeats)

        #expect(ArrangeNudge.verticalStep(direction: .down, modifiers: .shift) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .down, modifiers: .option) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .up, modifiers: .shift) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .up, modifiers: .option) == nil)
    }

    @Test("every COMBINATION of the four modifiers passes through too",
          arguments: ArrangeVerticalNudgeDirection.allCases)
    func everyChordPassesThrough(direction: ArrangeVerticalNudgeDirection) {
        // All 16 subsets of {⌘,⌃,⇧,⌥}: 0 is the bare press (must answer), the
        // other 15 are chords (must all pass through). Enumerated rather than
        // sampled, because "⌥ beats ⇧" on the horizontal axis proves that a
        // hand-picked list of chords is exactly where a precedence bug hides.
        let all: [TransportKeyModifiers] = [.command, .control, .shift, .option]
        for mask in 0..<16 {
            var mods: TransportKeyModifiers = []
            for (bit, m) in all.enumerated() where mask & (1 << bit) != 0 { mods.insert(m) }
            let step = ArrangeNudge.verticalStep(direction: direction, modifiers: mods)
            if mask == 0 {
                #expect(step?.trackDelta == direction.trackSign, "the bare press must answer")
            } else {
                #expect(step == nil, "chord mask \(mask) must pass through")
            }
        }
    }

    // MARK: - m25-l-1 ④ — WHICH LANE THE PRESS REACHES

    /// USER-REPORTED 2026-08-23: *"[cross-track clip drag] works when dragging
    /// by mouse over the audio, while if I use arrow keys, it gets stuck and
    /// does not jump over the audio track to the instrumental when it exists."*
    ///
    /// The mechanism, confirmed in code before any of this was written: the
    /// press could only ever REQUEST ±1, that ±1 landed on the audio row, and
    /// `moveClips(ids:byTracks:)` phase 2b threw
    /// `midiClipsRequireInstrumentTrack`. The mouse reached the far lane only
    /// because a pointer resolves an ABSOLUTE row and therefore requested ±2.
    ///
    /// ⚠️ NOTHING IN THIS TREE CAN PRESS AN ARROW KEY — `DAWApp` has no test
    /// target and the debug seam calls the handler directly, so these legs
    /// exercise the DECISION and its composition with the real store, never the
    /// gesture. The keystroke itself needs a human, or
    /// `scripts/gates/m23aj-cross-track-move.mjs` against a staging app.

    private static func midiClip(_ name: String, start: Double = 0) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: 4, notes: [])
    }

    private static func audioClip(_ name: String, start: Double = 0) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: 4,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    private static func inst(_ name: String, _ clips: [Clip] = []) -> Track {
        Track(name: name, kind: .instrument, clips: clips)
    }

    private static func audio(_ name: String, _ clips: [Clip] = []) -> Track {
        Track(name: name, kind: .audio, clips: clips)
    }

    private static func bus(_ name: String) -> Track { Track(name: name, kind: .bus) }

    /// The press, taken from its ONE producer. `ArrangeVerticalNudgeStep`'s init
    /// is fileprivate precisely so no test can assemble a step the keyboard
    /// cannot produce, and this helper keeps that true here.
    private static func press(_ direction: ArrangeVerticalNudgeDirection)
        -> ArrangeVerticalNudgeStep {
        ArrangeNudge.verticalStep(direction: direction, modifiers: [])!
    }

    /// ⭐ THE DEFECT, EXACTLY AS REPORTED — and a CONTROLLED PAIR, because a leg
    /// that only asserts "2" also passes against a resolver that always returns
    /// 2. The second half is the same fixture with the middle lane made
    /// eligible: there the answer must still be the plain ±1, or the fix would
    /// have changed every press that already worked.
    @Test("a press passes OVER a lane that cannot hold the clip, and takes the next one")
    func aPressSkipsAnIneligibleLane() {
        let clip = Self.midiClip("a")
        let blocked = [Self.inst("A", [clip]), Self.audio("B"), Self.inst("C")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: blocked) == 2)

        let clear = [Self.inst("A", [clip]), Self.inst("B"), Self.inst("C")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: clear) == 1,
            "a lane that CAN hold the clip must still be asked for as a plain ±1")
    }

    @Test("↑ skips symmetrically — the direction is not special-cased")
    func upSkipsSymmetrically() {
        let clip = Self.midiClip("a")
        let tracks = [Self.inst("A"), Self.audio("B"), Self.inst("C", [clip])]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.up), movingClipIDs: [clip.id], tracks: tracks) == -2)
    }

    /// A bus draws a row and holds no clips of either kind, so it is the other
    /// shape of ineligible lane — the one `ProjectStore`'s axis doc used to name
    /// as an accepted cost (`[audio, BUS, audio]`).
    @Test("a bus row is passed over too, not landed on")
    func aBusRowIsPassedOver() {
        let clip = Self.midiClip("a")
        let tracks = [Self.inst("A", [clip]), Self.bus("Reverb"), Self.inst("C")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    @Test("an audio clip skips an instrument lane — the rule is Track.canHold, not a kind list")
    func anAudioClipSkipsAnInstrumentLane() {
        let clip = Self.audioClip("a")
        let tracks = [Self.audio("A", [clip]), Self.inst("B"), Self.audio("C")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    /// SMALLEST WINS. Two eligible lanes below, and the press must take the
    /// nearer one — a resolver that ran to the end of the list would also pass a
    /// test that only checked "it skipped something".
    @Test("the search takes the SMALLEST reachable delta, never the furthest")
    func theSearchTakesTheSmallestReachableDelta() {
        let clip = Self.midiClip("a")
        let tracks = [Self.inst("A", [clip]), Self.audio("B"), Self.inst("C"), Self.inst("D")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    /// ⭐ NO REACHABLE LANE → THE RAW PRESS, so the store refuses EXACTLY as it
    /// did before this existed. Returning 0 (a silent no-op) was rejected for
    /// the store's own stated reason: a dead key is indistinguishable from a
    /// broken one, and a refusal that says why is strictly more informative.
    @Test("with nothing eligible below, the raw ±1 is handed back so the store still refuses")
    func nothingEligibleFallsBackToTheRawPress() {
        let clip = Self.midiClip("a")
        let tracks = [Self.inst("A", [clip]), Self.audio("B"), Self.audio("C")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: tracks) == 1)
    }

    /// The bottom of the track list. Today's behaviour is a whole-group clamp to
    /// a no-op, and it survives because the fallback is the raw ±1 — a search
    /// that "found nothing" must not turn a clamp into anything else.
    @Test("at the end of the track list the press still asks for ±1 and the store clamps it")
    func atTheEndOfTheListTheRawPressSurvives() {
        let clip = Self.midiClip("a")
        let tracks = [Self.inst("A"), Self.inst("B", [clip])]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: tracks) == 1)
    }

    /// ⭐ RIGIDITY UNDER A MULTI-LANE SELECTION. `byTracks` carries ONE `Int` for
    /// the whole group by design, so "the next eligible track" is not defined per
    /// clip and is not attempted: the group moves as a block or not at all.
    /// Here +1 is legal for NEITHER mover and +2 is legal for BOTH.
    @Test("a selection spanning lanes gets ONE uniform delta, legal for every mover")
    func aSpanningSelectionGetsOneUniformDelta() {
        let midi = Self.midiClip("m")
        let wav = Self.audioClip("w")
        let tracks = [Self.inst("A", [midi]), Self.audio("B", [wav]),
                      Self.inst("C"), Self.audio("D")]
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [midi.id, wav.id], tracks: tracks) == 2)
    }

    /// The other half of rigidity: when NO single delta suits every mover, the
    /// group does not split and does not creep — it falls back to the raw press
    /// and the store refuses.
    @Test("no delta legal for EVERY mover falls back rather than moving the group partly")
    func noUniformDeltaFallsBack() {
        let midi = Self.midiClip("m")
        let wav = Self.audioClip("w")
        let tracks = [Self.inst("A", [midi]), Self.audio("B", [wav]),
                      Self.audio("C"), Self.inst("D")]
        // +1: midi → audio ✗. +2: midi → audio ✗. +3 would suit the midi clip
        // but pushes the audio clip past the last row, so the clamp ends the
        // search. Nothing reachable ⇒ the raw press.
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [midi.id, wav.id], tracks: tracks) == 1)
    }

    @Test("degenerate inputs return the raw press rather than inventing a delta")
    func degenerateInputsReturnTheRawPress() {
        let clip = Self.midiClip("a")
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [], tracks: [Self.inst("A", [clip])]) == 1)
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.up), movingClipIDs: [clip.id], tracks: []) == -1)
        // A STALE id names no mover, so there is nothing to reason about and the
        // raw press is the honest answer — the store then reports `clipNotFound`.
        #expect(ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [UUID()],
            tracks: [Self.inst("A", [clip]), Self.audio("B"), Self.inst("C")]) == 1)
    }

    /// ⭐⭐ THE ASYMMETRY PIN — THE TRAP THIS ITEM IS MOST LIKELY TO BREAK.
    ///
    /// One fixture, three questions, side by side, because the fix is only
    /// correct if the other two answers are UNCHANGED:
    ///
    ///   • the KEYBOARD reaches +2 (passes over the audio lane);
    ///   • the POINTER still BACKS OFF TO ZERO — a drag lands where you point,
    ///     and one that slid past the lane under the cursor would be a new and
    ///     worse bug (note this is a gesture-layer back-off, not a throw);
    ///   • the STORE still THROWS on a raw +1 — the ineligible lane was never
    ///     made a legal destination, only passed over.
    @MainActor
    @Test("mouse and store are UNCHANGED — only what the keyboard ASKS FOR moved")
    func theMouseAndTheStoreAreUnchanged() throws {
        let store = ProjectStore()
        let top = store.addTrack(name: "Inst 1", kind: .instrument)
        _ = store.addTrack(name: "Audio 1", kind: .audio)
        _ = store.addTrack(name: "Inst 2", kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: top.id, name: "a", atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)])

        // 1 — the keyboard reaches the third lane.
        let reach = ArrangeVerticalNudgeReach.delta(
            step: Self.press(.down), movingClipIDs: [clip.id], tracks: store.tracks)
        #expect(reach == 2)

        // 2 — the pointer, on the identical project, still declines.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: store.tracks) == 0,
            "the drag must NOT learn to search — it lands where you point")

        // 3 — the store still refuses the raw ±1, with the same error. Spelled
        // as a pattern match rather than `#expect(throws:)` because
        // `ProjectError` is not `Equatable` — the `ClipCrossTrackMoveTests`
        // shape, and it lets the leg name the offending KIND.
        var refusal: ProjectError?
        do {
            _ = try store.moveClips(ids: [clip.id], byTracks: 1)
        } catch let error as ProjectError {
            refusal = error
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        guard case .midiClipsRequireInstrumentTrack(let kind)? = refusal else {
            Issue.record("expected midiClipsRequireInstrumentTrack, got \(String(describing: refusal))")
            return
        }
        #expect(kind == .audio)

        // 4 — and the delta the keyboard chose actually LANDS. Without this the
        // three legs above would all pass against a resolver that returned a
        // number nobody could use.
        _ = try store.moveClips(ids: [clip.id], byTracks: reach)
        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.tracks[1].clips.isEmpty)
        #expect(store.tracks[2].clips.map(\.id) == [clip.id])
    }
}
