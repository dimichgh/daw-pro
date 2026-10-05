import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-nt D4-1 (b) — WHAT THE FIRST EDIT ON AN OLD VOCAL COSTS, MEASURED.
///
/// The user ruled Q-U1 = (b) on 2026-09-26: the first note you drag on a vocal
/// tuned before natural tuning updates the whole vocal. The update engages the
/// per-hop formant curve on every tuned note (`formantCorrection` nil → 1.0),
/// so `RenderDiff` refuses a local extent (`.formantCurveEngagement`) and the
/// provisional splice DECLINES: the old render plays on until the whole-clip
/// render lands. A SECOND edit is local again and splices. This harness
/// measures both on a real take, p50 of 5, with the product's own functions:
///
///  * a LEGACY vocal: the take's notes tuned by the Natural preset, then its
///    three set-level fields put back to legacy (a preset-tuned vocal from
///    before the update);
///  * FIRST EDIT (trial k): note k moved +200 c through
///    `applyingNotePitchOffsets` (the drag's own transform, which updates the
///    vocal). Timed: `ProvisionalRender.build` against the legacy final (its
///    outcome), then `performRender` of the new set (when the new sound can
///    be heard);
///  * the SAME first edit under the old rule (a) (the move alone, legacy kept),
///    the control: what a first edit cost before the ruling;
///  * SECOND EDIT (trial k): on the updated vocal of trial 0, note k+1 moved
///    +200 c. Timed: `ProvisionalRender.build` against that vocal's final.
///
/// ENV-GATED, TIMED: run it under the timing lock, never in a normal
/// `./scripts/test.sh`:
///
///     D41_TAKE="<wav>" D41_OUT=<dir> ./scripts/test.sh --filter d41FirstEditRenderCost
///
/// No `@MainActor` (every function it calls is nonisolated), nothing plays,
/// and every file it writes lives in a temporary directory it removes.
@Suite("m23-nt D4-1 (b): the first edit on an old vocal against a second edit, on a real take (env-gated, timed)",
       .serialized)
struct D41FirstEditRenderCostTests {
    typealias Params = StretchRenderCache.Params

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    static func p50(_ x: [Double]) -> Double {
        let s = x.sorted()
        return s.isEmpty ? .nan : s[s.count / 2]
    }

    static func load() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l
    }

    static func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try body()
        return (value, ms(ContinuousClock.now - start))
    }

    static func describe(_ outcome: ProvisionalRender.Outcome) -> String {
        switch outcome {
        case .built(let built):
            let patch = built.patchedFrames.reduce(0) { $0 + $1.count }
            return "built \(built.kind.rawValue), patch \(String(format: "%.2f", Double(patch) / 48_000)) s"
        case .declined(let reason):
            return "declined: \(reason)"
        }
    }

    @Test("D4-1 (b) cost: first edit on an old vocal (provisional outcome + whole render) vs a second edit, p50 of 5 (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["D41_TAKE"] != nil))
    func d41FirstEditRenderCost() throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["D41_TAKE"]))
        let out = URL(fileURLWithPath: try #require(env["D41_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let work = try I1Signals.tempDir("d41-cost")
        defer { try? FileManager.default.removeItem(at: work) }
        let loadStart = Self.load()

        // The legacy vocal: a preset-tuned take with its set-level fields legacy.
        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let preset = PitchAutoCorrect.editSet(from: detection,
                                              options: PitchCorrectionPreset.natural.options())
        let legacy = PitchEditSet(analysisVersion: preset.analysisVersion, segments: preset.segments,
                                  retuneMs: preset.retuneMs)
        try #require(legacy.predatesNaturalTuning, "the fixture is not a legacy tuned vocal")
        let sung = legacy.segments.filter { $0.origin != .unpitched && $0.durationSeconds >= 0.3 }
        try #require(sung.count >= 6)
        let picked = (0..<6).map { sung[$0 * (sung.count - 1) / 5] }
        func moved(_ set: PitchEditSet, _ note: NoteSegment) throws -> PitchEditSet {
            let current = set.segments.first { $0.id == note.id }?.pitchOffsetCents ?? 0
            return try set.applyingNotePitchOffsets(
                [NotePitchOffset(segmentId: note.id, offsetCents: current + 200)], clipId: UUID())
        }
        func params(_ set: PitchEditSet) -> Params {
            Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: set)
        }
        func provisional(base: URL, baseSet: PitchEditSet, new: PitchEditSet, name: String)
            throws -> (ProvisionalRender.Outcome, Double) {
            try Self.timed {
                try ProvisionalRender.build(
                    ProvisionalRenderTests.job(source: take,
                                               base: ProvisionalRenderTests.base(base, params(baseSet)),
                                               params: params(new), dir: work, name: name),
                    isCancelled: { false })
            }
        }
        // Untimed: the legacy final (the base every first edit splices onto),
        // which also resolves the contour into `work` (the editor has it open).
        let legacyFinal = try ProvisionalRenderTests.finalRender(take, params(legacy), dir: work, name: "legacy")

        var rows: [[String: Any]] = []
        var firstProv: [Double] = [], firstWhole: [Double] = []
        var oldRuleProv: [Double] = []
        var firstOutcomes: [String] = [], oldRuleOutcomes: [String] = []
        var firstSet0: PitchEditSet?
        var firstFinal0: URL?
        for k in 0..<5 {
            let note = picked[k]
            let first = try moved(legacy, note)
            try #require(!first.predatesNaturalTuning, "the first edit did not update the vocal")
            let (outcome, provMs) = try provisional(base: legacyFinal, baseSet: legacy, new: first,
                                                    name: "first\(k)")
            let (finalURL, wholeMs) = try Self.timed {
                try ProvisionalRenderTests.finalRender(take, params(first), dir: work, name: "firstFinal\(k)")
            }
            if k == 0 { firstSet0 = first; firstFinal0 = finalURL }
            // The old rule (a): the move alone, the vocal left legacy.
            var oldRule = legacy
            if let i = oldRule.segments.firstIndex(where: { $0.id == note.id }) {
                oldRule.segments[i].pitchOffsetCents += 200
            }
            let (oldOutcome, oldMs) = try provisional(base: legacyFinal, baseSet: legacy, new: oldRule,
                                                      name: "oldRule\(k)")
            firstProv.append(provMs); firstWhole.append(wholeMs); oldRuleProv.append(oldMs)
            firstOutcomes.append(Self.describe(outcome)); oldRuleOutcomes.append(Self.describe(oldOutcome))
            let changed = first.segments.filter { $0.pitchOffsetCents != 0 }.count
            rows.append(["trial": k, "note": note.startSeconds, "firstProvisionalMs": provMs,
                         "firstProvisional": Self.describe(outcome), "firstWholeRenderMs": wholeMs,
                         "oldRuleProvisionalMs": oldMs, "oldRuleProvisional": Self.describe(oldOutcome),
                         "tunedNotes": changed, "notes": first.segments.count])
            print(String(format: "d41-cost| first edit %d (note at %.2f s): provisional %@ in %.0f ms; whole render %.0f ms; old rule (a): %@ in %.0f ms",
                         k, note.startSeconds, Self.describe(outcome), provMs, wholeMs,
                         Self.describe(oldOutcome), oldMs))
        }
        let base1 = try #require(firstSet0)
        let base1Final = try #require(firstFinal0)
        var secondProv: [Double] = [], secondOutcomes: [String] = []
        for k in 0..<5 {
            let second = try moved(base1, picked[k + 1])
            let expectedOnly = base1.withSegments(second.segments)
            try #require(second == expectedOnly, "a second edit touched the set-level fields")
            let (outcome, provMs) = try provisional(base: base1Final, baseSet: base1, new: second,
                                                    name: "second\(k)")
            secondProv.append(provMs); secondOutcomes.append(Self.describe(outcome))
            rows.append(["secondTrial": k, "note": picked[k + 1].startSeconds, "secondProvisionalMs": provMs,
                         "secondProvisional": Self.describe(outcome)])
            print(String(format: "d41-cost| second edit %d (note at %.2f s): provisional %@ in %.0f ms",
                         k, picked[k + 1].startSeconds, Self.describe(outcome), provMs))
        }
        let loadEnd = Self.load()
        let file = try AVAudioFile(forReading: take)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let summary: [String: Any] = [
            "take": take.path, "takeSeconds": seconds, "notes": legacy.segments.count,
            "tunedNotes": legacy.segments.filter { $0.pitchOffsetCents != 0 }.count,
            "p50FirstProvisionalMs": Self.p50(firstProv), "p50FirstWholeRenderMs": Self.p50(firstWhole),
            "p50OldRuleProvisionalMs": Self.p50(oldRuleProv), "p50SecondProvisionalMs": Self.p50(secondProv),
            "firstOutcomes": firstOutcomes, "oldRuleOutcomes": oldRuleOutcomes, "secondOutcomes": secondOutcomes,
            "loadStart": loadStart, "loadEnd": loadEnd, "rows": rows,
        ]
        let json = out.appendingPathComponent("d41-first-edit-cost.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: json)
        print(String(format: "d41-cost| SUMMARY p50 (5): first edit whole render %.0f ms (provisional %.0f ms to decide); second edit provisional %.0f ms; old rule (a) first edit provisional %.0f ms; load %@ -> %@",
                     Self.p50(firstWhole), Self.p50(firstProv), Self.p50(secondProv), Self.p50(oldRuleProv),
                     "\(loadStart)", "\(loadEnd)"))
        print("d41-cost| wrote \(json.path)")
    }
}
