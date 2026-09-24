import DAWCore
import Foundation

// p2-seg S2 — THE PRE-p2-seg REFERENCE (design
// `docs/design/2026-09-24-pitch-note-splitting.md` §5.2) and the three
// invariance legs that compare the product against it.
//
// ⚠️ THREE BYTE-IDENTICAL COPIES of this file exist — Tests/DAWCoreTests,
// Tests/DAWEngineTests and Tests/DAWAppKitTests — because the test targets
// share no support module. Edit none of them alone (`cmp` proves they match).
//
// ⛔ FROZEN. `editSet(contour:…)` below is `PitchAutoCorrect.editSet` and
// `detectedTable(from:…)` is `PitchNoteTable.detected` VERBATIM as they stood
// BEFORE p2-seg S2 (the `editSet` body is identical at git ed0d3ad and in the
// working tree S2 started from): ONE SEGMENT PER VOICED RUN. It is the oracle
// the §5.2 legs compare the product against, and the "today" the item-L
// listening harness renders (`NoteSplitListeningTests`). It must NEVER track
// the product — an oracle that moves with the code under test cannot see that
// code move. Its faithfulness is proved where it can be: the harness renders
// it into the handoff page's pre-S2 files (`ref/04-hard-tune.wav`,
// `ref/02-natural.wav`) bit for bit.
enum PrePitchNoteSplitReference {

    // MARK: - The frozen builders

    /// `PitchAutoCorrect.editSet(contour:frameRateHz:options:analysisVersion:)`
    /// before p2-seg, verbatim.
    static func editSet(contour frames: [ClipPitchFrame],
                        frameRateHz: Double,
                        options: PitchAutoCorrectOptions,
                        analysisVersion: Int = PitchEditSet.currentAnalysisVersion)
    -> PitchEditSet {
        guard options.strength > 0 else { return .empty }
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: frameRateHz)
        guard !runs.isEmpty else {
            return PitchEditSet(analysisVersion: analysisVersion,
                                segments: [], retuneMs: options.retuneMs)
        }
        // Flattening IS correction, so it scales with strength: at strength 0
        // both branches are the identity, and at strength 1 the robot branch
        // replaces the contour outright.
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)

        let segments = runs.map { run -> NoteSegment in
            let detectedMidi = PitchCorrectionMath.midi(fromHz: run.centreHz)
            let targetMidi = options.scale.nearestAllowedMidi(to: detectedMidi)
            let offset = options.strength * (targetMidi - detectedMidi) * 100
            return NoteSegment(
                startSeconds: run.startSeconds,
                endSeconds: run.endSeconds,
                detectedHz: run.centreHz,
                detectedConfidence: run.medianConfidence,
                pitchOffsetCents: offset,
                driftScale: shapeScale,
                vibratoScale: shapeScale)
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: segments,
                            retuneMs: options.retuneMs)
    }

    /// `PitchAutoCorrect.editSet(from:options:analysisVersion:)` before p2-seg.
    static func editSet(from result: PitchDetectionResult,
                        options: PitchAutoCorrectOptions,
                        analysisVersion: Int = PitchEditSet.currentAnalysisVersion)
    -> PitchEditSet {
        editSet(contour: result.frames, frameRateHz: result.frameRateHz,
                options: options, analysisVersion: analysisVersion)
    }

    /// `PitchNoteTable.detected(from:retuneMs:analysisVersion:)` before p2-seg,
    /// verbatim.
    static func detectedTable(from result: PitchDetectionResult,
                              retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
                              analysisVersion: Int = PitchEditSet.currentAnalysisVersion)
    -> PitchEditSet {
        let runs = PitchAutoCorrect.voicedRuns(in: result.frames, frameRateHz: result.frameRateHz)
        let segments = runs.map { run in
            NoteSegment(startSeconds: run.startSeconds,
                        endSeconds: run.endSeconds,
                        detectedHz: run.centreHz,
                        detectedConfidence: run.medianConfidence)
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: segments,
                            retuneMs: retuneMs)
    }

    // MARK: - Field-by-field comparison (ids excluded: they are minted per call)

    /// Every stored field of two segments except `id`, compared through
    /// `String(describing:)` — a Double's description is its shortest exact
    /// round trip, so equal text is equal bits, `-0.0` included. Returns the
    /// labels that differ and how many fields were compared, so a reflection
    /// that saw nothing cannot pass.
    static func differingFields(_ a: NoteSegment, _ b: NoteSegment) -> (differing: [String], compared: Int) {
        let ca = Array(Mirror(reflecting: a).children), cb = Array(Mirror(reflecting: b).children)
        guard ca.count == cb.count else { return (["<field count \(ca.count) vs \(cb.count)>"], 0) }
        var differing: [String] = [], compared = 0
        for (x, y) in zip(ca, cb) {
            guard x.label == y.label else { return (["<label \(x.label ?? "?") vs \(y.label ?? "?")>"], compared) }
            if x.label == "id" { continue }
            compared += 1
            let xs = String(describing: x.value), ys = String(describing: y.value)
            if xs != ys { differing.append("\(x.label ?? "?"): \(xs) vs \(ys)") }
        }
        return (differing, compared)
    }

    /// `nil` when `product` equals `reference` on every set-level field and on
    /// every stored field of every segment but `id`; otherwise the FIRST
    /// difference, in words.
    static func firstDifference(_ product: PitchEditSet, _ reference: PitchEditSet) -> String? {
        if product.analysisVersion != reference.analysisVersion {
            return "analysisVersion \(product.analysisVersion) vs \(reference.analysisVersion)"
        }
        if product.retuneMs.bitPattern != reference.retuneMs.bitPattern {
            return "retuneMs \(product.retuneMs) vs \(reference.retuneMs)"
        }
        if product.autoCorrectStamp != reference.autoCorrectStamp {
            return "autoCorrectStamp \(product.autoCorrectStamp ?? "nil") vs \(reference.autoCorrectStamp ?? "nil")"
        }
        if product.segments.count != reference.segments.count {
            return "\(product.segments.count) segments vs \(reference.segments.count)"
        }
        for (i, (p, r)) in zip(product.segments, reference.segments).enumerated() {
            let d = differingFields(p, r)
            if d.compared < 14 { return "segment \(i): only \(d.compared) fields compared" }
            if !d.differing.isEmpty { return "segment \(i): " + d.differing.joined(separator: "; ") }
        }
        return nil
    }

    // MARK: - The three §5.2 legs on one fixture

    /// The option sets the edit-set leg sweeps: every preset on two scales, the
    /// default options, and a partial-strength flattening pass.
    static let optionSweep: [(label: String, options: PitchAutoCorrectOptions)] = {
        var out: [(String, PitchAutoCorrectOptions)] = []
        for preset in PitchCorrectionPreset.allCases {
            out.append(("\(preset.rawValue)/chromatic", preset.options()))
            out.append(("\(preset.rawValue)/C major",
                        preset.options(scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major))))
        }
        out.append(("default options", PitchAutoCorrectOptions()))
        out.append(("robot at strength 0.4",
                    PitchAutoCorrectOptions(scale: .chromatic, strength: 0.4, retuneMs: 60,
                                            preserveVibrato: false)))
        return out
    }()

    /// A `PitchDetectionResult` wrapper for a frames-only fixture (the note-table
    /// leg needs one).
    static func result(_ frames: [ClipPitchFrame], frameRateHz: Double) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count),
            frameRateHz: frameRateHz, analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: 0, windowDurationSeconds: Double(frames.count) / max(frameRateHz, 1),
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// Design §5.2 on one fixture, all three legs:
    ///  * UNIT — `PitchNoteSplitter.parts` maps 1:1 onto `voicedRuns`: one
    ///    `.held` part per run with equal start, end, centre, confidence and
    ///    frame count (and its own run index and run centre);
    ///  * EDIT SET — `PitchAutoCorrect.editSet` equals the frozen reference field
    ///    by field (ids excluded) under every option set in `optionSweep` AND
    ///    every slide shape;
    ///  * NOTE TABLE — `PitchNoteTable.detected` equals the frozen reference
    ///    table the same way.
    /// Returns every failure found; empty means the fixture is invariant. A
    /// fixture that really contains a note change fails it BY DESIGN — that is
    /// the positive control, and such a fixture is named where it is used.
    static func invarianceFailures(frames: [ClipPitchFrame], frameRateHz: Double) -> [String] {
        var failures: [String] = []
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: frameRateHz)
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: frameRateHz)
        if parts.count != runs.count {
            failures.append("UNIT: \(parts.count) parts vs \(runs.count) voiced runs")
        } else {
            for (i, (part, run)) in zip(parts, runs).enumerated() {
                let same = part.kind == .held && part.runIndex == i
                    && part.startSeconds.bitPattern == run.startSeconds.bitPattern
                    && part.endSeconds.bitPattern == run.endSeconds.bitPattern
                    && part.centreHz.bitPattern == run.centreHz.bitPattern
                    && part.medianConfidence.bitPattern == run.medianConfidence.bitPattern
                    && part.frameCount == run.frameCount
                    && part.runCentreHz.bitPattern == run.centreHz.bitPattern
                if !same { failures.append("UNIT: part \(i) \(part) is not run \(i) \(run)") }
            }
        }
        for (label, options) in optionSweep {
            let reference = editSet(contour: frames, frameRateHz: frameRateHz, options: options)
            for shape in PitchSlideShape.allCases {
                let product = PitchAutoCorrect.editSet(contour: frames, frameRateHz: frameRateHz,
                                                       options: options, slideShape: shape)
                if let difference = firstDifference(product, reference) {
                    failures.append("EDIT SET (\(label), \(shape.rawValue)): \(difference)")
                }
            }
        }
        let wrapped = result(frames, frameRateHz: frameRateHz)
        if let difference = firstDifference(PitchNoteTable.detected(from: wrapped),
                                            detectedTable(from: wrapped)) {
            failures.append("NOTE TABLE: \(difference)")
        }
        return failures
    }
}
