import Foundation

// m34-i — THE SEQUENCE-POSITION PLAYER, built once for two features.
//
// ═══ WHY THIS IS NOT A BADGE TWEAK ═══
//
// The user's report was two sentences that turned out to be ONE defect: *"Four
// chords, 50 doowop, pop-punk does not change keyboard presets (lighted keys)"*
// and *"4 chords with number on them which is hard to read, it is better to
// light up border on then next recommeded chord."*
//
// Measured: `ChordProgressionPreset.litDegrees` is `Set(degrees)`, and Four
// Chords `[1,5,6,4]`, '50s Doo-Wop `[1,6,4,5]` and Pop-Punk `[6,4,1,5]` are the
// SAME SET `{1,4,5,6}` in three orders. They light identically **by
// construction** — that is real music theory, not a bug; those three
// progressions are famous precisely because they are rotations of the same four
// chords. So the order badges were carrying **100 % of the information that
// distinguished the presets**, and they were unreadable. Deleting them without a
// replacement would have made the three presets literally indistinguishable.
//
// The replacement the user proposed — light the BORDER of the next chord — needs
// something the surface did not have: **a position in a sequence that advances
// as you play.** That is exactly Playbox's (m34-g) sequence player at
// sequence-length 4, with a hand-authored progression instead of a generated
// one. It is therefore built HERE, as that player, so m34-g becomes "swap the
// fixed preset for a generated sequence and expose the advance modes" rather
// than a second mechanism that drifts from this one.
//
// ⭐ **STATE IS SHOWN BY LIGHT, NEVER TEXT.** A performer cannot read while
// playing — the conclusion Boss, Ableton and Loopy Pro all reach independently
// (`docs/research/spike-live-looping.md`). This type holds no strings.
//
// ⚠️ **PURE, VALUE-SHAPED, AND IN `DAWAppKit` ON PURPOSE.** `DAWCore` stays
// UI-free and this is a surface behaviour, not a domain fact; `DAWApp` has no
// test target, which is why every predicate of this kind lives here.

/// **WHEN THE CURSOR MOVES.**
///
/// ⛔⛔ **THIS IS A PARAMETER OF ONE PLAYER, NEVER THREE CODE PATHS.** The user
/// chose (m34-g, 2026-08-30) that all three advance models ship as a runtime
/// choice — *"provide all three options to select from on advancing mode"* —
/// because they are three different USES of one mechanism: wait-for-you is
/// *learning the part*, on-the-beat is *performing it*, lights-run-ahead is
/// *writing with it*. Three branches would triple the surface and guarantee they
/// drift, so all three are named here and every one of them moves the cursor
/// through the single `advance()` below.
///
/// ✅ **ALL THREE ARE DRIVEN AND SELECTABLE SINCE m34-g.** `MusicalTypingController
/// .setAdvanceMode` is the switch (a visible chip row on the strip, because the
/// user asked to choose), `.onBeat`'s tick is the transport's DOWNBEAT, and
/// `.free` is the default. The promise m34-i made in public is kept here.
public enum ChordSequenceAdvanceMode: String, Sendable, Codable, CaseIterable {
    /// **Wait for you.** The cursor moves only when the player actually sounds
    /// the chord it is pointing at. Synthesia's practice mode, and the only mode
    /// m34-i exposes.
    case onMatch
    /// **On the beat.** The cursor moves with the metronome and the player keeps
    /// up. Advanced by `beat()`.
    case onBeat
    /// **Lights run ahead, timing is yours.** ⭐ **THE DEFAULT (m34-g).** The
    /// queue shows the next few chords and **every chord you sound consumes one
    /// step of it** — matched or not. You are writing, so what you played IS the
    /// take and the plan simply rolls on to its next suggestion.
    ///
    /// ⛔⛔ **"ANY CHORD", NOT "THE RIGHT CHORD", AND THAT IS WHAT MAKES THIS A
    /// THIRD MODE RATHER THAN A SECOND `.onMatch`.** The look-ahead queue is
    /// drawn in EVERY mode (it is what finally tells Four Chords from Doo-Wop at
    /// rest — see `MusicalTypingChordCell.queueRank`), so if `.free` also
    /// advanced on a match only it would be behaviourally identical to
    /// `.onMatch`, and a three-position switch with two identical positions is a
    /// UI that lies. ⛔ It is still **a cue, never a gate**: an off-plan chord
    /// sounds exactly as it always did and is refused nothing — the only
    /// difference is that the suggestion it passed over is not offered twice.
    case free

    /// The chip's label. **Beginner-readable, in the words the user would use**
    /// (Rule 6) — never "onMatch"/"free", which describe the implementation.
    ///
    /// ⚠️ A control's LABEL is not the state-shown-by-light law's business; that
    /// law governs the play surface, where a performer cannot read. These chips
    /// are chrome, beside the key picker and the preset picker, which are
    /// labelled too.
    public var displayName: String {
        switch self {
        case .onMatch: return "WHEN I PLAY IT"
        case .onBeat: return "ON THE BEAT"
        case .free: return "AHEAD OF ME"
        }
    }

    /// What it is FOR — the tooltip. These are three different uses, not three
    /// competing designs, and saying which is which is what makes the switch
    /// worth having.
    public var summary: String {
        switch self {
        case .onMatch:
            return "Learning the part. The outline waits until you play the "
                + "chord it is showing you. Nothing is ever refused."
        case .onBeat:
            return "Performing it. The outline moves with the click, one chord "
                + "per bar, and you keep up."
        case .free:
            return "Writing with it. The outline moves on every chord you play, "
                + "so the timing is entirely yours."
        }
    }
}

/// A position in a chord sequence, expressed in **scale degrees** so it is
/// key-agnostic exactly as `ChordProgressionPreset` is.
///
/// ⛔⛔ **A CUE, NEVER A GATE.** Playing a chord that is not the next one does
/// nothing at all: the cursor stays where it is and the chord sounds normally.
/// Nothing in this type is on the sounding path, and there is no method that can
/// refuse anything — the whole promise of the lit-preset design is that you can
/// wander off it (*"Follow the lights, or ignore them. Same keys either way."*).
public struct ChordSequencePlayer: Sendable, Equatable {

    /// The scale degrees to play, in order. `[1, 5, 6, 4]` is I–V–vi–IV.
    ///
    /// ⚠️ **PUBLIC AND READ-ONLY SINCE m34-g, SO THE STAGING SEAM CAN ECHO IT.**
    /// A Playbox sequence is generated, so a gate cannot hardcode what it should
    /// contain; without this it would have to GUESS how many queue marks to
    /// expect and would guess wrong on any sequence with a repeated degree
    /// (measured: a generated `[?, F, ?, G]` marks two cells, not three). The
    /// ladder rule — derive the expectation from the app's own data, never from
    /// a second copy.
    public private(set) var steps: [Int]

    /// The index of the chord that comes NEXT — the one the border marks.
    ///
    /// ⚠️ **"NEXT", NOT "LAST PLAYED".** The cursor points at what to do, not at
    /// what was done, so a fresh sequence starts on step 1 and the very first
    /// thing the user sees is where to begin.
    public private(set) var position: Int

    /// When the cursor moves. See `ChordSequenceAdvanceMode`.
    public var advanceMode: ChordSequenceAdvanceMode

    public init(steps: [Int], advanceMode: ChordSequenceAdvanceMode = .onMatch) {
        self.steps = steps
        self.advanceMode = advanceMode
        self.position = 0
    }

    /// The scale degree the border marks, or nil when there is no sequence.
    public var nextDegree: Int? {
        steps.indices.contains(position) ? steps[position] : nil
    }

    /// Which step of the sequence the cursor sits on, 1-based — for the staging
    /// seam and for tests. **Never drawn** (see the file banner).
    public var nextStep: Int? { steps.isEmpty ? nil : position + 1 }

    /// How many chords are in the sequence.
    public var count: Int { steps.count }

    public var isEmpty: Bool { steps.isEmpty }

    /// A chord was SOUNDED. Moves the cursor iff this mode advances on a match
    /// and the degree is the one being cued.
    ///
    /// ⭐ **THE MATCH IS ON THE DEGREE, WHICH IS WIDER THAN THE BORDER ON
    /// PURPOSE.** The chord row draws several cells for one degree — the colour
    /// (seventh) keys and the second octave run — and every one of them plays
    /// that chord. So playing the cued chord from ANY of its cells advances the
    /// cursor, which keeps "any lit key plays this chord" true of the cue as
    /// well as of the sound. The border still lands on exactly one cell; that
    /// narrowing belongs to the view's projection, not here.
    ///
    /// ⚠️ **WHAT THE RETURN VALUE MEANS IS MODE-DEPENDENT, AND THE DIFFERENCE IS
    /// REAL (m34-g).** In `.onMatch` `true` means *"you followed the lights"*. In
    /// `.free` it means *"a step was consumed"* — which any sounded chord does.
    /// In `.onBeat` it is always `false`, because the metronome owns the cursor
    /// and a note-on must not race it.
    ///
    /// - Returns: whether the cursor moved.
    @discardableResult
    public mutating func played(degree: Int) -> Bool {
        guard !steps.isEmpty else { return false }
        switch advanceMode {
        case .onMatch:
            guard nextDegree == degree else { return false }
        case .free:
            // ⭐ ANY chord consumes a suggestion. See `.free`'s own doc for why
            // this is not a bug and not a gate.
            break
        case .onBeat:
            // The beat moves this cursor; playing must not move it too, or the
            // lights would run away from the click that is driving them.
            return false
        }
        advance()
        return true
    }

    /// A beat went by. Moves the cursor iff this mode advances on the beat.
    ///
    /// ⚠️ Nothing calls this yet — m34-g's on-the-beat mode will. It exists now
    /// so the advance model is one parameter rather than a later fork.
    @discardableResult
    public mutating func beat() -> Bool {
        guard advanceMode == .onBeat, !steps.isEmpty else { return false }
        advance()
        return true
    }

    /// **THE ONE CURSOR MOVE, and every mode goes through it.** Wraps at the end
    /// of the sequence — a four-chord loop is a loop, so the fifth chord is the
    /// first one again.
    public mutating func advance() {
        guard !steps.isEmpty else {
            position = 0
            return
        }
        position = (position + 1) % steps.count
    }

    /// Back to the first chord. Used when the sequence is (re)selected or the
    /// mode it lives in is left — see `MusicalTypingController.setProgression`.
    public mutating func rewind() { position = 0 }

    // MARK: - The look-ahead queue (m34-g)

    /// ⭐⭐ **THE LOOK-AHEAD: WHAT IS COMING, NEAREST FIRST, EXCLUDING THE CUE.**
    ///
    /// This is the piece the user asked for — *"pre-generate next series of
    /// lights to play"* — and it **also closes a defect m34-i could only state**.
    /// Four Chords `[1,5,6,4]` and Doo-Wop `[1,6,4,5]` are the same SET in
    /// different orders and **both open on I**, so with only a cue they look
    /// identical until the first chord is played. A queue distinguishes them
    /// before a note is struck: the same four cells, in two different orders of
    /// brightness.
    ///
    /// ⚠️ **IT WALKS AT MOST `count` STEPS, so a short loop is never shown
    /// twice.** ii–V–I with depth 3 yields two upcoming chords, not three with
    /// the tonic repeated — a queue that wrapped onto its own cue would paint
    /// the "next" light on the chord you are already being told to play.
    public func upcomingDegrees(depth: Int) -> [Int] {
        guard !steps.isEmpty, depth > 0 else { return [] }
        let reach = min(depth, steps.count - 1)
        guard reach > 0 else { return [] }
        return (1...reach).map { steps[(position + $0) % steps.count] }
    }

    /// **degree → how soon it comes up**, `0` being the cue itself.
    ///
    /// ⚠️ **A REPEATED DEGREE RESOLVES TO ITS SOONEST RANK, and it has to.** One
    /// scale degree is one cell on the chord row, so `[1, 5, 1, 4]` cannot paint
    /// its two `I`s differently; the honest answer is *"I comes up next"*, which
    /// is rank 0. The cost is stated rather than hidden: such a sequence marks
    /// three cells for four steps, and `MusicalTypingChordCell.queueRank` pins
    /// that in a test rather than pretending otherwise.
    public func rankByDegree(depth: Int) -> [Int: Int] {
        guard !steps.isEmpty else { return [:] }
        let reach = min(max(depth, 0), steps.count - 1)
        var ranks: [Int: Int] = [:]
        for offset in 0...reach {
            let degree = steps[(position + offset) % steps.count]
            if ranks[degree] == nil { ranks[degree] = offset }
        }
        return ranks
    }
}
