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

    // MARK: - Which way it runs (m39-levels-2, the user's 2026-09-20 ruling)

    /// ⭐ THE CONTRACT, AS LITERALS. Both arrays are written out rather than
    /// computed, so a mapping that is off by one — pad 8 as the centre, or
    /// −7…+8 — cannot pass by agreeing with a formula that shares its error.
    @Test("⭐ UP runs 0…+15 from pad 1; CENTRED runs −8…+7 with pad 9 at 0 — pad for pad")
    func bothDirectionsMapExactly() {
        let up = (0..<16).map { SixteenLevels.semitones(forPad: $0, direction: .up) }
        #expect(up == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        let centred = (0..<16).map { SixteenLevels.semitones(forPad: $0, direction: .centered) }
        #expect(centred == [-8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7])
        // Pad 9 (index 8) is the one that plays the recording as it is.
        #expect(SixteenLevels.Direction.centered.unshiftedPadIndex == 8)
        #expect(SixteenLevels.Direction.up.unshiftedPadIndex == 0)
        // Off the grid is nil in both directions, never a clamp.
        for direction in SixteenLevels.Direction.allCases {
            #expect(SixteenLevels.semitones(forPad: 16, direction: direction) == nil)
            #expect(SixteenLevels.semitones(forPad: -1, direction: direction) == nil)
        }
        // ⭐ UP IS THE DEFAULT — the shipped behaviour is what you get unasked.
        #expect(SixteenLevels.semitones(forPad: 0) == 0)
        #expect(SixteenLevels.semitones(forPad: 15) == 15)
        #expect(SixteenLevels.Direction.allCases == [.up, .centered])
        // The wire's future spelling is frozen from today.
        #expect(SixteenLevels.Direction.allCases.map(\.rawValue) == ["up", "centered"])
    }

    @Test("⭐ the direction decides ONLY the root — the keys, audio and window are identical")
    func directionDecidesOnlyTheRoot() {
        let source = zone(38, start: 44_100, end: 66_150)
        let up = SixteenLevels.zone(from: source, base: 20, direction: .up)
        let centred = SixteenLevels.zone(from: source, base: 20, direction: .centered)
        #expect(up.rootPitch == 20)
        #expect(centred.rootPitch == 28)
        for spread in [up, centred] {
            #expect(spread.minPitch == 20)
            #expect(spread.maxPitch == 35)
            #expect(spread.audioFileURL == source.audioFileURL)
            #expect(spread.startFrame == 44_100)
            #expect(spread.endFrame == 66_150)
            #expect(spread.id != source.id)
        }
        // Equal in every field but identity and root.
        var aligned = centred
        aligned.rootPitch = up.rootPitch
        #expect(aligned.minPitch == up.minPitch && aligned.maxPitch == up.maxPitch
                && aligned.gain == up.gain && aligned.tuneCents == up.tuneCents
                && aligned.startFrame == up.startFrame && aligned.endFrame == up.endFrame)
        // The default argument is UP.
        #expect(SixteenLevels.zone(from: source, base: 20).rootPitch == 20)
    }

    /// ⭐ The grid draws from the ZONE (`semitones(atPitch:on:)`), the contract
    /// is per PAD (`semitones(forPad:direction:)`). They must agree on every pad,
    /// in both directions, or the labels and the promise have drifted apart.
    @Test("⭐ labels read off the zone agree with the contract on every pad, both directions")
    func zoneReadingAgreesWithTheContract() {
        let source = zone(40)
        for direction in SixteenLevels.Direction.allCases {
            let spread = SixteenLevels.zone(from: source, base: 20, direction: direction)
            for pad in 0..<16 {
                #expect(SixteenLevels.semitones(atPitch: 20 + pad, on: spread)
                        == SixteenLevels.semitones(forPad: pad, direction: direction),
                        "\(direction) pad \(pad + 1)")
            }
            // A key the spread does not cover plays nothing of it.
            #expect(SixteenLevels.semitones(atPitch: 19, on: spread) == nil)
            #expect(SixteenLevels.semitones(atPitch: 36, on: spread) == nil)
        }
    }

    /// ⭐ THE PERSISTENCE MECHANISM IN ONE ASSERTION: the direction is recovered
    /// from the zone's own geometry — there is no flag to save, and so none to lose.
    @Test("⭐ a spread's direction is read back off its own zone; a non-spread reads nil")
    func directionIsRecoveredFromTheZone() {
        let source = zone(40)
        for direction in SixteenLevels.Direction.allCases {
            let spread = SixteenLevels.zone(from: source, base: 20, direction: direction)
            #expect(SixteenLevels.direction(of: spread) == direction)
        }
        // A one-key slice is not a spread.
        #expect(SixteenLevels.direction(of: source) == nil)
        // Sixteen keys wide but rooted on neither pad 1 nor pad 9: not ours.
        let odd = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-odd.wav"),
                              rootPitch: 23, minPitch: 20, maxPitch: 35)
        #expect(SixteenLevels.direction(of: odd) == nil)
        // Rooted like UP but fifteen keys wide: not a spread either.
        let narrow = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-narrow.wav"),
                                 rootPitch: 20, minPitch: 20, maxPitch: 34)
        #expect(SixteenLevels.direction(of: narrow) == nil)
    }

    /// ⛔⛔ THE TOGGLE'S ONLY EDIT. Every zone but the spread comes back as the
    /// same VALUE in the same ORDER; the spread keeps its id and every field
    /// but `rootPitch`. And a zone LEVELS did not make is REFUSED (nil), never
    /// re-rooted — that would be editing the user's chop.
    @Test("⛔⛔ re-spreading edits ONE field of ONE zone, and refuses a zone the spread did not make")
    func respreadTouchesOneFieldOfOneZone() throws {
        let slices = chop(count: 9)
        let spread = SixteenLevels.zone(from: slices[3], base: 20, direction: .up)
        let keymap = slices + [spread]

        let centred = try #require(SixteenLevels.keymap(keymap, respreading: spread.id,
                                                        to: .centered))
        #expect(centred.count == keymap.count)
        #expect(Array(centred.prefix(9)) == slices, "a slice was edited or reordered")
        let moved = try #require(centred.last)
        #expect(moved.id == spread.id)
        #expect(moved.rootPitch == 28)
        var back = moved
        back.rootPitch = spread.rootPitch
        #expect(back == spread, "something other than rootPitch changed")

        // And back again — the round trip is exact.
        let upAgain = try #require(SixteenLevels.keymap(centred, respreading: spread.id, to: .up))
        #expect(upAgain == keymap)

        // ⛔ A slice's id is refused, not re-rooted.
        #expect(SixteenLevels.keymap(keymap, respreading: slices[3].id, to: .centered) == nil)
        // An unknown id is refused.
        #expect(SixteenLevels.keymap(keymap, respreading: UUID(), to: .centered) == nil)
    }

    // MARK: - Recognised by shape, sourced by what it plays (m39-levels-3)

    /// ⭐ THE ONE PREDICATE IS LITERALLY `direction(of:) != nil` — so the grid,
    /// the store's refusal and the wire's `spreadDirection` cannot disagree
    /// about which zones are spreads.
    @Test("⭐ isSpread is exactly direction(of:) != nil, on spreads and non-spreads alike")
    func isSpreadIsTheDirectionPredicate() {
        let source = zone(40)
        let up = SixteenLevels.zone(from: source, base: 20, direction: .up)
        let centred = SixteenLevels.zone(from: source, base: 20, direction: .centered)
        let odd = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels3-odd.wav"),
                              rootPitch: 23, minPitch: 20, maxPitch: 35)
        let narrow = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels3-n.wav"),
                                 rootPitch: 20, minPitch: 20, maxPitch: 34)
        for candidate in [source, up, centred, odd, narrow] {
            #expect(SixteenLevels.isSpread(candidate)
                    == (SixteenLevels.direction(of: candidate) != nil))
        }
        // CONTROL: the predicate really does separate them.
        #expect(SixteenLevels.isSpread(up) && SixteenLevels.isSpread(centred))
        #expect(!SixteenLevels.isSpread(source) && !SixteenLevels.isSpread(odd)
                && !SixteenLevels.isSpread(narrow))
    }

    /// ⚠️ THE KNOWN GAP, PINNED AS A FACT rather than left as prose: shape is
    /// not provenance. An SFZ region `lokey=52 hikey=67` with no
    /// `pitch_keycenter` maps to root 60 (`SampleLibraryMapper`'s default) —
    /// sixteen keys rooted on the ninth — and reads as a CENTRED spread here,
    /// at the store, and on the wire. If this ever goes false, the predicate
    /// changed and `SixteenLevels.isSpread`'s note needs rewriting.
    @Test("⚠️ a sixteen-key SFZ-shaped zone rooted on its ninth key DOES read as a spread (known gap)")
    func shapeIsNotProvenance() {
        let imported = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels3-sfz.wav"),
                                   rootPitch: 60, minPitch: 52, maxPitch: 67)
        #expect(SixteenLevels.isSpread(imported))
        #expect(SixteenLevels.direction(of: imported) == .centered)
    }

    @Test("⭐ a spread's source is the slice that PLAYS the same file and window")
    func sourceSliceIsFoundByWhatItPlays() throws {
        let slices = chop(count: 9)
        let spread = SixteenLevels.zone(from: slices[3], base: 20, direction: .centered)
        let found = try #require(SixteenLevels.sourceSlice(of: spread, in: slices + [spread]))
        #expect(found.id == slices[3].id)

        // A different FILE is not the source, even over the same window.
        var otherFile = slices[3]
        otherFile.audioFileURL = URL(fileURLWithPath: "/tmp/m39levels3-other.wav")
        var keymap = slices
        keymap[3] = otherFile
        #expect(SixteenLevels.sourceSlice(of: spread, in: keymap + [spread]) == nil)

        // A slice whose window was edited after the spread was made is not its
        // source any more: the spread still plays the OLD window.
        var edited = slices[3]
        edited.endFrame = (edited.endFrame ?? 0) + 1
        keymap = slices
        keymap[3] = edited
        #expect(SixteenLevels.sourceSlice(of: spread, in: keymap + [spread]) == nil)

        // The source slice gone → nil, never a neighbour.
        keymap = slices
        keymap.remove(at: 3)
        #expect(SixteenLevels.sourceSlice(of: spread, in: keymap + [spread]) == nil)
    }

    /// Two slices playing the same window resolve to the LOWEST in the grid's
    /// numbering order — and a spread is never a candidate source.
    @Test("a duplicated window resolves to the lowest slice; spreads are never sources")
    func sourceSliceTieBreakAndSpreadsExcluded() throws {
        let slices = chop(count: 4)
        var duplicate = SamplerZone(audioFileURL: slices[2].audioFileURL,
                                    rootPitch: 50, minPitch: 50, maxPitch: 50)
        duplicate.startFrame = slices[2].startFrame
        duplicate.endFrame = slices[2].endFrame
        let spread = SixteenLevels.zone(from: slices[2], base: 20)
        // A second spread of the same slice plays the same file and window —
        // and must not be taken for the source of the first.
        let twin = SixteenLevels.zone(from: slices[2], base: 4)
        let found = try #require(SixteenLevels.sourceSlice(of: spread,
                                                           in: [twin, duplicate] + slices + [spread]))
        #expect(found.id == slices[2].id, "root 38 numbers before root 50")
        #expect(SixteenLevels.sourceSlice(of: spread, in: [twin, spread]) == nil)
    }

    @Test("negative intervals print with their sign")
    func negativeLabels() {
        #expect(SixteenLevels.offsetLabel(semitones: -8) == "-8")
        #expect(SixteenLevels.offsetLabel(semitones: -1) == "-1")
        #expect(SixteenLevels.offsetLabel(semitones: 7) == "+7")
    }
}
