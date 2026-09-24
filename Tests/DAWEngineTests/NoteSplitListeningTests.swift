import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// p2-seg item L — THE NOTE-SPLIT LISTENING SET, rendered through the PRODUCT
/// path from the user's own take (design
/// `docs/design/2026-09-24-pitch-note-splitting.md` §3.2, §3.3, §5.1, §12, §14).
///
/// All Hard Tune, chromatic, one axis: what happens DURING a slide between two
/// held notes. The note boundaries come from item S1's §1.3 splitter at T = 8,
/// S = 8 (a hand-specified cut list, `parts.json`, made by `L/l-parts.py` in the
/// durable folder); every NOTE VALUE comes from this process's own product
/// detection. The edit sets are built directly from public DAWCore types and
/// rendered by `StretchRenderCache.renderIfNeeded` — the product's offline
/// renderer, never an imitation. This is EVIDENCE FOR THE USER'S PICK, not the
/// S2 gate: S2-close re-renders the picked shape with the real splitter.
///
/// Env-gated, because the recording is the user's and is never in the tree:
///
///     NOTESPLIT_LISTEN_SOURCE=<DUR>/take/dry-norm.wav \
///     NOTESPLIT_LISTEN_PARTS=<DUR>/L/parts.json \
///     NOTESPLIT_LISTEN_OUT=<DUR>/L/wav \
///     NOTESPLIT_LISTEN_REF=<DUR>/L/ref \
///       ./scripts/test.sh --filter NoteSplitListeningTests
///
/// (`<DUR>` = `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics`.)
/// `NOTESPLIT_LISTEN_REF` holds the earlier harness renders the handoff page's
/// MP3s were made from (`ContourRenderListeningTests`, 2026-09-24 02:09); the
/// bit-exact controls read it and fail loudly without it.
///
/// ⚠️ **p2-seg S2 CHANGED TWO THINGS HERE.** (1) The product's
/// `PitchAutoCorrect.editSet` now splits runs into notes, so every "today" in
/// passes 1–2 is the FROZEN pre-p2-seg builder `PrePitchNoteSplitReference`
/// (four call sites, repointed; every assertion kept). (2) Pass 3 builds the
/// edit sets with the PRODUCT's splitter and slide shapes and compares their
/// renders with this folder's pass-2 WAVs bit for bit. Pass 3 reads L's WAVs
/// from `NOTESPLIT_LISTEN_OUT`, so run it (alone, or first) against L's folder;
/// a pass-2 re-run rewrites those WAVs.
///
/// ⚠️ **MAIN-ACTOR CENSUS.** `@MainActor` is spelled PER TEST, never on the
/// suite, exactly like `ContourRenderListeningTests`: every test here is
/// env-gated (`.enabled(if:)`), so in a normal `./scripts/test.sh` run nothing
/// in this file executes and it adds no main-actor occupancy. Putting
/// `@MainActor` on the suite would count against
/// `MainActorOccupancySiteTests` Leg C (cap 394, census 393 when this file was
/// written) for a suite that never runs by default.
@Suite("p2-seg L — note-split listening set (product renders of the user's take)", .serialized)
struct NoteSplitListeningTests {
    static func log(_ message: String) { print("notesplit-listen| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["NOTESPLIT_LISTEN_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["NOTESPLIT_LISTEN_PARTS"] != nil
        && ProcessInfo.processInfo.environment["NOTESPLIT_LISTEN_OUT"] != nil

    // MARK: - The parts file (L/l-parts.py)

    struct PartsFile: Decodable {
        struct Part: Decodable {
            /// "run" (the run is not split; its one part IS today's VoicedRun),
            /// "held", or "transition".
            let kind: String
            /// For a transition: "lead-in", "link" or "tail-off".
            let `where`: String?
            /// Absolute frame range `[startFrame, endFrame)` into the detection.
            let startFrame: Int
            let endFrame: Int
            let frameCount: Int
            let startSeconds: Double
            let endSeconds: Double
            /// From `busyline-frames.csv` (4-decimal Hz). Cross-checked, never rendered.
            let medianHz: Double
            /// For a transition: the index (within the run) of the held part it
            /// leads INTO (design §12 item 2).
            let destinationPart: Int?
        }
        struct Run: Decodable {
            let index: Int
            let label: String?
            let startFrame: Int
            let endFrame: Int
            let startSeconds: Double
            let endSeconds: Double
            let frameCount: Int
            let centreHz: Double
            let split: Bool
            let parts: [Part]
        }
        let frameRateHz: Double
        let frameCount: Int
        let runs: [Run]
    }

    // MARK: - The take, detected once, aligned against the parts file

    struct Take {
        let source: URL
        let outDir: URL
        let refDir: URL
        let parts: PartsFile
        let input: [[Float]]
        let sampleRate: Double
        let detection: PitchDetectionResult
        let runs: [VoicedRun]
        /// Per run, per part: the median Hz and median confidence recomputed from
        /// THIS process's detection frames (`PitchCorrectionMath`, the estimators
        /// `voicedRuns` uses), and the part's exact boundaries: a split run's
        /// interior boundary is the next part's first frame time, so abutting
        /// parts share it bit for bit (design §1.1), and a run's outer edges are
        /// its `VoicedRun`'s own.
        let partHz: [[Double]]
        let partConfidence: [[Double]]
        let partBounds: [[(start: Double, end: Double)]]
    }

    static func environment(_ key: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[key], "\(key) is not set")
    }

    /// Loads the take and runs THE ALIGNMENT CONTROL: this process's own
    /// `voicedRuns` over its own product detection must reproduce the parts
    /// file's 42 run boundaries to 1e-9 s, and every part median recomputed here
    /// must agree with the file's to 0.01 cents. Fails loudly otherwise.
    @MainActor
    static func load() throws -> Take {
        let source = URL(fileURLWithPath: try environment("NOTESPLIT_LISTEN_SOURCE"))
        let partsURL = URL(fileURLWithPath: try environment("NOTESPLIT_LISTEN_PARTS"))
        let outDir = URL(fileURLWithPath: try environment("NOTESPLIT_LISTEN_OUT"))
        let refDir = URL(fileURLWithPath: try environment("NOTESPLIT_LISTEN_REF"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let parts = try JSONDecoder().decode(PartsFile.self, from: Data(contentsOf: partsURL))

        let input = try TestSignals.readFile(source)
        let sampleRate = try AVAudioFile(forReading: source).processingFormat.sampleRate
        try #require(input.count == 1, "the take is mono; got \(input.count) channels")

        let clock = ContinuousClock()
        let started = clock.now
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        log("detection: \(clock.now - started) — \(detection.frameCount) frames at \(detection.frameRateHz) fps, \(detection.voicedFrameCount) voiced, runtime \(SwiftF0PitchTracker.runtimeIdentity)")
        try #require(detection.frames.count == parts.frameCount)
        try #require(detection.frameRateHz == parts.frameRateHz)

        // ── THE ALIGNMENT CONTROL ─────────────────────────────────────────────
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames,
                                               frameRateHz: detection.frameRateHz)
        try #require(runs.count == 42 && parts.runs.count == 42,
                     "voicedRuns gave \(runs.count) runs, the parts file \(parts.runs.count); both must be 42")
        var worstEdge = 0.0
        for (run, file) in zip(runs, parts.runs) {
            let edge = max(abs(run.startSeconds - file.startSeconds), abs(run.endSeconds - file.endSeconds))
            worstEdge = max(worstEdge, edge)
            try #require(edge <= 1e-9 && run.frameCount == file.frameCount,
                         "run \(file.index): harness \(run.startSeconds)–\(run.endSeconds) (\(run.frameCount) fr) vs parts file \(file.startSeconds)–\(file.endSeconds) (\(file.frameCount) fr)")
        }

        var partHz: [[Double]] = [], partConfidence: [[Double]] = []
        var partBounds: [[(start: Double, end: Double)]] = []
        var worstCents = 0.0
        for (run, file) in zip(runs, parts.runs) {
            var hzRow: [Double] = [], confRow: [Double] = []
            var boundsRow: [(start: Double, end: Double)] = []
            for (k, part) in file.parts.enumerated() {
                let frames = Array(detection.frames[part.startFrame..<part.endFrame])
                try #require(frames.count == part.frameCount && frames.allSatisfy { $0.frequencyHz != nil },
                             "run \(file.index) part \(k): frames [\(part.startFrame), \(part.endFrame)) are not all voiced")
                try #require(abs(frames[0].timeSeconds - part.startSeconds) <= 1e-9)
                let hz = try #require(PitchCorrectionMath.medianFrequency(frames.compactMap(\.frequencyHz)))
                let confidence = PitchCorrectionMath.median(frames.map(\.confidence)) ?? 0
                if part.kind == "run" {
                    // The unsplit part IS the VoicedRun, byte for byte (design §2.4).
                    try #require(file.parts.count == 1 && hz == run.centreHz
                                 && confidence == run.medianConfidence)
                }
                worstCents = max(worstCents, abs(1200 * log2(hz / part.medianHz)))
                let start = k == 0 ? run.startSeconds : detection.frames[part.startFrame].timeSeconds
                let end = k == file.parts.count - 1
                    ? run.endSeconds : detection.frames[file.parts[k + 1].startFrame].timeSeconds
                hzRow.append(hz)
                confRow.append(confidence)
                boundsRow.append((start, end))
            }
            partHz.append(hzRow)
            partConfidence.append(confRow)
            partBounds.append(boundsRow)
        }
        try #require(worstCents <= 0.01,
                     "a part median recomputed from the live detection is \(worstCents) c from the parts file")
        log(String(format: "ALIGNMENT CONTROL: PASS — voicedRuns over this detection gives 42 runs, worst edge |diff| %.2e s against the parts file (limit 1e-9); 59 part medians recomputed from the live frames agree with the file within %.4f c (limit 0.01; the file's Hz are 4-decimal CSV values)",
                       worstEdge, worstCents))
        return Take(source: source, outDir: outDir, refDir: refDir, parts: parts, input: input,
                    sampleRate: sampleRate, detection: detection, runs: runs,
                    partHz: partHz, partConfidence: partConfidence, partBounds: partBounds)
    }

    // MARK: - Rendering (the product path)

    /// The zero-curve reference: the product's OWN curve loop with nothing asked
    /// of it (`ContourRenderListeningTests`' `00-uncorrected`), so every tuned
    /// file differs from it by the tuning alone.
    static func uncorrected(_ take: Take) throws -> [Float] {
        try OfflineStretcher.stretchTransposeCurve(
            input: take.input, sampleRate: take.sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in 0 }, formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: take.sampleRate))[0]
    }

    /// One edit set through `StretchRenderCache.renderIfNeeded` — the path
    /// `ProjectStore+PitchCorrection.swift` names — with the contour shortfall
    /// asserted absent (a fallback render would be the pre-contour sound).
    @MainActor
    static func render(_ set: PitchEditSet, take: Take, cache: StretchRenderCache,
                       label: String) async throws -> [Float] {
        let clip = Clip(name: "vocal", audioFileURL: take.source, pitchEdits: set)
        let clock = ContinuousClock()
        let started = clock.now
        let url = try await cache.renderIfNeeded(clipID: clip.id, source: take.source,
                                                 params: .init(clip: clip))
        let shortfall = cache.contourShortfall(source: take.source, params: .init(clip: clip))
        #expect(shortfall == nil, "\(label) fell back: \(shortfall ?? "")")
        let rendered = try TestSignals.readFile(url)
        try #require(rendered.count == 1 && rendered[0].count == take.input[0].count)
        log("render \(label): \(clock.now - started), \(set.segments.count) segments, needs contour \(set.needsDetectedContour)")
        return rendered[0]
    }

    // MARK: - Sample-exact comparison

    struct BitDiff: CustomStringConvertible {
        let lengthA: Int
        let lengthB: Int
        /// The compared range `[from, to)` -- the whole common length unless a sub-range was asked for.
        let from: Int
        let to: Int
        let differing: Int
        let first: Int?
        let last: Int?
        let maxAbs: Double
        var bitExact: Bool { lengthA == lengthB && differing == 0 }
        var maxAbsDbfs: Double { maxAbs > 0 ? 20 * log10(maxAbs) : -.infinity }
        var range: String {
            from == 0 && to == min(lengthA, lengthB)
                ? "all \(to) samples" : "samples [\(from), \(to)) (\(to - from))"
        }
        var description: String {
            if bitExact { return "BIT-EXACT over \(range)" }
            return String(format: "%ld differ over %@ (lengths %ld / %ld), first %@, last %@, max |diff| %.3g = %.1f dBFS",
                          differing, range as NSString, lengthA, lengthB,
                          (first.map(String.init) ?? "-") as NSString,
                          (last.map(String.init) ?? "-") as NSString,
                          maxAbs, maxAbsDbfs)
        }
    }

    /// Bit-pattern comparison over `[from, to)` (the whole common length by default).
    static func bitDiff(_ a: [Float], _ b: [Float], from: Int = 0, to: Int? = nil) -> BitDiff {
        let n = min(a.count, b.count)
        let lo = max(0, min(from, n)), hi = max(lo, min(to ?? n, n))
        var differing = 0, first: Int?, last: Int?, maxAbs = 0.0
        for i in lo..<hi where a[i].bitPattern != b[i].bitPattern {
            differing += 1
            if first == nil { first = i }
            last = i
            maxAbs = max(maxAbs, abs(Double(a[i]) - Double(b[i])))
        }
        return BitDiff(lengthA: a.count, lengthB: b.count, from: lo, to: hi, differing: differing,
                       first: first, last: last, maxAbs: maxAbs)
    }

    // MARK: - Pass 1: the controls that must hold before anything new is rendered

    @Test("pass 1 — alignment, and today's product renders reproduce the handoff files bit for bit",
          .enabled(if: enabled))
    @MainActor
    func todaysRendersAreTheHandoffRenders() async throws {
        let take = try Self.load()
        let cacheDir = take.outDir.appendingPathComponent("render-cache-pass1", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)

        // The localiser: if (c) moved, this says whether the stretcher/read path
        // moved (00 differs too) or only the edit-set/curve path (00 exact).
        let uncorrected = try Self.uncorrected(take)
        let ref00 = try TestSignals.readFile(take.refDir.appendingPathComponent("00-uncorrected.wav"))[0]
        let d00 = Self.bitDiff(uncorrected, ref00)
        Self.log("BIT-EXACT 00-uncorrected (zero-curve product loop) vs ref/00-uncorrected.wav: \(d00)")
        #expect(d00.bitExact, "the zero-curve render moved since 02:09: \(d00)")

        // (c) CONTROL: today's Hard Tune, exactly as the handoff's pitch-04 came from.
        // ⚠️ REPOINTED BY p2-seg S2: "today" is the FROZEN pre-p2-seg builder
        // (`PrePitchNoteSplitReference`, one segment per voiced run), because the
        // product's `PitchAutoCorrect.editSet` now splits runs into notes. These
        // bit-exact controls are what prove that reference faithful.
        let today = PrePitchNoteSplitReference.editSet(from: take.detection,
                                                       options: PitchCorrectionPreset.hardTune.options())
        let renderedToday = try await Self.render(today, take: take, cache: cache, label: "(c) today")
        let ref04 = try TestSignals.readFile(take.refDir.appendingPathComponent("04-hard-tune.wav"))[0]
        let dc = Self.bitDiff(renderedToday, ref04)
        Self.log("BIT-EXACT (c) today's Hard Tune vs ref/04-hard-tune.wav: \(dc)")
        #expect(dc.bitExact || dc.maxAbsDbfs <= -100,
                "STOP: the render path changed since the handoff files were made: \(dc)")

        // Natural today, the Q2 pair's "before", vs the handoff's 02-natural
        // (the frozen pre-p2-seg builder, as above).
        let natural = PrePitchNoteSplitReference.editSet(from: take.detection,
                                                         options: PitchCorrectionPreset.natural.options())
        let renderedNatural = try await Self.render(natural, take: take, cache: cache,
                                                    label: "natural today")
        let ref02 = try TestSignals.readFile(take.refDir.appendingPathComponent("02-natural.wav"))[0]
        let dn = Self.bitDiff(renderedNatural, ref02)
        Self.log("BIT-EXACT natural today vs ref/02-natural.wav: \(dn)")
        #expect(dn.bitExact || dn.maxAbsDbfs <= -100,
                "STOP: the Natural render changed since the handoff files were made: \(dn)")

        // The comparison can fail: the same instrument on two DIFFERENT renders.
        let negative = Self.bitDiff(renderedToday, ref00)
        Self.log("negative control, (c) vs ref/00-uncorrected.wav (must differ): \(negative)")
        #expect(!negative.bitExact)
    }

    // MARK: - Pass 2: the edit sets

    /// Today's policy for ONE note — the pre-p2-seg `PitchAutoCorrect.editSet`'s
    /// arithmetic (frozen in `PrePitchNoteSplitReference`), mirrored exactly.
    /// Pass 2 proves the mirror on all 42 runs before it is used for a single
    /// held part.
    static func policySegment(start: Double, end: Double, hz: Double, confidence: Double,
                              options: PitchAutoCorrectOptions) -> NoteSegment {
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)
        let detectedMidi = PitchCorrectionMath.midi(fromHz: hz)
        let targetMidi = options.scale.nearestAllowedMidi(to: detectedMidi)
        let offset = options.strength * (targetMidi - detectedMidi) * 100
        return NoteSegment(startSeconds: start, endSeconds: end, detectedHz: hz,
                           detectedConfidence: confidence, pitchOffsetCents: offset,
                           driftScale: shapeScale, vibratoScale: shapeScale)
    }

    /// Every stored field of two segments except `id`, compared through
    /// `String(describing:)` — a Double's description is its shortest exact
    /// round trip, so equal text is equal bits, `-0.0` included. The field
    /// count is returned so a reflection that saw nothing cannot pass.
    static func sameExceptID(_ a: NoteSegment, _ b: NoteSegment) -> (equal: Bool, fields: Int) {
        let ca = Array(Mirror(reflecting: a).children), cb = Array(Mirror(reflecting: b).children)
        guard ca.count == cb.count else { return (false, 0) }
        var fields = 0, equal = true
        for (x, y) in zip(ca, cb) {
            guard x.label == y.label else { return (false, fields) }
            if x.label == "id" { continue }
            fields += 1
            if String(describing: x.value) != String(describing: y.value) { equal = false }
        }
        return (equal, fields)
    }

    /// One shape's edit set. Unsplit runs take `base`'s own segment VERBATIM
    /// (today's segment, byte for byte, same id). A split run becomes one
    /// segment per held part — `policySegment` for the part's own median — and
    /// whatever `transition` writes for each `.transition` part. Parts abut
    /// exactly (`Take.partBounds`), so `PitchEditSet.canonical` moves nothing,
    /// which is asserted.
    @MainActor
    static func buildSplit(_ take: Take, base: PitchEditSet, options: PitchAutoCorrectOptions,
                           roles: inout [UUID: String],
                           transition: (_ run: Int, _ part: Int, _ start: Double, _ end: Double) throws -> [NoteSegment]
    ) throws -> PitchEditSet {
        try #require(base.segments.count == take.runs.count)
        var segments: [NoteSegment] = []
        for (i, run) in take.parts.runs.enumerated() {
            guard run.split else {
                let today = base.segments[i]
                try #require(today.startSeconds == take.runs[i].startSeconds
                             && today.endSeconds == take.runs[i].endSeconds)
                segments.append(today)
                roles[today.id] = "run \(i) unsplit: today's segment, verbatim"
                continue
            }
            for (k, part) in run.parts.enumerated() {
                let (start, end) = take.partBounds[i][k]
                switch part.kind {
                case "held":
                    let segment = policySegment(start: start, end: end, hz: take.partHz[i][k],
                                                confidence: take.partConfidence[i][k], options: options)
                    segments.append(segment)
                    roles[segment.id] = "run \(i) part \(k) held"
                case "transition":
                    for segment in try transition(i, k, start, end) {
                        segments.append(segment)
                        roles[segment.id] = "run \(i) part \(k) transition/\(part.`where` ?? "?")"
                    }
                default:
                    Issue.record("run \(i) is split but its part \(k) is '\(part.kind)'")
                }
            }
        }
        let set = PitchEditSet(analysisVersion: base.analysisVersion, segments: segments,
                               retuneMs: options.retuneMs)
        try #require(set.segments.count == segments.count, "canonical() dropped a segment")
        for (a, b) in zip(set.segments, segments) {
            try #require(a.id == b.id && a.startSeconds == b.startSeconds && a.endSeconds == b.endSeconds,
                         "canonical() moved a segment: the parts do not abut exactly")
        }
        return set
    }

    // MARK: - Pass 2: the curve the renderer is handed, hop by hop

    struct Grid {
        let frames: [Int]
        let lookups: [Int]
        let values: [Double]
        var floatBits: [UInt32] { values.map { Float($0).bitPattern } }
    }

    /// What `stretchTransposeCurve` hands `css_set_transpose_semitones` before
    /// each chunk (`OfflineStretcher.swift:505-517`): `Float(plan.semitones(
    /// atOutputFrame: curveLookupFrame(outDone)))`, with the plan built exactly
    /// as `performRender` builds it (`StretchRenderCache.swift:651-656`: the
    /// contour only when the set needs one).
    static func grid(_ set: PitchEditSet, take: Take, contour: PitchRenderContour,
                     interval: Int) throws -> Grid {
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0, sampleRate: take.sampleRate, ratio: 1,
            contour: set.needsDetectedContour ? contour : nil))
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: take.sampleRate)
        var frames: [Int] = [], lookups: [Int] = [], values: [Double] = []
        var frame = 0
        while frame < take.input[0].count {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: frame, compensation: compensation, intervalSamples: interval)
            frames.append(frame)
            lookups.append(lookup)
            values.append(plan.semitones(atOutputFrame: lookup))
            frame += interval
        }
        return Grid(frames: frames, lookups: lookups, values: values)
    }

    // MARK: - Pass 2: the listening set

    @Test("pass 2 — the listening set: four slide shapes and the Natural pair, with their controls",
          .enabled(if: enabled))
    @MainActor
    func renderTheListeningSet() async throws {
        let take = try Self.load()
        let sr = take.sampleRate
        let cacheDir = take.outDir.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)
        let ht = PitchCorrectionPreset.hardTune.options()
        let nat = PitchCorrectionPreset.natural.options()
        try #require(ht.scale == .chromatic && nat.scale == .chromatic)

        // ── THE MIRROR, proved on all 42 runs before it touches a part ─────────
        // "Today" is the FROZEN pre-p2-seg builder (repointed by S2: the
        // product's `editSet` now splits runs, and pass 3 renders THAT).
        let today = PrePitchNoteSplitReference.editSet(from: take.detection, options: ht)
        let naturalBefore = PrePitchNoteSplitReference.editSet(from: take.detection, options: nat)
        try #require(today.segments.count == 42 && naturalBefore.segments.count == 42)
        var mirrorFields = Set<Int>()
        for (options, set) in [(ht, today), (nat, naturalBefore)] {
            for (run, segment) in zip(take.runs, set.segments) {
                let mirrored = Self.policySegment(start: run.startSeconds, end: run.endSeconds,
                                                  hz: run.centreHz, confidence: run.medianConfidence,
                                                  options: options)
                let same = Self.sameExceptID(mirrored, segment)
                mirrorFields.insert(same.fields)
                try #require(same.equal, "the policy mirror differs from editSet at \(run.startSeconds) s")
            }
        }
        try #require(mirrorFields.count == 1 && (mirrorFields.first ?? 0) >= 14)
        Self.log("MIRROR: policySegment reproduces the pre-p2-seg editSet (PrePitchNoteSplitReference) on all 42 runs, Hard Tune AND Natural, on every stored field but id (\(mirrorFields.first ?? 0) fields each)")

        // ── THE SHAPES ─────────────────────────────────────────────────────────
        var roles: [UUID: String] = [:]
        for s in today.segments { roles[s.id] = "run segment (today's policy)" }
        for s in naturalBefore.segments { roles[s.id] = "run segment (today's Natural)" }
        let hz = take.partHz, conf = take.partConfidence

        // (d) Straight to the note: the transition keeps its own detectedHz and
        // aims at the plateau it leads INTO (§12 item 2), flattened.
        let straight = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            let part = take.parts.runs[i].parts[k]
            let dest = try #require(part.destinationPart)
            try #require(part.`where` == "tail-off" ? dest == k - 1 : dest == k + 1)
            try #require(take.parts.runs[i].parts[dest].kind == "held")
            let detected = PitchCorrectionMath.midi(fromHz: hz[i][k])
            let target = ht.scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: hz[i][dest]))
            return [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k],
                                detectedConfidence: conf[i][k],
                                pitchOffsetCents: ht.strength * (target - detected) * 100,
                                driftScale: 0, vibratoScale: 0)]
        }
        // (a-T) Slide kept, note locked: the transition is an IDENTITY segment.
        let slideKept = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k], detectedConfidence: conf[i][k])]
        }
        // (a-N) In-between note: the transition gets today's Hard Tune for its OWN median.
        let inBetween = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            [Self.policySegment(start: s, end: e, hz: hz[i][k], confidence: conf[i][k], options: ht)]
        }
        // (b) Robot staircase PROTOTYPE: one Hard-Tuned sub-segment per stretch
        // of consecutive frames that share a chromatic nearest note.
        var stairs: [[String: Any]] = []
        let staircase = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            let part = take.parts.runs[i].parts[k]
            let frames = Array(take.detection.frames[part.startFrame..<part.endFrame])
            let notes = try frames.map { frame -> Double in
                let f = try #require(frame.frequencyHz)
                return ht.scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: f))
            }
            var out: [NoteSegment] = []
            var g = 0
            while g < frames.count {
                var h = g
                while h < frames.count && notes[h] == notes[g] { h += 1 }
                let groupHz = try #require(PitchCorrectionMath.medianFrequency(frames[g..<h].compactMap(\.frequencyHz)))
                let groupConf = PitchCorrectionMath.median(frames[g..<h].map(\.confidence)) ?? 0
                let detected = PitchCorrectionMath.midi(fromHz: groupHz)
                try #require(ht.scale.nearestAllowedMidi(to: detected) == notes[g])
                let start = g == 0 ? s : frames[g].timeSeconds
                let end = h == frames.count ? e : frames[h].timeSeconds
                out.append(NoteSegment(startSeconds: start, endSeconds: end, detectedHz: groupHz,
                                       detectedConfidence: groupConf,
                                       pitchOffsetCents: ht.strength * (notes[g] - detected) * 100,
                                       driftScale: 1 - ht.strength, vibratoScale: 1 - ht.strength))
                stairs.append(["run": i, "part": k, "start": start, "end": end, "frames": h - g,
                               "noteMidi": notes[g], "detectedMidi": detected])
                g = h
            }
            return out
        }
        // Natural with the split: held parts get Natural's constant for their own
        // median; transitions are identity; unsplit runs are Natural today's.
        let naturalAfter = try Self.buildSplit(take, base: naturalBefore, options: nat, roles: &roles) { i, k, s, e in
            [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k], detectedConfidence: conf[i][k])]
        }
        // THE PLANT (isolated copy): (a-T) with +50 c on unsplit run 3 — the
        // longest run before the first split run (run 5, 3.536 s).
        try #require(!take.parts.runs[3].split && take.parts.runs[5].split
                     && (0..<5).allSatisfy { !take.parts.runs[$0].split })
        let run3 = today.segments[3]
        let plantIndex = try #require(slideKept.segments.firstIndex { $0.id == run3.id })
        var plantSegments = slideKept.segments
        plantSegments[plantIndex] = NoteSegment(
            startSeconds: run3.startSeconds, endSeconds: run3.endSeconds, detectedHz: run3.detectedHz,
            detectedConfidence: run3.detectedConfidence, pitchOffsetCents: run3.pitchOffsetCents + 50,
            driftScale: run3.driftScale, vibratoScale: run3.vibratoScale)
        let plant = PitchEditSet(analysisVersion: slideKept.analysisVersion, segments: plantSegments,
                                 retuneMs: slideKept.retuneMs)
        try #require(plant.segments.count == slideKept.segments.count)

        let splitTransitions = take.parts.runs.reduce(0) { $0 + $1.parts.filter { $0.kind == "transition" }.count }
        try #require(straight.segments.count == 59 && slideKept.segments.count == 59
                     && inBetween.segments.count == 59 && naturalAfter.segments.count == 59)
        try #require(staircase.segments.count == 59 - splitTransitions + stairs.count)
        Self.log("SETS: (c) 42, (d)/(a-T)/(a-N)/natural-after 59 segments each (42 runs -> 59 parts); (b) \(staircase.segments.count) (the 7 transitions become \(stairs.count) note-stairs)")

        // ── RENDERS (the product path) ─────────────────────────────────────────
        let uncorrected = try Self.uncorrected(take)
        let sets: [(key: String, file: String, set: PitchEditSet)] = [
            ("c", "01-today.wav", today), ("d", "02-straight.wav", straight),
            ("aT", "03-slide-kept.wav", slideKept), ("b", "04-staircase.wav", staircase),
            ("aN", "05-in-between.wav", inBetween), ("natBefore", "06-natural-before.wav", naturalBefore),
            ("natAfter", "07-natural-after.wav", naturalAfter),
            ("plant", "90-plant-slide-kept-run3.wav", plant),
        ]
        var audio: [String: [Float]] = ["uncorrected": uncorrected]
        try M23QComparisonPair.writeWAV([uncorrected], sampleRate: sr,
                                        to: take.outDir.appendingPathComponent("00-uncorrected.wav"))
        for entry in sets {
            let rendered = try await Self.render(entry.set, take: take, cache: cache, label: entry.key)
            audio[entry.key] = rendered
            try M23QComparisonPair.writeWAV([rendered], sampleRate: sr,
                                            to: take.outDir.appendingPathComponent(entry.file))
        }
        let c = try #require(audio["c"])

        // ── (c) BIT-EXACT CONTROL, again, on this pass's render ───────────────
        var controls: [String: Any] = [:]
        for (key, ref) in [("uncorrected", "00-uncorrected.wav"), ("c", "04-hard-tune.wav"),
                           ("natBefore", "02-natural.wav")] {
            let mine = try #require(audio[key])
            let theirs = try TestSignals.readFile(take.refDir.appendingPathComponent(ref))[0]
            let d = Self.bitDiff(mine, theirs)
            Self.log("BIT-EXACT \(key) vs ref/\(ref): \(d)")
            #expect(d.bitExact || d.maxAbsDbfs <= -100, "STOP: \(key) moved since the handoff: \(d)")
            controls["bitExact.\(key)"] = ["ref": ref, "differing": d.differing, "bitExact": d.bitExact]
        }

        // ── THE HOP GRID IS WHAT THE RENDER CONSUMED ───────────────────────────
        // (1) A spy on the product loop (1 s of the take): the hop and the
        //     lookup offset, measured rather than restated.
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        guard case .frames(let latency) = compensation else {
            Issue.record("uncompensated render path"); return
        }
        var spied: [Int] = []
        _ = try OfflineStretcher.stretchTransposeCurve(
            input: [Array(take.input[0].prefix(Int(sr)))], sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { spied.append($0); return 0 }, formantPreserve: false,
            compensation: compensation)
        try #require(spied.count >= 4)
        let interval = spied[2] - spied[1]
        let lookupOffset = spied[1]
        try #require(spied[0] == spied[1], "the pre-roll must read the first chunk's value")
        for (k, lookup) in spied.dropFirst().enumerated() {
            try #require(lookup == k * interval + lookupOffset)
        }
        try #require(interval == 1440 && lookupOffset == latency + interval / 2)
        Self.log("SPY on the product loop: hop \(interval) frames (\(Double(interval) / sr * 1000) ms), each chunk F reads the curve at F + \(lookupOffset) (= measured latency \(latency) + hop/2), the pre-roll reads chunk 0's value; \(spied.count) calls over 1 s")
        // (2) The contour every render shaped against (a cache hit now), and a
        //     replica of (c) from the grid through the array entry point: if it
        //     is bit-exact, the grid IS the curve the product render consumed.
        let contour = PitchContourCache.renderContour(
            source: take.source, analysisVersion: today.analysisVersion,
            renderCacheDirectory: cacheDir, detector: .product)
        #expect(contour.frames == take.detection.frames)
        var grids: [String: Grid] = [:]
        for entry in sets {
            grids[entry.key] = try Self.grid(entry.set, take: take, contour: contour, interval: interval)
        }
        let gridC = try #require(grids["c"])
        let replica = try OfflineStretcher.stretchTransposeCurve(
            input: take.input, sampleRate: sr, ratio: 1,
            curve: zip(gridC.lookups, gridC.values).map { (outputFrame: $0, semitones: $1) },
            formantPreserve: false, compensation: compensation)[0]
        let dReplica = Self.bitDiff(replica, c)
        Self.log("GRID ≡ RENDER: (c) re-rendered from its hop grid through the array entry point vs the product render: \(dReplica)")
        try #require(dReplica.bitExact, "the hop grid is not the curve the render consumed")

        // ── INVARIANCE ─────────────────────────────────────────────────────────
        // A curve change at source second t reaches hop F only when F's lookup
        // second (F + lookupOffset) / sr lies inside a changed span's ramped
        // window [start − h, end + h]: the gate is 0 outside it
        // (PitchCorrection.swift:1367-1375) and the evaluator skips such spans
        // (:1309-1316), h = min(retuneMs/2, note/2) ≤ retuneMs/2 (:1185, :1239).
        // A chunk's transpose reaches output samples from its own first frame F
        // on, through one synthesis block (0.12·sr, OfflineStretcher.swift:250)
        // after its hop: the DIRECT reach of hops F_a…F_b is [F_a, F_b + hop + block).
        let block = Int((0.12 * sr).rounded())
        let splitRuns = take.parts.runs.filter(\.split)
        func windows(_ h: Double) -> [(Double, Double)] {
            splitRuns.map { ($0.startSeconds - h, $0.endSeconds + h) }
        }
        func inside(_ lookup: Int, _ w: [(Double, Double)]) -> Bool {
            let t = Double(lookup) / sr
            return w.contains { t >= $0.0 && t <= $0.1 }
        }
        var invariance: [String: Any] = [:]
        func compare(_ key: String, against refKey: String, h: Double) throws {
            let g = try #require(grids[key]), r = try #require(grids[refKey])
            let a = try #require(audio[key]), b = try #require(audio[refKey])
            let w = windows(h)
            var outsideDiff: [Int] = [], insideDiff: [Int] = []
            for (j, (x, y)) in zip(g.floatBits, r.floatBits).enumerated() where x != y {
                if inside(g.lookups[j], w) { insideDiff.append(j) } else { outsideDiff.append(j) }
            }
            // The earliest hop that may LEGITIMATELY differ: the first whose
            // lookup falls in a split window.
            let firstLegit = try #require(g.lookups.indices.first { inside(g.lookups[$0], w) })
            let fSplit = g.frames[firstLegit]
            let before = Self.bitDiff(a, b, from: 0, to: fSplit)
            let all = Self.bitDiff(a, b)
            let firstHopF = (outsideDiff + insideDiff).min().map { g.frames[$0] }
            let causal = all.first.map { first in firstHopF.map { first >= $0 } ?? false } ?? true
            // The brief's literal control: every sample outside the DIRECT reach
            // of the differing hops must be bit-identical to the reference.
            var reach: [(Int, Int)] = []
            for j in (outsideDiff + insideDiff).sorted() {
                let lo = g.frames[j], hi = g.frames[j] + interval + block
                if let last = reach.last, lo <= last.1 { reach[reach.count - 1].1 = max(last.1, hi) }
                else { reach.append((lo, hi)) }
            }
            var outsideReach = 0, lastOutside: Int?, maxOutside = 0.0
            var cursor = 0
            for (lo, hi) in reach + [(a.count, a.count)] {
                let d = Self.bitDiff(a, b, from: cursor, to: lo)
                outsideReach += d.differing
                if let l = d.last { lastOutside = l }
                maxOutside = max(maxOutside, d.maxAbs)
                cursor = hi
            }
            let dbfs = maxOutside > 0 ? 20 * log10(maxOutside) : -999
            Self.log(String(format: "INVARIANCE %@ vs %@ (h = %.0f ms): hops differing OUTSIDE the split windows %ld (must be 0), inside %ld of %ld; audio before the first split-window hop (F = %ld, %.3f s): %@; first differing sample %@ vs first differing hop F %@ -> causal %@; samples differing OUTSIDE the differing hops' direct reach [F, F + hop + block): %ld, last %@, max |diff| %.1f dBFS",
                             key as NSString, refKey as NSString, h * 1000, outsideDiff.count, insideDiff.count,
                             g.frames.count, fSplit, Double(fSplit) / sr, before.description as NSString,
                             (all.first.map(String.init) ?? "none") as NSString,
                             (firstHopF.map(String.init) ?? "none") as NSString,
                             (causal ? "yes" : "NO") as NSString, outsideReach,
                             (lastOutside.map(String.init) ?? "none") as NSString, dbfs))
            invariance["\(key)~\(refKey)"] = [
                "halfRampMs": h * 1000, "hopsDifferingOutsideSplitWindows": outsideDiff.count,
                "hopsDifferingOutsideTimes": outsideDiff.map { Double(g.lookups[$0]) / sr },
                "hopsDifferingInsideSplitWindows": insideDiff.count, "hops": g.frames.count,
                "firstSplitWindowHopFrame": fSplit, "audioBeforeFirstSplitWindowBitExact": before.bitExact,
                "audioBeforeFirstSplitWindowDiffering": before.differing,
                "firstDifferingSample": all.first ?? -1, "firstDifferingHopFrame": firstHopF ?? -1,
                "causal": causal, "samplesDifferingOutsideDirectReach": outsideReach,
                "lastSampleDifferingOutsideDirectReach": lastOutside ?? -1,
                "maxAbsDiffOutsideDirectReachDbfs": dbfs,
                "totalDifferingSamples": all.differing,
            ]
            if key != "plant" {
                #expect(outsideDiff.isEmpty, "\(key): the harness changed a hop outside every split run")
                #expect(before.bitExact, "\(key): audio differs before the first split window")
                #expect(causal, "\(key): audio differs before the first differing hop")
            }
        }
        for key in ["d", "aT", "b", "aN"] { try compare(key, against: "c", h: ht.retuneMs / 2000) }
        try compare("natAfter", against: "natBefore", h: nat.retuneMs / 2000)
        // THE PLANT: the same controls on an isolated copy with +50 c on unsplit
        // run 3. Both must FAIL — a control that cannot fail is not a control.
        try compare("plant", against: "c", h: ht.retuneMs / 2000)
        let plantRow = try #require(invariance["plant~c"] as? [String: Any])
        let plantOutside = try #require(plantRow["hopsDifferingOutsideSplitWindows"] as? Int)
        let plantBefore = try #require(plantRow["audioBeforeFirstSplitWindowBitExact"] as? Bool)
        #expect(plantOutside > 0 && !plantBefore,
                "the invariance control did not catch the planted +50 c on unsplit run 3")
        Self.log("PLANT: +50 c on unsplit run 3 in an isolated copy of (a-T) — curve control flags \(plantOutside) hops outside every split window, audio control \(plantBefore ? "MISSED it" : "flags audio before the first split window") -> \(plantOutside > 0 && !plantBefore ? "CAUGHT by both" : "NOT CAUGHT")")

        // ── THE STRETCHER'S MEMORY, measured on the one pair that differs in a
        //    single early run and nowhere else: the plant vs (a-T). ────────────
        let gp = try #require(grids["plant"]), gaT = try #require(grids["aT"])
        let plantHops = zip(gp.floatBits, gaT.floatBits).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let lastPlantHop = try #require(plantHops.last)
        let run3Window = (take.runs[3].startSeconds - ht.retuneMs / 2000,
                          take.runs[3].endSeconds + ht.retuneMs / 2000)
        #expect(plantHops.allSatisfy {
            let t = Double(gp.lookups[$0]) / sr
            return t >= run3Window.0 && t <= run3Window.1
        }, "a plant hop differs outside run 3's ramped window")
        let reachEnd = gp.frames[lastPlantHop] + interval + block
        let pa = try #require(audio["plant"]), aT = try #require(audio["aT"])
        let afterReach = Self.bitDiff(pa, aT, from: reachEnd)
        let tailStart = pa.count - Int(sr)
        var diffEnergy = 0.0, refEnergy = 0.0
        for i in tailStart..<pa.count {
            let d = Double(pa[i]) - Double(aT[i])
            diffEnergy += d * d
            refEnergy += Double(aT[i]) * Double(aT[i])
        }
        let tailDb = diffEnergy > 0 ? 10 * log10(diffEnergy / refEnergy) : -999
        Self.log(String(format: "MEMORY: plant vs (a-T) differ in %ld hops, all inside run 3's window (%.3f–%.3f s); after the last one's direct reach (sample %ld, %.3f s) %@; over the file's LAST second the difference is %.1f dB re the signal",
                         plantHops.count, Double(gp.lookups[plantHops[0]]) / sr, Double(gp.lookups[lastPlantHop]) / sr,
                         reachEnd, Double(reachEnd) / sr, afterReach.description as NSString, tailDb))

        // ── THE STAIRCASE'S OWN CURVE FACTS (the harness finds out, §10 item 7) ─
        let stairCurve = contour.curve(editSet: staircase, clipPitchShiftSemitones: 0)
        let unresolved = Set(stairCurve.unresolvedShapingSegmentIDs)
        let unresolvedStairs = staircase.segments.filter { unresolved.contains($0.id) }
        Self.log("STAIRCASE: \(stairs.count) note-stairs over the 7 transitions; \(unresolvedStairs.count) of them are single-frame stairs the curve cannot shape (fewer than 2 contour frames, PitchCorrection.swift:1207 — constant offset only): " +
                 unresolvedStairs.map { String(format: "%.3f s", $0.startSeconds) }.joined(separator: ", "))

        // ── MANIFEST for the physics and the page ──────────────────────────────
        func describe(_ set: PitchEditSet) -> [[String: Any]] {
            set.segments.map { s in
                let midi = PitchCorrectionMath.midi(fromHz: s.detectedHz)
                return ["start": s.startSeconds, "end": s.endSeconds, "detectedHz": s.detectedHz,
                        "detectedMidi": midi, "offsetCents": s.pitchOffsetCents,
                        "targetMidi": midi + s.pitchOffsetCents / 100, "drift": s.driftScale,
                        "vibrato": s.vibratoScale, "unresolvedShaping": unresolved.contains(s.id),
                        "role": roles[s.id] ?? "?"]
            }
        }
        var renders: [[String: Any]] = [["key": "uncorrected", "file": "00-uncorrected.wav",
                                         "what": "zero-curve product loop (nothing asked of it)"]]
        for entry in sets {
            renders.append(["key": entry.key, "file": entry.file, "retuneMs": entry.set.retuneMs,
                            "segmentCount": entry.set.segments.count,
                            "needsDetectedContour": entry.set.needsDetectedContour,
                            "segments": describe(entry.set)])
        }
        let manifest: [String: Any] = [
            "what": "p2-seg item L listening renders (NoteSplitListeningTests pass 2)",
            "sampleRate": sr, "hopFrames": interval, "lookupOffsetFrames": lookupOffset,
            "blockFrames": block, "renders": renders, "staircase": stairs,
            "controls": controls, "invariance": invariance,
            "memory": ["plantHops": plantHops.count, "reachEndFrame": reachEnd,
                       "differingAfterReach": afterReach.differing,
                       "lastDifferingSample": afterReach.last ?? -1,
                       "maxAbsAfterReachDbfs": afterReach.maxAbs > 0 ? afterReach.maxAbsDbfs : -999,
                       "lastSecondDiffDbReSignal": tailDb],
            "gridReplicaBitExact": dReplica.bitExact,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: take.outDir.appendingPathComponent("manifest.json"))
        Self.log("wrote \(sets.count + 1) WAVs and manifest.json to \(take.outDir.path)")
    }

    // MARK: - Pass 3 (p2-seg S2): the PRODUCT's splitter and slide shapes against L's renders

    /// The voiced run a hop's lookup second belongs to, for a diagnosis line: the
    /// run that CONTAINS it, else the nearest run whose ramped window
    /// `[start − h, end + h]` holds it (two windows overlap when a gap is under
    /// 2h), else the nearest run, flagged as outside.
    static func run(atSecond t: Double, runs: [VoicedRun], halfRamp h: Double) -> (index: Int, inside: Bool) {
        if let i = runs.firstIndex(where: { t >= $0.startSeconds && t < $0.endSeconds }) { return (i, true) }
        func distance(_ r: VoicedRun) -> Double { min(abs(t - r.startSeconds), abs(t - r.endSeconds)) }
        let nearest = runs.indices.min { distance(runs[$0]) < distance(runs[$1]) } ?? 0
        let inside = runs.indices.contains(nearest)
            && t >= runs[nearest].startSeconds - h && t <= runs[nearest].endSeconds + h
        return (nearest, inside)
    }

    /// Pass 3 — added by p2-seg S2 (design §15.5; S2 brief, amendment 2).
    ///
    /// Passes 1–2 built their edit sets by hand from S1's python cut list. This
    /// pass builds them with the PRODUCT — `PitchAutoCorrect.editSet`, i.e.
    /// `PitchNoteSplitter` plus `PitchSlideShape` — renders each through the same
    /// product path, and compares with L's WAVs in `NOTESPLIT_LISTEN_OUT`:
    ///
    ///     (c) → 01-today   (d) → 02-straight   (a-T) → 03-slide-kept
    ///     (a-N) → 05-in-between   Natural with the split → 07-natural-after
    ///
    /// Same parts and same arithmetic give the same bytes, so the target is
    /// BIT-EXACT, and it is asserted for (d), (a-T), (a-N) and Natural. (c) is the
    /// exception BY CONSTRUCTION, measured rather than assumed: L's 01-today is the
    /// pre-p2-seg table (one segment per run), while the product's (c) is design
    /// §3.2's "(c) on the split table" (one segment per PART, every part locked to
    /// the run's note). Each part holds its shaping at its own edge and crossfades
    /// with its neighbour where one segment interpolated straight through, so the
    /// two may differ inside a split run; for (c) this pass asserts L's three
    /// invariance controls instead (§15.3) and reports the first differing hop.
    ///
    /// Also: the product's parts against `parts.json` run by run (kinds, frame
    /// counts, and every boundary, centre and confidence BIT FOR BIT — a
    /// float-level difference is a finding, not a pass), the product's edit sets
    /// against L's (rebuilt with pass 2's own builder and closures), a negative
    /// control, and a planted +50 c that the diagnosis must localise.
    ///
    /// Writes its renders to `NOTESPLIT_LISTEN_OUT/pass3/` (the durable folder,
    /// never the repo) and deletes its render cache afterwards.
    @Test("pass 3 — p2-seg S2: the product's splitter and slide shapes reproduce L's renders bit for bit",
          .enabled(if: enabled))
    @MainActor
    func productSplitterReproducesTheListeningSet() async throws {
        let take = try Self.load()
        let sr = take.sampleRate
        let ht = PitchCorrectionPreset.hardTune.options()
        let nat = PitchCorrectionPreset.natural.options()
        try #require(ht.scale == .chromatic && nat.scale == .chromatic)
        let passDir = take.outDir.appendingPathComponent("pass3", isDirectory: true)
        let cacheDir = passDir.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        try FileManager.default.createDirectory(at: passDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = StretchRenderCache(directory: cacheDir)

        // ── 1. PARTS PARITY: the product splitter vs S1's cut list ─────────────
        let parts = PitchNoteSplitter.parts(in: take.detection.frames, frameRateHz: take.detection.frameRateHz)
        let byRun = Dictionary(grouping: parts, by: \.runIndex)
        var partsDiffer: [Int] = []
        var floatLevel: [String] = []
        for (i, file) in take.parts.runs.enumerated() {
            let mine = byRun[i] ?? []
            let mineText = mine.map { "\($0.kind == .held ? "H" : "T")\($0.frameCount)" }.joined(separator: " ")
            let fileText = file.parts.map { "\($0.kind == "transition" ? "T" : "H")\($0.frameCount)" }
                .joined(separator: " ")
            let sameShape = mine.count == file.parts.count && zip(mine, file.parts).allSatisfy {
                ($0.kind == .transition) == ($1.kind == "transition") && $0.frameCount == $1.frameCount
            }
            guard sameShape else {
                partsDiffer.append(i)
                Self.log("PARTS run \(i) (\(file.startSeconds) s): product \(mineText) vs parts.json \(fileText)")
                continue
            }
            for (k, p) in mine.enumerated() {
                let bounds = take.partBounds[i][k]
                let exact = p.startSeconds.bitPattern == bounds.start.bitPattern
                    && p.endSeconds.bitPattern == bounds.end.bitPattern
                    && p.centreHz.bitPattern == take.partHz[i][k].bitPattern
                    && p.medianConfidence.bitPattern == take.partConfidence[i][k].bitPattern
                if !exact {
                    floatLevel.append(String(format: "run %ld part %ld: start %.17g vs %.17g, end %.17g vs %.17g, centre %.17g vs %.17g Hz, confidence %.17g vs %.17g",
                                             i, k, p.startSeconds, bounds.start, p.endSeconds, bounds.end,
                                             p.centreHz, take.partHz[i][k], p.medianConfidence, take.partConfidence[i][k]))
                }
            }
        }
        let splitRuns = byRun.filter { $0.value.count > 1 }.keys.sorted()
        let held = parts.filter { byRun[$0.runIndex]?.count ?? 0 > 1 && $0.kind == .held }.count
        let transitions = parts.filter { $0.kind == .transition }.count
        Self.log("PARTS PARITY: product splitter \(parts.count) parts over \(byRun.count) runs; split runs \(splitRuns) (\(splitRuns.count)), \(held) held + \(transitions) transitions in them; runs whose parts differ from parts.json: \(partsDiffer.count) \(partsDiffer); parts equal in shape but not bit for bit (boundary/centre/confidence): \(floatLevel.count)")
        for line in floatLevel { Self.log("  FLOAT-LEVEL \(line)") }
        #expect(partsDiffer.isEmpty, "the product splitter disagrees with S1's cut list on runs \(partsDiffer)")
        #expect(floatLevel.isEmpty, "a part differs from L's only at float level: a finding, not a pass")
        #expect(parts.count == 59 && splitRuns.count == 12 && held == 22 && transitions == 7,
                "totals \(parts.count)/\(splitRuns.count)/\(held)/\(transitions) vs parts.json's 59/12/22/7")

        // ── 2. THE EDIT SETS: the product's, and L's rebuilt verbatim ──────────
        let product: [(key: String, file: String, set: PitchEditSet)] = [
            ("c", "01-today.wav", PitchAutoCorrect.editSet(from: take.detection, options: ht, slideShape: .runPin)),
            ("d", "02-straight.wav", PitchAutoCorrect.editSet(from: take.detection, options: ht,
                                                              slideShape: .straightToNote)),
            ("aT", "03-slide-kept.wav", PitchAutoCorrect.editSet(from: take.detection, options: ht,
                                                                 slideShape: .slideKeptNoteLocked)),
            ("aN", "05-in-between.wav", PitchAutoCorrect.editSet(from: take.detection, options: ht,
                                                                 slideShape: .inBetweenNote)),
            ("natAfter", "07-natural-after.wav", PitchAutoCorrect.editSet(from: take.detection, options: nat)),
        ]
        // The shipped default IS the user's pick, (a-T).
        #expect(PrePitchNoteSplitReference.firstDifference(
            PitchAutoCorrect.editSet(from: take.detection, options: ht), product[2].set) == nil)
        // L's sets, with pass 2's builder and its transition closures verbatim.
        let today = PrePitchNoteSplitReference.editSet(from: take.detection, options: ht)
        let naturalBefore = PrePitchNoteSplitReference.editSet(from: take.detection, options: nat)
        var roles: [UUID: String] = [:]
        let hz = take.partHz, conf = take.partConfidence
        let lStraight = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            let part = take.parts.runs[i].parts[k]
            let dest = try #require(part.destinationPart)
            try #require(part.`where` == "tail-off" ? dest == k - 1 : dest == k + 1)
            try #require(take.parts.runs[i].parts[dest].kind == "held")
            let detected = PitchCorrectionMath.midi(fromHz: hz[i][k])
            let target = ht.scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: hz[i][dest]))
            return [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k],
                                detectedConfidence: conf[i][k],
                                pitchOffsetCents: ht.strength * (target - detected) * 100,
                                driftScale: 0, vibratoScale: 0)]
        }
        let lSlideKept = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k], detectedConfidence: conf[i][k])]
        }
        let lInBetween = try Self.buildSplit(take, base: today, options: ht, roles: &roles) { i, k, s, e in
            [Self.policySegment(start: s, end: e, hz: hz[i][k], confidence: conf[i][k], options: ht)]
        }
        let lNaturalAfter = try Self.buildSplit(take, base: naturalBefore, options: nat, roles: &roles) { i, k, s, e in
            [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz[i][k], detectedConfidence: conf[i][k])]
        }
        let lSets: [String: PitchEditSet] = ["c": today, "d": lStraight, "aT": lSlideKept,
                                             "aN": lInBetween, "natAfter": lNaturalAfter]
        for entry in product {
            let theirs = try #require(lSets[entry.key])
            let difference = PrePitchNoteSplitReference.firstDifference(entry.set, theirs)
            Self.log("EDIT SET \(entry.key): product \(entry.set.segments.count) segments vs L's \(theirs.segments.count): \(difference ?? "IDENTICAL on every stored field but id")")
            if entry.key != "c" {
                #expect(difference == nil, "\(entry.key): the product's table is not L's: \(difference ?? "")")
            }
        }

        // ── 3. RENDERS (the product path) vs L's WAVs ──────────────────────────
        var audio: [String: [Float]] = [:]
        var verdict: [String: BitDiff] = [:]
        for entry in product {
            let rendered = try await Self.render(entry.set, take: take, cache: cache, label: "pass3 \(entry.key)")
            audio[entry.key] = rendered
            try M23QComparisonPair.writeWAV([rendered], sampleRate: sr,
                                            to: passDir.appendingPathComponent("p3-" + entry.file))
            let theirs = try TestSignals.readFile(take.outDir.appendingPathComponent(entry.file))[0]
            let d = Self.bitDiff(rendered, theirs)
            verdict[entry.key] = d
            Self.log("BIT-EXACT pass 3 \(entry.key) (product splitter + policy) vs wav/\(entry.file) (L): \(d)")
        }
        for key in ["d", "aT", "aN", "natAfter"] {
            let d = try #require(verdict[key])
            #expect(d.bitExact, "\(key) is not bit-exact with L's render: \(d)")
        }
        // NEGATIVE CONTROL: the same comparator on two different shapes must differ.
        let negative = Self.bitDiff(try #require(audio["aT"]),
                                    try TestSignals.readFile(take.outDir.appendingPathComponent("02-straight.wav"))[0])
        Self.log("negative control, pass 3 (a-T) vs wav/02-straight.wav (must differ): \(negative)")
        #expect(!negative.bitExact)

        // ── 4. THE HOP GRID: where each product render departs from L's ────────
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sr)
        var spied: [Int] = []
        _ = try OfflineStretcher.stretchTransposeCurve(
            input: [Array(take.input[0].prefix(Int(sr)))], sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { spied.append($0); return 0 }, formantPreserve: false,
            compensation: compensation)
        try #require(spied.count >= 4)
        let interval = spied[2] - spied[1]
        try #require(interval == 1440, "the hop moved: \(interval) frames")
        let contour = PitchContourCache.renderContour(
            source: take.source, analysisVersion: today.analysisVersion,
            renderCacheDirectory: cacheDir, detector: .product)
        #expect(contour.frames == take.detection.frames)

        /// One product set against one reference set, hop by hop, then audio.
        func diagnose(_ key: String, _ mine: PitchEditSet, against theirs: PitchEditSet,
                      mineAudio: [Float], theirAudio: [Float], h: Double) throws -> [String: Any] {
            let gm = try Self.grid(mine, take: take, contour: contour, interval: interval)
            let gt = try Self.grid(theirs, take: take, contour: contour, interval: interval)
            let differing = zip(gm.floatBits, gt.floatBits).enumerated()
                .filter { $0.element.0 != $0.element.1 }.map(\.offset)
            let windows = take.parts.runs.filter(\.split).map { ($0.startSeconds - h, $0.endSeconds + h) }
            func insideSplit(_ j: Int) -> Bool {
                let t = Double(gm.lookups[j]) / sr
                return windows.contains { t >= $0.0 && t <= $0.1 }
            }
            let outside = differing.filter { !insideSplit($0) }
            guard let first = differing.first else {
                Self.log("GRID \(key): identical to the reference on all \(gm.frames.count) hops")
                return ["hopsDiffering": 0]
            }
            let t = Double(gm.lookups[first]) / sr
            let where_ = Self.run(atSecond: t, runs: take.runs, halfRamp: h)
            let maxCents = differing.map { abs(gm.values[$0] - gt.values[$0]) * 100 }.max() ?? 0
            let firstSplitHop = try #require(gm.lookups.indices.first { insideSplit($0) })
            let before = Self.bitDiff(mineAudio, theirAudio, from: 0, to: gm.frames[firstSplitHop])
            let all = Self.bitDiff(mineAudio, theirAudio)
            let causal = all.first.map { $0 >= gm.frames[first] } ?? true
            // Which runs the differing hops fall in, and how far they move.
            var perRun: [Int: (hops: Int, maxCents: Double)] = [:]
            for j in differing {
                let r = Self.run(atSecond: Double(gm.lookups[j]) / sr, runs: take.runs, halfRamp: h).index
                let c = abs(gm.values[j] - gt.values[j]) * 100
                perRun[r] = ((perRun[r]?.hops ?? 0) + 1, max(perRun[r]?.maxCents ?? 0, c))
            }
            let perRunText = perRun.keys.sorted().map {
                String(format: "run %ld: %ld hops, max %.3g c", $0, perRun[$0]!.hops, perRun[$0]!.maxCents)
            }.joined(separator: "; ")
            Self.log(String(format: "GRID %@: %ld of %ld hops differ from the reference (max |diff| %.4g c); FIRST at hop F = %ld (lookup %.3f s) in run %ld (%@ its ramped window; its parts %@ parts.json); %ld differing hops lie OUTSIDE every split run's window; audio before the first split-window hop (F = %ld): %@; whole file: %@; causal %@",
                             key as NSString, differing.count, gm.frames.count, maxCents, gm.frames[first], t,
                             where_.index, (where_.inside ? "inside" : "OUTSIDE") as NSString,
                             (partsDiffer.contains(where_.index) ? "DIFFER from" : "equal") as NSString,
                             outside.count, gm.frames[firstSplitHop], before.description as NSString,
                             all.description as NSString, (causal ? "yes" : "NO") as NSString))
            Self.log("GRID \(key) per run: \(perRunText)")
            return ["hopsDiffering": differing.count, "firstHopFrame": gm.frames[first], "firstRun": where_.index,
                    "firstInside": where_.inside, "outsideSplitWindows": outside.count,
                    "beforeFirstSplitHopBitExact": before.bitExact, "causal": causal, "maxCents": maxCents,
                    "runs": perRun.keys.sorted()]
        }

        for entry in product {
            let theirs = try #require(lSets[entry.key])
            let h = (entry.key == "natAfter" ? nat : ht).retuneMs / 2000
            let row = try diagnose(entry.key, entry.set, against: theirs,
                                   mineAudio: try #require(audio[entry.key]),
                                   theirAudio: try TestSignals.readFile(take.outDir.appendingPathComponent(entry.file))[0],
                                   h: h)
            if entry.key == "c" {
                // (c) on the split table vs the pre-p2-seg table: L's invariance
                // controls (§15.3) — it may differ ONLY inside a split run.
                #expect(row["outsideSplitWindows"] as? Int == 0, "(c) changed a hop outside every split run")
                #expect(row["beforeFirstSplitHopBitExact"] as? Bool ?? true, "(c) differs before the first split run")
                #expect(row["causal"] as? Bool ?? true, "(c)'s audio differs before its first differing hop")
                if let runs = row["runs"] as? [Int] {
                    #expect(runs.allSatisfy { take.parts.runs[$0].split }, "(c) differs in an unsplit run: \(runs)")
                }
            }
        }

        // ── 5. THE PLANT: +50 c on one held part of an isolated copy of (a-T) ──
        // The diagnosis must localise it: the render departs from L's, and the
        // first differing hop lies in the planted run. The planted part is an
        // INTERIOR one (clear of its run's edges by more than the half-ramp), so
        // its first changed hop cannot sit in a neighbouring run's ramp.
        let edge = ht.retuneMs / 2000
        var plantSegments = product[2].set.segments
        let candidates = splitRuns.compactMap { r -> (run: Int, index: Int)? in
            let run = take.runs[r]
            return plantSegments.firstIndex {
                $0.startSeconds > run.startSeconds + edge && $0.endSeconds < run.endSeconds - edge
                    && $0.pitchOffsetCents != 0 && $0.driftScale == 0
            }.map { (r, $0) }
        }
        let (plantRun, plantIndex) = try #require(candidates.first)
        let original = plantSegments[plantIndex]
        plantSegments[plantIndex] = NoteSegment(
            startSeconds: original.startSeconds, endSeconds: original.endSeconds, detectedHz: original.detectedHz,
            detectedConfidence: original.detectedConfidence, pitchOffsetCents: original.pitchOffsetCents + 50,
            driftScale: original.driftScale, vibratoScale: original.vibratoScale)
        let plant = PitchEditSet(analysisVersion: product[2].set.analysisVersion, segments: plantSegments,
                                 retuneMs: product[2].set.retuneMs)
        let plantAudio = try await Self.render(plant, take: take, cache: cache, label: "pass3 plant")
        let l03 = try TestSignals.readFile(take.outDir.appendingPathComponent("03-slide-kept.wav"))[0]
        let plantVsL = Self.bitDiff(plantAudio, l03)
        let plantRow = try diagnose("plant", plant, against: lSlideKept, mineAudio: plantAudio, theirAudio: l03,
                                    h: ht.retuneMs / 2000)
        Self.log("PLANT: +50 c on run \(plantRun)'s held part at \(original.startSeconds) s in an isolated copy of the product's (a-T) — vs wav/03-slide-kept.wav: \(plantVsL); first differing hop in run \(plantRow["firstRun"] ?? "-")")
        #expect(!plantVsL.bitExact, "the bit-exact comparison did not see a planted +50 c")
        #expect(plantRow["firstRun"] as? Int == plantRun, "the hop diagnosis did not localise the plant")
    }
}
