import Foundation

// m39-w4-3 — THE VELOCITY A HAND-ENTERED NOTE IS BORN AT, in one home.
// `docs/design/2026-10-07-loop-drum-depth.md` §3.4–§3.6.
//
// Two gestures mint a fresh note with a default velocity: the piano roll's
// double-click add (`PianoRollModel.addNote`) and the step grid's click
// (`StepSequencerEdit.toggle`). Before this file each carried its own literal
// 100, and "a note authored in either editor sounds identically" held only
// because two literals happened to agree. Both now read THIS.
//
// Census (2026-10-07, `grep -rn "MIDINote("` over `Sources/DAWApp` and
// `Sources/DAWAppKit`): 8 sites. Two MINT a note (the two above). The other six
// rebuild an existing note and carry its velocity (`PianoRollModel.swift`
// move/resize/transpose/set-velocity, `PasteAnchorPolicy.swift`), so they are
// not entry. Live playing (`AuditionController.defaultVelocity`, the pads,
// musical typing) is PERFORMANCE velocity with its own controls: out of scope.
//
// ⛔ THE DRUM QUESTION IS `DrumLaneMap.lanes(for:) != nil`, NEVER
// `SMFProjectExporter.isDrumKit`. The export predicate answers "is this a
// General MIDI kit" (MIDI channel 10), which our own drum machine in its
// default `pads` layout answers "no". Through it, a new Drum Machine would get
// the melodic default and the General MIDI kit the drum one.
//
// Nothing here is stored. Notes carry their own velocity, so no saved project,
// template or preset reads differently (design §3.6).

public enum NoteEntryDefaults {

    /// A note entered on a melodic track (no drum rows).
    public static let melodicVelocity = 100

    /// A note entered on a track with drum rows (`DrumLaneMap.lanes(for:) != nil`).
    ///
    /// ⚠️ HELD AT 100 (today's value) UNTIL THE USER'S LISTENING PICK: the Drum
    /// Picks page, decision `decisions/drums-w4`, field `L1` (options 100 / 85 /
    /// 60 / 40). Below the drum machine's accent threshold (100 by default) a
    /// hand-entered hit is un-accented, so the Accent row has something to lift.
    /// At 100 every hand-entered hit on the drum machine is already accented
    /// (design C15). Change THIS constant, and nothing else, when the pick lands.
    public static let drumVelocity = 100

    /// What the Accent row writes (design §3.5): the MIDI maximum. On the drum
    /// machine it also passes any accent threshold (1…127), so the hit gets the
    /// kit's extra accent level and tone; on a General MIDI kit or a sampler,
    /// which have no accent bus, it is simply the hardest hit.
    public static let accentVelocity = 127

    /// The entry velocity for a track that does (or does not) have drum rows.
    public static func velocity(hasDrumLanes: Bool) -> Int {
        Values.shipped.velocity(hasDrumLanes: hasDrumLanes)
    }

    /// The entry velocity for a track whose drum rows are `drumLanes`
    /// (`DrumLaneMap.lanes(for:)` of its instrument; nil for a melodic track).
    public static func velocity(drumLanes: [DrumLane]?) -> Int {
        Values.shipped.velocity(drumLanes: drumLanes)
    }

    /// The same three numbers as a value, so a test can hold a fixture constant
    /// (the design's gates use a drum velocity of 80) and prove the editors read
    /// THIS function rather than a literal that happens to agree at 100.
    /// The app only ever uses `.shipped`.
    public struct Values: Sendable, Equatable {
        public var melodicVelocity: Int
        public var drumVelocity: Int
        public var accentVelocity: Int

        public init(melodicVelocity: Int = NoteEntryDefaults.melodicVelocity,
                    drumVelocity: Int = NoteEntryDefaults.drumVelocity,
                    accentVelocity: Int = NoteEntryDefaults.accentVelocity) {
            self.melodicVelocity = melodicVelocity
            self.drumVelocity = drumVelocity
            self.accentVelocity = accentVelocity
        }

        /// The values the app ships.
        public static let shipped = Values()

        public func velocity(hasDrumLanes: Bool) -> Int {
            hasDrumLanes ? drumVelocity : melodicVelocity
        }

        /// THE predicate, in one place: a track has drum rows exactly when the
        /// drum lane map returned some. Both editors call this with the lane
        /// list the step grid draws its rows from, so the entry velocity and the
        /// rows cannot disagree about whether a track is a drum track.
        public func velocity(drumLanes: [DrumLane]?) -> Int {
            velocity(hasDrumLanes: drumLanes != nil)
        }
    }
}
