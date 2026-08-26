import Foundation
import Testing

// m23-el SIGNATURE ARITHMETIC — pure geometry, no AVFoundation, no rendering.
//
// Why this lives in its OWN FILE rather than beside the spike it serves:
// `GaplessLoopSpikeTests` is governed by standing law C1 (docs/ROADMAP.md:231,
// m13-f/m14) — "the L-0 splice-primitive pins, 4 tests, stays green forever;
// any splice regression blocks M14 work that day and converts the milestone to
// NO-GO/park". SwiftPM's `--filter` matches the source fileID as well as the
// test ID, so a suite added to `GaplessLoopSpikeTests.swift` would be selected
// by `--filter GaplessLoopSpikeTests` too. That would (a) make the documented
// "4 tests in 1 suite" isolation figure read 12/2, and (b) — far worse — let a
// failure of this pure ARITHMETIC turn the L-0 pin red and park M14, which is
// the exact false-positive m23-el exists to prevent. Separate file keeps
// `--filter GaplessLoopSpikeTests` at 4 tests / 1 suite, unchanged.
//
// WHAT m23-el IS. The leg "segment queued while the player is already
// rendering" (GaplessLoopSpikeTests.swift) failed ONCE under parallel suite
// load with `second.count → 288` where 0 is expected. 288 is not an arbitrary
// number: it is exactly the tail of the 512-frame render quantum that straddles
// the splice at frame 6000 (the pull spans 5632..<6144, so 6000..<6144 = 144
// frames × 2 channels = 288). That whole pull carried pre-splice content and
// everything from 6144 on was correct.
//
// The leg schedules cycle N+1 on the CONTROL thread with a margin of 2928
// frames — 61 ms of AUDIO, but the engine renders `.offline`, so those frames
// are pulled in microseconds of wall clock. The suspected mechanism is that
// `scheduleBuffer` had not been registered by the player when the straddling
// quantum was rendered. THIS IS NOT CONFIRMED AND NOT REPRODUCED: 0 failures
// in 53 targeted attempts (5 full-suite runs + 48 under 8-way process
// contention). Nothing here fixes the race; it only makes a recurrence
// self-classifying so a future triage does not park a milestone on a load
// artefact — nor wave through a real splice regression.

/// The spike's ACTUAL geometry, read from `GaplessLoopSpikeTests.swift` rather
/// than hand-copied — `spikeQuantumFrames`/`spikeCycleFrames` are that file's
/// module-visible aliases for its own `quantumFrames`/`cycleFrames` (512 /
/// 6000; the design note pins the same values,
/// docs/research/design-m13f-gapless-loop.md §3). Divergence is therefore
/// impossible: if the spike's geometry ever changes, the assertions below fail
/// loudly and the m23-el record (288) must be re-derived — which is exactly the
/// review anyone changing that geometry should be forced into.
private let spikeQuantum = spikeQuantumFrames
private let spikeSplice = spikeCycleFrames

// MARK: - The geometry

/// Sample slots (frames × channels) in the TAIL of the render quantum that
/// STRADDLES `splice` — the slots at or after `splice` that belong to the same
/// pull as the last pre-splice frame.
///
/// This is exactly the mismatch count the spike's `mismatches(_:range:against:)`
/// reports over the post-splice region when that one straddling quantum carried
/// the wrong content (stale pre-splice material, or silence) and every quantum
/// after it was correct.
///
/// At the spike's own geometry — splice 6000, quantum 512, 2 channels — the
/// straddling pull spans 5632..<6144, so the tail is 6000..<6144 = 144 frames
/// × 2 ch = 288, the count observed once at m23-el.
///
/// Returns 0 when the splice lands ON a quantum boundary (nothing straddles it)
/// and for degenerate geometry (non-positive quantum/channels, negative splice)
/// rather than trapping or returning a nonsense figure.
func straddlingQuantumTailCount(splice: Int, quantum: Int, channels: Int) -> Int {
    guard quantum > 0, channels > 0, splice >= 0 else { return 0 }
    let offsetIntoQuantum = splice % quantum
    guard offsetIntoQuantum != 0 else { return 0 }
    return (quantum - offsetIntoQuantum) * channels
}

/// How a non-zero post-splice mismatch count relates to the quantum geometry.
enum SpliceMismatchSignature: Equatable {
    /// No mismatches.
    case clean
    /// The count is the straddling-quantum tail plus a whole number of further
    /// whole quanta: the first `quanta` pulls at and after the splice carried
    /// the wrong content and everything after them was correct. `quanta == 1`
    /// is the shape observed at m23-el (288 at 512/6000/2 ch); larger values are
    /// the SAME signature class with a longer scheduling stall, not a different
    /// fault — filing one of those as a real regression would park M14 on the
    /// very artefact this classifier exists to recognise.
    case missedQuanta(quanta: Int)
    /// The count is not quantum-aligned from the splice — it does not fit a
    /// late-registration stall at all.
    case unexplained
}

/// Classifies a post-splice mismatch count against the render-quantum grid.
///
/// The discriminating predicate is whether the count corresponds to a whole
/// number of missed pulls measured FROM the splice: the count must divide by
/// `channels`, reach at least the straddling tail, and exceed it by a multiple
/// of `quantum` frames.
func classifySpliceMismatch(count: Int, splice: Int,
                            quantum: Int, channels: Int) -> SpliceMismatchSignature {
    guard count != 0 else { return .clean }
    guard count > 0, quantum > 0, channels > 0 else { return .unexplained }
    // Tail in FRAMES: the same helper asked for one channel. Keeping the two
    // unit systems apart matters — comparing a frames×channels tail against a
    // frame count mis-files a two-quantum stall as a real regression.
    let tailFrames = straddlingQuantumTailCount(splice: splice, quantum: quantum, channels: 1)
    guard tailFrames != 0 else { return .unexplained }  // splice on a boundary
    guard count % channels == 0 else { return .unexplained }
    let frames = count / channels
    guard frames >= tailFrames else { return .unexplained }
    let extraFrames = frames - tailFrames
    guard extraFrames % quantum == 0 else { return .unexplained }
    return .missedQuanta(quanta: extraFrames / quantum + 1)
}

/// One line a future triage can act on WITHOUT re-deriving the geometry — the
/// whole point of m23-el, given that a red in the L-0 pin is a milestone-parking
/// signal under standing law C1.
func spliceMismatchVerdict(count: Int, splice: Int,
                           quantum: Int, channels: Int) -> String {
    let tail = straddlingQuantumTailCount(splice: splice, quantum: quantum, channels: channels)
    switch classifySpliceMismatch(count: count, splice: splice,
                                  quantum: quantum, channels: channels) {
    case .clean:
        return "signature: clean (0 mismatches; the straddling-quantum tail "
            + "would be \(tail))"
    case .missedQuanta(let quanta):
        return "signature: MATCHES the m23-el load-artefact signature "
            + "(see docs/ROADMAP.md m23-el) — \(count) == \(quanta) whole "
            + "render quantum/quanta missed from the splice (straddling-quantum "
            + "tail \(tail) = (\(quantum) − \(splice % quantum)) frames × "
            + "\(channels) ch\(quanta > 1 ? " + \(quanta - 1) × \(quantum) frames" : "")), "
            + "i.e. the pull(s) straddling the splice carried pre-splice content "
            + "and everything after them was correct. RE-RUN IN ISOLATION "
            + "(./scripts/test.sh --filter GaplessLoopSpikeTests) BEFORE "
            + "TREATING THIS AS A SPLICE REGRESSION: m23-el measured 0 failures "
            + "in 53 attempts (5 full-suite runs + 48 under 8-way process "
            + "contention) and the mechanism is NOT confirmed."
    case .unexplained:
        return "signature: does NOT match the m23-el load-artefact signature "
            + "(\(count) is not a whole number of \(quantum)-frame pulls × "
            + "\(channels) ch measured from the splice; the straddling-quantum "
            + "tail is \(tail)) — INVESTIGATE AS A REAL SPLICE REGRESSION."
    }
}

// MARK: - Tests (pure arithmetic — these must never touch AVAudioEngine)

@Suite("Splice artefact signature arithmetic (m23-el, m13-f L-0)")
struct SpliceArtefactSignatureTests {
    /// The count observed once at m23-el, under parallel suite load.
    private let observedM23ELCount = 288

    @Test("the spike's own geometry yields the count observed at m23-el")
    func realGeometryMatchesTheObservedCount() {
        // Guard the mirror itself, so a geometry change fails with a message
        // that says what to do rather than a bare "288 != n".
        #expect(spikeQuantum == 512,
                "the spike's render quantum changed to \(spikeQuantum) — re-derive the m23-el artefact count (recorded as 288) before trusting it")
        #expect(spikeSplice == 6_000,
                "the spike's cycle length changed to \(spikeSplice) — re-derive the m23-el artefact count (recorded as 288) before trusting it")
        // 6000 = 11×512 + 368, so the straddling pull is 5632..<6144 and the
        // post-splice tail is 6000..<6144 = 144 frames, ×2 channels = 288.
        #expect(straddlingQuantumTailCount(splice: spikeSplice, quantum: spikeQuantum,
                                           channels: 2) == observedM23ELCount)
        #expect(straddlingQuantumTailCount(splice: spikeSplice, quantum: spikeQuantum,
                                           channels: 1) == 144)
    }

    @Test("a splice landing ON a quantum boundary has no straddling tail")
    func spliceOnBoundaryHasNoTail() {
        for splice in [0, 512, 5_632, 6_144, 12_288] {
            #expect(straddlingQuantumTailCount(splice: splice, quantum: 512,
                                               channels: 2) == 0,
                    "splice \(splice) is a multiple of 512 — nothing straddles it")
        }
    }

    @Test("the tail tracks the quantum size, not a hardcoded 288")
    func tailTracksQuantumSize() {
        // 6144 = 2^11 × 3, so quanta 256/512/1024/2048 ALL leave 144 frames at
        // splice 6000 — pinning only those would not prove the quantum argument
        // is wired in at all. 4096 and 480 discriminate.
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 256, channels: 2) == 288)
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 1_024, channels: 2) == 288)
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 4_096, channels: 2) == 4_384)
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 480, channels: 2) == 480)
        #expect(straddlingQuantumTailCount(splice: 100, quantum: 64, channels: 2) == 56)
    }

    @Test("the tail scales linearly with channel count")
    func tailScalesWithChannels() {
        for channels in [1, 2, 4, 6] {
            #expect(straddlingQuantumTailCount(splice: spikeSplice, quantum: spikeQuantum,
                                               channels: channels) == 144 * channels)
        }
    }

    @Test("degenerate geometry returns 0 rather than trapping or going negative")
    func degenerateGeometryIsSafe() {
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 0, channels: 2) == 0)
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: -512, channels: 2) == 0)
        #expect(straddlingQuantumTailCount(splice: 6_000, quantum: 512, channels: 0) == 0)
        // Swift's % is negative for negative operands: an unguarded splice would
        // report MORE than a whole quantum.
        #expect(straddlingQuantumTailCount(splice: -6_000, quantum: 512, channels: 2) == 0)
    }

    @Test("the classifier recognises the artefact including multi-quantum stalls")
    func classifierRecognisesMissedQuanta() {
        let classify = { (count: Int) in
            classifySpliceMismatch(count: count, splice: spikeSplice,
                                   quantum: spikeQuantum, channels: 2)
        }
        #expect(classify(0) == .clean)
        // The observed case: only the straddling pull was wrong.
        #expect(classify(observedM23ELCount) == .missedQuanta(quanta: 1))
        // A slower control-thread hop misses whole further pulls. Same fault,
        // one quantum worse.
        #expect(classify((144 + 512) * 2) == .missedQuanta(quanta: 2))       // 1312
        #expect(classify((144 + 2 * 512) * 2) == .missedQuanta(quanta: 3))   // 2336
    }

    @Test("the classifier rejects counts that are not quantum-aligned")
    func classifierRejectsUnalignedCounts() {
        let classify = { (count: Int) in
            classifySpliceMismatch(count: count, splice: spikeSplice,
                                   quantum: spikeQuantum, channels: 2)
        }
        #expect(classify(7) == .unexplained)      // not a whole number of frames
        #expect(classify(100) == .unexplained)    // short of the tail
        #expect(classify(287) == .unexplained)    // odd — not both channels
        #expect(classify(290) == .unexplained)    // tail + 1 frame
        #expect(classify(12_000) == .unexplained) // whole region wrong, unaligned
        // A splice on a quantum boundary has no straddling pull to blame, so
        // ANY mismatch there is a real fault.
        #expect(classifySpliceMismatch(count: 288, splice: 6_144,
                                       quantum: 512, channels: 2) == .unexplained)
    }

    @Test("the verdict text names the item and the required next step")
    func verdictTextIsActionable() {
        let artefact = spliceMismatchVerdict(count: observedM23ELCount, splice: spikeSplice,
                                             quantum: spikeQuantum, channels: 2)
        #expect(artefact.contains("MATCHES the m23-el load-artefact signature"))
        #expect(artefact.contains("RE-RUN IN ISOLATION"))
        #expect(artefact.contains("NOT confirmed"))
        #expect(!artefact.contains("REAL SPLICE REGRESSION"))

        let regression = spliceMismatchVerdict(count: 290, splice: spikeSplice,
                                               quantum: spikeQuantum, channels: 2)
        #expect(regression.contains("does NOT match"))
        #expect(regression.contains("INVESTIGATE AS A REAL SPLICE REGRESSION"))

        let clean = spliceMismatchVerdict(count: 0, splice: spikeSplice,
                                          quantum: spikeQuantum, channels: 2)
        #expect(clean.contains("clean"))
    }
}
