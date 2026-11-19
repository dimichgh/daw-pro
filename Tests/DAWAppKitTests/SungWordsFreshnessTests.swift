import DAWAppKit
import DAWCore
import Foundation
import Testing

/// p2-sing-pr-words (design 2026-10-12 §3.3 D7) — "The words changed since this vocal was sung." The check is pure:
/// only LEAD takes sung FROM THIS CLIP count, and only when the words they were sung with differ from the clip's now.
///
/// ⚠️ NOT `@MainActor`: pure values.
@Suite("Piano roll words — has the sung vocal been sung with these words? (p2-sing-pr-words)")
struct SungWordsFreshnessTests {

    private static let clipID = UUID()

    private static func vocal(_ lyrics: String, from clip: UUID? = clipID, role: String? = nil) -> Track {
        // A track id that is NOT the clip id: the take names its SOURCE clip, never its own track.
        Track(name: "Vocal", kind: .audio,
              sungVocalProvenance: PianoRollWordsFixture.take(lyrics: lyrics, from: clip, partRole: role))
    }

    @Test("a lead take of this clip with the same words is fresh; with other words it is stale")
    func leadTakesOfThisClip() {
        let tracks = [Self.vocal("hello world")]
        let leads = SungWordsFreshness.leadLyrics(for: Self.clipID, in: tracks)
        #expect(leads == ["hello world"], "positive control: the take is found")
        #expect(!SungWordsFreshness.isStale(leadLyrics: leads, clipText: "hello world"))
        #expect(SungWordsFreshness.isStale(leadLyrics: leads, clipText: "hello big world"))
    }

    @Test("\"lead\" and a take sung on its own (no part role) both count; harmony and double parts never do")
    func onlyTheLeadCounts() {
        let tracks = [Self.vocal("a", role: nil), Self.vocal("b", role: SungVocalProvenance.PartRole.lead),
                      Self.vocal("c", role: SungVocalProvenance.PartRole.harmony),
                      Self.vocal("d", role: SungVocalProvenance.PartRole.double)]
        #expect(SungWordsFreshness.leadLyrics(for: Self.clipID, in: tracks) == ["a", "b"])
        #expect(!SungWordsFreshness.isStale(leadLyrics: SungWordsFreshness.leadLyrics(
            for: Self.clipID, in: [Self.vocal("x", role: SungVocalProvenance.PartRole.harmony)]), clipText: "y"),
                "a harmony part's words never make the lead stale")
    }

    @Test("⭐ another clip's take, a damaged record, a plain track: never this clip's")
    func otherClipsNever() {
        let tracks = [Self.vocal("other words", from: UUID()), Self.vocal("lost", from: nil),
                      Track(name: "Piano", kind: .instrument)]
        #expect(SungWordsFreshness.leadLyrics(for: Self.clipID, in: tracks).isEmpty)
        #expect(!SungWordsFreshness.isStale(leadLyrics: [], clipText: "anything"), "no take, no notice")
    }

    @Test("⭐ the take is matched by its SOURCE CLIP, not by the track it landed on")
    func matchedBySourceClip() {
        // The vocal track's own id is unrelated to the clip; a lookup by track id would find nothing here…
        let track = Self.vocal("old words")
        #expect(track.id != Self.clipID)
        #expect(SungWordsFreshness.leadLyrics(for: Self.clipID, in: [track]) == ["old words"])
        // …and a track whose id happens to equal some clip id is not that clip's take.
        let impostor = Track(id: Self.clipID, name: "Vocal", kind: .audio,
                             sungVocalProvenance: PianoRollWordsFixture.take(lyrics: "x", from: UUID()))
        #expect(SungWordsFreshness.leadLyrics(for: Self.clipID, in: [impostor]).isEmpty)
    }

    @Test("several lead takes: stale when ANY of them sang other words (an old take still plays beside the new one)")
    func anyStaleLeadCounts() {
        let leads = SungWordsFreshness.leadLyrics(for: Self.clipID, in: [Self.vocal("old"), Self.vocal("new")])
        #expect(leads == ["old", "new"])
        #expect(SungWordsFreshness.isStale(leadLyrics: leads, clipText: "new"))
        #expect(!SungWordsFreshness.isStale(leadLyrics: ["new", "new"], clipText: "new"))
    }
}
