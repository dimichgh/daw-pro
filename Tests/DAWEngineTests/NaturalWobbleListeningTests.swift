import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// P-L — THE NATURAL-WOBBLE LISTENING SET, rendered through the PRODUCT path
/// from the user's own take (design
/// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §2.1–§2.3).
///
/// Why it exists: the user heard Uncorrected, Gentle, Natural and Tight as
/// "all the same". Those presets only move each held note's CENTRE, by about
/// half the wobble they leave (§2.1). This set varies the one axis left, the
/// share of the singer's own wobble KEPT on held notes. Natural (strength
/// 0.85, retune 110 ms) is fixed. `keep` sets `driftScale = vibratoScale =
/// keep` on every `.held` part of the product's own table, which includes the
/// unsplit runs (the splitter makes each one ONE `.held` part). Every
/// `.transition` stays identity:
///
///     N0-natural-keep100  keep 1.0   today's Natural (the anchor)
///     N1-natural-keep60   keep 0.6
///     N2-natural-keep30   keep 0.3
///     N3-natural-keep0    keep 0.0
///
/// The pre-registered checks (design §2.3; their open readings were fixed in
/// the durable folder's `P-L/PREREG.txt` before any render):
///  * N0 is BIT-EXACT with item L's `07-natural-after.wav`, or nothing else
///    renders (the harness would not be the product path);
///  * N0 renders identically twice, from two fresh caches;
///  * L's invariance controls hold for N1–N3 over windows of held parts
///    ± 55 ms;
///  * the planted defects are caught.
/// The wander (`PitchWanderMeter`) is measured and logged here. Its verdicts,
/// the independent YIN, the loudness and the page files are the durable
/// folder's python (`P-L/pl-checks.py`, `P-L/pl-page.py`).
///
/// Env-gated, because the recording is the user's and is never in the tree.
/// It reuses item L's helpers (`NoteSplitListeningTests.load`, `render`,
/// `bitDiff`, `grid`, `uncorrected`), so it needs L's variables too, with
/// `NOTESPLIT_LISTEN_OUT` pointed at P-L's own folder and never at L's:
///
///     NATWOBBLE_LISTEN_OUT=<DUR>/P-L/wav \
///     NATWOBBLE_LISTEN_ANCHOR=<DUR>/L/wav/07-natural-after.wav \
///     NOTESPLIT_LISTEN_SOURCE=<DUR>/take/dry-norm.wav \
///     NOTESPLIT_LISTEN_PARTS=<DUR>/L/parts.json \
///     NOTESPLIT_LISTEN_OUT=<DUR>/P-L/wav \
///     NOTESPLIT_LISTEN_REF=<DUR>/L/ref \
///       ./scripts/test.sh --filter NaturalWobbleListeningTests
///
/// (`<DUR>` = `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics`.)
///
/// ⚠️ **MAIN-ACTOR CENSUS.** The main-actor attribute is spelled on the TEST,
/// never on the suite, as in `NoteSplitListeningTests`. The test is
/// env-gated, so a normal `./scripts/test.sh` run executes nothing here. A
/// suite-level attribute would count against `MainActorOccupancySiteTests`
/// Leg C (cap 394, census 393 when this file was written) for a suite that
/// never runs by default.
@Suite("P-L — Natural wobble listening set (product renders of the user's take)", .serialized)
struct NaturalWobbleListeningTests {
    static func log(_ message: String) { print("natwobble-listen| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["NATWOBBLE_LISTEN_OUT"] != nil

    /// The listening set, design §2.2: one axis, four points.
    static let listeningSet: [(key: String, file: String, keep: Double)] = [
        ("N0", "N0-natural-keep100.wav", 1.0),
        ("N1", "N1-natural-keep60.wav", 0.6),
        ("N2", "N2-natural-keep30.wav", 0.3),
        ("N3", "N3-natural-keep0.wav", 0.0),
    ]

    /// `base` with `driftScale = vibratoScale = keep` on the segments named in
    /// `keepAt` (by index), mutated IN PLACE, so every id, boundary, centre and
    /// offset stays the product's. Nothing else is touched, which is asserted.
    static func keeping(_ base: PitchEditSet, _ keepAt: [Int: Double]) throws -> PitchEditSet {
        var segments = base.segments
        for (index, keep) in keepAt {
            segments[index].driftScale = keep
            segments[index].vibratoScale = keep
        }
        let out = PitchEditSet(analysisVersion: base.analysisVersion, segments: segments,
                               retuneMs: base.retuneMs)
        try #require(out.segments.count == base.segments.count, "canonical() dropped a segment")
        for (a, b) in zip(out.segments, base.segments) {
            try #require(a.id == b.id && a.startSeconds.bitPattern == b.startSeconds.bitPattern
                         && a.endSeconds.bitPattern == b.endSeconds.bitPattern,
                         "canonical() moved a segment")
        }
        for (index, keep) in keepAt {
            try #require(out.segments[index].driftScale == keep && out.segments[index].vibratoScale == keep)
        }
        return out
    }

    /// Every stored field of every segment is `base`'s, except `driftScale` and
    /// `vibratoScale` on the segments in `changed`. Uses S2's reflection
    /// comparator, so a comparison that saw no fields cannot pass.
    static func onlyKeepFieldsDiffer(_ set: PitchEditSet, from base: PitchEditSet,
                                     changed: Set<Int>) throws {
        try #require(set.segments.count == base.segments.count && set.retuneMs == base.retuneMs
                     && set.analysisVersion == base.analysisVersion)
        for (i, (a, b)) in zip(set.segments, base.segments).enumerated() {
            let d = PrePitchNoteSplitReference.differingFields(a, b)
            try #require(d.compared >= 14, "segment \(i): only \(d.compared) fields compared")
            let labels = Set(d.differing.map { String($0.prefix { $0 != ":" }) })
            if changed.contains(i) {
                try #require(labels.isSubset(of: ["driftScale", "vibratoScale"]),
                             "segment \(i) changed more than its keep: \(d.differing)")
            } else {
                try #require(labels.isEmpty, "segment \(i) should be untouched: \(d.differing)")
            }
        }
    }

    /// A JSON-safe number (JSONSerialization rejects NaN and infinity).
    static func num(_ x: Double) -> Any { x.isFinite ? x : NSNull() }

    @Test("P-L — anchor, the four renders, L's invariance controls, the plants, and the wander",
          .enabled(if: enabled))
    @MainActor
    func renderTheNaturalWobbleSet() async throws {
        let outDir = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NATWOBBLE_LISTEN_OUT"))
        let anchorURL = URL(fileURLWithPath: try NoteSplitListeningTests.environment("NATWOBBLE_LISTEN_ANCHOR"))
        let take = try NoteSplitListeningTests.load()
        // L's loader creates and owns NOTESPLIT_LISTEN_OUT: it must be THIS
        // folder. Pointed at L's, a later pass-2 run would rewrite L's anchors.
        try #require(take.outDir.standardizedFileURL.path == outDir.standardizedFileURL.path,
                     "NOTESPLIT_LISTEN_OUT (\(take.outDir.path)) must equal NATWOBBLE_LISTEN_OUT (\(outDir.path))")
        let sr = take.sampleRate

        // ── THE PRESET, from code, not from the doc ───────────────────────────
        let nat = PitchCorrectionPreset.natural.options()
        try #require(nat.strength == 0.85 && nat.retuneMs == 110 && nat.preserveVibrato
                     && nat.scale == .chromatic,
                     "Natural is not strength 0.85 / retune 110 ms / preserve vibrato / chromatic")
        let h = nat.retuneMs / 2000
        try #require(h == 0.055)

        // ── THE TABLE: the product's Natural, and which segment is which part ──
        let product = PitchAutoCorrect.editSet(from: take.detection, options: nat)
        let parts = PitchNoteSplitter.parts(in: take.detection.frames,
                                            frameRateHz: take.detection.frameRateHz)
        try #require(parts.count == 59 && product.segments.count == 59,
                     "\(parts.count) parts, \(product.segments.count) segments; both must be 59")
        var held: [Int] = [], transitions: [Int] = [], partInRun: [Int] = []
        for (i, (part, segment)) in zip(parts, product.segments).enumerated() {
            try #require(part.startSeconds.bitPattern == segment.startSeconds.bitPattern
                         && part.endSeconds.bitPattern == segment.endSeconds.bitPattern
                         && part.centreHz.bitPattern == segment.detectedHz.bitPattern,
                         "part \(i) is not segment \(i)")
            try #require(segment.driftScale == 1 && segment.vibratoScale == 1,
                         "segment \(i): today's Natural keeps all the wobble")
            partInRun.append(i > 0 && parts[i - 1].runIndex == part.runIndex ? partInRun[i - 1] + 1 : 0)
            switch part.kind {
            case .held:
                held.append(i)
            case .transition:
                try #require(segment.pitchOffsetCents == 0, "segment \(i): a Natural transition is identity")
                transitions.append(i)
            }
        }
        let lHeld = take.parts.runs.reduce(0) { $0 + $1.parts.filter { $0.kind != "transition" }.count }
        let unsplit = take.parts.runs.filter { !$0.split }.count
        try #require(held.count == 52 && transitions.count == 7 && lHeld == 52 && unsplit == 30,
                     "held \(held.count) (parts.json \(lHeld)), transitions \(transitions.count), unsplit runs \(unsplit)")
        Self.log("TABLE: the product's Natural (strength \(nat.strength), retune \(nat.retuneMs) ms, preserveVibrato, chromatic), \(product.segments.count) segments = \(held.count) held (\(unsplit) unsplit runs + \(held.count - unsplit) held parts of split runs) + \(transitions.count) transitions; parts zip onto segments bit for bit; every scale is 1 today")

        // ── THE SETS ──────────────────────────────────────────────────────────
        func heldAt(_ keep: Double) -> [Int: Double] {
            Dictionary(uniqueKeysWithValues: held.map { ($0, keep) })
        }
        var sets: [String: PitchEditSet] = [:]
        for entry in Self.listeningSet {
            let set = try Self.keeping(product, heldAt(entry.keep))
            try Self.onlyKeepFieldsDiffer(set, from: product, changed: Set(held))
            sets[entry.key] = set
        }
        let n0 = try #require(sets["N0"])
        let n0Difference = PrePitchNoteSplitReference.firstDifference(n0, product)
        try #require(n0Difference == nil, "keep 1.0 is not the product's Natural table: \(n0Difference ?? "")")
        try #require(!n0.needsDetectedContour)
        for key in ["N1", "N2", "N3"] {
            let set = try #require(sets[key])
            try #require(set.needsDetectedContour, "\(key) does not ask for the contour")
        }
        Self.log("SETS: N0 through the same mapping at keep 1.0 == the product's Natural on every stored field but id (firstDifference nil); N1/N2/N3 differ from it ONLY in driftScale/vibratoScale on the \(held.count) held segments; ids kept")

        // ── THE PLANTS, by the pre-registered rules ────────────────────────────
        // P-H: among held parts >= 0.30 s, the largest median |frame cents −
        // part median cents| over the product's own detection frames.
        func frameWobble(_ i: Int) -> Double {
            let s = product.segments[i]
            let cents = take.detection.frames.compactMap { f -> Double? in
                guard let hz = f.frequencyHz, f.timeSeconds >= s.startSeconds, f.timeSeconds < s.endSeconds
                else { return nil }
                return 1200 * log2(hz / s.detectedHz)
            }
            let median = PitchWanderMeter.median(cents) ?? 0
            return PitchWanderMeter.median(cents.map { abs($0 - median) }) ?? 0
        }
        let ranked = held.filter { product.segments[$0].durationSeconds >= 0.30 }
            .map { (index: $0, wobble: frameWobble($0)) }
            .sorted { $0.wobble > $1.wobble }
        let plantHeld = try #require(ranked.first).index
        let plantPart = product.segments[plantHeld]
        Self.log("PLANT P-H part (rule: held >= 0.30 s, largest median |frame - median| in product frames): segment \(plantHeld), run \(parts[plantHeld].runIndex) part \(partInRun[plantHeld]), " +
                 String(format: "%.3f-%.3f s, %.1f c; next: ", plantPart.startSeconds, plantPart.endSeconds, ranked[0].wobble) +
                 ranked.dropFirst().prefix(4).map {
                     String(format: "run %ld %.3f s %.1f c", parts[$0.index].runIndex,
                            product.segments[$0.index].startSeconds, $0.wobble)
                 }.joined(separator: ", ") + " (\(ranked.count) candidates)")
        // P-T: the LONGEST transition.
        let plantTransition = try #require(transitions.max {
            product.segments[$0].durationSeconds < product.segments[$1].durationSeconds
        })
        let longest = product.segments[plantTransition].durationSeconds
        try #require(transitions.filter { product.segments[$0].durationSeconds == longest }.count == 1)
        Self.log(String(format: "PLANT P-T part (rule: the longest transition): segment %ld, run %ld part %ld, %.3f-%.3f s (%.3f s)",
                        plantTransition, parts[plantTransition].runIndex, partInRun[plantTransition],
                        product.segments[plantTransition].startSeconds,
                        product.segments[plantTransition].endSeconds, longest))
        var ptKeep = heldAt(0.6)
        ptKeep[plantTransition] = 0.6
        sets["P-H"] = try Self.keeping(product, [plantHeld: 0.6])
        sets["P-T"] = try Self.keeping(product, ptKeep)
        sets["P-9"] = try Self.keeping(product, heldAt(0.9))
        try Self.onlyKeepFieldsDiffer(try #require(sets["P-H"]), from: product, changed: [plantHeld])
        try Self.onlyKeepFieldsDiffer(try #require(sets["P-T"]), from: product, changed: Set(held + [plantTransition]))

        // ── RENDERS (the product path) ─────────────────────────────────────────
        let cacheDirA = outDir.appendingPathComponent("render-cache-a", isDirectory: true)
        let cacheDirB = outDir.appendingPathComponent("render-cache-b", isDirectory: true)
        for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) }
        defer { for dir in [cacheDirA, cacheDirB] { try? FileManager.default.removeItem(at: dir) } }
        let cacheA = StretchRenderCache(directory: cacheDirA)
        let cacheB = StretchRenderCache(directory: cacheDirB)
        func params(_ set: PitchEditSet) -> StretchRenderCache.Params {
            .init(clip: Clip(name: "vocal", audioFileURL: take.source, pitchEdits: set))
        }
        var audio: [String: [Float]] = [:]
        var controls: [String: Any] = [:]

        // CHECK 1 — THE ANCHOR, before anything else renders.
        audio["N0"] = try await NoteSplitListeningTests.render(n0, take: take, cache: cacheA, label: "N0")
        let anchor = try TestSignals.readFile(anchorURL)[0]
        let d1 = NoteSplitListeningTests.bitDiff(try #require(audio["N0"]), anchor)
        Self.log("CHECK 1 ANCHOR: N0 vs \(anchorURL.lastPathComponent): \(d1)")
        try #require(d1.bitExact && d1.differing == 0,
                     "STOP: N0 is not L's 07-natural-after.wav, so this harness is not the product path: \(d1)")
        controls["anchor"] = ["file": anchorURL.path, "samples": d1.to, "differing": d1.differing,
                              "bitExact": d1.bitExact]

        let rendered: [(key: String, file: String)] = [
            ("N1", "N1-natural-keep60.wav"), ("N2", "N2-natural-keep30.wav"), ("N3", "N3-natural-keep0.wav"),
            ("P-H", "90-plant-PH-keep60-on-one-held-part.wav"),
            ("P-T", "91-plant-PT-N1-plus-keep60-on-one-transition.wav"),
            ("P-9", "92-plant-P9-keep90.wav"),
        ]
        for entry in rendered {
            let set = try #require(sets[entry.key])
            audio[entry.key] = try await NoteSplitListeningTests.render(set, take: take, cache: cacheA,
                                                                        label: entry.key)
            // The silent-fallback trap: a render that could not shape plays
            // N0's constant offsets and nothing else would notice.
            let shortfall = cacheA.contourShortfall(source: take.source, params: params(set))
            try #require(shortfall == nil, "\(entry.key) fell back to constant offsets: \(shortfall ?? "")")
        }
        for entry in Self.listeningSet {
            try M23QComparisonPair.writeWAV([try #require(audio[entry.key])], sampleRate: sr,
                                            to: outDir.appendingPathComponent(entry.file))
        }
        for entry in rendered where entry.key.hasPrefix("P-") {
            try M23QComparisonPair.writeWAV([try #require(audio[entry.key])], sampleRate: sr,
                                            to: outDir.appendingPathComponent(entry.file))
        }
        // Check 1's plant: the same comparator on a DIFFERENT render must differ.
        let d1Negative = NoteSplitListeningTests.bitDiff(try #require(audio["N1"]), anchor)
        Self.log("CHECK 1 negative control, N1 vs \(anchorURL.lastPathComponent) (must differ): \(d1Negative)")
        #expect(!d1Negative.bitExact)
        controls["anchorNegativeControlN1"] = ["differing": d1Negative.differing, "first": d1Negative.first ?? -1]

        // CHECK 2 — N0's settings rendered a second time, in a FRESH cache.
        let n0Again = try await NoteSplitListeningTests.render(n0, take: take, cache: cacheB, label: "N0 again (fresh cache)")
        let d2 = NoteSplitListeningTests.bitDiff(n0Again, try #require(audio["N0"]))
        let fileA = try await cacheA.renderIfNeeded(clipID: UUID(), source: take.source, params: params(n0))
        let fileB = try await cacheB.renderIfNeeded(clipID: UUID(), source: take.source, params: params(n0))
        let bytesA = try Data(contentsOf: fileA), bytesB = try Data(contentsOf: fileB)
        try #require(fileA.path != fileB.path, "the two N0 renders are one file")
        Self.log("CHECK 2 DETERMINISM: N0 rendered again in a fresh cache: \(d2); cache files \(bytesA.count) vs \(bytesB.count) bytes, identical \(bytesA == bytesB) (\(fileA.deletingLastPathComponent().lastPathComponent)/ vs \(fileB.deletingLastPathComponent().lastPathComponent)/)")
        #expect(d2.bitExact, "N0 is not deterministic: \(d2)")
        #expect(bytesA == bytesB, "N0's two cache files differ in bytes")
        controls["determinism"] = ["samplesDiffering": d2.differing, "bitExact": d2.bitExact,
                                   "cacheFileBytes": bytesA.count, "cacheFilesIdentical": bytesA == bytesB]
        audio["N0-again"] = n0Again

        // A context control: the zero-curve product loop is L's reference.
        let uncorrected = try NoteSplitListeningTests.uncorrected(take)
        let ref00 = try TestSignals.readFile(take.refDir.appendingPathComponent("00-uncorrected.wav"))[0]
        let d00 = NoteSplitListeningTests.bitDiff(uncorrected, ref00)
        Self.log("CONTEXT: the zero-curve product loop vs ref/00-uncorrected.wav: \(d00)")
        #expect(d00.bitExact)
        controls["uncorrectedVsRef00"] = ["differing": d00.differing, "bitExact": d00.bitExact]
        audio["uncorrected"] = uncorrected

        // ── THE HOP GRID the render consumed (L's spy and replica) ─────────────
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        guard case .frames(let latency) = compensation else {
            Issue.record("uncompensated render path"); return
        }
        var spied: [Int] = []
        _ = try OfflineStretcher.stretchTransposeCurve(
            input: [Array(take.input[0].prefix(Int(sr)))], sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { spied.append($0); return 0 }, formantPreserve: false,
            compensation: compensation)
        try #require(spied.count >= 4 && spied[0] == spied[1])
        let interval = spied[2] - spied[1]
        let lookupOffset = spied[1]
        for (k, lookup) in spied.dropFirst().enumerated() {
            try #require(lookup == k * interval + lookupOffset)
        }
        try #require(interval == 1440 && lookupOffset == latency + interval / 2)
        Self.log("SPY: hop \(interval) frames, each chunk F reads the curve at F + \(lookupOffset) (latency \(latency) + hop/2)")
        let contour = PitchContourCache.renderContour(
            source: take.source, analysisVersion: n0.analysisVersion,
            renderCacheDirectory: cacheDirA, detector: .product)
        try #require(contour.frames == take.detection.frames, "the render's contour is not this detection")
        var unresolvedCounts: [String: Int] = [:]
        for key in ["N1", "N2", "N3", "P-H", "P-T", "P-9"] {
            let curve = contour.curve(editSet: try #require(sets[key]), clipPitchShiftSemitones: 0)
            unresolvedCounts[key] = curve.unresolvedShapingSegmentIDs.count
            try #require(curve.unresolvedShapingSegmentIDs.isEmpty,
                         "\(key): \(curve.unresolvedShapingSegmentIDs.count) segments could not be shaped")
        }
        Self.log("CONTOUR: the render's contour equals this detection; unresolved shaping segments: \(unresolvedCounts)")
        var grids: [String: NoteSplitListeningTests.Grid] = [:]
        for key in ["N0", "N1", "N2", "N3", "P-H", "P-T", "P-9"] {
            grids[key] = try NoteSplitListeningTests.grid(try #require(sets[key]), take: take,
                                                          contour: contour, interval: interval)
        }
        let g3 = try #require(grids["N3"])
        let replica = try OfflineStretcher.stretchTransposeCurve(
            input: take.input, sampleRate: sr, ratio: 1,
            curve: zip(g3.lookups, g3.values).map { (outputFrame: $0, semitones: $1) },
            formantPreserve: false, compensation: compensation)[0]
        let dReplica = NoteSplitListeningTests.bitDiff(replica, try #require(audio["N3"]))
        Self.log("GRID ≡ RENDER: N3 re-rendered from its hop grid through the array entry point vs the product render: \(dReplica)")
        try #require(dReplica.bitExact, "the hop grid is not the curve the N3 render consumed")
        controls["gridReplicaN3BitExact"] = dReplica.bitExact

        // ── CHECK 3 (i)/(ii): L's curve and audio controls ─────────────────────
        let heldWindows = held.map { (n0.segments[$0].startSeconds - h, n0.segments[$0].endSeconds + h) }
        var invariance: [String: Any] = [:]
        func checkInvariance(_ key: String, windows: [(Double, Double)], declaredAs: String) throws -> (outside: Int, beforeExact: Bool, causal: Bool, hopTimes: [Double]) {
            let g = try #require(grids[key]), r = try #require(grids["N0"])
            let a = try #require(audio[key]), b = try #require(audio["N0"])
            func inWindow(_ j: Int) -> Bool {
                let t = Double(g.lookups[j]) / sr
                return windows.contains { t >= $0.0 && t <= $0.1 }
            }
            var outside: [Int] = [], inside: [Int] = []
            for (j, (x, y)) in zip(g.floatBits, r.floatBits).enumerated() where x != y {
                if inWindow(j) { inside.append(j) } else { outside.append(j) }
            }
            let firstAllowed = g.lookups.indices.first { inWindow($0) }
            let beforeEnd = firstAllowed.map { g.frames[$0] } ?? a.count
            let before = NoteSplitListeningTests.bitDiff(a, b, from: 0, to: beforeEnd)
            let all = NoteSplitListeningTests.bitDiff(a, b)
            let differing = (outside + inside).sorted()
            let firstHopF = differing.first.map { g.frames[$0] }
            let causal = all.first.map { first in firstHopF.map { first >= $0 } ?? false } ?? true
            let hopTimes = differing.map { Double(g.lookups[$0]) / sr }
            Self.log(String(format: "INVARIANCE %@ (declared %@, %ld windows) vs N0: hops differing OUTSIDE the permitted windows %ld, inside %ld, of %ld; audio before the first permitted hop (F = %ld, %.3f s): %@; first differing sample %@ vs first differing hop F %@ -> causal %@",
                             key as NSString, declaredAs as NSString, windows.count, outside.count, inside.count,
                             g.frames.count, beforeEnd, Double(beforeEnd) / sr, before.description as NSString,
                             (all.first.map(String.init) ?? "none") as NSString,
                             (firstHopF.map(String.init) ?? "none") as NSString, (causal ? "yes" : "NO") as NSString))
            invariance[key] = [
                "declaredAs": declaredAs, "windows": windows.count, "hopsOutside": outside.count,
                "hopsInside": inside.count, "hops": g.frames.count,
                "firstPermittedHopFrame": beforeEnd, "audioBeforeFirstPermittedHopBitExact": before.bitExact,
                "audioBeforeFirstPermittedHopDiffering": before.differing,
                "firstDifferingSample": all.first ?? -1, "firstDifferingHopFrame": firstHopF ?? -1,
                "causal": causal, "totalDifferingSamples": all.differing,
                "differingHopLookupSeconds": hopTimes,
                "outsideHopLookupSeconds": outside.map { Double(g.lookups[$0]) / sr },
            ]
            return (outside.count, before.bitExact, causal, hopTimes)
        }
        for key in ["N1", "N2", "N3"] {
            let r = try checkInvariance(key, windows: heldWindows, declaredAs: key)
            #expect(r.outside == 0, "3(i): \(key) changed \(r.outside) hops outside every held window")
            #expect(r.beforeExact, "3(ii): \(key)'s audio differs before its first permitted hop")
            #expect(r.causal, "3(ii): \(key)'s audio differs before its first differing hop")
        }
        // P-H is declared as N0's settings: no window is permitted, so every
        // differing hop is outside one and the whole file must match.
        let ph = try checkInvariance("P-H", windows: [], declaredAs: "N0")
        let plantWindow = (plantPart.startSeconds - h, plantPart.endSeconds + h)
        let localised = !ph.hopTimes.isEmpty && ph.hopTimes.allSatisfy { $0 >= plantWindow.0 && $0 <= plantWindow.1 }
        Self.log(String(format: "PLANT P-H (keep 0.6 on segment %ld only, declared N0): 3(i) flags %ld hops -> %@; 3(ii) whole-file bit-exact %@ -> %@; localisation: every differing hop inside the planted part ± 55 ms (%.3f-%.3f s): %@ (%.3f-%.3f s)",
                        plantHeld, ph.outside, (ph.outside > 0 ? "CAUGHT" : "NOT CAUGHT") as NSString,
                        (ph.beforeExact ? "yes" : "no") as NSString,
                        (ph.beforeExact ? "NOT CAUGHT" : "CAUGHT") as NSString, plantWindow.0, plantWindow.1,
                        (localised ? "yes" : "NO") as NSString,
                        ph.hopTimes.first ?? -1, ph.hopTimes.last ?? -1))
        #expect(ph.outside > 0 && !ph.beforeExact, "the P-H plant was not caught by 3(i)/3(ii)")
        #expect(localised, "the P-H plant's hops are not confined to its part")
        // P-T is declared as N1: held windows are permitted, the transition is not.
        let pt = try checkInvariance("P-T", windows: heldWindows, declaredAs: "N1")
        Self.log("PLANT P-T (N1 + keep 0.6 on the longest transition, declared N1): 3(i) flags \(pt.outside) hops outside the held windows -> \(pt.outside > 0 ? "CAUGHT" : "NOT CAUGHT")")
        #expect(pt.outside > 0, "the P-T plant was not caught by 3(i)")

        // ── CHECKS 4/5 input: the wander, PitchWanderMeter (the pinned instrument) ─
        let heldSegments = held.map { n0.segments[$0] }
        var readings: [String: [UUID: PitchWanderMeter.NoteReading]] = [:]
        for (key, samples) in audio {
            let read = PitchWanderMeter.readNotes(samples, sampleRate: sr, segments: heldSegments)
            readings[key] = Dictionary(uniqueKeysWithValues: read.map { ($0.segmentID, $0) })
        }
        let common = heldSegments.map(\.id).filter { id in
            ["N0", "N1", "N2", "N3"].allSatisfy { readings[$0]?[id] != nil }
        }
        try #require(common.count >= 5, "only \(common.count) held parts are readable in all four files")
        func wanderOf(_ key: String) -> Double? {
            let values = common.compactMap { readings[key]?[$0]?.spreadCents }
            return values.count == common.count ? PitchWanderMeter.median(values) : nil
        }
        var w: [String: Double] = [:]
        for key in audio.keys { if let value = wanderOf(key) { w[key] = value } }
        let wN = try Self.listeningSet.map { try #require(w[$0.key], "\($0.key) is not readable on every common part") }
        let strictly = zip(wN, wN.dropFirst()).allSatisfy { $0 > $1 }
        let halved = wN[3] <= 0.5 * wN[0]
        let steps = zip(wN, wN.dropFirst()).map { abs($0 - $1) }
        Self.log(String(format: "WANDER (PitchWanderMeter, median SD over the %ld held parts readable in N0-N3): N0 %.2f  N1 %.2f  N2 %.2f  N3 %.2f c | uncorrected %.2f, P-H %.2f, P-T %.2f, P-9 %.2f, N0-again %.2f",
                        common.count, wN[0], wN[1], wN[2], wN[3], w["uncorrected"] ?? .nan, w["P-H"] ?? .nan,
                        w["P-T"] ?? .nan, w["P-9"] ?? .nan, w["N0-again"] ?? .nan))
        Self.log(String(format: "CHECK 4 (PitchWanderMeter): strictly falling %@, W(N3) <= 0.5 W(N0) %@ (%.2f vs %.2f) -> %@",
                        (strictly ? "yes" : "NO") as NSString, (halved ? "yes" : "NO") as NSString,
                        wN[3], 0.5 * wN[0], (strictly && halved ? "PASS" : "FAIL") as NSString))
        let fallback = [wN[0], wN[1], wN[2], try #require(w["N0-again"])]
        let fallbackPasses = zip(fallback, fallback.dropFirst()).allSatisfy { $0 > $1 } && fallback[3] <= 0.5 * fallback[0]
        Self.log("CHECK 4 plant (N0's re-render in N3's place, what a contour fallback produces): \(fallbackPasses ? "PASSES -> NOT CAUGHT" : "FAILS -> CAUGHT")")
        Self.log(String(format: "CHECK 5 (PitchWanderMeter, bound 0.2 W(N0) = %.2f c): |N0-N1| %.2f %@, |N1-N2| %.2f %@, |N2-N3| %.2f %@; N0-N3 %.2f %@",
                        0.2 * wN[0], steps[0], (steps[0] >= 0.2 * wN[0] ? "pass" : "FAIL") as NSString,
                        steps[1], (steps[1] >= 0.2 * wN[0] ? "pass" : "FAIL") as NSString,
                        steps[2], (steps[2] >= 0.2 * wN[0] ? "pass" : "FAIL") as NSString,
                        wN[0] - wN[3], (wN[0] - wN[3] >= 0.2 * wN[0] ? "pass" : "FAIL -> STOP") as NSString))
        let p9Step = abs(wN[0] - (w["P-9"] ?? .nan))
        Self.log(String(format: "CHECK 5 plant (N0, P-9 = keep 0.9): |dW| %.2f vs bound %.2f -> %@", p9Step, 0.2 * wN[0],
                        (p9Step >= 0.2 * wN[0] ? "passes -> NOT CAUGHT" : "fails -> CAUGHT") as NSString))
        for id in common {
            let s = try #require(heldSegments.first { $0.id == id })
            let row = ["N0", "N1", "N2", "N3", "uncorrected"].map {
                String(format: "%@ %.1f", $0 as NSString, readings[$0]?[id]?.spreadCents ?? .nan)
            }.joined(separator: "  ")
            Self.log(String(format: "  part %.3f-%.3f s (%ld est. in N0): %@", s.startSeconds, s.endSeconds,
                            readings["N0"]?[id]?.estimateCount ?? 0, row as NSString))
        }

        // ── MANIFEST, for the python physics and the page ─────────────────────
        let index = Dictionary(uniqueKeysWithValues: n0.segments.enumerated().map { ($1.id, $0) })
        var partRows: [[String: Any]] = []
        for (i, (part, s)) in zip(parts, n0.segments).enumerated() {
            let midi = PitchCorrectionMath.midi(fromHz: s.detectedHz)
            partRows.append(["index": i, "id": s.id.uuidString, "kind": part.kind.rawValue,
                             "run": part.runIndex, "partInRun": partInRun[i], "start": s.startSeconds,
                             "end": s.endSeconds, "detectedHz": s.detectedHz, "detectedMidi": midi,
                             "offsetCents": s.pitchOffsetCents, "targetMidi": midi + s.pitchOffsetCents / 100,
                             "wanderReadableInAllFour": common.contains(s.id)])
        }
        var renderRows: [[String: Any]] = [["key": "uncorrected", "file": "L/ref/00-uncorrected.wav",
                                            "what": "zero-curve product loop (L's reference)"]]
        let files = Self.listeningSet.map { ($0.key, $0.file) } + rendered.filter { $0.key.hasPrefix("P-") }.map { ($0.key, $0.file) }
        for (key, file) in files {
            let set = try #require(sets[key])
            renderRows.append(["key": key, "file": file, "retuneMs": set.retuneMs,
                               "needsDetectedContour": set.needsDetectedContour,
                               "drift": set.segments.map(\.driftScale),
                               "vibrato": set.segments.map(\.vibratoScale)])
        }
        var wanderRows: [String: Any] = [:]
        for (key, byID) in readings {
            var rows: [[String: Any]] = []
            for (id, r) in byID.sorted(by: { (index[$0.key] ?? 0) < (index[$1.key] ?? 0) }) {
                rows.append(["index": index[id] ?? -1, "estimates": r.estimateCount, "medianHz": r.medianHz,
                             "spreadCents": r.spreadCents, "iqrCents": r.iqrCents])
            }
            wanderRows[key] = ["W": Self.num(w[key] ?? .nan), "parts": rows]
        }
        let manifest: [String: Any] = [
            "what": "P-L Natural wobble listening renders (NaturalWobbleListeningTests)",
            "sampleRate": sr, "hopFrames": interval, "lookupOffsetFrames": lookupOffset, "halfRampSeconds": h,
            "preset": ["name": "natural", "strength": nat.strength, "retuneMs": nat.retuneMs,
                       "preserveVibrato": nat.preserveVibrato],
            "parts": partRows, "renders": renderRows,
            "plants": ["P-H": ["index": plantHeld, "keep": 0.6, "declaredAs": "N0",
                               "rule": "held >= 0.30 s with the largest median |frame - median| (product frames)",
                               "ranked": ranked.prefix(8).map {
                                   ["index": $0.index, "medianAbsDevCents": $0.wobble] as [String: Any]
                               }],
                       "P-T": ["index": plantTransition, "keep": 0.6, "declaredAs": "N1",
                               "rule": "the longest transition"],
                       "P-9": ["keep": 0.9, "rule": "every held part at keep 0.9"]],
            "controls": controls, "invariance": invariance,
            "wander": ["instrument": "PitchWanderMeter (M23QToneTracker, band +-300 c, 0.10 s margin, >= 12 estimates)",
                       "commonIndices": common.compactMap { index[$0] }, "files": wanderRows],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("manifest.json"))
        Self.log("wrote \(files.count) WAVs and manifest.json to \(outDir.path)")
    }
}
