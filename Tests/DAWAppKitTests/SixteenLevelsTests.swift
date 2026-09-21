import Testing
import Foundation
@testable import DAWAppKit
import DAWCore

/// SIXTEEN LEVELS' arithmetic (m39-levels) — where a spread may go, and what it
/// carries.
///
/// NON-isolated on purpose, the `PadGridGeometryTests` rule: `SixteenLevels`
/// touches no actor, so this suite costs nothing against the `@MainActor` suite
/// cadence cap (at its 380 ceiling, zero slack). The model-level cases that need
/// the main actor fold into `PadGridTests` instead.
@Suite("Sixteen Levels (m39-levels)")
struct SixteenLevelsTests {

    private func zone(_ pitch: Int, file: String = "/tmp/m39levels-src.wav",
                      start: Int = 1000, end: Int = 2000) -> SamplerZone {
        SamplerZone(audioFileURL: URL(fileURLWithPath: file),
                    rootPitch: pitch, minPitch: pitch, maxPitch: pitch,
                    startFrame: start, endFrame: end)
    }

    /// A chop of `count` slices from `base`, exactly as `SliceToSampler` writes
    /// them: one key wide each.
    private func chop(count: Int, from base: Int = 36) -> [SamplerZone] {
        (0..<count).map { zone(base + $0, start: $0 * 1000, end: $0 * 1000 + 900) }
    }

    // MARK: - Where a spread may go

    @Test("a spread goes DIRECTLY BELOW the chop, so the two sit next to each other")
    func prefersTheWindowBelow() {
        let base = try! #require(SixteenLevels.freeBase(zones: chop(count: 9)))
        // 9 slices from 36 occupy 36…44; the window below is 20…35.
        #expect(base == 36 - SixteenLevels.span)
        #expect(base == 20)
    }

    @Test("with no room below, it goes above")
    func fallsBackAbove() {
        // A chop based at 4 leaves only 0…3 below — not sixteen keys.
        let zones = chop(count: 9, from: 4)
        let base = try! #require(SixteenLevels.freeBase(zones: zones))
        #expect(base == 13)   // 4…12 occupied, so 13…28
    }

    /// ⛔⛔ **nil IS A REAL ANSWER AND THE REASON THIS IS A FUNCTION.** The
    /// tempting build hard-codes "an octave below"; a 96-slice chop low on the
    /// keyboard genuinely leaves no sixteen free notes, and a hard-coded window
    /// would silently overlap the chop — pads that sometimes play the spread and
    /// sometimes play a slice.
    @Test("⛔ a keymap with no sixteen free keys REFUSES rather than overlapping")
    func refusesWhenFull() {
        // 0…127 is 128 keys. 96 slices from 16 occupy 16…111. Below: 0…15 is
        // exactly 16 keys — free. So fill from 1 instead: 1…96, leaving 0 alone
        // below and 97…127 (31 keys) above… still room. Occupy the whole range.
        let full = (0...127).map { zone($0) }
        #expect(SixteenLevels.freeBase(zones: full) == nil)
    }

    @Test("⭐ a window is refused when a zone merely CLIPS it, not only when contained")
    func partialOverlapIsACollision() {
        // One wide zone covering 30…40. A window at 25 spans 25…40 — it does not
        // CONTAIN the zone and the zone does not contain it, but they touch, and
        // touching is a collision: zones layer across groups.
        let wide = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-w.wav"),
                               rootPitch: 30, minPitch: 30, maxPitch: 40)
        #expect(SixteenLevels.windowIsFree(base: 25, zones: [wide]) == false)
        #expect(SixteenLevels.windowIsFree(base: 41, zones: [wide]))
        #expect(SixteenLevels.windowIsFree(base: 14, zones: [wide]))
        // 15…30 touches at exactly one key — still a collision.
        #expect(SixteenLevels.windowIsFree(base: 15, zones: [wide]) == false)
    }

    @Test("a window that would run off either end of MIDI is not free")
    func windowStaysInsideMIDI() {
        #expect(SixteenLevels.windowIsFree(base: -1, zones: []) == false)
        #expect(SixteenLevels.windowIsFree(base: 113, zones: []) == false)
        #expect(SixteenLevels.windowIsFree(base: 112, zones: []))   // 112…127
        #expect(SixteenLevels.windowIsFree(base: 0, zones: []))
    }

    @Test("an empty keymap still has somewhere to put a spread")
    func emptyKeymapHasRoom() {
        #expect(SixteenLevels.freeBase(zones: []) == 0)
    }

    // MARK: - What the spread carries

    @Test("⭐ the spread is the SOURCE's audio and slice window, sixteen keys wide")
    func spreadCarriesTheSlice() {
        let source = zone(38, start: 44_100, end: 66_150)
        let spread = SixteenLevels.zone(from: source, base: 20)
        #expect(spread.audioFileURL == source.audioFileURL)
        #expect(spread.startFrame == 44_100)
        #expect(spread.endFrame == 66_150)
        #expect(spread.minPitch == 20)
        #expect(spread.maxPitch == 35)
        #expect(spread.maxPitch - spread.minPitch + 1 == SixteenLevels.span)
        // ⭐ PAD 1 IS THE SLICE AS RECORDED: root == base, so pad 1 plays it
        // unshifted and each pad up is one semitone.
        #expect(spread.rootPitch == 20)
    }

    /// ⛔⛔ **A FRESH IDENTITY, AND IT IS LOAD-BEARING.** `var copy = source`
    /// keeps the source's `id` (it is a `let`), and then removing the spread on
    /// exit — which matches BY ID — would take the user's slice with it.
    @Test("⛔ the spread has its OWN id, so exiting cannot delete the source slice")
    func spreadHasAFreshIdentity() {
        let source = zone(38)
        let spread = SixteenLevels.zone(from: source, base: 20)
        #expect(spread.id != source.id)
    }

    /// ⛔ A looping voice is never one-shot (`if voice.looping { oneShotOverride
    /// = 0 }`), so carrying `loopMode` would silently overrule the grid's LET GO
    /// switch on exactly the sources that had a loop.
    @Test("⛔ loopMode is NOT carried — it would overrule the LET GO switch")
    func loopModeIsNotCarried() {
        let looped = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-l.wav"),
                                 rootPitch: 38, minPitch: 38, maxPitch: 38,
                                 startFrame: 0, endFrame: 1000,
                                 loopMode: .continuous, loopStart: 10, loopEnd: 900)
        // The fixture really does carry one — otherwise this test passes over a
        // source that never had a loop to drop.
        #expect(looped.loopMode != nil)
        #expect(SixteenLevels.zone(from: looped, base: 20).loopMode == nil)
    }

    // MARK: - The labels

    @Test("pad 1 is 0 semitones and the top pad is +15")
    func semitonesRunFromZero() {
        #expect(SixteenLevels.semitones(forPad: 0) == 0)
        #expect(SixteenLevels.semitones(forPad: 15) == 15)
        #expect(SixteenLevels.semitones(forPad: 16) == nil)
        #expect(SixteenLevels.semitones(forPad: -1) == nil)
        #expect(SixteenLevels.offsetLabel(semitones: 0) == "0")
        #expect(SixteenLevels.offsetLabel(semitones: 7) == "+7")
        #expect(SixteenLevels.offsetLabel(semitones: -2) == "-2")
    }

    /// The spread must fit ONE grid — paging to reach half of it would defeat
    /// the point of putting it on the pads.
    @Test("the spread is exactly one bank wide, derived not restated")
    func spanTracksTheGrid() {
        #expect(SixteenLevels.span == PadGridGeometry.padsPerBank)
        #expect(SixteenLevels.span == 16)
    }
}
