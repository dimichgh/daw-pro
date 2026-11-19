import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x6: a harmony part's TRANSIENT clip carries the lead's singing style with every per-note choice moved to
/// the part note sung in its lead note's place (`HarmonyNote.leadNoteID` → `id`). Without the move, every choice is
/// keyed by a lead note id the part does not have: an orphan the style pass never reads (W8-X5M's finding).
/// Pure values, so NOT `@MainActor`.
///
/// Plant that must turn it red: drop the remap in `HarmonyPlan.transientClip` (the copied style keeps the lead ids).
@Suite("HarmonyPlan.transientClip moves the lead's per-note style to the part's notes (p2-sing-x6)")
struct HarmonyPartStyleTests {

    static let ids = (1...4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }

    static func lead(style: SingStyle?) -> Clip {
        let notes = zip(ids, [60, 62, 64, 65]).enumerated().map { i, pair in
            MIDINote(id: pair.0, pitch: pair.1, velocity: 90, startBeat: Double(i), lengthBeats: 1)
        }
        return Clip(name: "Melody", lengthBeats: 4, notes: notes, singStyle: style)
    }

    static func part(of clip: Clip, partIndex: Int = 1) -> HarmonyPlan {
        HarmonyPlanner.notes(lead: clip.notes ?? [], spec: HarmonySpec(interval: .third, direction: .above,
                                                                      chordSource: .none),
                             key: SongKey(tonicPitchClass: 0, mode: .major), partIndex: partIndex,
                             chordAt: { _ in nil })
    }

    @Test("a per-note choice follows its lead note to the part note in its place; clip-wide choices stay")
    func choicesFollowTheirNotes() throws {
        let style = SingStyle(vibrato: .gentle, air: 0.25, followVelocity: true,
                              notes: [Self.ids[1]: NoteSingStyle(vibrato: .wide),
                                      Self.ids[3]: NoteSingStyle(air: 1)])
        let clip = Self.lead(style: style)
        let plan = Self.part(of: clip)
        let transient = plan.transientClip(replacingNotesOf: clip)
        let moved = try #require(transient.singStyle)
        let second = HarmonyPlanner.partNoteID(leadNoteID: Self.ids[1], partIndex: 1)
        let fourth = HarmonyPlanner.partNoteID(leadNoteID: Self.ids[3], partIndex: 1)
        #expect(moved.notes == [second: NoteSingStyle(vibrato: .wide), fourth: NoteSingStyle(air: 1)])
        #expect(moved.vibrato == .gentle && moved.air == 0.25 && moved.followVelocity == true)
        // Every choice now names a note the part HAS: no orphan, and each resolves as the lead's note did.
        #expect(moved.orphanedNoteIDs(in: transient.notes).isEmpty)
        for note in plan.notes {
            #expect(moved.resolvedVibrato(forNote: note.id) == style.resolvedVibrato(forNote: note.leadNoteID))
            #expect(moved.resolvedAir(forNote: note.id) == style.resolvedAir(forNote: note.leadNoteID))
        }
        // Control: the lead's own ids are gone from the part's style, and the part's notes are not the lead's.
        #expect(moved.notes?[Self.ids[1]] == nil)
        #expect(Set((transient.notes ?? []).map(\.id)).isDisjoint(with: Self.ids))
    }

    @Test("no per-note choice (or no style): the copy is the lead's style unchanged; orphans of the LEAD stay out")
    func nothingToMove() throws {
        let plain = SingStyle(vibrato: .wide)
        #expect(Self.part(of: Self.lead(style: plain)).transientClip(replacingNotesOf: Self.lead(style: plain))
                    .singStyle == plain)
        #expect(Self.part(of: Self.lead(style: nil)).transientClip(replacingNotesOf: Self.lead(style: nil))
                    .singStyle == nil)
        // A choice whose note the lead no longer has does not reach the part, and a style left with nothing is nil.
        let orphan = SingStyle(notes: [UUID(): NoteSingStyle(vibrato: .wide)])
        let clip = Self.lead(style: orphan)
        #expect(Self.part(of: clip).transientClip(replacingNotesOf: clip).singStyle == nil)
    }

    @Test("a second part keys the same choice by ITS note ids (the part index is in the id)")
    func eachPartItsOwnIDs() throws {
        let clip = Self.lead(style: SingStyle(notes: [Self.ids[0]: NoteSingStyle(vibrato: .straight)]))
        let two = Self.part(of: clip, partIndex: 2).transientClip(replacingNotesOf: clip)
        #expect(two.singStyle?.notes?.keys.first == HarmonyPlanner.partNoteID(leadNoteID: Self.ids[0], partIndex: 2))
        #expect(two.singStyle?.notes?.keys.first != HarmonyPlanner.partNoteID(leadNoteID: Self.ids[0], partIndex: 1))
    }
}
