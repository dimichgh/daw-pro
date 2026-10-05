import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// W7-NTL — THE NATURAL-TUNING LISTENING SETS, rendered through the PRODUCT
/// path from the user's own take (design
/// `docs/design/2026-09-25-natural-tuning.md` §1(h), R6, R20, §4.h, R26 and
/// the "Open questions" L1/L2; ROADMAP NT-F220).
///
/// The user picks by ear; the pick sets a default. Two sets, one axis each:
///
///     L1  voice size a moved note keeps   formantCorrection 0 / 0.5 / 0.75 / 1
///         e1  one sustained note moved up +400 c
///         e2  a phrase with the Natural preset's ordinary corrections (R20)
///         e3  the note nearest 220 Hz moved down −500 c (NT-F220), with a
///             fallback note fixed in advance
///     L2  how gently a moved note slides   slope legacy / 6000 / 3000 / 1500 c/s
///         into its unmoved neighbour
///
/// Every reading the spec leaves open was fixed in the durable folder's
/// `NT-L/PREREG.txt` before any render. This harness renders the sets, runs
/// the product-side controls (determinism from two fresh caches, the
/// anchors, the per-hop curve invariance, the plants) and logs the pinned
/// cepstral meter (`SpectralEnvelopeMeter`) per analysis window. The
/// verdicts, the independent LPC/YIN instruments, the loudness and the page
/// files are the durable folder's python (`NT-L/nt-checks.py`,
/// `NT-L/nt-page.py`).
///
/// Every set is built in ONE order: the product's seed, then a move through
/// the one-home drag transform (`applyingNotePitchOffsets`), then the axis
/// field. A legacy (`nil`) twin built the other way round would be upgraded
/// back to 1.0 by `afterHandEdit`, so the order is asserted, set by set.
///
/// Env-gated, because the recording is the user's and is never in the tree.
/// It reuses item L's helpers (`NoteSplitListeningTests.load`, `render`,
/// `bitDiff`) and the formant suite's synthetic fixture
/// (`NaturalTuningFormantRenderTests.physicsPlan`/`render`/`envelopeShift`/
/// `tolerance`), unmodified:
///
///     NTL_LISTEN_OUT=<DUR>/NT-L/wav \
///     NTL_PL_MANIFEST=<DUR>/P-L/wav/manifest.json \
///     NTL_PL_ANCHOR=<DUR>/L/wav/07-natural-after.wav \
///     NOTESPLIT_LISTEN_SOURCE=<DUR>/take/dry-norm.wav \
///     NOTESPLIT_LISTEN_PARTS=<DUR>/L/parts.json \
///     NOTESPLIT_LISTEN_OUT=<DUR>/NT-L/wav \
///     NOTESPLIT_LISTEN_REF=<DUR>/L/ref \
///       ./scripts/test.sh --filter NaturalTuningListeningTests
///
/// (`<DUR>` = `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics`.)
///
/// ⚠️ **MAIN-ACTOR CENSUS.** The main-actor attribute is spelled on the TEST,
/// never on the suite (as `NaturalWobbleListeningTests`): the test is
/// env-gated, and a suite-level attribute would count against
/// `MainActorOccupancySiteTests` Leg C (cap 394) for a suite that never runs
/// by default.
@Suite("NT-L — natural-tuning listening sets (product renders of the user's take)", .serialized)
struct NaturalTuningListeningTests {
    static func log(_ message: String) { print("ntl-listen| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["NTL_LISTEN_OUT"] != nil

    @Test("NT-L — L1 voice size (three excerpts) and L2 slides: renders, determinism, anchors, invariance, plants, the gate meter",
          .enabled(if: enabled))
    @MainActor
    func renderTheNaturalTuningSets() async throws {
        try await Self.renderAll()
    }

    // MARK: - The pre-registered constants (NT-L/PREREG.txt)

    /// L1's axis: `formantCorrection`. `nil` is the legacy twin, never an option.
    static let l1Options: [(key: String, amount: Double, tag: String)] = [
        ("A", 0.0, "keep0"), ("B", 0.5, "keep50"), ("C", 0.75, "keep75"), ("D", 1.0, "keep100"),
    ]
    /// L2's axis: `transitionSlopeCentsPerSecond`. 0 = legacy joins (option A).
    static let l2Options: [(key: String, slope: Double, tag: String)] = [
        ("A", 0, "snappy-legacy"), ("B", 6000, "quick-6000"), ("C", 3000, "smooth-3000"),
        ("D", 1500, "slow-1500"),
    ]
    static let windowFrames = 2_048
    static let windowHop = 480
    static let noteMargin = 0.040
    static let contextSeconds = 3.0
    static let minimumGapSeconds = 0.100
    static let e3MinimumValidWindows = 5
    static let l2MinimumDuration = 0.267
    static let e1Move = 400.0
    static let e3Move = -500.0
    static let l2Move = 400.0
    /// The synthetic P+ cell's residual at 220 Hz −500 c, c = 1 (the formant
    /// suite's G2 fixture), ± 1.0 c. Was 63.6 (NT-E1b's pin, ROADMAP "+63.6 c"):
    /// the library's formant envelope sagged between harmonics. RE-PINNED
    /// 2026-10-04 by W7-F220I (the orchestrator's ruling): vendored patch 0004
    /// (the envelope through the harmonic peaks, explicit base only) is the
    /// mechanism, and this harness reads 16.55 c with it (MEASURED on e6f7a27).
    /// Without 0004 the cell reads 63.2 c, and `NaturalTuningFormantEnvelopeTests`
    /// F220-1 and the formant suite's G2 go red (planted 2026-10-04).
    static let pinnedResidual220 = 16.55

    // MARK: - Small helpers

    /// A JSON-safe number (JSONSerialization rejects NaN and infinity).
    static func num(_ x: Double) -> Any { x.isFinite ? x : NSNull() }
    static func num(_ x: Double?) -> Any { x.map { num($0) } ?? NSNull() }

    static func median(_ values: [Double]) -> Double? {
        let v = values.filter(\.isFinite).sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : 0.5 * (v[v.count / 2 - 1] + v[v.count / 2])
    }

    /// The index in `set.segments` of the NOTE (never a sound) whose edges are
    /// `part`'s, bit for bit. The seeds interleave notes and `.unpitched`
    /// sounds by start time, so an index into the splitter's parts is not an
    /// index into a set.
    static func noteIndex(of part: NotePart, in set: PitchEditSet) throws -> Int {
        let hits = set.segments.indices.filter {
            set.segments[$0].origin != .unpitched
                && set.segments[$0].startSeconds.bitPattern == part.startSeconds.bitPattern
                && set.segments[$0].endSeconds.bitPattern == part.endSeconds.bitPattern
        }
        try #require(hits.count == 1, "\(hits.count) notes carry the edges of the part at \(part.startSeconds)")
        return hits[0]
    }

    /// The three natural-tuning set-level fields, as one comparable row.
    static func setLevel(_ set: PitchEditSet) -> String {
        "formant \(set.formantCorrection.map { String($0) } ?? "nil"), consonants \(set.keepsConsonantsUntuned), slope \(set.transitionSlopeCentsPerSecond), retune \(set.retuneMs)"
    }

    /// `set`'s segment array is `base`'s, every stored field of every
    /// segment (S2's reflection comparator; ids compared separately).
    static func sameSegments(_ set: PitchEditSet, _ base: PitchEditSet, _ label: String) throws {
        try #require(set.segments.count == base.segments.count, "\(label): segment count moved")
        for (i, (a, b)) in zip(set.segments, base.segments).enumerated() {
            try #require(a.id == b.id, "\(label): segment \(i) id moved")
            let d = PrePitchNoteSplitReference.differingFields(a, b)
            try #require(d.compared >= 14, "\(label): segment \(i): only \(d.compared) fields compared")
            try #require(d.differing.isEmpty, "\(label): segment \(i) differs: \(d.differing)")
        }
    }

    /// One set's option with the L1 axis written LAST, directly (what
    /// `ProjectStore.setClipFormantCorrection` stores: that field alone).
    static func withAmount(_ set: PitchEditSet, _ amount: Double?) -> PitchEditSet {
        var copy = set
        copy.formantCorrection = amount
        return copy
    }

    /// One set's option with the L2 axis written LAST: 0 = legacy joins
    /// (the wire refuses 0; a set may carry it), otherwise the product's
    /// `applyingTransitionSmoothness`.
    static func withSlope(_ set: PitchEditSet, _ slope: Double) throws -> PitchEditSet {
        if slope == 0 {
            var copy = set
            copy.transitionSlopeCentsPerSecond = 0
            return copy
        }
        return try set.applyingTransitionSmoothness(centsPerSecond: slope)
    }

    /// Hands a counter to escaping closures without a captured `var`.
    final class Counter { var misses = 0 }

    /// What the curve loop hands the shim, chunk by chunk: the transpose,
    /// and (when the plan builds one) the formant shift and base, each at the
    /// chunk's lookup frame, as the `Float` bits the shim receives
    /// (`OfflineStretcher.applyFormant`, `css_set_transpose_semitones`). The
    /// plan is built exactly as the render builds it (the contour only when
    /// the set needs one).
    struct HopGrid {
        let frames: [Int]
        let lookups: [Int]
        let transpose: [Double]
        let formant: [Double]?
        let base: [Double]?
        func bits(_ values: [Double]) -> [UInt32] { values.map { Float($0).bitPattern } }
    }

    static func hopGrid(_ set: PitchEditSet, sampleRate sr: Double, frames count: Int,
                        contour: PitchRenderContour, interval: Int) throws -> HopGrid {
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0, sampleRate: sr, ratio: 1,
            contour: set.needsDetectedContour ? contour : nil))
        let formant = plan.formantCurve(formantPreserve: false)
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        var frames: [Int] = [], lookups: [Int] = [], transpose: [Double] = []
        var shift: [Double] = [], base: [Double] = []
        var frame = 0
        while frame < count {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: frame, compensation: compensation, intervalSamples: interval)
            frames.append(frame)
            lookups.append(lookup)
            transpose.append(plan.semitones(atOutputFrame: lookup))
            if let formant {
                shift.append(formant.semitonesAtOutputFrame(lookup))
                base.append(formant.baseHzAtOutputFrame(lookup))
            }
            frame += interval
        }
        return HopGrid(frames: frames, lookups: lookups, transpose: transpose,
                       formant: formant == nil ? nil : shift, base: formant == nil ? nil : base)
    }
}

// MARK: - The controls: invariance, the meter windows, the replica

extension NaturalTuningListeningTests {

    /// P-L's legs (i) and (ii), on BOTH curves the shim receives. A hop
    /// differs when its transpose, formant shift or formant base differs by a
    /// single `Float` bit (or when one render builds a formant curve and the
    /// other does not). `windows` are the PERMITTED source-second windows; a
    /// hop is inside one when its lookup frame is.
    struct Invariance {
        let hops: Int
        let outside: [Int]
        let inside: [Int]
        let firstPermittedFrame: Int
        let before: NoteSplitListeningTests.BitDiff
        let all: NoteSplitListeningTests.BitDiff
        let causal: Bool
        let lookups: [Int]
        let sampleRate: Double
        var row: [String: Any] {
            [
                "hops": hops, "hopsOutside": outside.count, "hopsInside": inside.count,
                "firstPermittedHopFrame": firstPermittedFrame,
                "audioBeforeFirstPermittedHopBitExact": before.bitExact,
                "audioBeforeFirstPermittedHopDiffering": before.differing,
                "firstDifferingSample": all.first ?? -1, "totalDifferingSamples": all.differing,
                "causal": causal,
                "outsideHopLookupSeconds": outside.prefix(40).map { Double(lookups[$0]) / sampleRate },
            ]
        }
    }

    static func invariance(_ test: [Float], _ reference: [Float], grid: HopGrid, referenceGrid: HopGrid,
                           windows: [(Double, Double)], sampleRate sr: Double) throws -> Invariance {
        try #require(grid.lookups == referenceGrid.lookups && grid.frames == referenceGrid.frames,
                     "the two hop grids are not on the same chunks")
        let engagedMismatch = (grid.formant == nil) != (referenceGrid.formant == nil)
        let t = grid.bits(grid.transpose), rt = referenceGrid.bits(referenceGrid.transpose)
        let f = grid.formant.map(grid.bits), rf = referenceGrid.formant.map(referenceGrid.bits)
        let b = grid.base.map(grid.bits), rb = referenceGrid.base.map(referenceGrid.bits)
        func inWindow(_ j: Int) -> Bool {
            let s = Double(grid.lookups[j]) / sr
            return windows.contains { s >= $0.0 && s <= $0.1 }
        }
        var outside: [Int] = [], inside: [Int] = []
        for j in grid.lookups.indices {
            var differs = engagedMismatch || t[j] != rt[j]
            if !differs, let f, let rf, f[j] != rf[j] { differs = true }
            if !differs, let b, let rb, b[j] != rb[j] { differs = true }
            guard differs else { continue }
            if inWindow(j) { inside.append(j) } else { outside.append(j) }
        }
        let firstAllowed = grid.lookups.indices.first { inWindow($0) }
        let beforeEnd = firstAllowed.map { grid.frames[$0] } ?? test.count
        let before = NoteSplitListeningTests.bitDiff(test, reference, from: 0, to: beforeEnd)
        let all = NoteSplitListeningTests.bitDiff(test, reference)
        let firstHopFrame = (outside + inside).min().map { grid.frames[$0] }
        let causal = all.first.map { first in firstHopFrame.map { first >= $0 } ?? false } ?? true
        return Invariance(hops: grid.lookups.count, outside: outside, inside: inside,
                          firstPermittedFrame: beforeEnd, before: before, all: all, causal: causal,
                          lookups: grid.lookups, sampleRate: sr)
    }

    /// Leg (iii): every output frame where the consonant mix plays the take
    /// DRY (`tunedWeight == 0` exactly; ratio 1, so output frame f is source
    /// second f / sr) must be bit-exact across the set AND equal the source.
    /// `dryMask` lists those frames ONCE per set (every option of a set has
    /// the same notes, so the same regions); `dryFrames` compares one pair,
    /// split at `after` (source seconds): frames at or past it are "after
    /// the permitted window", the ones the leg is about.
    static func dryMask(regions: [PitchConsonantRegion], frames n: Int, sampleRate sr: Double) -> [Int] {
        var out: [Int] = []
        for region in regions {
            let lo = max(0, Int((region.startSeconds * sr).rounded(.up)))
            let hi = region.endSeconds.isFinite ? min(n, Int((region.endSeconds * sr).rounded(.down)) + 1) : n
            guard hi > lo else { continue }
            for frame in lo..<hi where region.tunedWeight(atSourceSecond: Double(frame) / sr) == 0 {
                out.append(frame)
            }
        }
        return out
    }

    static func dryFrames(_ test: [Float], _ reference: [Float], source: [Float],
                          mask: [Int], after: Double, sampleRate sr: Double) -> [String: Any] {
        var dryAfter = 0, vsReferenceAfter = 0, vsSourceAfter = 0
        var dryBefore = 0, vsReferenceBefore = 0, vsSourceBefore = 0
        let n = min(test.count, reference.count, source.count)
        for frame in mask where frame < n {
            let late = Double(frame) / sr >= after
            if late { dryAfter += 1 } else { dryBefore += 1 }
            if test[frame].bitPattern != reference[frame].bitPattern {
                if late { vsReferenceAfter += 1 } else { vsReferenceBefore += 1 }
            }
            if test[frame].bitPattern != source[frame].bitPattern {
                if late { vsSourceAfter += 1 } else { vsSourceBefore += 1 }
            }
        }
        return ["afterSeconds": after,
                "dryFramesAfter": dryAfter, "differFromReferenceAfter": vsReferenceAfter,
                "differFromSourceAfter": vsSourceAfter,
                "dryFramesBefore": dryBefore, "differFromReferenceBefore": vsReferenceBefore,
                "differFromSourceBefore": vsSourceBefore]
    }

    /// The analysis-window centres inside one note (PREREG §3): 2048-frame
    /// windows every 480 frames, each wholly inside
    /// `[start + 0.040, end − 0.040]`, anchored at the first admissible centre.
    static func windowCentres(start: Double, end: Double, sampleRate sr: Double) -> [Int] {
        let half = windowFrames / 2
        let lo = Int(((start + noteMargin) * sr).rounded(.up)) + half
        let hi = Int(((end - noteMargin) * sr).rounded(.down)) - half
        guard hi >= lo else { return [] }
        return Array(stride(from: lo, through: hi, by: windowHop))
    }

    /// The pinned cepstral meter, SOURCE window vs RENDER window, at `centre`.
    static func gateReading(source: [Float], render: [Float], centre: Int, sampleRate sr: Double) -> Double? {
        let half = windowFrames / 2
        guard centre - half >= 0, centre + half <= min(source.count, render.count) else { return nil }
        return SpectralEnvelopeMeter.envelopeShiftCents(
            reference: Array(source[(centre - half)..<(centre + half)]),
            shifted: Array(render[(centre - half)..<(centre + half)]), sampleRate: sr)
    }

    /// GRID ≡ RENDER: the set re-rendered from its hop grid through the
    /// closure entry point, then the consonant mix the product applies. If
    /// the grid is what the render consumed, this is the product render bit
    /// for bit; a lookup the grid does not hold is counted (must be 0).
    static func replica(_ grid: HopGrid, set: PitchEditSet, input: [[Float]],
                        sampleRate sr: Double) throws -> (audio: [Float], misses: Int) {
        let counter = Counter()
        let transpose = Dictionary(uniqueKeysWithValues: zip(grid.lookups, grid.transpose))
        var formant: OfflineStretcher.FormantCurve?
        if let shift = grid.formant, let base = grid.base {
            let shiftAt = Dictionary(uniqueKeysWithValues: zip(grid.lookups, shift))
            let baseAt = Dictionary(uniqueKeysWithValues: zip(grid.lookups, base))
            formant = OfflineStretcher.FormantCurve(
                semitonesAtOutputFrame: { frame in
                    if let v = shiftAt[frame] { return v }
                    counter.misses += 1
                    return 0
                },
                baseHzAtOutputFrame: { frame in
                    if let v = baseAt[frame] { return v }
                    counter.misses += 1
                    return 110
                })
        }
        var out = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { frame in
                if let v = transpose[frame] { return v }
                counter.misses += 1
                return 0
            },
            formantPreserve: false, formant: formant,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sr))
        try StretchCurvePlan.applyConsonantMix(set.consonantRegions(), wet: &out, dry: input,
                                               sampleRate: sr, ratio: 1)
        return (out[0], counter.misses)
    }

    /// The synthetic cell of the formant suite's G2 fixture, unmodified: one
    /// note at `f0` moved `cents`, c = 1, read by the pinned meter against
    /// the source; `withheld` is the same plan with the curve withheld
    /// (legacy); `tol` is the G2/G3 tolerance rule for that cell.
    static func syntheticCell(f0: Double, cents: Double) throws -> [String: Any] {
        let source = NaturalTuningFormantRenderTests.sourceVoice(f0: f0)
        let plan = try NaturalTuningFormantRenderTests.physicsPlan(f0: f0, cents: cents, amount: 1)
        let kept = try NaturalTuningFormantRenderTests.render([source], plan: plan, formantPreserve: false)
        let withheld = try NaturalTuningFormantRenderTests.render([source], plan: plan, formantPreserve: false,
                                                                  formant: .some(nil))
        let e = NaturalTuningFormantRenderTests.envelopeShift(source, kept)
        let eWithheld = NaturalTuningFormantRenderTests.envelopeShift(source, withheld)
        let tol = NaturalTuningFormantRenderTests.tolerance(f0: f0, cents: cents)
        return ["f0": f0, "cents": cents, "keptC1": num(e), "withheldLegacy": num(eWithheld), "tol": num(tol)]
    }
}

// MARK: - The run

extension NaturalTuningListeningTests {

    /// One file of a set: its option key, the WAV name, the set, and whether
    /// it is a page option (rendered twice for determinism) or a reference.
    struct Entry {
        let key: String
        let file: String
        let set: PitchEditSet
        let pageOption: Bool
    }

    /// One listening set (an L1 excerpt or L2), with the note it moved.
    struct ListeningSet {
        let id: String
        let kind: String
        let move: Double?
        let noteIndex: Int?
        let part: NotePart?
        let base: PitchEditSet
        let entries: [Entry]
    }

    static func partRow(_ part: NotePart, index: Int, segment: Int?) -> [String: Any] {
        var row: [String: Any] = [
            "partIndex": index, "run": part.runIndex, "kind": part.kind.rawValue,
            "start": part.startSeconds, "end": part.endSeconds,
            "duration": part.endSeconds - part.startSeconds, "detectedHz": part.centreHz,
            "semitonesFrom220": 12 * log2(part.centreHz / 220),
        ]
        if let segment { row["segmentIndex"] = segment }
        return row
    }

    @MainActor
    static func renderAll() async throws {
        let outDir = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NTL_LISTEN_OUT"))
        let plManifestURL = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NTL_PL_MANIFEST"))
        let plAnchorURL = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NTL_PL_ANCHOR"))
        let take = try NoteSplitListeningTests.load()
        // L's loader creates and owns NOTESPLIT_LISTEN_OUT: it must be THIS
        // folder, never L's (a run would write into L's).
        try #require(take.outDir.standardizedFileURL.path == outDir.standardizedFileURL.path,
                     "NOTESPLIT_LISTEN_OUT (\(take.outDir.path)) must equal NTL_LISTEN_OUT (\(outDir.path))")
        let sr = take.sampleRate
        let source = take.input[0]
        let takeSeconds = Double(source.count) / sr
        var controls: [String: Any] = [:]

        // ── C2(a) THE CONTEXT ANCHOR, before anything else renders ────────────
        let uncorrected = try NoteSplitListeningTests.uncorrected(take)
        let ref00 = try TestSignals.readFile(take.refDir.appendingPathComponent("00-uncorrected.wav"))[0]
        let d00 = NoteSplitListeningTests.bitDiff(uncorrected, ref00)
        log("C2(a) ANCHOR: the zero-curve product loop vs L/ref/00-uncorrected.wav: \(d00)")
        try #require(d00.bitExact, "STOP: the zero-curve product loop is not L's reference: \(d00)")
        controls["anchorZeroCurve"] = ["differing": d00.differing, "bitExact": d00.bitExact, "samples": d00.to]
        log("render key: transposeEngineVersion \(StretchRenderCache.transposeEngineVersion), formantRenderVersion \(PitchEditSet.formantRenderVersion), transitionRenderVersion \(PitchEditSet.transitionRenderVersion)")

        // ── THE EDITOR SEED, from code ─────────────────────────────────────────
        let seed = PitchNoteTable.detected(from: take.detection)
        try #require(seed.retuneMs == PitchEditSet.engineMinimumRetuneMs && seed.retuneMs == 30,
                     "the editor seed's retune is \(seed.retuneMs)")
        try #require(seed.formantCorrection == PitchEditSet.newSetFormantCorrection && seed.formantCorrection == 1.0
                     && seed.keepsConsonantsUntuned
                     && seed.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope
                     && seed.transitionSlopeCentsPerSecond == 3000,
                     "the editor seed is not at the new-set defaults: \(setLevel(seed))")
        try #require(seed.isIdentity, "a fresh editor seed bends nothing")
        let parts = PitchNoteSplitter.parts(in: take.detection.frames, frameRateHz: take.detection.frameRateHz)
        try #require(parts.count == 59, "\(parts.count) parts; parts.json has 59")
        var partSegment: [Int] = []
        for (k, part) in parts.enumerated() {
            let i = try noteIndex(of: part, in: seed)
            try #require(seed.segments[i].detectedHz.bitPattern == part.centreHz.bitPattern,
                         "part \(k) and its note disagree on the centre")
            try #require(seed.segments[i].glideFollow == (part.kind == .transition ? 1 : 0),
                         "part \(k) (\(part.kind)): glideFollow \(seed.segments[i].glideFollow)")
            partSegment.append(i)
        }
        let soundCount = seed.segments.filter { $0.origin == .unpitched }.count
        let slideCount = parts.filter { $0.kind == .transition }.count
        log("SEED: PitchNoteTable.detected = \(seed.segments.count) segments (\(parts.count) notes, \(slideCount) of them sung slides following their neighbours, + \(soundCount) sounds); \(setLevel(seed)); every note identity")

        // ── THE PICKS, by the pre-registered rules ─────────────────────────────
        func duration(_ i: Int) -> Double { parts[i].endSeconds - parts[i].startSeconds }
        func gapBefore(_ i: Int) -> Double {
            i == 0 ? parts[0].startSeconds : parts[i].startSeconds - parts[i - 1].endSeconds
        }
        func gapAfter(_ i: Int) -> Double {
            i == parts.count - 1 ? takeSeconds - parts[i].endSeconds : parts[i + 1].startSeconds - parts[i].endSeconds
        }
        func context(_ i: Int) -> Bool {
            parts[i].startSeconds >= contextSeconds && takeSeconds - parts[i].endSeconds >= contextSeconds
        }
        func clean(_ i: Int) -> Bool { gapBefore(i) >= minimumGapSeconds && gapAfter(i) >= minimumGapSeconds }
        func from220(_ i: Int) -> Double { abs(12 * log2(parts[i].centreHz / 220)) }
        let held = parts.indices.filter { parts[$0].kind == .held }
        let e1Ranked = held.filter { clean($0) && context($0) }.sorted { duration($0) > duration($1) }
        try #require(e1Ranked.count >= 2)
        let e1 = e1Ranked[0]
        let e3p = try #require(held.filter(context).min { from220($0) < from220($1) })
        let e3f = try #require(held.filter { context($0) && clean($0) }.min { from220($0) < from220($1) })
        let l2Pairs = parts.indices.dropLast().filter { i in
            parts[i].kind == .held && parts[i + 1].kind == .held
                && parts[i].runIndex == parts[i + 1].runIndex
                && parts[i].endSeconds.bitPattern == parts[i + 1].startSeconds.bitPattern
                && gapAfter(i + 1) >= minimumGapSeconds
                && duration(i) >= l2MinimumDuration && duration(i + 1) >= l2MinimumDuration
                && context(i + 1) && parts[i].startSeconds >= contextSeconds
        }.sorted { min(duration($0), duration($0 + 1)) > min(duration($1), duration($1 + 1)) }
        let l2Left = try #require(l2Pairs.first)
        let l2Right = l2Left + 1
        // The plant's note (P-X) and the phase-wake note (G2b's control).
        let pxPart = try #require(held.first { parts[$0].runIndex == 16 })
        let e2Window = (start: 661_584.0 / sr, end: 945_072.0 / sr)
        let wakePart = try #require(held.filter { parts[$0].endSeconds <= e2Window.start - 0.5 }.last)
        func near(_ i: Int, _ start: Double, _ end: Double) -> Bool {
            abs(parts[i].startSeconds - start) < 0.0005 && abs(parts[i].endSeconds - end) < 0.0005
        }
        // PREREG named each pick from parts.json; a different pick means the
        // detection moved under this harness, and nothing below is the plan.
        try #require(near(e1, 17.840, 18.496) && parts[e1].runIndex == 21, "e1 pick moved: \(partRow(parts[e1], index: e1, segment: nil))")
        try #require(near(e1Ranked[1], 29.744, 30.192) && parts[e1Ranked[1]].runIndex == 37, "e1 ladder pick moved")
        try #require(near(e3p, 16.816, 16.992) && parts[e3p].runIndex == 20, "e3 primary moved: \(partRow(parts[e3p], index: e3p, segment: nil))")
        try #require(near(e3f, 20.992, 21.440) && parts[e3f].runIndex == 25, "e3 fallback moved: \(partRow(parts[e3f], index: e3f, segment: nil))")
        try #require(near(l2Left, 7.776, 8.160) && near(l2Right, 8.160, 8.560) && parts[l2Left].runIndex == 10,
                     "L2 pair moved: \(partRow(parts[l2Left], index: l2Left, segment: nil))")
        try #require(near(pxPart, 13.024, 13.424), "P-X note moved")
        try #require(near(wakePart, 12.176, 12.336) && parts[wakePart].runIndex == 15, "wake note moved")
        try #require(parts[e3p].centreHz < 220 * pow(2, -2.0 / 12),
                     "a note within 2 st of 220 Hz exists after all: \(parts[e3p].centreHz) Hz")
        try #require(parts[e3p - 1].kind == .transition
                     && parts[e3p - 1].endSeconds.bitPattern == parts[e3p].startSeconds.bitPattern,
                     "e3's primary no longer abuts a sung slide")
        for (label, i) in [("e1", e1), ("e1 ladder", e1Ranked[1]), ("e3 primary", e3p), ("e3 fallback", e3f),
                           ("L2 left", l2Left), ("L2 right (moved)", l2Right)] {
            log(String(format: "PICK %@: run %ld (%@), %.3f-%.3f s (%.3f s), %.2f Hz = %+.2f st from 220 Hz, gaps %.3f / %.3f s",
                       label as NSString, parts[i].runIndex, parts[i].kind.rawValue as NSString,
                       parts[i].startSeconds, parts[i].endSeconds, duration(i), parts[i].centreHz,
                       12 * log2(parts[i].centreHz / 220), gapBefore(i), gapAfter(i)))
        }

        // ── THE SETS: seed → move (the one-home drag) → the axis field LAST ────
        let clipId = UUID()
        func move(_ base: PitchEditSet, segment: Int, cents: Double) throws -> PitchEditSet {
            let moved = try base.applyingNotePitchOffsets(
                [NotePitchOffset(segmentId: base.segments[segment].id, offsetCents: cents)], clipId: clipId)
            try #require(setLevel(moved) == setLevel(base),
                         "the move changed a set-level field: \(setLevel(base)) -> \(setLevel(moved))")
            try #require(moved.segments[segment].pitchOffsetCents == cents)
            return moved
        }
        func l1Set(_ id: String, base: PitchEditSet, move cents: Double?, part: Int?) throws -> ListeningSet {
            var entries: [Entry] = []
            for option in l1Options {
                let set = withAmount(base, option.amount)
                try sameSegments(set, base, "\(id) \(option.key)")
                try #require(set.formantCorrection == option.amount && set.keepsConsonantsUntuned
                             && set.transitionSlopeCentsPerSecond == 3000 && set.engagesFormantCurve,
                             "\(id) \(option.key): \(setLevel(set))")
                entries.append(Entry(key: option.key, file: "\(id)-\(option.key)-\(option.tag).wav", set: set,
                                     pageOption: true))
            }
            let twin = withAmount(base, nil)
            try sameSegments(twin, base, "\(id) nil")
            try #require(twin.formantCorrection == nil && twin.keepsConsonantsUntuned
                         && twin.transitionSlopeCentsPerSecond == 3000 && !twin.engagesFormantCurve,
                         "\(id) nil twin: \(setLevel(twin))")
            entries.append(Entry(key: "nil", file: "\(id)-nil-legacy.wav", set: twin, pageOption: false))
            return ListeningSet(id: id, kind: "L1", move: cents, noteIndex: part.map { partSegment[$0] },
                                part: part.map { parts[$0] }, base: base, entries: entries)
        }
        let e1Base = try move(seed, segment: partSegment[e1], cents: e1Move)
        let e3pBase = try move(seed, segment: partSegment[e3p], cents: e3Move)
        let e3fBase = try move(seed, segment: partSegment[e3f], cents: e3Move)

        let natOptions = PitchCorrectionPreset.natural.options()
        try #require(natOptions.strength == 0.85 && natOptions.retuneMs == 110 && natOptions.preserveVibrato
                     && natOptions.scale == .chromatic,
                     "Natural is not strength 0.85 / retune 110 ms / preserve vibrato / chromatic")
        let natural = PitchAutoCorrect.editSet(from: take.detection, options: natOptions)
        try #require(natural.formantCorrection == 1.0 && natural.keepsConsonantsUntuned
                     && natural.transitionSlopeCentsPerSecond == 3000 && natural.retuneMs == 110,
                     "the Natural preset table is not at the new-set defaults: \(setLevel(natural))")
        try #require(natural.segments.allSatisfy { $0.driftScale == 1 && $0.vibratoScale == 1 },
                     "R6/R20: option A's material must be UNSHAPED; a Natural segment carries a shaping scale")

        var sets = try [
            l1Set("L1-e1", base: e1Base, move: e1Move, part: e1),
            l1Set("L1-e2", base: natural, move: nil, part: nil),
            l1Set("L1-e3p", base: e3pBase, move: e3Move, part: e3p),
            l1Set("L1-e3f", base: e3fBase, move: e3Move, part: e3f),
        ]
        if let step = ProcessInfo.processInfo.environment["NTL_E1_LADDER"] {
            // PREREG §1: the e1 fallback ladder, rendered only when asked.
            let (part, cents): (Int, Double) = switch step {
            case "1": (e1, 500)
            case "2": (e1Ranked[1], 400)
            default: (e1Ranked[1], 500)
            }
            sets.append(try l1Set("L1-e1L\(step)", base: try move(seed, segment: partSegment[part], cents: cents),
                                  move: cents, part: part))
        }
        let l2Base = try move(seed, segment: partSegment[l2Right], cents: l2Move)
        let joinLeft = partSegment[l2Left], joinRight = partSegment[l2Right]
        try #require(l2Base.nextCurveNoteIndex(after: joinLeft) == joinRight
                     && l2Base.joinKind(between: joinLeft, and: joinRight) == .soft,
                     "the L2 join is not a soft join between the two notes")
        if let after = l2Base.nextCurveNoteIndex(after: joinRight) {
            try #require(l2Base.joinKind(between: joinRight, and: after) == .gap,
                         "the moved L2 note's other edge is not a gap")
        }
        var l2Entries: [Entry] = []
        var appliedWidths: [String: Any] = [:]
        for option in l2Options {
            let set = try withSlope(l2Base, option.slope)
            try sameSegments(set, l2Base, "L2 \(option.key)")
            try #require(set.formantCorrection == 1.0 && set.keepsConsonantsUntuned
                         && set.transitionSlopeCentsPerSecond == option.slope,
                         "L2 \(option.key): \(setLevel(set))")
            let reading = try #require(set.joinReading(afterSegmentAt: joinLeft))
            try #require(reading.kind == .soft && reading.nextSegmentId == set.segments[joinRight].id)
            if option.slope == 0 {
                try #require(reading.appliedWidthMs == nil, "option A must keep the legacy halves")
            } else {
                let expected = 1000 * l2Move / option.slope
                let applied = try #require(reading.appliedWidthMs)
                try #require(abs(applied - expected) <= 0.01, "L2 \(option.key): applied \(applied) ms, expected \(expected)")
            }
            appliedWidths[option.key] = num(reading.appliedWidthMs)
            l2Entries.append(Entry(key: option.key, file: "L2-\(option.key)-\(option.tag).wav", set: set, pageOption: true))
        }
        log("L2 applied widths (joinReading): \(appliedWidths)")
        sets.append(ListeningSet(id: "L2", kind: "L2", move: l2Move, noteIndex: joinRight, part: parts[l2Right],
                                 base: l2Base, entries: l2Entries))
        log("SETS: \(sets.map { "\($0.id) [\($0.entries.map(\.key).joined(separator: " "))]" }.joined(separator: ", ")); every sibling carries its base's segment array bit for bit")

        // ── THE PLANT AND CONTROL SETS (PREREG §4) ──────────────────────────────
        // P-X: e1's D plus +30 c on run 16's note (before the moved note,
        // outside every permitted window), declared as D.
        let e1D = try #require(sets[0].entries.first { $0.key == "D" }).set
        let plantX = try move(e1D, segment: partSegment[pxPart], cents: 30)
        // P-C: e1's D with the consonant mix off, declared as D.
        var plantC = e1D
        plantC.keepsConsonantsUntuned = false
        // G2b's phase-wake control: e2's nil twin with +30 c more on run 15's
        // note. Written through `withSegments` (the one rebuild that carries
        // the set-level fields), never `applyingNotePitchOffsets`: the twin
        // is LEGACY, and the drag transform would upgrade it back to 1.0.
        let natNil = withAmount(natural, nil)
        let wakeIndex = try noteIndex(of: parts[wakePart], in: natNil)
        var wakeSegments = natNil.segments
        wakeSegments[wakeIndex].pitchOffsetCents += 30
        let wake = natNil.withSegments(wakeSegments)
        try #require(wake.formantCorrection == nil && wake.keepsConsonantsUntuned
                     && wake.transitionSlopeCentsPerSecond == 3000
                     && wake.segments[wakeIndex].pitchOffsetCents == natNil.segments[wakeIndex].pitchOffsetCents + 30,
                     "the wake control is not the twin plus one edit: \(setLevel(wake))")
        // C2(b): P-L's N0 RECONSTRUCTED: today's Natural notes (no sounds), the
        // three natural-tuning fields at legacy (the memberwise defaults).
        let plN0 = PitchEditSet(analysisVersion: natural.analysisVersion,
                                segments: natural.segments.filter { $0.origin != .unpitched },
                                retuneMs: natural.retuneMs)
        try #require(plN0.formantCorrection == nil && !plN0.keepsConsonantsUntuned
                     && plN0.transitionSlopeCentsPerSecond == 0 && plN0.segments.count == 59)
        for set in sets.flatMap({ $0.entries.map(\.set) }) + [plantX, plantC, wake, plN0] {
            try #require(!set.needsDetectedContour, "a set asks for contour shaping; none should")
        }

        try await renderAndCheck(take: take, sets: sets, controls: controls, outDir: outDir,
                                 plManifestURL: plManifestURL, plAnchorURL: plAnchorURL,
                                 parts: parts, partSegment: partSegment,
                                 picks: ["e1": e1, "e1Ladder": e1Ranked[1], "e3p": e3p, "e3f": e3f,
                                         "l2Left": l2Left, "l2Right": l2Right, "px": pxPart, "wake": wakePart],
                                 plants: ["P-X": plantX, "P-C": plantC, "wake": wake, "PL-N0": plN0],
                                 natural: natural, e2Window: e2Window)
    }
}

// MARK: - Renders, controls, the gate meter, the manifest

extension NaturalTuningListeningTests {

    /// The permitted windows of one L1 set (PREREG C3 (i)): every moved note,
    /// and every sung slide that FOLLOWS a moved note it abuts (its tilt is
    /// the move's reach), each ± the widest ramp half-width the set applies
    /// (the retune half, or a soft join's half from `joinReading`).
    static func permittedWindows(_ set: PitchEditSet) -> (windows: [(Double, Double)], halfWidth: Double) {
        var half = set.retuneMs / 2000
        for i in set.segments.indices {
            if let width = set.joinReading(afterSegmentAt: i)?.appliedWidthMs { half = max(half, width / 2000) }
        }
        half += 1e-6
        let moved = Set(set.segments.indices.filter { set.segments[$0].pitchOffsetCents != 0 })
        var reach = moved
        for i in set.segments.indices where set.segments[i].glideFollow > 0 {
            let s = set.segments[i]
            let touches = moved.contains {
                set.segments[$0].endSeconds.bitPattern == s.startSeconds.bitPattern
                    || set.segments[$0].startSeconds.bitPattern == s.endSeconds.bitPattern
            }
            if touches { reach.insert(i) }
        }
        let windows = reach.sorted().map { (set.segments[$0].startSeconds - half, set.segments[$0].endSeconds + half) }
        return (windows, half)
    }

    @MainActor
    static func renderAndCheck(take: NoteSplitListeningTests.Take, sets: [ListeningSet],
                               controls inControls: [String: Any], outDir: URL,
                               plManifestURL: URL, plAnchorURL: URL, parts: [NotePart], partSegment: [Int],
                               picks: [String: Int], plants: [String: PitchEditSet],
                               natural: PitchEditSet, e2Window: (start: Double, end: Double)) async throws {
        var controls = inControls
        let sr = take.sampleRate
        let source = take.input[0]
        let count = source.count

        let cacheDirA = outDir.appendingPathComponent("render-cache-a", isDirectory: true)
        let cacheDirB = outDir.appendingPathComponent("render-cache-b", isDirectory: true)
        for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) }
        defer { for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) } }
        let cacheA = StretchRenderCache(directory: cacheDirA)
        let cacheB = StretchRenderCache(directory: cacheDirB)
        func params(_ set: PitchEditSet) -> StretchRenderCache.Params {
            .init(clip: Clip(name: "vocal", audioFileURL: take.source, pitchEdits: set))
        }
        func render(_ set: PitchEditSet, _ label: String, in cache: StretchRenderCache) async throws -> [Float] {
            let rendered = try await NoteSplitListeningTests.render(set, take: take, cache: cache, label: label)
            let shortfall = cache.contourShortfall(source: take.source, params: params(set))
            try #require(shortfall == nil, "\(label) fell back: \(shortfall ?? "")")
            return rendered
        }

        // ── RENDERS (the product path) and C1 DETERMINISM ─────────────────────
        var audio: [String: [Float]] = [:]
        var determinism: [String: Any] = [:]
        for ls in sets {
            for entry in ls.entries {
                let key = "\(ls.id)/\(entry.key)"
                let a = try await render(entry.set, key, in: cacheA)
                audio[key] = a
                try M23QComparisonPair.writeWAV([a], sampleRate: sr, to: outDir.appendingPathComponent(entry.file))
                guard entry.pageOption else { continue }
                let b = try await render(entry.set, "\(key) again (fresh cache)", in: cacheB)
                let d = NoteSplitListeningTests.bitDiff(b, a)
                let fileA = try await cacheA.renderIfNeeded(clipID: UUID(), source: take.source, params: params(entry.set))
                let fileB = try await cacheB.renderIfNeeded(clipID: UUID(), source: take.source, params: params(entry.set))
                try #require(fileA.path != fileB.path, "\(key): the two renders are one file")
                let bytesA = try Data(contentsOf: fileA), bytesB = try Data(contentsOf: fileB)
                log("C1 DETERMINISM \(key): fresh-cache re-render \(d); cache files \(bytesA.count) vs \(bytesB.count) bytes, identical \(bytesA == bytesB)")
                #expect(d.bitExact, "C1: \(key) is not deterministic: \(d)")
                #expect(bytesA == bytesB, "C1: \(key)'s two cache files differ in bytes")
                determinism[key] = ["samplesDiffering": d.differing, "bitExact": d.bitExact,
                                    "cacheFileBytes": bytesA.count, "cacheFilesIdentical": bytesA == bytesB]
            }
        }
        // C1's negative control: the same comparator on two DIFFERENT options.
        let c1Negative = NoteSplitListeningTests.bitDiff(try #require(audio["L1-e1/A"]), try #require(audio["L1-e1/B"]))
        let c1NegativeL2 = NoteSplitListeningTests.bitDiff(try #require(audio["L2/A"]), try #require(audio["L2/B"]))
        log("C1 negative control (must differ): L1-e1 A vs B \(c1Negative); L2 A vs B \(c1NegativeL2)")
        #expect(!c1Negative.bitExact && !c1NegativeL2.bitExact)
        controls["determinismNegativeControl"] = ["L1-e1 A vs B differing": c1Negative.differing,
                                                  "L2 A vs B differing": c1NegativeL2.differing]

        // Plants and controls, rendered once each (never page options).
        var plantAudio: [String: [Float]] = [:]
        for (key, set) in plants.sorted(by: { $0.key < $1.key }) {
            plantAudio[key] = try await render(set, key, in: cacheA)
        }

        // ── C2(b): P-L's N0, reconstructed, against P-L's anchor ───────────────
        let plManifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: plManifestURL)) as? [String: Any])
        let plParts = try #require(plManifest["parts"] as? [[String: Any]])
        let plN0 = try #require(plants["PL-N0"])
        try #require(plParts.count == plN0.segments.count, "P-L has \(plParts.count) parts, the reconstruction \(plN0.segments.count)")
        var worstEdge = 0.0, worstCents = 0.0
        for (s, p) in zip(plN0.segments, plParts) {
            let start = try #require(p["start"] as? Double), end = try #require(p["end"] as? Double)
            let cents = try #require(p["offsetCents"] as? Double)
            worstEdge = max(worstEdge, abs(s.startSeconds - start), abs(s.endSeconds - end))
            worstCents = max(worstCents, abs(s.pitchOffsetCents - cents))
        }
        try #require(worstEdge <= 1e-9 && worstCents <= 1e-9,
                     "the reconstruction is not P-L's N0 table: edges \(worstEdge) s, offsets \(worstCents) c")
        let plAnchor = try TestSignals.readFile(plAnchorURL)[0]
        let dN0 = NoteSplitListeningTests.bitDiff(try #require(plantAudio["PL-N0"]), plAnchor)
        log("C2(b) P-L N0 RECONSTRUCTED (59 notes = P-L's manifest within \(worstCents) c / \(worstEdge) s; legacy fields) vs \(plAnchorURL.lastPathComponent): \(dN0) — a mismatch is EXPECTED (transposeEngineVersion now \(StretchRenderCache.transposeEngineVersion); P-L rendered before p2-acc-3), REPORTED, never a STOP")
        controls["anchorPLN0Reconstructed"] = [
            "notesMatchPLManifest": true, "worstOffsetCents": worstCents, "worstEdgeSeconds": worstEdge,
            "bitExact": dN0.bitExact, "differing": dN0.differing, "first": dN0.first ?? -1,
            "maxAbsDbfs": num(dN0.maxAbsDbfs), "transposeEngineVersion": StretchRenderCache.transposeEngineVersion,
        ]

        // ── THE HOP GRID the render consumed (P-L's spy, then the grids) ───────
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        guard case .frames(let latency) = compensation else {
            Issue.record("uncompensated render path")
            return
        }
        var spied: [Int] = []
        _ = try OfflineStretcher.stretchTransposeCurve(
            input: [Array(source.prefix(Int(sr)))], sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { spied.append($0); return 0 }, formantPreserve: false,
            compensation: compensation)
        try #require(spied.count >= 4 && spied[0] == spied[1])
        let interval = spied[2] - spied[1]
        let lookupOffset = spied[1]
        for (k, lookup) in spied.dropFirst().enumerated() {
            try #require(lookup == k * interval + lookupOffset)
        }
        try #require(interval == 1440 && lookupOffset == latency + interval / 2)
        log("SPY: hop \(interval) frames, each chunk F reads the curves at F + \(lookupOffset) (latency \(latency) + hop/2)")
        let contour = PitchContourCache.renderContour(
            source: take.source, analysisVersion: natural.analysisVersion,
            renderCacheDirectory: cacheDirA, detector: .product)
        try #require(contour.frames == take.detection.frames, "the render's contour is not this detection")
        var grids: [String: HopGrid] = [:]
        for ls in sets {
            for entry in ls.entries {
                grids["\(ls.id)/\(entry.key)"] = try hopGrid(entry.set, sampleRate: sr, frames: count,
                                                             contour: contour, interval: interval)
            }
        }
        for (key, set) in plants {
            grids[key] = try hopGrid(set, sampleRate: sr, frames: count, contour: contour, interval: interval)
        }
        // GRID ≡ RENDER: one L1 option (a formant curve) and one L2 option.
        var replicas: [String: Any] = [:]
        for (setID, key) in [("L1-e1", "B"), ("L2", "C")] {
            let ls = try #require(sets.first { $0.id == setID })
            let entry = try #require(ls.entries.first { $0.key == key })
            let r = try replica(try #require(grids["\(setID)/\(key)"]), set: entry.set, input: take.input, sampleRate: sr)
            let d = NoteSplitListeningTests.bitDiff(r.audio, try #require(audio["\(setID)/\(key)"]))
            log("GRID ≡ RENDER \(setID) \(key): re-rendered from its hop grids (+ the consonant mix) vs the product render: \(d); grid misses \(r.misses)")
            try #require(r.misses == 0 && d.bitExact, "the hop grids are not what the \(setID) \(key) render consumed: \(d)")
            replicas["\(setID)/\(key)"] = ["bitExact": d.bitExact, "misses": r.misses]
        }
        controls["gridReplica"] = replicas

        // ── C3 INVARIANCE ──────────────────────────────────────────────────────
        var invarianceRows: [String: Any] = [:]
        var windowsBySet: [String: [(Double, Double)]] = [:]
        for ls in sets {
            let reference = try #require(audio["\(ls.id)/A"]), referenceGrid = try #require(grids["\(ls.id)/A"])
            let windows: [(Double, Double)]
            let half: Double
            if ls.kind == "L1" {
                let permitted = permittedWindows(ls.base)
                windows = permitted.windows
                half = permitted.halfWidth
                let transposeBits = referenceGrid.bits(referenceGrid.transpose)
                for entry in ls.entries {
                    let g = try #require(grids["\(ls.id)/\(entry.key)"])
                    #expect(g.bits(g.transpose) == transposeBits,
                            "C3(i): \(ls.id) \(entry.key)'s TRANSPOSE curve differs from A's; L1 options share one")
                }
            } else {
                let edge = try #require(ls.part).startSeconds
                half = 0.13334
                windows = [(edge - half, edge + half)]
            }
            windowsBySet[ls.id] = windows
            let mask = dryMask(regions: ls.base.consonantRegions(), frames: count, sampleRate: sr)
            let after = windows.map(\.1).min() ?? 0
            var rows: [String: Any] = ["permittedWindows": windows.map { [$0.0, $0.1] }, "halfWidth": half,
                                       "dryFrames": mask.count]
            let dryA = dryFrames(reference, reference, source: source, mask: mask, after: after, sampleRate: sr)
            rows["A-dryVsSource"] = dryA
            log("C3(iii) \(ls.id) A: \(mask.count) dry frames; vs the source: \(dryA["differFromSourceBefore"] ?? -1) before / \(dryA["differFromSourceAfter"] ?? -1) after \(String(format: "%.3f", after)) s differ")
            for entry in ls.entries where entry.key != "A" {
                let key = "\(ls.id)/\(entry.key)"
                let inv = try invariance(try #require(audio[key]), reference, grid: try #require(grids[key]),
                                         referenceGrid: referenceGrid, windows: windows, sampleRate: sr)
                let dry = dryFrames(try #require(audio[key]), reference, source: source, mask: mask,
                                    after: after, sampleRate: sr)
                var row = inv.row
                row["dry"] = dry
                rows[entry.key] = row
                log(String(format: "C3 %@ %@ vs A (%ld windows, ±%.1f ms): hops differing OUTSIDE %ld, inside %ld of %ld; audio before the first permitted hop (F = %ld, %.3f s): %@; causal %@; dry frames differing from A %@/%@, from the source %@/%@ (before/after)",
                                 ls.id as NSString, entry.key as NSString, windows.count, half * 1000,
                                 inv.outside.count, inv.inside.count, inv.hops, inv.firstPermittedFrame,
                                 Double(inv.firstPermittedFrame) / sr, inv.before.description as NSString,
                                 (inv.causal ? "yes" : "NO") as NSString,
                                 "\(dry["differFromReferenceBefore"] ?? -1)" as NSString,
                                 "\(dry["differFromReferenceAfter"] ?? -1)" as NSString,
                                 "\(dry["differFromSourceBefore"] ?? -1)" as NSString,
                                 "\(dry["differFromSourceAfter"] ?? -1)" as NSString))
                if entry.pageOption {
                    #expect(inv.outside.isEmpty, "C3(i): \(key) changed \(inv.outside.count) hops outside its permitted windows")
                    #expect(inv.before.bitExact, "C3(ii): \(key) differs before its first permitted hop: \(inv.before)")
                    #expect(inv.causal, "C3(ii): \(key) differs before its first differing hop")
                }
            }
            invarianceRows[ls.id] = rows
        }
        // PLANT P-X (declared L1-e1 D): an edit outside every permitted window.
        let e1Windows = try #require(windowsBySet["L1-e1"])
        let e1DAudio = try #require(audio["L1-e1/D"]), e1DGrid = try #require(grids["L1-e1/D"])
        let px = try invariance(try #require(plantAudio["P-X"]), e1DAudio, grid: try #require(grids["P-X"]),
                                referenceGrid: e1DGrid, windows: e1Windows, sampleRate: sr)
        log("PLANT P-X (e1 D + 30 c on run 16, declared D): (i) flags \(px.outside.count) hops outside -> \(px.outside.isEmpty ? "NOT CAUGHT" : "CAUGHT"); (ii) before the first permitted hop \(px.before) -> \(px.before.bitExact ? "NOT CAUGHT" : "CAUGHT")")
        #expect(!px.outside.isEmpty && !px.before.bitExact, "plant P-X was not caught by C3 (i)/(ii)")
        // PLANT P-C (declared L1-e1 D): the consonant mix off.
        let e1Mask = dryMask(regions: try #require(sets.first { $0.id == "L1-e1" }).base.consonantRegions(),
                             frames: count, sampleRate: sr)
        let pcDry = dryFrames(try #require(plantAudio["P-C"]), e1DAudio, source: source, mask: e1Mask,
                              after: e1Windows.map(\.1).min() ?? 0, sampleRate: sr)
        let pcInv = try invariance(try #require(plantAudio["P-C"]), e1DAudio, grid: try #require(grids["P-C"]),
                                   referenceGrid: e1DGrid, windows: e1Windows, sampleRate: sr)
        let pcCaught = ((pcDry["differFromReferenceAfter"] as? Int) ?? 0) > 0
        log("PLANT P-C (e1 D with the consonant mix off, declared D): (iii) dry frames differing from D \(pcDry["differFromReferenceBefore"] ?? -1) before / \(pcDry["differFromReferenceAfter"] ?? -1) after -> \(pcCaught ? "CAUGHT" : "NOT CAUGHT"); (i) hops outside \(pcInv.outside.count) (the mix is not in the curve); (ii) \(pcInv.before)")
        #expect(pcCaught, "plant P-C was not caught by C3 (iii)")
        let plantRows: [String: Any] = ["P-X": px.row, "P-C": ["dry": pcDry, "invariance": pcInv.row] as [String: Any]]
        controls["plants"] = plantRows
        controls["invariance"] = invarianceRows

        try await gateAndManifest(take: take, sets: sets, audio: audio, plantAudio: plantAudio,
                                  controls: controls, determinism: determinism, outDir: outDir,
                                  parts: parts, partSegment: partSegment, picks: picks,
                                  natural: natural, e2Window: e2Window, interval: interval,
                                  lookupOffset: lookupOffset)
    }
}

// MARK: - The gate meter, G2b on the take, the synthetic controls, the manifest

extension NaturalTuningListeningTests {

    @MainActor
    static func gateAndManifest(take: NoteSplitListeningTests.Take, sets: [ListeningSet],
                                audio: [String: [Float]], plantAudio: [String: [Float]],
                                controls: [String: Any], determinism: [String: Any], outDir: URL,
                                parts: [NotePart], partSegment: [Int], picks: [String: Int],
                                natural: PitchEditSet, e2Window: (start: Double, end: Double),
                                interval: Int, lookupOffset: Int) async throws {
        let sr = take.sampleRate
        let source = take.input[0]

        // ── THE TOLERANCES (PREREG C4: the G2/G3 rule at each note's f0 and move) ─
        var tolerances: [String: Double] = [:]
        for ls in sets where ls.kind == "L1" {
            if let part = ls.part, let move = ls.move {
                tolerances[ls.id] = NaturalTuningFormantRenderTests.tolerance(f0: part.centreHz, cents: move)
            }
        }
        let tolE1 = try #require(tolerances["L1-e1"])
        tolerances["L1-e2"] = tolE1 / 400
        log("TOLERANCES (max(50 c, 2 × |f0-only control|) at each note's f0 and move): \(tolerances.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")) (L1-e2 is relative: tol(e1) / 400)")

        // ── C4/C5 INPUT: the pinned meter, per analysis window ────────────────
        var gateRows: [String: Any] = [:]
        for ls in sets where ls.kind == "L1" {
            let keys = ls.entries.map(\.key)
            var windows: [(centre: Int, segment: Int, move: Double)] = []
            if let part = ls.part, let note = ls.noteIndex, let move = ls.move {
                windows = windowCentres(start: part.startSeconds, end: part.endSeconds, sampleRate: sr)
                    .map { ($0, note, move) }
            } else {
                for (i, s) in ls.base.segments.enumerated()
                where s.origin != .unpitched && s.startSeconds >= e2Window.start && s.endSeconds <= e2Window.end
                    && abs(s.pitchOffsetCents) >= 5 {
                    windows += windowCentres(start: s.startSeconds, end: s.endSeconds, sampleRate: sr)
                        .map { ($0, i, s.pitchOffsetCents) }
                }
            }
            var readings: [String: [Double?]] = [:]
            for key in keys {
                let rendered = try #require(audio["\(ls.id)/\(key)"])
                readings[key] = windows.map { gateReading(source: source, render: rendered, centre: $0.centre, sampleRate: sr) }
            }
            let valid = windows.indices.filter { w in keys.allSatisfy { (readings[$0]?[w] ?? nil) != nil } }
            var stat: [String: Double] = [:]
            for key in keys {
                let values = valid.compactMap { readings[key]?[$0] ?? nil }
                if ls.part != nil {
                    stat[key] = median(values) ?? .nan
                } else {
                    var numerator = 0.0, denominator = 0.0
                    for (w, s) in zip(valid, values) {
                        numerator += s * windows[w].move
                        denominator += windows[w].move * windows[w].move
                    }
                    stat[key] = denominator > 0 ? numerator / denominator : .nan
                }
            }
            // The verdicts are the python's (NT-L/nt-checks.py); logged here
            // so the harness log says what the pinned meter saw.
            let sign = (ls.move ?? 1) < 0 ? -1.0 : 1.0
            let tol = try #require(tolerances[ls.id])
            func toward(_ key: String) -> Double { (stat[key] ?? .nan) * (ls.part != nil ? sign : 1) }
            let steps = [toward("A") - toward("B"), toward("B") - toward("C"), toward("C") - toward("D")]
            let ordered = steps.allSatisfy { $0 > tol / 2 }
            let dZero = abs(stat["D"] ?? .nan) <= tol
            let likeToday = abs((stat["A"] ?? .nan) - (stat["nil"] ?? .nan)) <= tol
            let what = ls.part != nil ? "median envelope shift (c)" : "move-weighted slope BETA"
            log(String(format: "GATE %@ (%@, %ld of %ld windows valid in all five files): A %.3f  B %.3f  C %.3f  D %.3f | nil %.3f | tol %.3f -> steps toward the move %@ each > tol/2: %@; |D| <= tol: %@; |A - nil| <= tol (\"like today\"): %@",
                             ls.id as NSString, what as NSString, valid.count, windows.count,
                             stat["A"] ?? .nan, stat["B"] ?? .nan, stat["C"] ?? .nan, stat["D"] ?? .nan,
                             stat["nil"] ?? .nan, tol,
                             steps.map { String(format: "%.3f", $0) }.joined(separator: "/") as NSString,
                             (ordered ? "yes" : "NO") as NSString, (dZero ? "yes" : "NO") as NSString,
                             (likeToday ? "yes" : "NO") as NSString))
            var row: [String: Any] = [
                "statistic": ls.part != nil ? "median" : "beta", "tol": tol,
                "centres": windows.map(\.centre), "segments": windows.map(\.segment),
                "moves": windows.map(\.move), "valid": valid,
                "stat": stat.mapValues { num($0) },
                "loggedOrdered": ordered, "loggedDZero": dZero, "loggedLikeToday": likeToday,
            ]
            var readingRows: [String: Any] = [:]
            for key in keys { readingRows[key] = (readings[key] ?? []).map { num($0) } }
            row["readings"] = readingRows
            gateRows[ls.id] = row
        }
        let e3pValid = ((gateRows["L1-e3p"] as? [String: Any])?["valid"] as? [Int])?.count ?? 0
        log("e3 MEASURABILITY (PREREG: the primary is used iff >= \(e3MinimumValidWindows) valid windows): primary run 20.2 has \(e3pValid) -> \(e3pValid >= e3MinimumValidWindows ? "PRIMARY" : "FALLBACK run 25") (the python applies the rule; this is the harness's reading)")

        // ── G2b ON THE TAKE (R20's publish rule for e2) ────────────────────────
        let span = 661_584..<945_072
        func compare(_ a: [Float], _ b: [Float], _ range: Range<Int>) -> SpanRenderMetrics.Comparison {
            SpanRenderMetrics.compare(Array(a[range]), Array(b[range]), sampleRate: sr, minHz: 60, maxHz: 300)
        }
        let e2Nil = try #require(audio["L1-e2/nil"]), e2D = try #require(audio["L1-e2/D"])
        let control = compare(e2Nil, try #require(plantAudio["wake"]), span)
        let limits = SpanRenderMetrics.Limits(control: control)
        let measured = compare(e2Nil, e2D, span)
        var tilted = e2D
        for i in stride(from: tilted.count - 1, to: 0, by: -1) { tilted[i] -= 0.5 * e2D[i - 1] }
        let tiltPlant = compare(e2Nil, tilted, span)
        let e1Part = try #require(sets.first { $0.id == "L1-e1" }?.part)
        let farSpan = Int(((e1Part.startSeconds - 0.1) * sr).rounded())..<Int(((e1Part.endSeconds + 0.1) * sr).rounded())
        let far = compare(try #require(audio["L1-e1/nil"]), try #require(audio["L1-e1/D"]), farSpan)
        log("G2b ON THE TAKE (e2 window, minHz 60, maxHz 300): phase-wake control \(control); limits \(limits); nil vs D \(measured) -> \(limits.admits(measured) ? "ADMITTED (G2b holds)" : "NOT ADMITTED (G2b fails on the take)"); controls: e1's +4 st nil vs D \(far) -> \(limits.admits(far) ? "ADMITTED (G2b INCAPABLE)" : "not admitted"); PLANT tilt \(tiltPlant) -> \(limits.admits(tiltPlant) ? "ADMITTED (NOT CAUGHT)" : "not admitted (CAUGHT)")")
        #expect(!limits.admits(far), "G2b control: e1's +4 st formant change was admitted, so G2b cannot see a formant change")
        #expect(!limits.admits(tiltPlant), "G2b plant: an injected tilt was admitted, so G2b cannot see colouration")
        func comparisonRow(_ c: SpanRenderMetrics.Comparison) -> [String: Any] {
            ["lsdMean": num(c.lsdMean), "lsdP95": num(c.lsdP95), "lsdMax": num(c.lsdMax), "lsdFrames": c.lsdFrames,
             "pitchMedian": num(c.pitchMedian), "pitchP90": num(c.pitchP90), "pitchFrames": c.pitchFrames]
        }
        let wakeIndex = try #require(picks["wake"])
        let g2b: [String: Any] = [
            "span": [span.lowerBound, span.upperBound], "minHz": 60, "maxHz": 300,
            "control": comparisonRow(control),
            "limits": ["lsdMean": limits.lsdMean, "lsdP95": limits.lsdP95, "pitchP90": limits.pitchP90],
            "measuredNilVsD": comparisonRow(measured), "admitted": limits.admits(measured),
            "farE1NilVsD": comparisonRow(far), "farAdmitted": limits.admits(far),
            "tiltPlant": comparisonRow(tiltPlant), "tiltAdmitted": limits.admits(tiltPlant),
            "wakeNote": partRow(parts[wakeIndex], index: wakeIndex, segment: partSegment[wakeIndex]),
        ]

        // ── NT-F220: the synthetic cells (the formant suite's G2 fixture) ──────
        var synthetic: [String: Any] = [:]
        let p220 = try syntheticCell(f0: 220, cents: e3Move)
        synthetic["P+ 220"] = p220
        for id in ["L1-e3p", "L1-e3f"] {
            let part = try #require(sets.first { $0.id == id }?.part)
            synthetic["pred \(id)"] = try syntheticCell(f0: part.centreHz, cents: e3Move)
        }
        let kept220 = try #require(p220["keptC1"] as? Double)
        log("NT-F220 SYNTHETIC: P+ 220 Hz −500 c at c = 1 reads \(String(format: "%.2f", kept220)) c (pinned \(pinnedResidual220) ± 1.0); predictions at this take's f0: \(synthetic.filter { $0.key.hasPrefix("pred") }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; "))")
        #expect(abs(kept220 - pinnedResidual220) <= 1.0,
                "P+: the harness does not reproduce NT-F220's pinned residual (\(kept220) vs \(pinnedResidual220))")

        // ── THE MANIFEST, for the python checks and the page ───────────────────
        var setRows: [String: Any] = [:]
        let l2LeftSegment = partSegment[try #require(picks["l2Left"])]
        for ls in sets {
            var files: [String: Any] = [:]
            for entry in ls.entries {
                var row: [String: Any] = [
                    "file": entry.file, "formantCorrection": num(entry.set.formantCorrection),
                    "slope": entry.set.transitionSlopeCentsPerSecond,
                    "consonants": entry.set.keepsConsonantsUntuned, "pageOption": entry.pageOption,
                    "retuneMs": entry.set.retuneMs,
                ]
                if ls.kind == "L2" {
                    row["appliedWidthMs"] = num(entry.set.joinReading(afterSegmentAt: l2LeftSegment)?.appliedWidthMs)
                }
                files[entry.key] = row
            }
            var row: [String: Any] = ["kind": ls.kind, "files": files, "move": num(ls.move)]
            if let part = ls.part, let index = parts.firstIndex(of: part) {
                row["note"] = partRow(part, index: index, segment: ls.noteIndex)
            }
            if ls.kind == "L2" {
                let left = try #require(picks["l2Left"])
                row["left"] = partRow(parts[left], index: left, segment: l2LeftSegment)
                row["edgeSeconds"] = parts[left].endSeconds
            }
            if let gate = gateRows[ls.id] { row["gate"] = gate }
            setRows[ls.id] = row
        }
        let naturalNotes: [[String: Any]] = natural.segments.enumerated()
            .filter { $0.element.origin != .unpitched }
            .map { ["segmentIndex": $0.offset, "start": $0.element.startSeconds, "end": $0.element.endSeconds,
                    "detectedHz": $0.element.detectedHz, "offsetCents": $0.element.pitchOffsetCents] }
        var pickRows: [String: Any] = [:]
        for (key, index) in picks { pickRows[key] = partRow(parts[index], index: index, segment: partSegment[index]) }
        let manifest: [String: Any] = [
            "what": "NT-L natural-tuning listening renders (NaturalTuningListeningTests)",
            "prereg": "NT-L/PREREG.txt", "sampleRate": sr, "frames": source.count,
            "hopFrames": interval, "lookupOffsetFrames": lookupOffset,
            "transposeEngineVersion": StretchRenderCache.transposeEngineVersion,
            "formantRenderVersion": PitchEditSet.formantRenderVersion,
            "transitionRenderVersion": PitchEditSet.transitionRenderVersion,
            "analysisWindow": ["frames": windowFrames, "hop": windowHop, "noteMargin": noteMargin],
            "e2Window": ["startSample": 661_584, "endSample": 945_072],
            "parts": parts.enumerated().map { partRow($1, index: $0, segment: partSegment[$0]) },
            "picks": pickRows, "naturalNotes": naturalNotes, "sets": setRows,
            "tolerances": tolerances, "determinism": determinism, "controls": controls,
            "g2b": g2b, "synthetic": synthetic,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("manifest.json"))
        log("wrote \(sets.reduce(0) { $0 + $1.entries.count }) WAVs and manifest.json to \(outDir.path)")
    }
}

// MARK: - Round 2: L2 at the join PREREG-L2r2.txt selected

/// ROUND 2 (orchestrator 05:38 PDT): the slides set again, at a join the
/// tracker can see in the ORIGINAL. `NT-L/l2r2-select.py` applies
/// PREREG-L2r2.txt §1 to the take and names the join's edge; this test
/// re-derives the material candidates from its own detection, requires the
/// named edge to be one of them, and renders the four slopes exactly as round
/// 1 did (seed → move → the slope field last). Before any new render it
/// re-renders two ROUND-1 files and requires them bit for bit (C2(b)): the
/// render path is being edited by another lane, and a moved engine must stop
/// this run rather than quietly change what round 2 compares. Env-gated:
///
///     NTL_L2R2_OUT=<DUR>/NT-L/wav-l2r2  NTL_L2R2_EDGE=<edge s>  NTL_ROUND1_WAV=<DUR>/NT-L/wav \
///     NOTESPLIT_LISTEN_SOURCE=… NOTESPLIT_LISTEN_PARTS=… NOTESPLIT_LISTEN_OUT=<DUR>/NT-L/wav-l2r2 \
///     NOTESPLIT_LISTEN_REF=<DUR>/L/ref ./scripts/test.sh --filter NaturalTuningListeningTests
extension NaturalTuningListeningTests {

    static let roundTwoEnabled = ProcessInfo.processInfo.environment["NTL_L2R2_OUT"] != nil
    static let roundThreeEnabled = ProcessInfo.processInfo.environment["NTL_L2R3_OUT"] != nil

    /// One L2 re-run's identity: every env var, file name, log prefix and
    /// earlier join it refuses. Round 2 (run 27) emits exactly what it did
    /// before this was factored out; round 3 (run 7, PREREG-L2r3) is new.
    struct SlideRound: Sendable {
        let number: Int
        let setName: String
        let preregStem: String
        let outEnv: String
        let edgeEnv: String
        let usedEdges: [Double]
        let plainFileNames: Bool
        let what: String
        var logPrefix: String { "R\(number) " }
        var manifestName: String { "manifest-\(setName.lowercased()).json" }

        static let two = SlideRound(
            number: 2, setName: "L2r2", preregStem: "PREREG-L2r2", outEnv: "NTL_L2R2_OUT", edgeEnv: "NTL_L2R2_EDGE",
            usedEdges: [8.160], plainFileNames: false,
            what: "NT-L round 2: L2 slides at the join PREREG-L2r2 selected (NaturalTuningListeningTests)")
        static let three = SlideRound(
            number: 3, setName: "L2r3", preregStem: "PREREG-L2r3", outEnv: "NTL_L2R3_OUT", edgeEnv: "NTL_L2R3_EDGE",
            usedEdges: [8.160, 22.912], plainFileNames: true,
            what: "NT-L round 3: L2 slides at run 7, the join PREREG-L2r3 fixed (the NT-L listening harness)")
    }

    /// Round 3's file names (PREREG-L2r3 §2): R26's names only.
    static let l2PlainNames: [String: String] = ["A": "snappy", "B": "quick", "C": "smooth", "D": "slow"]

    /// PREREG-L2r2.txt §1's material rule (round 1's L2 pair rule): two
    /// `.held` parts of one run that abut bit for bit, the right one's other
    /// edge a gap, both long enough for Slow's width, three seconds of take on
    /// either side. Returns the LEFT part's index of every such pair.
    static func slideCandidates(_ parts: [NotePart], takeSeconds: Double) -> [Int] {
        func duration(_ i: Int) -> Double { parts[i].endSeconds - parts[i].startSeconds }
        func gapAfter(_ i: Int) -> Double {
            i == parts.count - 1 ? takeSeconds - parts[i].endSeconds : parts[i + 1].startSeconds - parts[i].endSeconds
        }
        return parts.indices.dropLast().filter { i in
            parts[i].kind == .held && parts[i + 1].kind == .held
                && parts[i].runIndex == parts[i + 1].runIndex
                && parts[i].endSeconds.bitPattern == parts[i + 1].startSeconds.bitPattern
                && gapAfter(i + 1) >= minimumGapSeconds
                && duration(i) >= l2MinimumDuration && duration(i + 1) >= l2MinimumDuration
                && parts[i].startSeconds >= contextSeconds && takeSeconds - parts[i + 1].endSeconds >= contextSeconds
        }
    }

    @Test("NT-L round 2 — L2 slides at the join PREREG-L2r2 chose: anchors, renders, determinism, invariance, plants",
          .enabled(if: roundTwoEnabled))
    @MainActor
    func renderTheSlidesRoundTwo() async throws {
        try await Self.renderSlides(.two)
    }

    @Test("NT-L round 3 — L2 slides at run 7, the join PREREG-L2r3 fixed: anchors, renders, determinism, invariance, plants",
          .enabled(if: roundThreeEnabled))
    @MainActor
    func renderTheSlidesRoundThree() async throws {
        try await Self.renderSlides(.three)
    }

    @MainActor
    static func renderSlides(_ round: SlideRound) async throws {
        let p = round.logPrefix
        let outDir = URL(fileURLWithPath: try NoteSplitListeningTests.environment(round.outEnv))
        let round1Dir = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NTL_ROUND1_WAV"))
        let edgeText = try NoteSplitListeningTests.environment(round.edgeEnv)
        let edgeWanted = try #require(Double(edgeText), "\(round.edgeEnv) is not a number: \(edgeText)")
        let take = try NoteSplitListeningTests.load()
        try #require(take.outDir.standardizedFileURL.path == outDir.standardizedFileURL.path,
                     "NOTESPLIT_LISTEN_OUT (\(take.outDir.path)) must equal \(round.outEnv) (\(outDir.path))")
        let sr = take.sampleRate
        let source = take.input[0]
        let count = source.count
        let takeSeconds = Double(count) / sr
        var controls: [String: Any] = [:]

        // ── C2(a) THE ZERO-CURVE ANCHOR, before anything else renders ──────────
        let uncorrected = try NoteSplitListeningTests.uncorrected(take)
        let ref00 = try TestSignals.readFile(take.refDir.appendingPathComponent("00-uncorrected.wav"))[0]
        let d00 = NoteSplitListeningTests.bitDiff(uncorrected, ref00)
        log("\(p)C2(a) ANCHOR: the zero-curve product loop vs L/ref/00-uncorrected.wav: \(d00)")
        try #require(d00.bitExact, "STOP (\(round.preregStem) C2(a)): the zero-curve product loop moved: \(d00)")
        controls["anchorZeroCurve"] = ["differing": d00.differing, "bitExact": d00.bitExact, "samples": d00.to]
        log("\(p)render key: transposeEngineVersion \(StretchRenderCache.transposeEngineVersion), formantRenderVersion \(PitchEditSet.formantRenderVersion), transitionRenderVersion \(PitchEditSet.transitionRenderVersion)")

        // ── THE EDITOR SEED AND THE PARTS (round 1's asserts) ──────────────────
        let seed = PitchNoteTable.detected(from: take.detection)
        try #require(seed.retuneMs == 30 && seed.formantCorrection == 1.0 && seed.keepsConsonantsUntuned
                     && seed.transitionSlopeCentsPerSecond == 3000 && seed.isIdentity,
                     "the editor seed is not at the new-set defaults: \(setLevel(seed))")
        let parts = PitchNoteSplitter.parts(in: take.detection.frames, frameRateHz: take.detection.frameRateHz)
        try #require(parts.count == 59, "\(parts.count) parts; parts.json has 59")
        var partSegment: [Int] = []
        for part in parts { partSegment.append(try noteIndex(of: part, in: seed)) }

        // ── THE JOIN: the selection's edge must be one of this detection's candidates ─
        let candidates = slideCandidates(parts, takeSeconds: takeSeconds)
        for i in candidates {
            log(p + String(format: "CANDIDATE run %ld: %.3f-%.3f | %.3f-%.3f s, %.2f -> %.2f Hz, post-move interval %.0f c",
                       parts[i].runIndex, parts[i].startSeconds, parts[i].endSeconds, parts[i + 1].startSeconds,
                       parts[i + 1].endSeconds, parts[i].centreHz, parts[i + 1].centreHz,
                       abs(1200 * log2(parts[i + 1].centreHz / parts[i].centreHz) + l2Move)))
        }
        let left = try #require(candidates.first { abs(parts[$0].endSeconds - edgeWanted) < 0.0005 },
                                "the selected edge \(edgeWanted) s is not a material candidate of this detection")
        let right = left + 1
        let edge = parts[left].endSeconds
        for used in round.usedEdges {
            try #require(abs(edge - used) >= 0.0005, "\(round.preregStem) refuses the join at \(used) s: an earlier round used it")
        }
        let interval = abs(1200 * log2(parts[right].centreHz / parts[left].centreHz) + l2Move)
        try #require(interval >= 100, "the post-move interval \(interval) c is under a semitone")

        // ── THE SET: seed → move R +400 c (the one-home drag) → the slope LAST ─
        let clipId = UUID()
        func move(_ base: PitchEditSet, segment: Int, cents: Double) throws -> PitchEditSet {
            let moved = try base.applyingNotePitchOffsets(
                [NotePitchOffset(segmentId: base.segments[segment].id, offsetCents: cents)], clipId: clipId)
            try #require(setLevel(moved) == setLevel(base),
                         "the move changed a set-level field: \(setLevel(base)) -> \(setLevel(moved))")
            try #require(moved.segments[segment].pitchOffsetCents == cents)
            return moved
        }
        let joinLeft = partSegment[left], joinRight = partSegment[right]
        let base = try move(seed, segment: joinRight, cents: l2Move)
        try #require(base.nextCurveNoteIndex(after: joinLeft) == joinRight
                     && base.joinKind(between: joinLeft, and: joinRight) == .soft,
                     "the selected join is not a soft join between the two notes")
        if let after = base.nextCurveNoteIndex(after: joinRight) {
            try #require(base.joinKind(between: joinRight, and: after) == .gap,
                         "the moved note's other edge is not a gap")
        }
        var entries: [Entry] = []
        var appliedWidths: [String: Any] = [:]
        for option in l2Options {
            let set = try withSlope(base, option.slope)
            try sameSegments(set, base, "\(round.setName) \(option.key)")
            try #require(set.formantCorrection == 1.0 && set.keepsConsonantsUntuned
                         && set.transitionSlopeCentsPerSecond == option.slope,
                         "\(round.setName) \(option.key): \(setLevel(set))")
            try #require(!set.needsDetectedContour, "\(round.setName) \(option.key) asks for contour shaping")
            let reading = try #require(set.joinReading(afterSegmentAt: joinLeft))
            try #require(reading.kind == .soft && reading.nextSegmentId == set.segments[joinRight].id)
            if option.slope == 0 {
                try #require(reading.appliedWidthMs == nil, "option A must keep the legacy halves")
            } else {
                let applied = try #require(reading.appliedWidthMs)
                try #require(abs(applied - 1000 * l2Move / option.slope) <= 0.01,
                             "\(round.setName) \(option.key): applied \(applied) ms")
            }
            appliedWidths[option.key] = num(reading.appliedWidthMs)
            let tag = round.plainFileNames ? (l2PlainNames[option.key] ?? option.tag) : option.tag
            entries.append(Entry(key: option.key, file: "\(round.setName)-\(option.key)-\(tag).wav", set: set,
                                 pageOption: true))
        }
        log(p + String(format: "JOIN run %ld at %.3f s: L %.3f-%.3f s (%.2f Hz) | R %.3f-%.3f s (%.2f Hz) moved +400 c; the slide spans %.0f c; applied widths %@",
                   parts[left].runIndex, edge, parts[left].startSeconds, parts[left].endSeconds, parts[left].centreHz,
                   parts[right].startSeconds, parts[right].endSeconds, parts[right].centreHz, interval,
                   "\(appliedWidths)" as NSString))

        // ── C2(b) inputs: round 1's L2 C (run 10) and L1-e1 D, rebuilt the round-1 way ─
        func near(_ i: Int, _ start: Double, _ end: Double) -> Bool {
            abs(parts[i].startSeconds - start) < 0.0005 && abs(parts[i].endSeconds - end) < 0.0005
        }
        let r1Left = try #require(parts.indices.first { near($0, 7.776, 8.160) }, "round 1's L2 pair moved")
        let r1C = try withSlope(try move(seed, segment: partSegment[r1Left + 1], cents: l2Move), 3000)
        let e1 = try #require(parts.indices.first { near($0, 17.840, 18.496) }, "round 1's e1 note moved")
        let e1D = withAmount(try move(seed, segment: partSegment[e1], cents: e1Move), 1.0)

        // ── THE PLANTS (PREREG-L2r2 C3) ─────────────────────────────────────────
        let cSet = try #require(entries.first { $0.key == "C" }).set
        let pxPart = try #require(parts.indices.filter {
            parts[$0].kind == .held && parts[$0].endSeconds <= edge - 1.0
        }.last, "no held note ends a second before the join")
        let plantX = try move(cSet, segment: partSegment[pxPart], cents: 30)
        var plantC = cSet
        plantC.keepsConsonantsUntuned = false
        log(p + String(format: "PLANTS: P-X2 = C + 30 c on run %ld (%.3f-%.3f s), declared C; P-C2 = C with the consonant mix off, declared C",
                   parts[pxPart].runIndex, parts[pxPart].startSeconds, parts[pxPart].endSeconds))

        try await renderAndCheckSlides(
            round: round, take: take, entries: entries, controls: controls, outDir: outDir, round1Dir: round1Dir,
            parts: parts, partSegment: partSegment, left: left, right: right, edge: edge, interval: interval,
            candidates: candidates, anchors: [("round-1 L2 C (run 10, 3000 c/s)", r1C, "L2-C-smooth-3000.wav"),
                                              ("round-1 L1-e1 D (voice size 100 %)", e1D, "L1-e1-D-keep100.wav")],
            plants: ["P-X2": plantX, "P-C2": plantC], pxPart: pxPart, analysisVersion: seed.analysisVersion)
    }

    @MainActor
    static func renderAndCheckSlides(round: SlideRound, take: NoteSplitListeningTests.Take, entries: [Entry],
                                       controls inControls: [String: Any], outDir: URL, round1Dir: URL,
                                       parts: [NotePart], partSegment: [Int], left: Int, right: Int,
                                       edge: Double, interval: Double, candidates: [Int],
                                       anchors: [(label: String, set: PitchEditSet, file: String)],
                                       plants: [String: PitchEditSet], pxPart: Int,
                                       analysisVersion: Int) async throws {
        var controls = inControls
        let p = round.logPrefix
        let sr = take.sampleRate
        let source = take.input[0]
        let count = source.count
        let cacheDirA = outDir.appendingPathComponent("render-cache-a", isDirectory: true)
        let cacheDirB = outDir.appendingPathComponent("render-cache-b", isDirectory: true)
        for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) }
        defer { for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) } }
        let cacheA = StretchRenderCache(directory: cacheDirA)
        let cacheB = StretchRenderCache(directory: cacheDirB)
        func params(_ set: PitchEditSet) -> StretchRenderCache.Params {
            .init(clip: Clip(name: "vocal", audioFileURL: take.source, pitchEdits: set))
        }
        func render(_ set: PitchEditSet, _ label: String, in cache: StretchRenderCache) async throws -> [Float] {
            let rendered = try await NoteSplitListeningTests.render(set, take: take, cache: cache, label: label)
            let shortfall = cache.contourShortfall(source: take.source, params: params(set))
            try #require(shortfall == nil, "\(label) fell back: \(shortfall ?? "")")
            return rendered
        }

        // ── C2(b): round 1's files, rendered now, bit for bit — or STOP ────────
        var anchorRows: [String: Any] = [:]
        for anchor in anchors {
            let now = try await render(anchor.set, anchor.label, in: cacheA)
            let then = try TestSignals.readFile(round1Dir.appendingPathComponent(anchor.file))[0]
            let d = NoteSplitListeningTests.bitDiff(now, then)
            log("\(p)C2(b) ANCHOR \(anchor.label) rendered now vs round 1's NT-L/wav/\(anchor.file): \(d)")
            anchorRows[anchor.label] = ["file": anchor.file, "bitExact": d.bitExact, "differing": d.differing,
                                        "first": d.first ?? -1, "maxAbsDbfs": num(d.maxAbsDbfs)]
            try #require(d.bitExact, "STOP (\(round.preregStem) C2(b)): \(anchor.label) no longer renders as round 1 did: \(d). The render path moved under this harness; report it, do not compare round \(round.number).")
        }
        controls["anchorsRound1"] = anchorRows

        // ── RENDERS (the product path) and C1 DETERMINISM ─────────────────────
        var audio: [String: [Float]] = [:]
        var determinism: [String: Any] = [:]
        for entry in entries {
            let key = "\(round.setName)/\(entry.key)"
            let a = try await render(entry.set, key, in: cacheA)
            audio[entry.key] = a
            try M23QComparisonPair.writeWAV([a], sampleRate: sr, to: outDir.appendingPathComponent(entry.file))
            let b = try await render(entry.set, "\(key) again (fresh cache)", in: cacheB)
            let d = NoteSplitListeningTests.bitDiff(b, a)
            let fileA = try await cacheA.renderIfNeeded(clipID: UUID(), source: take.source, params: params(entry.set))
            let fileB = try await cacheB.renderIfNeeded(clipID: UUID(), source: take.source, params: params(entry.set))
            try #require(fileA.path != fileB.path, "\(key): the two renders are one file")
            let bytesA = try Data(contentsOf: fileA), bytesB = try Data(contentsOf: fileB)
            log("\(p)C1 DETERMINISM \(key): fresh-cache re-render \(d); cache files \(bytesA.count) vs \(bytesB.count) bytes, identical \(bytesA == bytesB)")
            #expect(d.bitExact, "C1: \(key) is not deterministic: \(d)")
            #expect(bytesA == bytesB, "C1: \(key)'s two cache files differ in bytes")
            determinism[key] = ["samplesDiffering": d.differing, "bitExact": d.bitExact,
                                "cacheFileBytes": bytesA.count, "cacheFilesIdentical": bytesA == bytesB]
        }
        let c1Negative = NoteSplitListeningTests.bitDiff(try #require(audio["A"]), try #require(audio["B"]))
        log("\(p)C1 negative control (must differ): A vs B \(c1Negative)")
        #expect(!c1Negative.bitExact)
        controls["determinismNegativeControl"] = ["A vs B differing": c1Negative.differing]
        var plantAudio: [String: [Float]] = [:]
        for (key, set) in plants.sorted(by: { $0.key < $1.key }) {
            plantAudio[key] = try await render(set, key, in: cacheA)
        }

        // ── THE HOP GRID the render consumed (round 1's spy) ───────────────────
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        guard case .frames(let latency) = compensation else {
            Issue.record("uncompensated render path")
            return
        }
        var spied: [Int] = []
        _ = try OfflineStretcher.stretchTransposeCurve(
            input: [Array(source.prefix(Int(sr)))], sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { spied.append($0); return 0 }, formantPreserve: false,
            compensation: compensation)
        try #require(spied.count >= 4 && spied[0] == spied[1])
        let hop = spied[2] - spied[1]
        let lookupOffset = spied[1]
        try #require(hop == 1440 && lookupOffset == latency + hop / 2)
        log("\(p)SPY: hop \(hop) frames, each chunk F reads the curves at F + \(lookupOffset)")
        let contour = PitchContourCache.renderContour(
            source: take.source, analysisVersion: analysisVersion,
            renderCacheDirectory: cacheDirA, detector: .product)
        try #require(contour.frames == take.detection.frames, "the render's contour is not this detection")
        var grids: [String: HopGrid] = [:]
        for entry in entries {
            grids[entry.key] = try hopGrid(entry.set, sampleRate: sr, frames: count, contour: contour, interval: hop)
        }
        for (key, set) in plants {
            grids[key] = try hopGrid(set, sampleRate: sr, frames: count, contour: contour, interval: hop)
        }
        let cEntry = try #require(entries.first { $0.key == "C" })
        let replicaC = try replica(try #require(grids["C"]), set: cEntry.set, input: take.input, sampleRate: sr)
        let dReplica = NoteSplitListeningTests.bitDiff(replicaC.audio, try #require(audio["C"]))
        log("\(p)GRID ≡ RENDER C: re-rendered from its hop grids (+ the consonant mix) vs the product render: \(dReplica); grid misses \(replicaC.misses)")
        try #require(replicaC.misses == 0 && dReplica.bitExact, "the hop grids are not what the C render consumed: \(dReplica)")
        controls["gridReplica"] = ["\(round.setName)/C": ["bitExact": dReplica.bitExact, "misses": replicaC.misses]]

        // ── C3 INVARIANCE (reference = A; the permitted window = Slow's reach) ──
        let half = 0.13334
        let windows = [(edge - half, edge + half)]
        let reference = try #require(audio["A"]), referenceGrid = try #require(grids["A"])
        let mask = dryMask(regions: cEntry.set.consonantRegions(), frames: count, sampleRate: sr)
        let after = edge + half
        var rows: [String: Any] = ["permittedWindows": windows.map { [$0.0, $0.1] }, "halfWidth": half,
                                   "dryFrames": mask.count]
        rows["A-dryVsSource"] = dryFrames(reference, reference, source: source, mask: mask, after: after, sampleRate: sr)
        func check(_ key: String, _ test: [Float]) throws -> (inv: Invariance, dry: [String: Any]) {
            let inv = try invariance(test, reference, grid: try #require(grids[key]), referenceGrid: referenceGrid,
                                     windows: windows, sampleRate: sr)
            let dry = dryFrames(test, reference, source: source, mask: mask, after: after, sampleRate: sr)
            log(p + String(format: "C3 %@ vs A (±%.1f ms): hops differing OUTSIDE %ld, inside %ld of %ld; audio before the first permitted hop (F = %ld, %.3f s): %@; causal %@; dry frames differing from A %@/%@, from the source %@/%@ (before/after)",
                       key as NSString, half * 1000, inv.outside.count, inv.inside.count, inv.hops,
                       inv.firstPermittedFrame, Double(inv.firstPermittedFrame) / sr,
                       inv.before.description as NSString, (inv.causal ? "yes" : "NO") as NSString,
                       "\(dry["differFromReferenceBefore"] ?? -1)" as NSString,
                       "\(dry["differFromReferenceAfter"] ?? -1)" as NSString,
                       "\(dry["differFromSourceBefore"] ?? -1)" as NSString,
                       "\(dry["differFromSourceAfter"] ?? -1)" as NSString))
            return (inv, dry)
        }
        for entry in entries where entry.key != "A" {
            let r = try check(entry.key, try #require(audio[entry.key]))
            var row = r.inv.row
            row["dry"] = r.dry
            rows[entry.key] = row
            #expect(r.inv.outside.isEmpty, "C3(i): \(entry.key) changed \(r.inv.outside.count) hops outside the window")
            #expect(r.inv.before.bitExact, "C3(ii): \(entry.key) differs before its first permitted hop")
            #expect(r.inv.causal, "C3(ii): \(entry.key) differs before its first differing hop")
        }
        let px = try check("P-X2", try #require(plantAudio["P-X2"]))
        let pxCaught = !px.inv.outside.isEmpty && !px.inv.before.bitExact
        log("\(p)PLANT P-X2 (C + 30 c on run \(parts[pxPart].runIndex), declared C): (i) \(px.inv.outside.count) hops outside, (ii) before the window \(px.inv.before) -> \(pxCaught ? "CAUGHT" : "NOT CAUGHT")")
        #expect(pxCaught, "plant P-X2 was not caught by C3 (i)/(ii)")
        let pc = try check("P-C2", try #require(plantAudio["P-C2"]))
        let pcCaught = ((pc.dry["differFromReferenceAfter"] as? Int) ?? 0) > 0
        log("\(p)PLANT P-C2 (C with the consonant mix off, declared C): (iii) dry frames differing from A after the window \(pc.dry["differFromReferenceAfter"] ?? -1) -> \(pcCaught ? "CAUGHT" : "NOT CAUGHT")")
        #expect(pcCaught, "plant P-C2 was not caught by C3 (iii)")
        controls["invariance"] = rows
        controls["plants"] = ["P-X2": ["invariance": px.inv.row, "dry": px.dry, "caught": pxCaught] as [String: Any],
                              "P-C2": ["invariance": pc.inv.row, "dry": pc.dry, "caught": pcCaught] as [String: Any]]

        // ── THE MANIFEST, for l2r2-checks.py and the page ──────────────────────
        var files: [String: Any] = [:]
        for entry in entries {
            files[entry.key] = [
                "file": entry.file, "slope": entry.set.transitionSlopeCentsPerSecond,
                "appliedWidthMs": num(entry.set.joinReading(afterSegmentAt: partSegment[left])?.appliedWidthMs),
                "formantCorrection": num(entry.set.formantCorrection), "consonants": entry.set.keepsConsonantsUntuned,
                "retuneMs": entry.set.retuneMs, "pageOption": entry.pageOption,
            ] as [String: Any]
        }
        let manifest: [String: Any] = [
            "what": round.what,
            "prereg": "NT-L/\(round.preregStem).txt", "sampleRate": sr, "frames": count,
            "hopFrames": hop, "lookupOffsetFrames": lookupOffset,
            "transposeEngineVersion": StretchRenderCache.transposeEngineVersion,
            "formantRenderVersion": PitchEditSet.formantRenderVersion,
            "transitionRenderVersion": PitchEditSet.transitionRenderVersion,
            "parts": parts.enumerated().map { partRow($1, index: $0, segment: partSegment[$0]) },
            "join": ["left": partRow(parts[left], index: left, segment: partSegment[left]),
                     "right": partRow(parts[right], index: right, segment: partSegment[right]),
                     "edgeSeconds": edge, "postMoveIntervalCents": interval, "move": l2Move,
                     "candidateLeftParts": candidates,
                     "plantNote": partRow(parts[pxPart], index: pxPart, segment: partSegment[pxPart])] as [String: Any],
            "files": files, "determinism": determinism, "controls": controls,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent(round.manifestName))
        log("\(p)wrote \(entries.count) WAVs and \(round.manifestName) to \(outDir.path)")
    }
}
