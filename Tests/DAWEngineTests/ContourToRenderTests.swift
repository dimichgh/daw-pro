import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// contour-to-render (2026-09-24) — **THE DETECTED CONTOUR REACHES THE AUDIO.**
///
/// Before this, `StretchRenderCache.performRender` built every curve with
/// `contour: []`, so drift correction, `vibratoScale` flattening and Hard
/// Tune resolved to nothing: Hard Tune rendered as "a stronger Tight". This
/// suite proves the product path — `StretchRenderCache.renderIfNeeded`, not a
/// test harness — now renders them, and that nothing else moved.
///
/// Reading order, and it is the project's law rather than a preference:
///  * §1 THE KEYS — the invariance half first. Every clip whose output did not
///    change keeps a byte-identical key; every clip whose output did, re-keys,
///    and the contour's inputs are inside that key.
///  * §2 THE SEAM — one function yields the contour; whole file, from source
///    second 0, cached, deterministic, total.
///  * §3 THE PHYSICS — measured on the RENDERED AUDIO with an instrument that
///    is not the detector (`PitchWanderMeter`). Distinct bytes prove nothing.
///    Each physics test carries its own control that must come out the other
///    way.
///  * §4 HARNESS ≡ PRODUCT — what separates the render the user heard from the
///    one the product now makes, decomposed and measured.
///
/// Deliberately NOT `@MainActor` at suite level (`MainActorOccupancySiteTests`
/// Leg C counts suites). The tests that drive the main-actor cache are
/// `@MainActor` one by one.
@Suite("contour-to-render — the detected contour reaches the audio", .serialized)
struct ContourToRenderTests {
    static let sampleRate = 48_000.0

    static func log(_ message: String) { print("contour-to-render| \(message)") }

    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-contour-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A voice-like harmonic tone (SwiftF0 voices these at the PRODUCT's 0.9
    /// threshold; a bare sine sits at ~0.48) whose f0 is `hz(t)`.
    static func tone(seconds: Double, hz: @escaping (Double) -> Double) -> [Float] {
        PitchTrackerAccuracyTests.Fixture.tone(
            seconds: seconds, amplitude: 0.5, partials: 12,
            sampleRate: sampleRate, f0: hz)
    }

    static func write(_ samples: [Float], to url: URL) throws {
        try M23QComparisonPair.writeWAV([samples], sampleRate: sampleRate, to: url)
    }

    /// A sung-like note: `baseHz` planted `detuneCents` sharp, with a
    /// `vibratoHz` ±`depthCents` vibrato. 35 cents sharp is the preset gate's
    /// own choice — far enough from the 50-cent watershed that chromatic
    /// correction cannot pick the neighbouring semitone.
    static func vibratoNote(baseHz: Double = 220, detuneCents: Double = 35,
                            vibratoHz: Double = 5.5, depthCents: Double = 50,
                            seconds: Double = 3.0) -> [Float] {
        tone(seconds: seconds) { t in
            baseHz * pow(2, (detuneCents + depthCents * sin(2 * .pi * vibratoHz * t)) / 1200)
        }
    }

    /// The segments `clip.autoCorrectPitch` would store for an untrimmed clip
    /// of this file: the store detects over the clip's whole window, which for
    /// an untrimmed clip IS the whole file — the same call the seam makes.
    static func autoCorrectSet(_ url: URL, _ preset: PitchCorrectionPreset) throws -> PitchEditSet {
        let detection = try PitchContourCache.detectWholeFile(url, .product)
        return PitchAutoCorrect.editSet(from: detection, options: preset.options())
    }

    /// The uncorrected reference: the same stretcher with nothing asked of it
    /// — the processing every tuned render goes through, minus the tuning.
    static func uncorrected(_ input: [Float]) throws -> [Float] {
        try OfflineStretcher.stretch(input: [input], sampleRate: sampleRate, ratio: 1,
                                     semitones: 0, formantPreserve: false)[0]
    }

    /// A detector whose runs are counted, around the product's own detection.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func counting(_ counter: Counter) -> PitchContourCache.Detector {
        var detector = PitchContourCache.Detector.product
        detector.run = { url, config in
            counter.bump()
            return try PitchContourCache.detectWholeFile(url, config)
        }
        return detector
    }

    struct PlantedDetectorFailure: Error, CustomStringConvertible {
        var description: String { "planted detector failure" }
    }

    /// The product detector with its model taken away — the only failure a
    /// shipped app can actually meet (`scripts/bundle.sh` has been known to
    /// drop the weights' bundle).
    static let failing: PitchContourCache.Detector = {
        var detector = PitchContourCache.Detector.product
        detector.run = { _, _ in throw PlantedDetectorFailure() }
        return detector
    }()

    static func hardTuneSet(analysisVersion: Int = PitchEditSet.currentAnalysisVersion) -> PitchEditSet {
        PitchEditSet(
            analysisVersion: analysisVersion,
            segments: [
                NoteSegment(id: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
                            startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220,
                            detectedConfidence: 0.95, pitchOffsetCents: -35,
                            driftScale: 0, vibratoScale: 0)
            ],
            retuneMs: 30)
    }

    /// The pre-contour key formula, VERBATIM — the golden every clip that
    /// needs no contour must still hit, and the key every contour clip's
    /// FALLBACK must still live at.
    static func preContourKey(source: URL, ratio: Double, semitones: Double,
                              formant: Bool, edits: PitchEditSet?) throws -> String {
        let path = source.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        var fields = [
            path, String(size), String(mtime.bitPattern),
            String(ratio.bitPattern), String(semitones.bitPattern),
            formant ? "1" : "0", String(StretchRenderCache.stretchEngineVersion),
        ]
        let digest = PitchEditSetDigest.hex(edits)
        if !digest.isEmpty { fields.append("pitch:" + digest) }
        var hasher = SHA256()
        for field in fields {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §1 THE KEYS
    // ═══════════════════════════════════════════════════════════════════════

    /// ⭐ **THE INVARIANCE HALF, FIRST.** Nothing that renders the same audio
    /// as before may key differently, or its entry on every user's disk is
    /// orphaned by a feature that did not touch it.
    @Test("§1 every clip that needs no contour keys EXACTLY as it did before")
    func noContourNoNewKey() throws {
        let dir = try Self.tempDir("key-invariance")
        let source = dir.appendingPathComponent("tone.wav")
        try Self.write(Self.tone(seconds: 0.3) { _ in 220 }, to: source)

        var generator = NoteSegment(startSeconds: 0.05, endSeconds: 0.25, detectedHz: 220,
                                    detectedConfidence: 0.9, pitchOffsetCents: -12)
        generator.vibratoRateHz = 5.5
        generator.vibratoDepthCents = 40
        let cases: [(String, PitchEditSet?)] = [
            ("never tuned", nil),
            ("detected, unedited", PitchEditSet(segments: [
                NoteSegment(startSeconds: 0.05, endSeconds: 0.25, detectedHz: 220,
                            detectedConfidence: 0.9)])),
            ("plain offset (the ladder's shape)", PitchEditSet(segments: [
                NoteSegment(startSeconds: 0.05, endSeconds: 0.25, detectedHz: 220,
                            detectedConfidence: 0.9, pitchOffsetCents: -18.8)], retuneMs: 40)),
            ("generator only", PitchEditSet(segments: [generator])),
            ("another detector generation", Self.hardTuneSet(analysisVersion: 7)),
        ]
        for (label, edits) in cases {
            for (ratio, semitones, formant) in [(1.0, 0.0, false), (1.5, 2.0, true)] {
                let params = StretchRenderCache.Params(
                    ratio: ratio, semitones: semitones, formantPreserve: formant, pitchEdits: edits)
                let keys = try StretchRenderCache.renderKeys(source: source, params: params,
                                                             detector: .product)
                let golden = try Self.preContourKey(source: source, ratio: ratio,
                                                    semitones: semitones, formant: formant,
                                                    edits: edits)
                #expect(keys.resolved == golden,
                        "\(label) @ ratio \(ratio): the key MOVED for a clip whose audio did not change — every cached render of it is orphaned")
                #expect(keys.legacy == golden)
                #expect(try StretchRenderCache.cacheKey(source: source, params: params) == golden)
            }
        }
        // Every ladder preset, built the way the door builds it, is in this class.
        for preset in PitchCorrectionPreset.ladder {
            #expect(preset.options().preserveVibrato,
                    "\(preset.rawValue) flattens — it would need the contour and re-key")
        }
    }

    /// ⭐⭐ **THE RE-KEY HALF — AND THE TEST THE PLANTED DEFECT MUST FAIL.**
    /// A contour-shaped render produces DIFFERENT AUDIO than it did before the
    /// contour reached the render (flattened, not a constant offset), so it
    /// must not answer to the old key — and anything that changes the contour
    /// must change the render's key. If `renderKeys` stopped appending the
    /// contour, the old constant-offset render would be served as the fix,
    /// and a detector upgrade would keep serving renders shaped against the
    /// OLD detector's contour.
    @Test("§1 a contour-shaped render re-keys, and every input of its contour is inside the key")
    func contourShapedRenderRekeysOnItsContour() throws {
        let dir = try Self.tempDir("key-rekey")
        let source = dir.appendingPathComponent("tone.wav")
        try Self.write(Self.tone(seconds: 0.5) { _ in 224 }, to: source)
        let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                               pitchEdits: Self.hardTuneSet())
        let product = try StretchRenderCache.renderKeys(source: source, params: params,
                                                        detector: .product)
        let golden = try Self.preContourKey(source: source, ratio: 1, semitones: 0,
                                            formant: false, edits: Self.hardTuneSet())
        #expect(product.legacy == golden,
                "the FALLBACK key moved — the constant-offset render already on disk for this set would be orphaned instead of reused")
        #expect(product.resolved != product.legacy,
                "a contour-shaped render shares the pre-contour key — the old constant-offset audio would be served as the flattened render")

        // The new formula, restated: the legacy fields plus the contour's own key.
        var hasherFields = try StretchRenderCache.sourceIdentityFields(source: source)
        hasherFields += [String(1.0.bitPattern), String(0.0.bitPattern), "0",
                         String(StretchRenderCache.stretchEngineVersion),
                         "pitch:" + PitchEditSetDigest.hex(Self.hardTuneSet()),
                         "contour:" + (try PitchContourCache.key(source: source, detector: .product)),
                         "shaping:\(PitchRenderContour.shapingVersion)"]
        #expect(product.resolved == StretchRenderCache.keyDigest(hasherFields))

        // Every contour input, changed alone, must move the CONTOUR key and
        // the RENDER key, and leave the fallback key where it is — the
        // fallback does not depend on the contour.
        let contourKey = try PitchContourCache.key(source: source, detector: .product)
        typealias Mutation = (String, (inout PitchContourCache.Detector) -> Void)
        let mutations: [Mutation] = [
            ("confidenceThreshold", { $0.confidenceThreshold = 0.5 }),
            ("silenceFloorDbfs", { $0.silenceFloorDbfs = -45 }),
            ("modelSampleRate", { $0.modelSampleRate = 22_050 }),
            ("hopLength", { $0.hopLength = 160 }),
            ("modelIdentity", { $0.modelIdentity = "another-network" }),
            ("runtimeIdentity", { $0.runtimeIdentity = "onnxruntime-0.0.0" }),
        ]
        for (field, mutate) in mutations {
            var detector = PitchContourCache.Detector.product
            mutate(&detector)
            #expect(try PitchContourCache.key(source: source, detector: detector) != contourKey,
                    "changing the detector's \(field) did not re-key the CONTOUR")
            let moved = try StretchRenderCache.renderKeys(source: source, params: params,
                                                          detector: detector)
            #expect(moved.resolved != product.resolved,
                    "changing the detector's \(field) did not re-key the RENDER — a render shaped against the old contour would be served as current")
            #expect(moved.legacy == product.legacy,
                    "\(field) moved the fallback key, which does not depend on the contour")
        }
        // The detector GENERATION re-keys the contour too. (For the render it
        // is the §7.2 mismatch rule instead: a set from another generation is
        // not shaped at all — `noContourNoNewKey` pins that case.)
        var nextGeneration = PitchContourCache.Detector.product
        nextGeneration.analysisVersion += 1
        #expect(try PitchContourCache.key(source: source, detector: nextGeneration) != contourKey)

        // And the source file itself: a rewritten file re-keys both.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: source.path)
        let touched = try StretchRenderCache.renderKeys(source: source, params: params,
                                                        detector: .product)
        #expect(touched.resolved != product.resolved)
        #expect(try PitchContourCache.key(source: source, detector: .product) != contourKey)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §2 THE SEAM
    // ═══════════════════════════════════════════════════════════════════════

    @Test("§2 the seam analyses the WHOLE file from source second 0, and caches exactly what it returns")
    func seamIsWholeFileCachedAndTotal() throws {
        let dir = try Self.tempDir("seam")
        let source = dir.appendingPathComponent("vib.wav")
        let seconds = 2.5
        try Self.write(Self.vibratoNote(seconds: seconds), to: source)
        let cacheDir = dir.appendingPathComponent("renders", isDirectory: true)
        let counter = Counter()
        let detector = Self.counting(counter)

        let first = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: cacheDir, detector: detector)
        let detection = try #require(first.detection, "the seam did not detect: \(first)")
        #expect(counter.count == 1)

        // WHOLE FILE, FROM 0, SOURCE-ABSOLUTE, ON THE DETECTOR'S OWN GRID.
        #expect(detection.windowStartSeconds == 0)
        #expect(detection.frames.first?.timeSeconds == 0)
        #expect(abs(detection.windowDurationSeconds - seconds) < 1e-9,
                "analysed \(detection.windowDurationSeconds) s of a \(seconds) s file")
        let period = 1 / detection.frameRateHz
        for (a, b) in zip(detection.frames, detection.frames.dropFirst()) {
            #expect(abs((b.timeSeconds - a.timeSeconds) - period) < 1e-9)
        }
        // …and all the way to the end of the file, not to a clip's window end.
        let covered = (detection.frames.last?.timeSeconds ?? 0) + period
        #expect(covered > seconds - 2 * period && covered <= seconds + period,
                "the frames cover up to \(covered) s of a \(seconds) s file")
        #expect(detection.voicedFrameCount > detection.frameCount * 9 / 10,
                "the fixture was not voiced at the product threshold")

        // CACHED: the second read runs nothing and returns the same BITS.
        let second = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: cacheDir, detector: detector)
        #expect(counter.count == 1, "a cached contour was detected again")
        let again = try #require(second.detection)
        #expect(again.frames.count == detection.frames.count)
        for (a, b) in zip(detection.frames, again.frames) {
            #expect(a.timeSeconds.bitPattern == b.timeSeconds.bitPattern)
            #expect(a.frequencyHz?.bitPattern == b.frequencyHz?.bitPattern)
            #expect(a.confidence.bitPattern == b.confidence.bitPattern)
        }
        let key = try PitchContourCache.key(source: source, detector: detector)
        let entry = PitchContourCache.directory(inRenderCacheDirectory: cacheDir)
            .appendingPathComponent(key + ".json")
        #expect(FileManager.default.fileExists(atPath: entry.path),
                "the contour is not where the design puts it: beside the renders, keyed by content")

        // A damaged entry is replaced, not trusted and not left blocking.
        try Data("not a contour".utf8).write(to: entry)
        let healed = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: cacheDir, detector: detector)
        #expect(healed.detection?.frames == detection.frames)
        #expect(counter.count == 2, "a corrupt entry must be re-detected")
        #expect(PitchContourCache.read(entry, key: key, detector: detector) != nil)
    }

    @Test("§2 a version mismatch detects nothing; a failure caches nothing; neither invents frames")
    func seamRefusesHonestly() throws {
        let dir = try Self.tempDir("seam-refuse")
        let source = dir.appendingPathComponent("vib.wav")
        try Self.write(Self.vibratoNote(seconds: 1.0), to: source)
        let cacheDir = dir.appendingPathComponent("renders", isDirectory: true)
        let counter = Counter()

        let mismatch = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion + 1,
            renderCacheDirectory: cacheDir, detector: Self.counting(counter))
        #expect(mismatch == .analysisVersionMismatch(
            editSet: PitchEditSet.currentAnalysisVersion + 1,
            detector: PitchEditSet.currentAnalysisVersion))
        #expect(counter.count == 0, "edits from another detector generation were analysed anyway")
        #expect(mismatch.frames.isEmpty)

        let failed = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: cacheDir, detector: Self.failing)
        guard case .unavailable(let reason) = failed else {
            Issue.record("a failing detector produced \(failed)")
            return
        }
        #expect(reason.contains("planted detector failure"))
        #expect(failed.frames.isEmpty)
        let contourDir = PitchContourCache.directory(inRenderCacheDirectory: cacheDir)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: contourDir.path)) ?? []
        #expect(leftovers.isEmpty, "a failed detection left \(leftovers) in the cache")

        // …and the next working call is not blocked by it.
        let later = PitchContourCache.renderContour(
            source: source, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: cacheDir, detector: Self.counting(counter))
        #expect(later.detection != nil)
    }

    /// The cache is only as honest as the detector is deterministic: a purged
    /// entry is re-detected, and a re-detection that came back different would
    /// re-render different audio under the same key. Measured on the real
    /// vocal too (2081 frames bit-identical across two processes); this is the
    /// always-on synthetic leg, plus the codec's own exactness.
    @Test("§2 detection is bit-deterministic, and the cache's codec does not move a bit")
    func detectionIsDeterministic() throws {
        let dir = try Self.tempDir("determinism")
        let source = dir.appendingPathComponent("vib.wav")
        try Self.write(Self.vibratoNote(seconds: 2.0), to: source)
        let a = try PitchContourCache.detectWholeFile(source, .product)
        let b = try PitchContourCache.detectWholeFile(source, .product)
        #expect(a.frames.count == b.frames.count)
        var differing = 0
        for (x, y) in zip(a.frames, b.frames)
        where x.frequencyHz?.bitPattern != y.frequencyHz?.bitPattern
            || x.confidence.bitPattern != y.confidence.bitPattern
            || x.levelDbfs?.bitPattern != y.levelDbfs?.bitPattern
            || x.timeSeconds.bitPattern != y.timeSeconds.bitPattern {
            differing += 1
        }
        #expect(differing == 0, "\(differing) frames differ between two detections of one file")

        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(PitchDetectionResult.self, from: data)
        var moved = 0
        for (x, y) in zip(a.frames, back.frames)
        where x.frequencyHz?.bitPattern != y.frequencyHz?.bitPattern
            || x.confidence.bitPattern != y.confidence.bitPattern
            || x.levelDbfs?.bitPattern != y.levelDbfs?.bitPattern
            || x.timeSeconds.bitPattern != y.timeSeconds.bitPattern {
            moved += 1
        }
        #expect(moved == 0, "the JSON round trip moved \(moved) frames' bits")
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §3 THE PHYSICS, THROUGH THE PRODUCT PATH
    // ═══════════════════════════════════════════════════════════════════════

    /// Renders `clip` through a real `StretchRenderCache` — debounce, detached
    /// job, contour fetch-or-detect, CAF commit — and reads the CAF back.
    @MainActor
    static func productRender(_ clip: Clip, cache: StretchRenderCache) async throws
    -> (audio: [Float], url: URL) {
        let url = try await cache.renderIfNeeded(
            clipID: clip.id, source: try #require(clip.audioFileURL),
            params: .init(clip: clip))
        return (try TestSignals.readFile(url)[0], url)
    }

    /// ⭐⭐ **THE GATE.** A clip carrying a Hard Tune edit set, rendered by the
    /// product's own cache, comes back with its within-note wander cut — and
    /// the SAME clip rendered with the contour unavailable does not. Measured
    /// on the audio, against the uncorrected render of the same file.
    @Test("§3 Hard Tune through StretchRenderCache flattens the sung wobble; without the contour it does not")
    @MainActor
    func hardTuneFlattensThroughTheProductPath() async throws {
        let dir = try Self.tempDir("hardtune")
        let source = dir.appendingPathComponent("sung.wav")
        let input = Self.vibratoNote()
        try Self.write(input, to: source)
        let hard = try Self.autoCorrectSet(source, .hardTune)
        let tight = try Self.autoCorrectSet(source, .tight)
        try #require(hard.segments.count == 1, "the fixture segmented into \(hard.segments.count) notes")
        #expect(hard.needsDetectedContour && !tight.needsDetectedContour)

        let before = PitchWanderMeter.readNotes(try Self.uncorrected(input),
                                                sampleRate: Self.sampleRate,
                                                segments: hard.segments)
        let cache = StretchRenderCache(directory: try Self.tempDir("hardtune-cache"))
        let hardClip = Clip(name: "sung", audioFileURL: source, pitchEdits: hard)
        let flattened = try await Self.productRender(hardClip, cache: cache)
        let tuned = try await Self.productRender(
            Clip(name: "sung", audioFileURL: source, pitchEdits: tight), cache: cache)
        #expect(cache.contourShortfall(source: source, params: .init(clip: hardClip)) == nil,
                "the healthy render reported a fallback")
        #expect(flattened.url.lastPathComponent
                == (try StretchRenderCache.renderKeys(
                    source: source, params: .init(clip: hardClip), detector: .product)
                    .resolved) + ".caf",
                "the flattened render was not committed at the key that names its contour")

        let hardCmp = try #require(PitchWanderMeter.compare(
            before: before,
            after: PitchWanderMeter.readNotes(flattened.audio, sampleRate: Self.sampleRate,
                                              segments: hard.segments)))
        let tightCmp = try #require(PitchWanderMeter.compare(
            before: before,
            after: PitchWanderMeter.readNotes(tuned.audio, sampleRate: Self.sampleRate,
                                              segments: hard.segments)))

        // The CONTROL: the same Hard Tune clip, the contour unavailable.
        let blind = StretchRenderCache(directory: try Self.tempDir("hardtune-blind"),
                                       contourDetector: Self.failing)
        let blindClip = Clip(name: "sung", audioFileURL: source, pitchEdits: hard)
        let fellBack = try await Self.productRender(blindClip, cache: blind)
        let blindCmp = try #require(PitchWanderMeter.compare(
            before: before,
            after: PitchWanderMeter.readNotes(fellBack.audio, sampleRate: Self.sampleRate,
                                              segments: hard.segments)))

        let centreHz = try #require(PitchWanderMeter.readNotes(
            flattened.audio, sampleRate: Self.sampleRate, segments: hard.segments).first?.medianHz)
        Self.log(String(format:
            "hardTune %.1f -> %.1f c (%.0f%%)  tight %.1f -> %.1f c (%.0f%%)  hardTune-without-contour %.1f -> %.1f c (%.0f%%)  hardTune centre %.2f Hz (%+.1f c from A3)",
            hardCmp.beforeWanderCents, hardCmp.afterWanderCents, hardCmp.medianReduction * 100,
            tightCmp.beforeWanderCents, tightCmp.afterWanderCents, tightCmp.medianReduction * 100,
            blindCmp.beforeWanderCents, blindCmp.afterWanderCents, blindCmp.medianReduction * 100,
            centreHz, 1200 * log2(centreHz / 220)))

        // THE CLAIM.
        #expect(hardCmp.medianReduction >= 0.45,
                "Hard Tune through the product path cut the wander by only \(Int(hardCmp.medianReduction * 100))% (\(hardCmp.beforeWanderCents) -> \(hardCmp.afterWanderCents) cents) — the contour is not reaching the audio")
        #expect(hardCmp.afterWanderCents < 20)
        // …on pitch, to the detector's own ±12.9-cent resolution.
        #expect(abs(1200 * log2(centreHz / 220)) < 12.9)
        // DISTINCT FROM TIGHT, on the axis Hard Tune exists for.
        #expect(tightCmp.medianReduction < 0.10,
                "Tight flattened the wobble (\(Int(tightCmp.medianReduction * 100))%) — it must keep it")
        #expect(hardCmp.afterWanderCents < tightCmp.afterWanderCents * 0.6)
        // THE CONTROL COMES OUT THE OTHER WAY — so the claim above is about
        // the contour, not about some other difference between the renders.
        #expect(blindCmp.medianReduction < 0.10,
                "with the contour unavailable Hard Tune still cut the wander by \(Int(blindCmp.medianReduction * 100))% — the gate cannot tell a contour from none")
        #expect(blind.contourShortfall(source: source, params: .init(clip: blindClip))?
                    .contains("planted detector failure") == true)
    }

    /// ⭐ **THE FALLBACK IS THE PRE-CONTOUR RENDER, WHERE THE PRE-CONTOUR KEY
    /// PUT IT — and it does not outlive the session.** Never silence, never a
    /// degraded render served as fresh.
    @Test("§3 an unavailable contour commits the byte-identical legacy render at the legacy key, and the next session retries")
    @MainActor
    func fallbackIsTheLegacyRender() async throws {
        let dir = try Self.tempDir("fallback")
        let source = dir.appendingPathComponent("sung.wav")
        let input = Self.vibratoNote(seconds: 1.5)
        try Self.write(input, to: source)
        let hard = try Self.autoCorrectSet(source, .hardTune)
        let clip = Clip(name: "sung", audioFileURL: source, pitchEdits: hard)
        let params = StretchRenderCache.Params(clip: clip)
        let cacheDir = try Self.tempDir("fallback-cache")

        let blind = StretchRenderCache(directory: cacheDir, contourDetector: Self.failing)
        let fell = try await blind.renderIfNeeded(clipID: clip.id, source: source, params: params)
        let keys = try StretchRenderCache.renderKeys(source: source, params: params,
                                                     detector: .product)
        #expect(fell.lastPathComponent == keys.legacy + ".caf",
                "the fallback was committed at \(fell.lastPathComponent), not the pre-contour key")
        #expect(!FileManager.default.fileExists(
            atPath: cacheDir.appendingPathComponent(keys.resolved + ".caf").path),
                "the fallback was written under the RESOLVED key — it would be served as the flattened render forever")
        #expect(blind.cachedURL(source: source, params: params) == fell,
                "the engine's lookup does not find the fallback — the clip would play silence")
        #expect(blind.contourShortfall(source: source, params: params)?
                    .contains("planted detector failure") == true,
                "the fallback plays and nothing says why")

        // BYTE-IDENTICAL to what the pre-contour code rendered for this set.
        let legacyPlan = try #require(StretchCurvePlan.make(
            editSet: hard, clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1))
        #expect(legacyPlan.curve.unresolvedShapingSegmentIDs.count == hard.segments.count)
        let legacy = try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: Self.sampleRate, ratio: 1,
            semitonesAtOutputFrame: { legacyPlan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: Self.sampleRate))[0]
        let committed = try TestSignals.readFile(fell)[0]
        #expect(committed.count == legacy.count)
        var differing = 0
        for (a, b) in zip(committed, legacy) where a.bitPattern != b.bitPattern { differing += 1 }
        #expect(differing == 0, "\(differing) samples of the fallback differ from the pre-contour render")

        // NEXT SESSION, detector healthy: the flattened render is made, at the
        // resolved key, and the fallback is not what plays.
        let healthy = StretchRenderCache(directory: cacheDir)
        #expect(healthy.cachedURL(source: source, params: params) == nil,
                "a new session found the fallback and would never retry detection")
        #expect(healthy.contourShortfall(source: source, params: params) == nil,
                "a new session reports the OLD session's failure before it has even retried")
        let resolved = try await healthy.renderIfNeeded(clipID: clip.id, source: source,
                                                        params: params)
        #expect(resolved.lastPathComponent == keys.resolved + ".caf")
        #expect(healthy.contourShortfall(source: source, params: params) == nil)
        let shaped = try TestSignals.readFile(resolved)[0]
        var changed = 0
        for (a, b) in zip(shaped, legacy) where a != b { changed += 1 }
        #expect(changed > 0, "the resolved render is the fallback's audio")
    }

    /// ⭐ **A FALLBACK SERVED FROM DISK IS STILL SAID OUT LOUD.** Edits from
    /// another detector generation are never shaped (§7.2), so their render
    /// is the constant-offset one under the unchanged legacy key — and in a
    /// LATER session it is served straight from disk with no job at all. A
    /// notice only a completed render could raise would go quiet exactly
    /// then, which is the silent substitution §7.2 forbids. This pins that
    /// the shortfall is answered from what is COMMITTED, and that the
    /// engine's bounce says it with no render running.
    @Test("§3 another detector generation's edits are reported at lookup — even served from disk in a later session, with no render")
    @MainActor
    func mismatchIsReportedWithoutARender() async throws {
        let dir = try Self.tempDir("mismatch")
        let source = dir.appendingPathComponent("sung.wav")
        try Self.write(Self.vibratoNote(seconds: 1.0), to: source)
        let cacheDir = try Self.tempDir("mismatch-cache")
        let counter = Counter()
        let foreign = Self.hardTuneSet(analysisVersion: PitchEditSet.currentAnalysisVersion + 1)
        let clip = Clip(name: "old take", startBeat: 0, lengthBeats: 2,
                        audioFileURL: source, pitchEdits: foreign)
        let params = StretchRenderCache.Params(clip: clip)
        let keys = try StretchRenderCache.renderKeys(source: source, params: params,
                                                     detector: .product)
        #expect(keys.resolved == keys.legacy)

        // Session 1 renders it: constant offset, legacy key, nothing detected.
        let first = StretchRenderCache(directory: cacheDir, contourDetector: Self.counting(counter))
        let url = try await first.renderIfNeeded(clipID: clip.id, source: source, params: params)
        #expect(url.lastPathComponent == keys.legacy + ".caf")
        #expect(counter.count == 0, "edits from another detector generation were analysed")
        let reason = try #require(first.contourShortfall(source: source, params: params))
        #expect(reason.contains("v\(PitchEditSet.currentAnalysisVersion + 1)"))

        // Session 2: served from disk, no job — and STILL reported.
        let second = StretchRenderCache(directory: cacheDir, contourDetector: Self.counting(counter))
        #expect(second.cachedURL(source: source, params: params) == url)
        #expect(second.contourShortfall(source: source, params: params) == reason,
                "a fallback served from disk in a later session goes unreported")

        // The ENGINE says it with no render running — a bounce through session 2.
        let engine = AudioEngine()
        engine.stretchCache = second
        var notices: [EngineNoticeEvent] = []
        engine.engineNoticeHandler = { notices.append($0) }
        let out = try Self.tempDir("mismatch-out").appendingPathComponent("mix.wav")
        let tempo = TempoMap(constantBPM: 120)
        _ = try await engine.renderMixdown(
            tracks: [Track(name: "T", kind: .audio, clips: [clip])], tempoMap: tempo,
            masterVolume: 1, fromBeat: 0, durationSeconds: 1.0, to: out)
        #expect(second.renderCount == 0,
                "the bounce re-rendered instead of playing the committed fallback")
        let posted = notices.filter { $0.code == "clip-pitch-contour-unavailable" }
        #expect(posted.count == 1, "the bounce posted \(posted.count) contour notices")
        #expect(posted.first?.message.contains("'old take'") == true)
        #expect(posted.first?.message.contains(reason) == true)
        // …and the bounce is AUDIBLE — the fallback, never silence.
        let bounced = try TestSignals.readFile(out)[0]
        #expect(TestSignals.rms(bounced, in: 12_000..<36_000) > 0.05)

        // CONTROL: the same bounce of a clip whose edits ask for no
        // flattening says nothing — the notice is about the contour, not
        // about pitch edits in general.
        notices.removeAll()
        let plain = Clip(name: "plain take", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                         pitchEdits: PitchEditSet(segments: [
                            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220,
                                        detectedConfidence: 0.95, pitchOffsetCents: -35)],
                                                  retuneMs: 40))
        _ = try await engine.renderMixdown(
            tracks: [Track(name: "T", kind: .audio, clips: [plain])], tempoMap: tempo,
            masterVolume: 1, fromBeat: 0, durationSeconds: 1.0, to: out)
        #expect(!notices.contains { $0.code == "clip-pitch-contour-unavailable" })
    }

    /// The other shortfall, through the ENGINE: a current-generation Hard Tune
    /// clip whose contour cannot be detected bounces its constant-offset
    /// fallback — audibly — and the bounce says why, naming the clip.
    @Test("§3 the engine's bounce reports an unavailable contour with its reason, and bounces the fallback, not silence")
    @MainActor
    func bounceReportsAnUnavailableContour() async throws {
        let dir = try Self.tempDir("bounce-unavailable")
        let source = dir.appendingPathComponent("sung.wav")
        try Self.write(Self.vibratoNote(seconds: 1.0), to: source)
        let clip = Clip(name: "lead vocal", startBeat: 0, lengthBeats: 2,
                        audioFileURL: source, pitchEdits: Self.hardTuneSet())
        let cache = StretchRenderCache(directory: try Self.tempDir("bounce-unavailable-cache"),
                                       contourDetector: Self.failing)
        let engine = AudioEngine()
        engine.stretchCache = cache
        var notices: [EngineNoticeEvent] = []
        engine.engineNoticeHandler = { notices.append($0) }
        let out = try Self.tempDir("bounce-unavailable-out").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [Track(name: "T", kind: .audio, clips: [clip])],
            tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: out)
        let posted = notices.filter { $0.code == "clip-pitch-contour-unavailable" }
        #expect(posted.count == 1, "the bounce posted \(posted.count) contour notices")
        #expect(posted.first?.message.contains("'lead vocal'") == true)
        #expect(posted.first?.message.contains("planted detector failure") == true)
        #expect(cache.renderCount == 1)
        let bounced = try TestSignals.readFile(out)[0]
        #expect(TestSignals.rms(bounced, in: 12_000..<36_000) > 0.05,
                "the fallback bounced as silence")
    }

    /// ⭐ **THE BORING INVARIANCE CONTROL — historically the one that catches
    /// the bug.** `vibratoScale: 0` on ONE note of three flattens THAT note in
    /// the product render and leaves its neighbours' wobble alone.
    ///
    /// **Measured 2026-09-24:** the edited note (B3, ±45 c at 5.5 Hz) comes
    /// back 31.35 → 20.57 c — a 34 % cut, not Hard Tune's ~50 %, and that is
    /// understood rather than tolerated: with `driftScale` left at 1 the
    /// 250 ms drift separator hands 121 % of a 5.5 Hz wobble to "vibrato",
    /// and at B3 SwiftF0 reads 97 % of the depth, so the curve over-corrects;
    /// the same edit at A3, where the detector reads 80 %, cuts 56 %
    /// (`PitchRenderContour.shapingVersion`'s doc carries the sweep). The
    /// neighbours come back 0.00 c from where they were, in wander AND centre.
    /// The bound below is set from that measurement with margin; the planted
    /// no-contour defect leaves the note at ~0 % and fails it.
    @Test("§3 vibratoScale 0 on one note flattens that note and leaves its neighbours alone")
    @MainActor
    func oneNoteVibratoScaleZero() async throws {
        let dir = try Self.tempDir("one-note")
        let source = dir.appendingPathComponent("three.wav")
        let noteSeconds = 0.9, gapSeconds = 0.3
        let centres = [220.0, 246.94, 261.63]
        var input: [Float] = []
        for (i, hz) in centres.enumerated() {
            input += Self.tone(seconds: noteSeconds) { t in
                hz * pow(2, 45 * sin(2 * .pi * 5.5 * t) / 1200)
            }
            if i < centres.count - 1 {
                input += [Float](repeating: 0, count: Int(gapSeconds * Self.sampleRate))
            }
        }
        try Self.write(input, to: source)
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames,
                                               frameRateHz: detection.frameRateHz)
        try #require(runs.count == 3, "the three-note fixture segmented into \(runs.count) notes")
        // p2-seg §5.2 (design 2026-09-24-pitch-note-splitting.md), on the REAL
        // detector's frames: three ±45 c vibrato notes change pitch nowhere
        // inside, so the note splitter returns each run whole and both note-table
        // builders write the pre-p2-seg table field by field.
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: detection.frames,
                                                                       frameRateHz: detection.frameRateHz)
        #expect(invariance.isEmpty, "\(invariance.prefix(3))")
        let segments = runs.enumerated().map { index, run in
            NoteSegment(startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                        detectedHz: run.centreHz, detectedConfidence: run.medianConfidence,
                        vibratoScale: index == 1 ? 0 : 1)
        }
        let set = PitchEditSet(segments: segments, retuneMs: 30)
        #expect(set.needsDetectedContour && !set.isIdentity)

        let cache = StretchRenderCache(directory: try Self.tempDir("one-note-cache"))
        let rendered = try await Self.productRender(
            Clip(name: "three", audioFileURL: source, pitchEdits: set), cache: cache)
        let before = PitchWanderMeter.readNotes(try Self.uncorrected(input),
                                                sampleRate: Self.sampleRate, segments: set.segments)
        let after = PitchWanderMeter.readNotes(rendered.audio, sampleRate: Self.sampleRate,
                                               segments: set.segments)
        try #require(before.count == 3 && after.count == 3)
        for i in 0..<3 {
            Self.log(String(format: "note %d (%@): wander %.2f -> %.2f c, centre %.2f -> %.2f Hz",
                            i + 1, (i == 1 ? "vibratoScale 0" : "untouched") as NSString,
                            before[i].spreadCents, after[i].spreadCents,
                            before[i].medianHz, after[i].medianHz))
        }
        // The edited note is flattened (measured 34 %; the bound is 20 %)…
        #expect(after[1].spreadCents < before[1].spreadCents * 0.8,
                "vibratoScale 0 left note 2 at \(after[1].spreadCents) of \(before[1].spreadCents) cents")
        // …and the neighbours are not touched: their wobble and their centre
        // are where the uncorrected render has them.
        for i in [0, 2] {
            #expect(abs(after[i].spreadCents - before[i].spreadCents) < 1.5,
                    "note \(i + 1) was never edited and its wander moved \(before[i].spreadCents) -> \(after[i].spreadCents) cents")
            #expect(abs(1200 * log2(after[i].medianHz / before[i].medianHz)) < 1.5,
                    "note \(i + 1) was never edited and its centre moved")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - §4 HARNESS ≡ PRODUCT
    // ═══════════════════════════════════════════════════════════════════════

    /// The listening files the user heard were made by `M23QComparisonPair`,
    /// which samples the curve onto a 1440-frame grid from frame 0 and
    /// sample-and-holds it, and built that curve with no frame-centre offset.
    /// The product evaluates the curve AT each hop's lookup frame and places
    /// every detector value at its frame's centre. This decomposes the gap:
    ///
    ///  (C) harness fed the product's own lookups → BIT-IDENTICAL, so the
    ///      mechanism is shared and nothing else differs;
    ///  (B) harness grid, product curve → the grid's effect alone;
    ///  (A) the harness exactly as the user heard it → grid + offset.
    @Test("§4 harness ≡ product: identical given the same lookups; the two named differences measured")
    @MainActor
    func harnessMatchesProduct() async throws {
        let dir = try Self.tempDir("harness")
        let source = dir.appendingPathComponent("sung.wav")
        let input = Self.vibratoNote()
        try Self.write(input, to: source)
        let hard = try Self.autoCorrectSet(source, .hardTune)
        let cache = StretchRenderCache(directory: try Self.tempDir("harness-cache"))
        let product = try await Self.productRender(
            Clip(name: "sung", audioFileURL: source, pitchEdits: hard), cache: cache)
        let contour = PitchContourCache.renderContour(
            source: source, analysisVersion: hard.analysisVersion,
            renderCacheDirectory: cache.directory, detector: .product)
        let plan = try #require(StretchCurvePlan.make(
            editSet: hard, clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate,
            ratio: 1, contour: contour))
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: Self.sampleRate)
        let interval = 1440

        // (C) breakpoints at EXACTLY the frames the product looks up.
        var lookups: [(outputFrame: Int, semitones: Double)] = []
        var outFrame = 0
        while outFrame <= input.count + interval {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: outFrame, compensation: compensation, intervalSamples: interval)
            lookups.append((lookup, plan.semitones(atOutputFrame: lookup)))
            outFrame += interval
        }
        let exact = try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: Self.sampleRate, ratio: 1, curve: lookups,
            formantPreserve: false, compensation: compensation)[0]
        var exactDiffering = 0
        for (a, b) in zip(exact, product.audio) where a.bitPattern != b.bitPattern {
            exactDiffering += 1
        }
        #expect(exact.count == product.audio.count)
        #expect(exactDiffering == 0,
                "the harness fed the product's own lookups differs in \(exactDiffering) samples — the product path is doing something the harness mechanism is not")

        // (B) and (A): the harness's own grid.
        func harnessGrid(_ curve: PitchCorrectionCurve) -> [(outputFrame: Int, semitones: Double)] {
            stride(from: 0, to: input.count, by: interval).map {
                ($0, curve.semitones(atSourceSecond: Double($0) / Self.sampleRate))
            }
        }
        let gridProductCurve = try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: Self.sampleRate, ratio: 1,
            curve: harnessGrid(plan.curve), formantPreserve: false,
            compensation: compensation)[0]
        let asHeard = try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: Self.sampleRate, ratio: 1,
            curve: harnessGrid(PitchCorrectionCurve.make(editSet: hard, contour: contour.frames)),
            formantPreserve: false, compensation: compensation)[0]

        let before = PitchWanderMeter.readNotes(try Self.uncorrected(input),
                                                sampleRate: Self.sampleRate, segments: hard.segments)
        func read(_ x: [Float]) -> PitchWanderMeter.NoteReading? {
            PitchWanderMeter.readNotes(x, sampleRate: Self.sampleRate, segments: hard.segments).first
        }
        let p = try #require(read(product.audio))
        let b = try #require(read(gridProductCurve))
        let a = try #require(read(asHeard))
        let beforeWander = try #require(before.first?.spreadCents)
        Self.log(String(format:
            "harness≡product: (C) exact-lookup harness differs in %d samples; wander before %.1f c | product %.1f | (B) harness grid, product curve %.1f | (A) harness as heard %.1f; centres product %.2f Hz, (B) %.2f, (A) %.2f",
            exactDiffering, beforeWander, p.spreadCents, b.spreadCents, a.spreadCents,
            p.medianHz, b.medianHz, a.medianHz))
        // The stated tolerance for "the same correction": the note lands on
        // the same centre within 3 cents — well inside the detector's own
        // ±12.9-cent floor — and the product flattens at least as well as
        // the render the user heard.
        #expect(abs(1200 * log2(p.medianHz / a.medianHz)) < 3)
        #expect(p.spreadCents <= a.spreadCents + 1)
    }
}
