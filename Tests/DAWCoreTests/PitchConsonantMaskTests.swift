import Foundation
import Testing
@testable import DAWCore

// Natural tuning §2 (m23-nt, lane NT-C C2): THE CONSONANT MASK, THE INACTIVE
// REASONS, THE SEEDS AND THE CONSTRUCTION-SITE CENSUS. Design
// `docs/design/2026-09-25-natural-tuning.md` §2b.2, §2b.5, §2c, §2g (G-C7a,
// G-C8, G-C10, G-C13 at the mask level), R15, R21.
//
// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps `@MainActor`
// suites). The store half (the setter, the flag through every writer) is
// appended to `PitchCorrectionWriterTests`; the digest half (slot 8, G-C7b/c,
// G-C9's tripwire) to `NaturalTuningDigestTests`.
@Suite("Natural tuning §2 — the consonant mask, its reasons and the carry census (NT-C C2)")
struct PitchConsonantMaskTests {

    static let idA = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000000B")!
    static let idC = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000000C")!
    static let idD = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000000D")!
    static let idE = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000000E")!
    static let idS = UUID(uuidString: "C2C2C2C2-0000-4000-8000-00000000005A")!

    static func note(_ id: UUID, _ start: Double, _ end: Double, cents: Double = 0,
                     origin: NoteOrigin = .detected, cleared: Bool = false) -> NoteSegment {
        NoteSegment(id: id, startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: origin == .unpitched ? 0.4 : 0.9,
                    pitchOffsetCents: cents, isCleared: cleared, origin: origin)
    }

    /// Every join kind the mask reads, flag ON, two notes moved:
    ///
    ///     head [0, 0.20]   200 ms before the first note: a region
    ///     A [0.20, 0.60]   +300 c
    ///     B [0.60, 0.90]   abuts A: SOFT, no region
    ///     C [0.932, 1.30]  a 32 ms blink after B: SOFT, stays wet (G-C10)
    ///     S [1.30, 1.45]   an UNTOUCHED SOUND abutting C and D: inside the
    ///                      C-D region (150 ms, a gap)
    ///     D [1.45, 1.80]   −200 c
    ///     E [1.92, 2.40]   a 120 ms gap after D: a region
    ///     tail [2.40, +∞]
    static func phrase(consonants: Bool = true) -> PitchEditSet {
        PitchEditSet(segments: [
            note(idA, 0.20, 0.60, cents: 300),
            note(idB, 0.60, 0.90),
            note(idC, 0.932, 1.30),
            note(idS, 1.30, 1.45, origin: .unpitched),
            note(idD, 1.45, 1.80, cents: -200),
            note(idE, 1.92, 2.40),
        ], keepsConsonantsUntuned: consonants)
    }

    static let phraseRegions: [PitchConsonantRegion] = [
        PitchConsonantRegion(startSeconds: 0, endSeconds: 0.20, followsNote: false, precedesNote: true),
        PitchConsonantRegion(startSeconds: 1.30, endSeconds: 1.45, followsNote: true, precedesNote: true),
        PitchConsonantRegion(startSeconds: 1.80, endSeconds: 1.92, followsNote: true, precedesNote: true),
        PitchConsonantRegion(startSeconds: 2.40, endSeconds: .infinity, followsNote: true, precedesNote: false),
    ]

    /// Source seconds 0...3 at 1 ms, index-built (never accumulated).
    static let probe: [Double] = (0...3000).map { Double($0) * 0.001 }

    // MARK: - The regions

    @Test("regions: the gaps between curve notes, the head and the tail; soft joins and blinks make none")
    func regionsAreTheGapJoins() {
        let set = Self.phrase()
        #expect(set.consonantRegions() == Self.phraseRegions)
        #expect(set.consonantRegions().allSatisfy { $0.fadeSeconds == PitchEditSet.consonantFadeSeconds },
                "no region of this phrase is short enough for the half-region clamp to bind")
        #expect(Self.phrase(consonants: false).consonantRegions().isEmpty, "flag off: no region")
    }

    // MARK: - The weight's physics

    @Test("physics: w == 1 at EVERY note sample (1 ms probe), and w < 1 only inside a region")
    func weightIsOneAtEveryNoteSample() {
        let set = Self.phrase()
        #expect(set.hasConsonantMix)
        let curveNotes = set.segments.filter(\.entersPitchCurve)
        var noteSamples = 0
        var drySamples = 0
        for s in Self.probe {
            let w = set.tunedWeight(atSourceSecond: s)
            #expect(w >= 0 && w <= 1 && w.isFinite)
            if curveNotes.contains(where: { s >= $0.startSeconds && s <= $0.endSeconds }) {
                noteSamples += 1
                #expect(w == 1, "the ramp entered a note: w(\(s)) = \(w)")
            }
            if w < 1 {
                drySamples += 1
                #expect(Self.phraseRegions.contains { $0.contains(s) },
                        "w(\(s)) = \(w) outside every region: the mix reaches time it must not")
            }
        }
        // Controls: the probe sat on notes, and the mask did act somewhere.
        #expect(noteSamples > 1500)
        #expect(drySamples > 500)
    }

    @Test("the per-region weight (the mix's hot path) equals tunedWeight on every probed second")
    func regionWeightEqualsSetWeight() {
        let set = Self.phrase()
        let regions = set.consonantRegions()
        var inside = 0
        for s in Self.probe {
            let region = regions.first { $0.contains(s) }
            if region != nil { inside += 1 }
            #expect((region?.tunedWeight(atSourceSecond: s) ?? 1) == set.tunedWeight(atSourceSecond: s),
                    "the two weights disagree at \(s)")
        }
        #expect(inside > 500, "control: the probe visited the regions")
    }

    @Test("physics: w == 0 mid-region and beyond every ramp; the head has no ramp at the clip start")
    func weightIsZeroInsideRegions() {
        let set = Self.phrase()
        for region in Self.phraseRegions {
            let upper = region.endSeconds.isFinite ? region.endSeconds : 3.0
            let fade = region.fadeSeconds
            for s in Self.probe where s >= region.startSeconds && s <= upper {
                let pastIn = !region.followsNote || s - region.startSeconds >= fade
                let pastOut = !region.precedesNote || region.endSeconds - s >= fade
                if pastIn && pastOut {
                    #expect(set.tunedWeight(atSourceSecond: s) == 0, "w(\(s)) is not dry")
                }
            }
        }
        #expect(set.tunedWeight(atSourceSecond: 0) == 0, "the head ramped up at the clip start")
        #expect(set.tunedWeight(atSourceSecond: 1.375) == 0)
        #expect(set.tunedWeight(atSourceSecond: 1.86) == 0)
        #expect(set.tunedWeight(atSourceSecond: 1e6) == 0, "the tail runs to the end of the take")
    }

    @Test("physics: each ramp is monotone, 1 on the note edge, 0 one fade into the gap, on the gap side only")
    func rampIsMonotoneOnTheGapSide() {
        let set = Self.phrase()
        let fade = PitchEditSet.consonantFadeSeconds
        // Hand-overs FROM a note (A..., D, E ends) and TO a note (A, D, E starts).
        let fromNote: [Double] = [1.30, 1.80, 2.40]
        let toNote: [Double] = [0.20, 1.45, 1.92]
        for edge in fromNote {
            var previous = set.tunedWeight(atSourceSecond: edge)
            #expect(previous == 1, "w on the note's end edge (\(edge)) is not 1")
            for step in 1...100 {
                let w = set.tunedWeight(atSourceSecond: edge + fade * Double(step) / 100)
                #expect(w <= previous, "the ramp after \(edge) rose at step \(step)")
                previous = w
            }
            #expect(previous < 1e-9, "one fade after \(edge) is not dry")
            #expect(set.tunedWeight(atSourceSecond: edge - 1e-9) == 1, "w < 1 on the note side of \(edge)")
        }
        for edge in toNote {
            var previous = set.tunedWeight(atSourceSecond: edge)
            #expect(previous == 1, "w on the note's start edge (\(edge)) is not 1")
            for step in 1...100 {
                let w = set.tunedWeight(atSourceSecond: edge - fade * Double(step) / 100)
                #expect(w <= previous, "the ramp before \(edge) rose at step \(step)")
                previous = w
            }
            #expect(previous < 1e-9, "one fade before \(edge) is not dry")
            #expect(set.tunedWeight(atSourceSecond: edge + 1e-9) == 1, "w < 1 on the note side of \(edge)")
        }
        // Strictly inside a ramp the weight is a true blend.
        let mid = set.tunedWeight(atSourceSecond: 1.80 + fade / 2)
        #expect(mid > 0.49 && mid < 0.51)
    }

    @Test("G-C10: a 32 ms blink stays WET; a 120 ms gap goes dry; the 64 ms threshold is joinKind's, both sides")
    func blinksStayWet() {
        let set = Self.phrase()
        for s in Self.probe where s >= 0.90 && s <= 0.932 {
            #expect(set.tunedWeight(atSourceSecond: s) == 1, "the blink at \(s) went dry: a dry island")
        }
        #expect(set.tunedWeight(atSourceSecond: 1.86) == 0, "control: a 120 ms gap goes dry")
        // EXACTLY at the threshold (an exact subtraction: the head, from 0):
        // `joinKind` says .gap at 64 ms and .soft just under it.
        func head(_ start: Double) -> PitchEditSet {
            PitchEditSet(segments: [Self.note(Self.idA, start, 0.5, cents: 300)],
                         keepsConsonantsUntuned: true)
        }
        #expect(PitchEditSet.joinKind(leftEndSeconds: 0, rightStartSeconds: 0.064) == .gap)
        #expect(head(0.064).consonantRegions().first?.endSeconds == 0.064)
        #expect(head(0.064).tunedWeight(atSourceSecond: 0.02) == 0)
        #expect(head(0.0639).consonantRegions().first?.startSeconds == 0.5,
                "a 63.9 ms head is a blink: no head region, the tail comes first")
        #expect(head(0.0639).tunedWeight(atSourceSecond: 0.02) == 1)
        // Between two notes, exactly at the threshold (0.314 − 0.25 is 0.064
        // bit for bit): a gap, so a region; 0.3139 is a soft join, so none.
        func pair(_ rightStart: Double) -> PitchEditSet {
            PitchEditSet(segments: [Self.note(Self.idA, 0.1, 0.25, cents: 300),
                                    Self.note(Self.idB, rightStart, 0.6)],
                         keepsConsonantsUntuned: true)
        }
        #expect(0.314 - 0.25 == PitchEditSet.consonantMinimumGapSeconds, "the fixture is not exact")
        #expect(pair(0.314).consonantRegions().contains { $0.startSeconds == 0.25 && $0.endSeconds == 0.314 })
        #expect(pair(0.314).tunedWeight(atSourceSecond: 0.282) == 0)
        #expect(!pair(0.3139).consonantRegions().contains { $0.startSeconds == 0.25 })
        #expect(pair(0.3139).tunedWeight(atSourceSecond: 0.282) == 1)
    }

    @Test("physics: the half-region clamp: two ramps meet at 0 mid-region, symmetric, never overlapping")
    func halfRegionClampHolds() {
        // An exact binary region (62.5 ms) and a fade (50 ms) wider than half
        // of it: the clamp must bring each ramp to 31.25 ms.
        let region = PitchConsonantRegion(startSeconds: 0, endSeconds: 0.0625,
                                          followsNote: true, precedesNote: true)
        #expect(PitchConsonantRegion.clampedFade(0.05, durationSeconds: 0.0625) == 0.03125)
        func w(_ s: Double) -> Double {
            PitchEditSet.consonantWeight(atSourceSecond: s, in: region, fadeSeconds: 0.05)
        }
        #expect(w(0) == 1 && w(0.0625) == 1)
        #expect(w(0.03125) == 0, "the clamped ramps do not meet at 0 mid-region")
        var previous = 1.0
        for i in 0...625 {
            let s = Double(i) * 0.0001
            let value = w(s)
            #expect(abs(value - w(0.0625 - s)) < 1e-9, "asymmetric at \(s): the ramps overlap")
            if i > 0 && s <= 0.03125 { #expect(value <= previous) }
            previous = value
        }
        // The shipped fade on a region the clamp would bind (10 ms long).
        #expect(PitchConsonantRegion.clampedFade(PitchEditSet.consonantFadeSeconds,
                                                 durationSeconds: 0.010) == 0.005)
        #expect(PitchConsonantRegion.clampedFade(.nan, durationSeconds: 1) == 0)
        #expect(PitchConsonantRegion.clampedFade(-1, durationSeconds: 1) == 0)
    }

    @Test("gates: flag off, identity or levels only: w == 1 everywhere; non-finite seconds read 1")
    func noMixMeansWeightOne() {
        var levelOnly = Self.phrase()
        for index in levelOnly.segments.indices { levelOnly.segments[index].pitchOffsetCents = 0 }
        levelOnly.segments[0].amplitudeDb = -6
        #expect(levelOnly.isPitchIdentity && !levelOnly.isIdentity)
        var identity = levelOnly
        identity.segments[0].amplitudeDb = 0
        #expect(identity.isIdentity)
        for (name, set) in [("flag off", Self.phrase(consonants: false)),
                            ("levels only", levelOnly), ("identity", identity)] {
            #expect(!set.hasConsonantMix, "\(name)")
            for s in Self.probe {
                #expect(set.tunedWeight(atSourceSecond: s) == 1, "\(name): w(\(s)) is not 1")
            }
        }
        // Regions are gated on the flag alone (a drawing may show them early).
        #expect(identity.consonantRegions() == Self.phraseRegions)
        let set = Self.phrase()
        for s in [Double.nan, .infinity, -.infinity] {
            #expect(set.tunedWeight(atSourceSecond: s) == 1)
        }
        #expect(set.tunedWeight(atSourceSecond: -0.5) == 1, "before the clip start is outside every region")
    }

    @Test("a table with no curve note at all is ONE region, the whole take")
    func noCurveNoteIsOneRegion() {
        var set = PitchEditSet(segments: [
            Self.note(Self.idS, 0.3, 0.5, origin: .unpitched),
            NoteSegment(id: Self.idA, startSeconds: 0.8, endSeconds: 1.0, detectedHz: 220,
                        detectedConfidence: 0.4, timeStartDeltaSeconds: 0.01, origin: .unpitched),
        ], keepsConsonantsUntuned: true)
        #expect(!set.isPitchIdentity && set.segments.allSatisfy { !$0.entersPitchCurve })
        #expect(set.consonantRegions() == [PitchConsonantRegion(startSeconds: 0, endSeconds: .infinity,
                                                                followsNote: false, precedesNote: false)])
        #expect(set.tunedWeight(atSourceSecond: 0.4) == 0 && set.tunedWeight(atSourceSecond: 0) == 0)
        set.keepsConsonantsUntuned = false
        #expect(set.tunedWeight(atSourceSecond: 0.4) == 1)
    }

    // MARK: - R21 and the one soft/gap predicate

    /// Two notes with an untouched SOUND abutting both. Between the CURVE
    /// notes the join is a 200 ms gap; between ADJACENT segments every edge
    /// abuts (soft). A mask that re-derived the rule over adjacent segments,
    /// instead of reading `joinKind` between curve notes, keeps the breath wet.
    static func soundBetween(offset: Double, cleared: Bool = false) -> PitchEditSet {
        PitchEditSet(segments: [
            note(idA, 0.2, 0.8, cents: 300),
            NoteSegment(id: idS, startSeconds: 0.8, endSeconds: 1.0, detectedHz: 220,
                        detectedConfidence: 0.4, pitchOffsetCents: offset, isCleared: cleared,
                        origin: .unpitched),
            note(idB, 1.0, 1.6),
        ], keepsConsonantsUntuned: true)
    }

    @Test("G-C13 (R21): an untouched sound between notes plays DRY; a sound dragged +300 c renders moved")
    func untouchedSoundIsDryDraggedSoundMoves() {
        let untouched = Self.soundBetween(offset: 0)
        #expect(!untouched.segments[1].entersPitchCurve)
        // Adjacent segments abut (the re-derivation's view): soft both sides.
        #expect(PitchEditSet.joinKind(leftEndSeconds: 0.8, rightStartSeconds: 0.8) == .soft)
        #expect(untouched.joinKind(between: 0, and: 2) == .gap, "curve-note view: a 200 ms gap")
        #expect(untouched.consonantRegions().contains(
            PitchConsonantRegion(startSeconds: 0.8, endSeconds: 1.0, followsNote: true, precedesNote: true)))
        #expect(untouched.tunedWeight(atSourceSecond: 0.9) == 0, "the untouched breath is not dry")

        let dragged = Self.soundBetween(offset: 300)
        #expect(dragged.segments[1].entersPitchCurve)
        #expect(!dragged.consonantRegions().contains { $0.contains(0.9) })
        for s in Self.probe where s >= 0.8 && s <= 1.0 {
            #expect(dragged.tunedWeight(atSourceSecond: s) == 1,
                    "the dragged sound at \(s) plays dry: U5 (R21) says a deliberate drag moves it")
        }
    }

    /// A deterministic fuzz: for every pair of neighbouring CURVE notes, a
    /// region spans exactly their hole iff `joinKind(between:and:)` is `.gap`.
    @Test("R15: regions agree with joinKind on every curve-note pair (fuzzed tables with sounds)")
    func regionsAgreeWithJoinKind() {
        var state: UInt64 = 0xC2C2_2025_0925_0001
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var gapPairs = 0
        var softPairs = 0
        for _ in 0..<200 {
            var t = next() * 0.1
            var segments: [NoteSegment] = []
            for _ in 0..<8 {
                let length = 0.06 + next() * 0.4
                let isSound = next() < 0.3
                let moved = next() < 0.4
                segments.append(NoteSegment(startSeconds: t, endSeconds: t + length, detectedHz: 220,
                                            detectedConfidence: 0.8,
                                            pitchOffsetCents: moved ? 150 : 0,
                                            origin: isSound ? .unpitched : .detected))
                // Abut, a blink, a threshold-ish hole, or a real gap.
                let pick = next()
                t += length + (pick < 0.3 ? 0 : pick < 0.5 ? 0.02 : pick < 0.6 ? 0.07 : 0.1 + next() * 0.3)
            }
            let set = PitchEditSet(segments: segments, keepsConsonantsUntuned: true)
            let regions = set.consonantRegions()
            let curve = set.segments.indices.filter { set.segments[$0].entersPitchCurve }
            for (left, right) in zip(curve, curve.dropFirst()) {
                let expectGap = set.joinKind(between: left, and: right) == .gap
                let hasRegion = regions.contains {
                    $0.startSeconds == set.segments[left].endSeconds
                        && $0.endSeconds == set.segments[right].startSeconds
                }
                #expect(hasRegion == expectGap, "pair \(left)-\(right) disagrees with joinKind")
                if expectGap { gapPairs += 1 } else { softPairs += 1 }
            }
        }
        #expect(gapPairs > 100 && softPairs > 100, "the fuzz did not exercise both join kinds")
    }

    // MARK: - The level mask overlaps the consonant mask on a cleared sound

    /// ⛔ §2b.4's "disjoint frames, order cannot change a byte" is FALSE once
    /// sounds are in the table: a cleared untouched breath is inside a region
    /// (dry) AND level-masked (silent). The render must MIX FIRST, then mask
    /// (NT-E2). This pins the overlap so nobody re-reads the design's claim.
    @Test("order: a cleared untouched sound is dry (w 0) AND silenced (gain 0), so mix-then-mask is required")
    func clearedSoundIsInBothMasks() {
        let set = Self.soundBetween(offset: 0, cleared: true)
        #expect(set.tunedWeight(atSourceSecond: 0.9) == 0)
        #expect(set.gain(atSourceSecond: 0.9) == 0)
        // Control: a cleared NOTE is wet (the mask never touches it).
        var clearedNote = set
        clearedNote.segments[0].isCleared = true
        #expect(clearedNote.tunedWeight(atSourceSecond: 0.5) == 1 && clearedNote.gain(atSourceSecond: 0.5) == 0)
    }

    // MARK: - Why the mix is inactive (§2b.5)

    @Test("inactive reasons: stretched, transposed, then time edits (dormant); nil at ratio 1 and 0 st")
    func inactiveReasons() {
        let set = Self.phrase()
        #expect(set.consonantMixInactiveReason(stretchRatio: 1, clipSemitones: 0) == nil)
        #expect(set.consonantMixIsActive(stretchRatio: 1, clipSemitones: 0))
        #expect(set.consonantMixInactiveReason(stretchRatio: 1.5, clipSemitones: 0) == .clipStretched)
        #expect(set.consonantMixInactiveReason(stretchRatio: 1, clipSemitones: 2) == .clipTransposed)
        #expect(set.consonantMixInactiveReason(stretchRatio: 0.5, clipSemitones: -3) == .clipStretched)
        #expect(set.consonantMixInactiveReason(stretchRatio: .nan, clipSemitones: 0) == .clipStretched)
        #expect(set.consonantMixInactiveReason(stretchRatio: 1, clipSemitones: -0.0) == nil)
        #expect(!set.consonantMixIsActive(stretchRatio: 1, clipSemitones: 2))
        // Retimed notes: dormant while the render does not read the warp.
        var timed = set
        timed.segments[0].timeEndDeltaSeconds = 0.02
        #expect(timed.hasTimeEdits && !PitchEditSet.consonantMixRenderReadsTimeWarp)
        #expect(timed.consonantMixInactiveReason(stretchRatio: 1, clipSemitones: 0) == nil)
        // Flag off: off by choice, no reason, never active.
        let off = Self.phrase(consonants: false)
        #expect(off.consonantMixInactiveReason(stretchRatio: 1.5, clipSemitones: 2) == nil)
        #expect(!off.consonantMixIsActive(stretchRatio: 1, clipSemitones: 0))
        // An identity set with the flag on: the reason still speaks (the editor
        // can say "off while transposed" before the first drag); never active.
        var identity = set
        for index in identity.segments.indices { identity.segments[index].pitchOffsetCents = 0 }
        #expect(identity.consonantMixInactiveReason(stretchRatio: 1, clipSemitones: 2) == .clipTransposed)
        #expect(!identity.consonantMixIsActive(stretchRatio: 1, clipSemitones: 0))
        // The wire's strings (§2b.5), pinned.
        #expect(ConsonantMixInactiveReason.allCases.map(\.rawValue)
                == ["clip stretched", "clip transposed", "time edits"])
    }

    // MARK: - G-C7a: legacy decodes false, new sets seed true

    @Test("G-C7a: absent decodes false, false is omitted, true round-trips; the memberwise init is false")
    func codableAndMemberwiseAreLegacy() throws {
        #expect(!PitchEditSet.empty.keepsConsonantsUntuned)
        #expect(!PitchEditSet(segments: Self.phrase().segments).keepsConsonantsUntuned)
        let off = Self.phrase(consonants: false)
        let offText = String(decoding: try JSONEncoder().encode(off), as: UTF8.self)
        #expect(!offText.contains("keepsConsonantsUntuned"))
        #expect(offText.contains("\"segments\""), "control: the probe reads the payload")
        #expect(try JSONDecoder().decode(PitchEditSet.self, from: Data(offText.utf8))
                    .keepsConsonantsUntuned == false)
        let on = Self.phrase()
        let onText = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        #expect(onText.contains("\"keepsConsonantsUntuned\":true"))
        #expect(try JSONDecoder().decode(PitchEditSet.self, from: Data(onText.utf8)) == on)
    }

    @Test("G-C7a: every seam that CREATES a set seeds the flag on (editor table, every preset)")
    func newSetsSeedTheFlag() {
        let result = NaturalTuningFieldCarryTests.slideResult()
        let editor = PitchNoteTable.detected(from: result)
        #expect(!editor.isEmpty && editor.keepsConsonantsUntuned, "the editor's table dropped the flag")
        for preset in PitchCorrectionPreset.allCases {
            let set = PitchAutoCorrect.editSet(from: result, options: preset.options())
            #expect(!set.isEmpty && set.keepsConsonantsUntuned, "\(preset) dropped the flag")
        }
        for policy in [PitchEditSet.SeedPolicy.editor, .preset] {
            #expect(PitchEditSet.seeded(analysisVersion: 1, segments: Self.phrase().segments,
                                        retuneMs: 30, partKinds: [:], seedPolicy: policy)
                        .keepsConsonantsUntuned)
        }
    }

    // MARK: - G-C8: the construction-site census

    /// Every place in `Sources/` that CONSTRUCTS a `PitchEditSet` by its
    /// memberwise `init`, by file (relative to `Sources/`), with its role. A
    /// construction can drop `keepsConsonantsUntuned` (and every other
    /// set-level field) silently, so each one is named here on purpose:
    ///  * `.empty`: the legacy identity constant, false by design;
    ///  * `seeded`: THE one seed (both product seams call it), true.
    /// Every REBUILD goes through `withSegments` (a copy, so it carries
    /// everything) or mutates a copy; decoding goes through `init(from:)`,
    /// which reads the key. A NEW construction site turns this red until it
    /// is reviewed (does it carry, or seed, the flag?) and listed.
    static let constructionSites: [String: Int] = [
        "DAWCore/PitchCorrection.swift": 2,
    ]

    /// The repo root, from this file's path (the `repoSource` idiom of
    /// `InsertSpectrumCoverageTests`).
    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Constructor-shaped code: `PitchEditSet(` or `PitchEditSet.init(`, or a
    /// type-inferred `.init(analysisVersion:` (the memberwise init's first
    /// label). Comment lines are skipped, and a line's trailing `//` comment
    /// is cut, so a doc comment that names the shape is not a site.
    static let constructorShapes = [#"\bPitchEditSet\s*(\.init)?\s*\("#,
                                    #"\.init\s*\(\s*analysisVersion\s*:"#]

    static func constructionCount(in text: String) throws -> Int {
        let expressions = try constructorShapes.map { try NSRegularExpression(pattern: $0) }
        var count = 0
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            let range = NSRange(line.startIndex..., in: line)
            for expression in expressions {
                count += expression.numberOfMatches(in: line, range: range)
            }
        }
        return count
    }

    @Test("G-C8 census: the only PitchEditSet constructions in Sources/ are .empty and seeded")
    func constructionSiteCensus() throws {
        // The instrument can see a site (positive controls on the shapes).
        #expect(try Self.constructionCount(in: "let s = PitchEditSet(segments: [])") == 1)
        #expect(try Self.constructionCount(in: "let s: PitchEditSet = .init(analysisVersion: 1)") == 1)
        #expect(try Self.constructionCount(in: "/// PitchEditSet(segments:) in a doc") == 0)
        #expect(try Self.constructionCount(in: "x = y // PitchEditSet( in a comment") == 0)

        let root = try #require(Self.repoRoot(), "could not locate the repo from \(#filePath)")
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        var scanned = 0
        var found: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            let count = try Self.constructionCount(in: text)
            if count > 0 {
                let parts = url.standardizedFileURL.pathComponents
                let from = (parts.lastIndex(of: "Sources") ?? 0) + 1
                let relative = parts[from...].joined(separator: "/")
                found[relative] = count
            }
        }
        #expect(scanned > 200, "the census read only \(scanned) files: it did not see the tree")
        #expect(found == Self.constructionSites,
                """
                PitchEditSet construction sites changed: \(found.sorted { $0.key < $1.key }). \
                A new construction can silently reset keepsConsonantsUntuned (and every other \
                set-level field) to legacy. Rebuild with `withSegments`, seed with `seeded`, \
                or list the site in `constructionSites` with the reason it is right.
                """)
        // The behavioural half: the two listed sites do what the list says.
        #expect(!PitchEditSet.empty.keepsConsonantsUntuned)
        #expect(PitchEditSet.seeded(analysisVersion: 1, segments: [], retuneMs: 30,
                                    partKinds: [:], seedPolicy: .preset).keepsConsonantsUntuned)
    }

    @Test("G-C8 carry: withSegments and the pure hand-edit transforms keep the flag, true AND false; on an OLD vocal a hand edit turns it on (D4-1 (b))")
    func pureRebuildsCarryTheFlag() throws {
        for flag in [true, false] {
            // A set that is already NEW (it carries a formant amount, 0.5: not
            // the seed's 1.0), so D4-1 is inert and every rebuild must carry.
            var set = Self.phrase(consonants: flag)
            set.formantCorrection = 0.5
            #expect(!set.predatesNaturalTuning)
            var notes = set.segments
            notes[1].pitchOffsetCents = 120
            #expect(set.withSegments(notes).keepsConsonantsUntuned == flag)
            let dragged = try set.applyingNotePitchOffsets(
                [NotePitchOffset(segmentId: Self.idB, offsetCents: -80)], clipId: UUID())
            #expect(dragged.keepsConsonantsUntuned == flag, "the drag's transform changed the flag")
            let smoother = try set.applyingTransitionSmoothness(centsPerSecond: 6000)
            #expect(smoother.keepsConsonantsUntuned == flag)
            let width = try set.applyingNoteTransition(segmentId: Self.idA, widthMs: 120, clipId: UUID())
            #expect(width.keepsConsonantsUntuned == flag)
            #expect(set.afterHandEdit().keepsConsonantsUntuned == flag,
                    "D4-1 updates only a vocal that predates natural tuning")
        }
        // The one upgrade path turns it on (X4), explicitly.
        #expect(Self.phrase(consonants: false).upgradedToNaturalTuning().keepsConsonantsUntuned)
        // D4-1 (b), the user's ruling of 2026-09-26: on an OLD vocal (no
        // formant amount) a hand edit is the first note you change, so it
        // updates the vocal and the flag comes on; the explicit smoothness
        // switch is a set-level request and leaves it off.
        let old = Self.phrase(consonants: false)
        #expect(old.predatesNaturalTuning, "positive control: a tuned vocal from before the update")
        let dragged = try old.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: Self.idB, offsetCents: -80)], clipId: UUID())
        #expect(dragged.keepsConsonantsUntuned, "a first pitch drag left an old vocal's consonants tuned")
        let width = try old.applyingNoteTransition(segmentId: Self.idA, widthMs: 120, clipId: UUID())
        #expect(width.keepsConsonantsUntuned, "a first slide edit left an old vocal's consonants tuned")
        #expect(old.afterHandEdit().keepsConsonantsUntuned)
        #expect(try !old.applyingTransitionSmoothness(centsPerSecond: 6000).keepsConsonantsUntuned,
                "the explicit smoothness switch turned consonant protection on")
    }
}
