import AVFAudio
import Accelerate
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// p2-ren Stage B (design `docs/design/2026-09-25-incremental-note-render.md`
// §6, §11 steps 9-13, §12): THE PROVISIONAL RENDER. The pure half, nonisolated
// and device-free: the extent (`RenderDiff`), the seams, the assembly, and the
// env-gated measurements on the user's take. The engine-bound gates (the
// resolution tier, the slot, the deferred swap) live in the existing
// `StretchEngineTests` suite, so no `@MainActor` suite is added.
@Suite("p2-ren Stage B — the provisional render (extent, seams, assembly)")
struct ProvisionalRenderTests {

    // MARK: - Fixtures

    typealias Params = StretchRenderCache.Params

    /// `seconds` of `SpanRenderSignals.voice` (three sung notes and glides,
    /// repeating), written to `dir`: Float32 WAV, or 24-bit integer PCM when
    /// `bits24` (a source that is NOT a Float32 CAF, so a base on it must take
    /// the rewrite). Stereo repeats the voice with a small gain on the right.
    static func voiceFile(_ dir: URL, seconds: Double, stereo: Bool = false,
                          bits24: Bool = false) throws -> (url: URL, notes: [NoteSegment]) {
        let voice = SpanRenderSignals.voice(seconds: seconds, sampleRate: 48_000)
        let planar = stereo ? [voice.samples, voice.samples.map { $0 * 0.8 }] : [voice.samples]
        let url = dir.appendingPathComponent(bits24 ? "voice24.wav" : "voice.wav")
        if bits24 {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: planar.count, AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 48_000,
                                                    channels: AVAudioChannelCount(planar.count),
                                                    interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(planar[0].count)))
            for (channel, samples) in planar.enumerated() {
                samples.withUnsafeBufferPointer {
                    buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: $0.count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(planar[0].count)
            try file.write(from: buffer)
        } else {
            try I1Signals.write(planar, sampleRate: 48_000, to: url)
        }
        return (url, voice.notes)
    }

    static func params(_ notes: [NoteSegment], ratio: Double = 1, semitones: Double = 0,
                       formant: Bool = false, retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
                       _ edit: (inout [NoteSegment]) -> Void = { _ in }) -> Params {
        var segments = notes
        edit(&segments)
        return Params(ratio: ratio, semitones: semitones, formantPreserve: formant,
                      pitchEdits: PitchEditSet(segments: segments, retuneMs: retuneMs))
    }

    /// The whole-file render `performRender` commits for `params`: its URL.
    static func finalRender(_ source: URL, _ params: Params, dir: URL, name: String) throws -> URL {
        let destination = dir.appendingPathComponent("\(name).caf")
        let fallback = dir.appendingPathComponent("\(name)-fb.caf")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: fallback)
        switch try StretchRenderCache.performRender(
            source: source, partial: dir.appendingPathComponent("\(name).partial.caf"),
            destination: destination, fallbackDestination: fallback, params: params,
            renderCacheDirectory: dir, detector: .product, isCancelled: { false }) {
        case .rendered(let url), .fellBack(let url, _): return url
        }
    }

    static func base(_ url: URL, _ params: Params, isSource: Bool = false) -> ProvisionalRender.Base {
        ProvisionalRender.Base(url: url, params: params, name: url.deletingPathExtension().lastPathComponent,
                               isSource: isSource, contourFallback: false)
    }

    static func job(source: URL, base: ProvisionalRender.Base, params: Params, dir: URL,
                    name: String) -> ProvisionalRender.Job {
        ProvisionalRender.Job(source: source, base: base, params: params, newKey: name,
                              destination: dir.appendingPathComponent("\(name)~prov.caf"),
                              renderCacheDirectory: dir, detector: .product)
    }

    static func built(_ outcome: ProvisionalRender.Outcome) throws -> ProvisionalRender.Built {
        switch outcome {
        case .built(let built): return built
        case .declined(let reason):
            Issue.record("declined: \(reason)")
            throw CocoaError(.featureUnsupported)
        }
    }

    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    static func extent(_ source: URL, old: Params, new: Params) throws
        -> Result<RenderDiff.Extent, RenderDiff.Refusal> {
        let shape = try StretchRenderCache.SpanSource.open(source)
        return try RenderDiff.extent(old: .init(params: old, curveContour: nil),
                                     new: .init(params: new, curveContour: nil),
                                     sourceFrames: shape.frames, channels: shape.channels,
                                     sampleRate: shape.sampleRate)
    }

    // MARK: - Assembly: the file format and the two writers

    @Test("p2-ren Stage B: a render file's CAF layout is what the clone-and-patch path assumes (payload at 4096, Float32 little-endian interleaved, data chunk last), and a WAV or a 16-bit CAF is refused")
    func cafLayoutOfARenderFile() async throws {
        let dir = try I1Signals.tempDir("ren-b-caf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 1.5, stereo: true)
        let render = try Self.finalRender(voice.url, Self.params(voice.notes) { $0[0].pitchOffsetCents = 100 },
                                          dir: dir, name: "r")
        let layout = try #require(ProvisionalRender.CAFLayout.parse(render))
        #expect(layout.payloadOffset == 4_096)
        #expect(layout.channels == 2 && layout.bytesPerFrame == 8 && layout.sampleRate == 48_000)
        #expect(layout.frames == 72_000)
        // The negative controls: the parser refuses what it must not patch.
        #expect(ProvisionalRender.CAFLayout.parse(voice.url) == nil, "a WAV parsed as a render CAF")
        let int16 = dir.appendingPathComponent("i16.caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        do {
            let file = try AVAudioFile(forWriting: int16, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            try file.write(from: buffer)
        }
        #expect(ProvisionalRender.CAFLayout.parse(int16) == nil, "a 16-bit CAF parsed as Float32")
    }

    @Test("p2-ren Stage B: clone-and-patch writes the SAME BYTES as the reference streaming rewrite (both paths ran), the patched frames read back as the patch and every other frame as the base")
    func cloneAndPatchEqualsRewrite() async throws {
        let dir = try I1Signals.tempDir("ren-b-clone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 3, stereo: true)
        let base = try Self.finalRender(voice.url, Self.params(voice.notes) { $0[1].pitchOffsetCents = 150 },
                                        dir: dir, name: "base")
        let baseAudio = try I1Signals.read(base).planar
        func patch(_ first: Int, _ count: Int, _ value: Float) -> ProvisionalRender.Patch {
            ProvisionalRender.Patch(firstFrame: first, planar: (0..<2).map { c in
                (0..<count).map { Float($0 % 97) * value + Float(c) * 0.01 }
            })
        }
        let patches = [patch(10_000, 4_801, 0.001), patch(100_000, 12_345, -0.002)]
        let format = try ProvisionalRender.sourceProcessingFormat(voice.url)
        let cloned = dir.appendingPathComponent("cloned.caf")
        let rewritten = dir.appendingPathComponent("rewritten.caf")
        let a = try ProvisionalRender.assemble(base: base, baseIsSource: false, patches: patches,
                                               outputFrames: 144_000, channels: 2, sampleRate: 48_000,
                                               sourceFormat: format, to: cloned, isCancelled: { false })
        let b = try ProvisionalRender.assemble(base: base, baseIsSource: false, patches: patches,
                                               outputFrames: 144_000, channels: 2, sampleRate: 48_000,
                                               sourceFormat: format, to: rewritten, forceRewrite: true,
                                               isCancelled: { false })
        #expect(a == .clone, "the clone path did not run (\(a))")
        #expect(b == .rewrite)
        #expect(try Self.bytes(cloned) == Self.bytes(rewritten), "clone-and-patch bytes differ from the rewrite")
        let out = try I1Signals.read(cloned).planar
        var wrongPatched = 0, wrongBase = 0
        for c in 0..<2 {
            for i in 0..<144_000 {
                if let p = patches.first(where: { $0.frames.contains(i) }) {
                    if out[c][i].bitPattern != p.planar[c][i - p.firstFrame].bitPattern { wrongPatched += 1 }
                } else if out[c][i].bitPattern != baseAudio[c][i].bitPattern {
                    wrongBase += 1
                }
            }
        }
        #expect(wrongPatched == 0 && wrongBase == 0, "patched \(wrongPatched), base \(wrongBase) frames wrong")
        // Control: the byte compare can fail (a different patch, different bytes).
        let other = dir.appendingPathComponent("other.caf")
        _ = try ProvisionalRender.assemble(base: base, baseIsSource: false, patches: [patch(10_000, 4_801, 0.0011)],
                                           outputFrames: 144_000, channels: 2, sampleRate: 48_000,
                                           sourceFormat: format, to: other, isCancelled: { false })
        #expect(try Self.bytes(other) != Self.bytes(cloned))
    }

    // MARK: - The extent

    @Test("p2-ren Stage B: the extent on synthetic sets — one note's pitch is local, a level edit is exactly its note's frames, a split and a timing-only edit are EMPTY, a ratio or formant change is refused")
    func extentOnSyntheticSets() async throws {
        let dir = try I1Signals.tempDir("ren-b-extent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 6)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 50 }
        // One note's pitch: local, after the note's start minus the lookahead.
        let pitch = try Self.extent(voice.url, old: old,
                                    new: Self.params(notes) { $0[0].pitchOffsetCents = 50; $0[3].pitchOffsetCents = 200 }).get()
        #expect(pitch.pitchRanges.count == 1 && pitch.maskRanges.isEmpty && pitch.prefixExact)
        let noteStart = Int(notes[3].startSeconds * 48_000)
        let noteEnd = Int(notes[3].endSeconds * 48_000)
        let first = try #require(pitch.firstDifferingFrame)
        print(String(format: "ren-b-extent| one note %.3f–%.3f s: pitch ranges %@ (first %.3f s, last %.3f s)",
                     notes[3].startSeconds, notes[3].endSeconds, "\(pitch.pitchRanges)",
                     Double(first) / 48_000, Double(pitch.pitchRanges[0].upperBound) / 48_000))
        #expect(first > noteStart - 9_600 && first < noteStart, "the first chunk is not just before the note")
        #expect(pitch.pitchRanges[0].upperBound > noteEnd - 9_600
                && pitch.pitchRanges[0].upperBound < noteEnd + 4_800)
        // A level edit: exactly the note's frames, and no pitch range.
        let level = try Self.extent(voice.url, old: old,
                                    new: Self.params(notes) { $0[0].pitchOffsetCents = 50; $0[2].amplitudeDb = -6 }).get()
        #expect(level.pitchRanges.isEmpty && level.maskRanges.count == 1)
        let lo = StretchCurvePlan.firstOutputFrame(atOrAfterSourceSecond: notes[2].startSeconds,
                                                   frames: level.outputFrames, ratio: 1, sampleRate: 48_000)
        let hi = StretchCurvePlan.firstOutputFrame(atOrAfterSourceSecond: notes[2].endSeconds,
                                                   frames: level.outputFrames, ratio: 1, sampleRate: 48_000)
        // Exactly the frames whose gain differs: inside the note, all of it
        // but an edge frame whose ramp still reads 1.
        #expect(level.maskRanges.count == 1)
        if let range = level.maskRanges.first {
            #expect(range.lowerBound >= lo && range.upperBound <= hi && range.count >= hi - lo - 2,
                    "mask range \(range) vs the note's frames \(lo..<hi)")
        }
        // A split into two halves with the same offset: nothing the render reads moves.
        let split = try Self.extent(voice.url, old: old, new: Self.params(notes) { segs in
            segs[0].pitchOffsetCents = 50
            let whole = segs[4]
            let middle = (whole.startSeconds + whole.endSeconds) / 2
            segs[4].endSeconds = middle
            segs.append(NoteSegment(startSeconds: middle, endSeconds: whole.endSeconds,
                                    detectedHz: whole.detectedHz, detectedConfidence: whole.detectedConfidence))
        }).get()
        print("ren-b-extent| split: pitch \(split.pitchRanges), mask \(split.maskRanges)")
        #expect(split.isEmpty, "a split moved the transpose or the mask")
        // Timing-only (the render does not read W yet: `StretchCurvePlan.readsTimeWarp`).
        #expect(!StretchCurvePlan.readsTimeWarp)
        let timing = try Self.extent(voice.url, old: old, new: Self.params(notes) {
            $0[0].pitchOffsetCents = 50; $0[2].timeStartDeltaSeconds = 0.05
        }).get()
        #expect(timing.isEmpty)
        // Refusals: the time base, the formant flag.
        #expect(try Self.extent(voice.url, old: old, new: Self.params(notes, ratio: 1.25) { $0[0].pitchOffsetCents = 50 })
                == .failure(.timeBase))
        #expect(try Self.extent(voice.url, old: old, new: Self.params(notes, formant: true) { $0[0].pitchOffsetCents = 50 })
                == .failure(.formantFlag))
        // Across loops (a level-only base, a pitch edit): the prefix is approximate.
        let across = try Self.extent(voice.url, old: Self.params(notes) { $0[1].isCleared = true },
                                     new: Self.params(notes) { $0[1].isCleared = true; $0[3].pitchOffsetCents = 100 }).get()
        #expect(!across.prefixExact && across.oldLoop == .sourceTimesMask && across.newLoop == .stretcher)
    }

    @Test("p2-ren Stage B: RANDOMISED DIFFERENTIAL — for random edit pairs, the whole-file finals are bit-identical before the extent's first frame (and everywhere when it is empty); the extent is tight (the finals do differ where it says)")
    func extentRandomisedDifferential() async throws {
        let dir = try I1Signals.tempDir("ren-b-diff")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 4)
        let notes = voice.notes
        var state: UInt64 = 0x5EED_2026_0925
        func random(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        func randomEdit(_ segs: inout [NoteSegment]) -> String {
            let i = random(segs.count)
            switch random(7) {
            case 0: segs[i].pitchOffsetCents += Double(random(400) - 200); return "offset[\(i)]"
            case 1: segs[i].vibratoDepthCents = Double(10 + random(40)); segs[i].vibratoRateHz = 5.5
                return "vibrato[\(i)]"
            case 2: segs[i].amplitudeDb = -Double(1 + random(12)); return "level[\(i)]"
            case 3: segs[i].isCleared.toggle(); return "clear[\(i)]"
            case 4: segs[i].timeStartDeltaSeconds = 0.03; return "timing[\(i)]"
            case 5:
                let whole = segs[i]
                let middle = (whole.startSeconds + whole.endSeconds) / 2
                segs[i].endSeconds = middle
                let tail = NoteSegment(startSeconds: middle, endSeconds: whole.endSeconds, detectedHz: whole.detectedHz,
                                   detectedConfidence: whole.detectedConfidence,
                                   pitchOffsetCents: whole.pitchOffsetCents, amplitudeDb: whole.amplitudeDb,
                                   isCleared: whole.isCleared)
                segs.append(tail)
                return "split[\(i)]"
            default: segs[i].vibratoOnsetSeconds = 0.1; return "onset[\(i)]"
            }
        }
        var cases = 0, empties = 0, lags: [Int] = []
        for trial in 0..<10 {
            var oldSegs = notes
            oldSegs[random(notes.count)].pitchOffsetCents = Double(random(200))
            var newSegs = oldSegs
            let what = randomEdit(&newSegs)
            let retune = trial % 4 == 3 ? 80.0 : PitchEditSet.engineMinimumRetuneMs
            let old = Params(ratio: 1, semitones: 0, formantPreserve: false,
                             pitchEdits: PitchEditSet(segments: oldSegs))
            let new = Params(ratio: 1, semitones: 0, formantPreserve: false,
                             pitchEdits: PitchEditSet(segments: newSegs, retuneMs: retune))
            let a = try I1Signals.read(Self.finalRender(voice.url, old, dir: dir, name: "a\(trial)")).planar[0]
            let b = try I1Signals.read(Self.finalRender(voice.url, new, dir: dir, name: "b\(trial)")).planar[0]
            let ext = try Self.extent(voice.url, old: old, new: new).get()
            let firstActual = zip(a, b).enumerated().first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
            let predicted = ext.firstDifferingFrame
            print("ren-b-diff| trial \(trial) \(what) retune \(retune): predicted \(predicted.map(String.init) ?? "none"), actual \(firstActual.map(String.init) ?? "none"), exact prefix \(ext.prefixExact)")
            cases += 1
            if let firstActual {
                let bound = try #require(predicted, "trial \(trial) (\(what)): the finals differ at \(firstActual) and the extent is EMPTY")
                #expect(firstActual >= bound, "trial \(trial) (\(what)): the finals differ at \(firstActual), BEFORE the extent's first frame \(bound)")
                lags.append(firstActual - bound)
            } else {
                empties += 1
                // An extent where nothing differs is allowed (conservative),
                // but say so: it would build a needless span.
                if predicted != nil { print("ren-b-diff| trial \(trial): extent non-empty, finals identical") }
            }
        }
        print("ren-b-diff| \(cases) pairs, \(empties) bit-identical; lag from predicted to actual first difference (frames): \(lags.sorted())")
        // Tightness: where the transpose changes, the finals differ within a
        // few chunks of the predicted frame (not an arbitrarily early bound).
        #expect(lags.allSatisfy { $0 < 4 * 1_440 }, "the extent starts far earlier than the change: \(lags)")
        #expect(cases - empties >= 5, "too few differing pairs to mean anything")
    }

    // MARK: - The builder: the exact kinds

    @Test("p2-ren Stage B: a level-only change on the level-only path builds a provisional BYTE-IDENTICAL to the final, from a committed render (clone-and-patch) and from a 24-bit SOURCE (the rewrite), with no seam")
    func levelOnlyProvisionalIsTheFinalByteForByte() async throws {
        let dir = try I1Signals.tempDir("ren-b-level")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 4, stereo: true, bits24: true)
        let notes = voice.notes
        let old = Self.params(notes) { $0[1].isCleared = true }
        let new = Self.params(notes) { $0[1].isCleared = true; $0[3].amplitudeDb = -6 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let finalURL = try Self.finalRender(voice.url, new, dir: dir, name: "new")
        // From the committed render.
        let fromRender = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: new, dir: dir, name: "k1"),
            isCancelled: { false }))
        #expect(fromRender.kind == .levelOnlyExact && fromRender.assembly == .clone && fromRender.seams.isEmpty)
        #expect(try Self.bytes(fromRender.url) == Self.bytes(finalURL), "the level-only provisional is not the final's bytes")
        // From the SOURCE (an identity clip's first level edit).
        let identity = Params(ratio: 1, semitones: 0, formantPreserve: false)
        let firstEdit = Self.params(notes) { $0[3].amplitudeDb = -6 }
        let firstFinal = try Self.finalRender(voice.url, firstEdit, dir: dir, name: "first")
        let fromSource = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(voice.url, identity, isSource: true),
                     params: firstEdit, dir: dir, name: "k2"),
            isCancelled: { false }))
        #expect(fromSource.kind == .levelOnlyExact && fromSource.assembly == .rewrite)
        #expect(try Self.bytes(fromSource.url) == Self.bytes(firstFinal),
                "the rewrite from a 24-bit source is not the final's bytes (block-wise write vs performRender's one write)")
        // Control: the compare can fail (the base itself is not the final).
        #expect(try Self.bytes(baseURL) != Self.bytes(finalURL))
    }

    @Test("p2-ren Stage B: a level change on the CURVE path rescales the base (max relative error ≤ 1e-6 against the final); an un-clear, which a zeroed base cannot rescale, is spliced instead")
    func rescaleProvisionalMatchesTheFinal() async throws {
        let dir = try I1Signals.tempDir("ren-b-rescale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 5)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[3].amplitudeDb = -3 }
        let new = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[3].amplitudeDb = -9; $0[2].amplitudeDb = 2 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let final = try I1Signals.read(Self.finalRender(voice.url, new, dir: dir, name: "new")).planar[0]
        let built = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: new, dir: dir, name: "k"),
            isCancelled: { false }))
        #expect(built.kind == .rescale && built.seams.isEmpty && built.spanFrames == 0)
        let out = try I1Signals.read(built.url).planar[0]
        var worst = 0.0, exact = 0, compared = 0
        for i in final.indices where abs(final[i]) > 1e-6 {
            compared += 1
            let rel = Double(abs(out[i] - final[i])) / Double(abs(final[i]))
            worst = max(worst, rel)
            if out[i].bitPattern == final[i].bitPattern { exact += 1 }
        }
        print(String(format: "ren-b-rescale| max relative error %.3g over %d samples, %d bit-exact", worst, compared, exact))
        #expect(worst <= 1e-6)
        // Un-clear: the old mask is 0 there, so the rescale refuses and the splice builds.
        let cleared = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[3].isCleared = true }
        let clearedBase = try Self.finalRender(voice.url, cleared, dir: dir, name: "cleared")
        let unclear = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(clearedBase, cleared),
                     params: Self.params(notes) { $0[0].pitchOffsetCents = 100 }, dir: dir, name: "u"),
            isCancelled: { false }))
        #expect(unclear.kind == .spliced)
    }

    @Test("p2-ren Stage B: an edit the render does not read (timing-only, before C2-3) serves the BASE itself, and a ratio or formant change declines (the bridge plays on)")
    func baseAsIsAndRefusals() async throws {
        let dir = try I1Signals.tempDir("ren-b-asis")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 4)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let timing = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[1].timeStartDeltaSeconds = 0.04 }
        let asIs = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: timing, dir: dir, name: "t"),
            isCancelled: { false }))
        #expect(asIs.kind == .baseAsIs && asIs.url == baseURL && asIs.assembly == .none)
        // And the final really is the base (the design's "final == base, cmp").
        let timingFinal = try Self.finalRender(voice.url, timing, dir: dir, name: "timing")
        #expect(try Self.bytes(timingFinal) == Self.bytes(baseURL))
        for (label, new) in [("ratio", Self.params(notes, ratio: 1.25) { $0[0].pitchOffsetCents = 100 }),
                             ("formant", Self.params(notes, formant: true) { $0[0].pitchOffsetCents = 100 })] {
            let outcome = try ProvisionalRender.build(
                Self.job(source: voice.url, base: Self.base(baseURL, old), params: new, dir: dir, name: label),
                isCancelled: { false })
            guard case .declined(let reason) = outcome else {
                Issue.record("\(label): a provisional was built across a \(label) change")
                continue
            }
            print("ren-b-asis| \(label) declined: \(reason)")
        }
    }

    // MARK: - The builder: the splice, and the seam gate (§12 G3)

    /// §12 G3, the test's own instrument (independent of the builder). Over a
    /// seam's crossfade ± 2 ms: the first-difference bound
    /// max|Δy| ≤ 1.1 × max(max|Δbase|, max|Δspan|); and the local-envelope
    /// bound: the RMS of y within [−6, +1.5] dB of the mean of the two sides'
    /// RMS, over windows of `window` frames centred every 2 ms across the
    /// crossfade (windows where the sides are below −80 dBFS skipped).
    ///
    /// ⚠️ **THE WINDOW IS 20 ms, NOT THE DESIGN'S 2 ms, AND THAT IS A
    /// MEASUREMENT** (`seamInstrumentPositiveControls`): a 2 ms RMS is shorter
    /// than one period of a sung note (9 ms at 110 Hz), so it reads the
    /// waveform's shape, not its envelope. On a power-matched crossfade of two
    /// 110 Hz tones 60° apart, whose envelope is FLAT by construction, the
    /// 2 ms instrument reports a violation and the 20 ms one reads flat. The
    /// 20 ms instrument still fails both planted defects.
    struct SeamVerdict: CustomStringConvertible {
        var worstDelta: Float
        var deltaBound: Float
        var envelopeLowDb: Double
        var envelopeHighDb: Double
        /// THE SMOOTH-GAIN RESIDUAL (added by the Stage B lane; design §17 E11):
        /// the output over the fade ± 2 ms against its best fit with CONTINUOUS
        /// gains (`smoothGainResidualDb`). Any real crossfade law is a
        /// continuous pair of gains and fits; a cut, or gains that jump, cannot.
        /// It reads the TRANSITION, so a signal's own high-frequency content
        /// (which drowns the first-difference bound on a stretched voice,
        /// measured under the hard-cut plant) cannot mask it.
        var gainResidualDb: Double
        static let smoothGainLimitDb = -40.0
        var firstDifferenceOK: Bool { worstDelta <= deltaBound }
        var envelopeOK: Bool { envelopeLowDb >= -6 && envelopeHighDb <= 1.5 }
        var smoothGainOK: Bool { gainResidualDb <= Self.smoothGainLimitDb }
        var passes: Bool { firstDifferenceOK && envelopeOK && smoothGainOK }
        var description: String {
            String(format: "max|Δy| %.5f vs bound %.5f; envelope %+.2f…%+.2f dB; gain residual %.1f dB",
                   worstDelta, deltaBound, envelopeLowDb, envelopeHighDb, gainResidualDb)
        }
    }

    /// `SeamVerdict.gainResidualDb`: least squares over the fade ± `pad` with
    /// y ≈ gb(n)·base + gs(n)·span, where gb and gs are PIECEWISE LINEAR with a
    /// knot every `knotSpacing` frames and one on each fade edge. That family
    /// holds every real law to within its curvature (≪ −40 dB at 1 ms knots),
    /// including the corner where a fade starts, but no jump: a cut leaves its
    /// step, spread over one knot interval, as residual. A tiny ridge keeps
    /// near-identical sides solvable. Returns 10·log10(the worst 1 ms of
    /// residual power / the mean output power over the window).
    static func smoothGainResidualDb(y: [Float], base: [Float], span: [Float], fade: Range<Int>,
                                     pad: Int = 96, knotSpacing: Int = 48) -> Double {
        let lo = max(0, fade.lowerBound - pad), hi = min(y.count, fade.upperBound + pad)
        guard hi - lo >= 2 else { return .nan }
        var knots = Set(stride(from: lo, to: hi, by: knotSpacing))
        knots.formUnion([fade.lowerBound, fade.upperBound, hi - 1].filter { $0 >= lo && $0 < hi })
        let grid = knots.sorted()
        let k = grid.count
        let m = 2 * k
        var ata = [Double](repeating: 0, count: m * m)
        var aty = [Double](repeating: 0, count: m)
        var energy = 0.0
        /// The (index, weight) pairs of frame n's two hat functions.
        func hats(_ n: Int, _ interval: inout Int) -> [(Int, Double)] {
            while interval + 1 < k - 1, grid[interval + 1] <= n { interval += 1 }
            let a = grid[interval], b = grid[min(interval + 1, k - 1)]
            let w = b > a ? Double(n - a) / Double(b - a) : 0
            return [(interval, 1 - w), (min(interval + 1, k - 1), w)]
        }
        var interval = 0
        for n in lo..<hi {
            let target = Double(y[n])
            energy += target * target
            var entries: [(Int, Double)] = []
            for (j, w) in hats(n, &interval) {
                entries.append((j, w * Double(base[n])))
                entries.append((k + j, w * Double(span[n])))
            }
            for (i, vi) in entries {
                aty[i] += vi * target
                for (j, vj) in entries { ata[i * m + j] += vi * vj }
            }
        }
        guard energy > 0 else { return -.infinity }
        var trace = 0.0
        for i in 0..<m { trace += ata[i * m + i] }
        for i in 0..<m { ata[i * m + i] += 1e-12 * trace / Double(m) + 1e-30 }
        // Gaussian elimination with partial pivoting.
        var a = ata, b = aty
        for col in 0..<m {
            var pivot = col
            for r in (col + 1)..<m where abs(a[r * m + col]) > abs(a[pivot * m + col]) { pivot = r }
            guard a[pivot * m + col] != 0 else { return .nan }
            if pivot != col {
                for c in 0..<m { a.swapAt(col * m + c, pivot * m + c) }
                b.swapAt(col, pivot)
            }
            for r in (col + 1)..<m {
                let factor = a[r * m + col] / a[col * m + col]
                guard factor != 0 else { continue }
                for c in col..<m { a[r * m + c] -= factor * a[col * m + c] }
                b[r] -= factor * b[col]
            }
        }
        var g = [Double](repeating: 0, count: m)
        for r in stride(from: m - 1, through: 0, by: -1) {
            var sum = b[r]
            for c in (r + 1)..<m { sum -= a[r * m + c] * g[c] }
            g[r] = sum / a[r * m + r]
        }
        var residual = [Double](repeating: 0, count: hi - lo)
        interval = 0
        for n in lo..<hi {
            var fit = 0.0
            for (j, w) in hats(n, &interval) {
                fit += w * (g[j] * Double(base[n]) + g[k + j] * Double(span[n]))
            }
            let r = Double(y[n]) - fit
            residual[n - lo] = r * r
        }
        // The WORST 1 ms of residual power against the window's mean output
        // power: a cut lives in one knot interval, so a whole-window mean
        // would dilute it by the window's length.
        let local = min(knotSpacing, residual.count)
        var sum = residual[0..<local].reduce(0, +)
        var worst = sum
        for n in local..<residual.count {
            sum += residual[n] - residual[n - local]
            worst = max(worst, sum)
        }
        let meanPower = energy / Double(hi - lo)
        return 10 * log10(max(worst / Double(local), 1e-300) / meanPower)
    }

    static func seamVerdict(y: [Float], base: [Float], span: [Float], fade: Range<Int>,
                            window: Int = 960) -> SeamVerdict {
        let pad = 96
        let lo = max(1, fade.lowerBound - pad), hi = min(y.count, fade.upperBound + pad)
        var dy: Float = 0, db: Float = 0, ds: Float = 0
        for n in lo..<hi {
            dy = max(dy, abs(y[n] - y[n - 1]))
            db = max(db, abs(base[n] - base[n - 1]))
            ds = max(ds, abs(span[n] - span[n - 1]))
        }
        var low = 0.0, high = 0.0
        var centre = fade.lowerBound
        while centre <= fade.upperBound {
            let r = max(0, centre - window / 2)..<min(y.count, centre - window / 2 + window)
            let sides = (I1Signals.rms(base[r]) + I1Signals.rms(span[r])) / 2
            if sides > 1e-4 {
                let d = 20 * log10(max(I1Signals.rms(y[r]), 1e-12) / sides)
                low = min(low, d)
                high = max(high, d)
            }
            centre += 96
        }
        return SeamVerdict(worstDelta: dy, deltaBound: 1.1 * max(db, ds), envelopeLowDb: low, envelopeHighDb: high,
                           gainResidualDb: smoothGainResidualDb(y: y, base: base, span: span, fade: fade))
    }

    @Test("p2-ren Stage B G3 instrument, positive controls: a HARD CUT between two phases of one tone fails the first-difference bound, equal-POWER on identical sides fails the envelope (+3 dB), a real crossfade passes; the design's 2 ms envelope window misreads a FLAT crossfade of a 110 Hz voice where 20 ms reads it flat; and the SMOOTH-GAIN residual fails a cut hidden in a hissy voice that the first-difference bound passes, while every real law passes it")
    func seamInstrumentPositiveControls() {
        let n = 9_600
        func tone(_ hz: Double, _ phase: Double) -> [Float] {
            (0..<n).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / 48_000 + phase)) }
        }
        let a = tone(200, 0), b = tone(200, 2.2)
        let fade = 4_080..<(4_080 + 1_440)
        func splice(_ law: ProvisionalRender.Law?, _ base: [Float], _ span: [Float], rho: Double = 0) -> [Float] {
            var y = base
            for i in fade.lowerBound..<n {
                guard let law, i < fade.upperBound else { y[i] = span[i]; continue }
                let t = (Double(i - fade.lowerBound) + 0.5) / Double(fade.count)
                let gb: Double, gs: Double
                switch law {
                case .equalGain: (gb, gs) = (1 - t, t)
                case .equalPower: (gb, gs) = (cos(Double.pi / 2 * t), sin(Double.pi / 2 * t))
                case .powerMatched:
                    let norm = (t * t + (1 - t) * (1 - t) + 2 * rho * t * (1 - t)).squareRoot()
                    (gb, gs) = ((1 - t) / norm, t / norm)
                }
                y[i] = Float(gb) * base[i] + Float(gs) * span[i]
            }
            return y
        }
        let hard = Self.seamVerdict(y: splice(nil, a, b), base: a, span: b, fade: fade)
        let powerOnSame = Self.seamVerdict(y: splice(.equalPower, a, a), base: a, span: a, fade: fade)
        let gainOnSame = Self.seamVerdict(y: splice(.equalGain, a, a), base: a, span: a, fade: fade)
        let powerOnOther = Self.seamVerdict(y: splice(.equalPower, a, b), base: a, span: b, fade: fade)
        // A sung-register pair 60° apart, power-matched at ρ = cos 60°: flat by construction.
        let v1 = tone(110, 0), v2 = tone(110, Double.pi / 3)
        let flat = splice(.powerMatched, v1, v2, rho: 0.5)
        let flat20 = Self.seamVerdict(y: flat, base: v1, span: v2, fade: fade)
        let flat2 = Self.seamVerdict(y: flat, base: v1, span: v2, fade: fade, window: 96)
        print("ren-b-g3| hard cut: \(hard); equal-power on identical: \(powerOnSame); equal-gain on identical: \(gainOnSame); equal-power across phases: \(powerOnOther); flat 110 Hz pair, 20 ms: \(flat20); the same, 2 ms: \(flat2)")
        #expect(!hard.firstDifferenceOK, "a hard cut passed the first-difference bound")
        #expect(!hard.smoothGainOK, "a hard cut passed the smooth-gain residual")
        #expect(!powerOnSame.envelopeOK, "equal-power on identical sides passed the envelope bound")
        #expect(gainOnSame.passes && powerOnOther.firstDifferenceOK)
        // Every real law is a smooth gain pair: equal-gain, equal-power, power-matched.
        #expect(gainOnSame.smoothGainOK && powerOnSame.smoothGainOK && powerOnOther.smoothGainOK && flat20.smoothGainOK,
                "a real crossfade failed the smooth-gain residual")
        // A cut hidden in a voice-like signal whose own slope dwarfs the step
        // (the case the first-difference bound misses): 10 harmonics of 110 Hz
        // at 0.05 plus hiss at 0.1 (shared by both sides), cut between two
        // phases 60° apart.
        func voiced(_ phase: Double) -> [Float] {
            var state: UInt64 = 0x5EED
            return (0..<n).map { i in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let hiss = Double(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
                var v = 0.0
                for k in 1...10 { v += sin(Double(k) * (2 * Double.pi * 110 * Double(i) / 48_000 + phase)) / Double(k) }
                return Float(0.05 * v + 0.1 * hiss)
            }
        }
        let w1 = voiced(0), w2 = voiced(Double.pi / 3)
        let hiddenCut = Self.seamVerdict(y: splice(nil, w1, w2), base: w1, span: w2, fade: fade)
        let voicedFade = Self.seamVerdict(y: splice(.powerMatched, w1, w2, rho: 0.5), base: w1, span: w2, fade: fade)
        print("ren-b-g3| hidden cut in a hissy voice: \(hiddenCut); a power-matched fade of it: \(voicedFade)")
        #expect(hiddenCut.firstDifferenceOK, "premise: the first-difference bound catches a cut in a hissy voice")
        #expect(!hiddenCut.smoothGainOK, "the smooth-gain residual missed a cut the first-difference bound cannot see")
        #expect(voicedFade.smoothGainOK)
        #expect(flat20.envelopeOK, "the 20 ms instrument misreads a flat crossfade")
        #expect(!flat2.envelopeOK, "premise: the 2 ms window misreads a flat crossfade of a 110 Hz voice")
    }

    @Test("p2-ren Stage B: a pitch edit on a synthetic voice builds a SPLICED provisional: the frames before the patch are the final's bytes, the new pitch is in it (≤ 5 c from the final's), and both seams pass G3 against the base and the raw span")
    func splicedProvisionalOnASyntheticVoice() async throws {
        let dir = try I1Signals.tempDir("ren-b-splice")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 8)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100 }
        let new = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[4].pitchOffsetCents = 200 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let base = try I1Signals.read(baseURL).planar[0]
        let final = try I1Signals.read(Self.finalRender(voice.url, new, dir: dir, name: "new")).planar[0]
        let built = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: new, dir: dir, name: "k"),
            isCancelled: { false }))
        #expect(built.kind == .spliced && built.assembly == .clone && built.seams.count == 2)
        let y = try I1Signals.read(built.url).planar[0]
        let patch = try #require(built.patchedFrames.first)
        print("ren-b-splice| extent \(built.extent.pitchRanges), patch \(patch) (\(String(format: "%.3f", Double(patch.count) / 48_000)) s), span \(built.spanFrames) frames, millis \(built.millis)")
        for seam in built.seams {
            print(String(format: "ren-b-splice| %@ seam at %.3f s: xf %d, %@, rms %.1f dB vs active %.1f dB (quiet %@), ρ %.3f",
                         seam.side.rawValue, Double(seam.centreFrame) / 48_000, seam.crossfadeFrames,
                         seam.law.rawValue, seam.seamRmsDb, seam.activeRmsDb, seam.isQuiet ? "yes" : "no",
                         seam.correlation))
        }
        // Prefix: the final's bytes (both curve renders, same history).
        #expect(built.extent.prefixExact)
        let prefixDiffs = (0..<patch.lowerBound).filter { y[$0].bitPattern != final[$0].bitPattern }.count
        #expect(prefixDiffs == 0, "\(prefixDiffs) prefix samples differ from the final")
        // Outside the patch the file is the base, bit for bit.
        let outside = (patch.upperBound..<y.count).filter { y[$0].bitPattern != base[$0].bitPattern }.count
        #expect(outside == 0)
        // The edit is in it: pitch against the final over the note.
        let noteRange = Int(notes[4].startSeconds * 48_000 + 4_800)..<Int(notes[4].endSeconds * 48_000 - 4_800)
        let comparison = SpanRenderMetrics.compare(Array(final[noteRange]), Array(y[noteRange]),
                                                   sampleRate: 48_000, minHz: 70, maxHz: 400)
        let shift = SpanRenderMetrics.signedShift(base[noteRange], y[noteRange], sampleRate: 48_000,
                                                  minHz: 70, maxHz: 400, around: 200)
        print("ren-b-splice| note vs final: \(comparison); vs base: \(String(format: "%+.1f", shift.median)) c")
        #expect(comparison.pitchMedian <= 5)
        #expect(abs(shift.median - 200) <= 15, "the provisional does not carry the +200 c edit")
        // G3 at both seams, against the base and the raw span.
        #expect(built.spanRanges.count == 1)
        let spanFull = try Self.rawSpans(built, voice: voice.url, params: new, dir: dir, base: base)
        for seam in built.seams {
            let fade = (seam.centreFrame - seam.crossfadeFrames / 2)..<(seam.centreFrame - seam.crossfadeFrames / 2 + seam.crossfadeFrames)
            let verdict = Self.seamVerdict(y: y, base: base, span: spanFull, fade: fade)
            print("ren-b-g3| \(seam.side.rawValue) seam: \(verdict)")
            #expect(verdict.passes, "the \(seam.side.rawValue) seam fails G3: \(verdict)")
        }
    }

    /// The builder's own spans, re-rendered (deterministic: the same frames
    /// from the same start give the same samples), laid over the base.
    static func rawSpans(_ built: ProvisionalRender.Built, voice: URL, params: Params, dir: URL,
                         base: [Float]) throws -> [Float] {
        let source = try StretchRenderCache.SpanSource.open(voice)
        var full = base
        for window in built.spanRanges {
            let span = try StretchRenderCache.renderOutputFrames(window, of: source, params: params,
                                                                renderCacheDirectory: dir, detector: .product,
                                                                isCancelled: { false }).planar[0]
            for (i, v) in span.enumerated() { full[window.lowerBound + i] = v }
        }
        return full
    }

    @Test("p2-ren Stage B: at a stretch ratio of 1.5 (unchanged by the edit) a pitch edit builds a SPLICED provisional in OUTPUT frames: the prefix is the final's bytes, the rest outside the patch is the base's, the edit is in it where the stretched note plays, and both seams pass G3")
    func splicedProvisionalAtARatio() async throws {
        let ratio = 1.5
        let dir = try I1Signals.tempDir("ren-b-ratio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 8)
        let notes = voice.notes
        let old = Self.params(notes, ratio: ratio) { $0[0].pitchOffsetCents = 100 }
        let new = Self.params(notes, ratio: ratio) { $0[0].pitchOffsetCents = 100; $0[4].pitchOffsetCents = 200 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let base = try I1Signals.read(baseURL).planar[0]
        let final = try I1Signals.read(Self.finalRender(voice.url, new, dir: dir, name: "new")).planar[0]
        #expect(base.count == Int((8 * 48_000 * ratio).rounded()), "premise: the render is not in stretched output frames")
        let built = try Self.built(ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: new, dir: dir, name: "k"),
            isCancelled: { false }))
        #expect(built.kind == .spliced && built.assembly == .clone && built.seams.count == 2)
        let y = try I1Signals.read(built.url).planar[0]
        #expect(y.count == base.count)
        let patch = try #require(built.patchedFrames.first)
        print("ren-b-ratio| extent \(built.extent.pitchRanges), patch \(patch) (\(String(format: "%.3f", Double(patch.count) / 48_000)) s), note 4 at \(String(format: "%.3f–%.3f", notes[4].startSeconds * ratio, notes[4].endSeconds * ratio)) s out, millis \(built.millis)")
        #expect(built.extent.prefixExact)
        let prefixDiffs = (0..<patch.lowerBound).filter { y[$0].bitPattern != final[$0].bitPattern }.count
        #expect(prefixDiffs == 0, "\(prefixDiffs) prefix samples differ from the final")
        let outside = (patch.upperBound..<y.count).filter { y[$0].bitPattern != base[$0].bitPattern }.count
        #expect(outside == 0)
        // The note plays at ratio × its source time.
        let noteRange = Int(notes[4].startSeconds * ratio * 48_000 + 4_800)..<Int(notes[4].endSeconds * ratio * 48_000 - 4_800)
        #expect(patch.contains(noteRange.lowerBound) && patch.contains(noteRange.upperBound - 1),
                "the patch misses the stretched note")
        let comparison = SpanRenderMetrics.compare(Array(final[noteRange]), Array(y[noteRange]),
                                                   sampleRate: 48_000, minHz: 70, maxHz: 400)
        let shift = SpanRenderMetrics.signedShift(base[noteRange], y[noteRange], sampleRate: 48_000,
                                                  minHz: 70, maxHz: 400, around: 200)
        print("ren-b-ratio| note vs final: \(comparison); vs base: \(String(format: "%+.1f", shift.median)) c")
        #expect(comparison.pitchMedian <= 5)
        #expect(abs(shift.median - 200) <= 15, "the provisional does not carry the +200 c edit")
        let spanFull = try Self.rawSpans(built, voice: voice.url, params: new, dir: dir, base: base)
        for seam in built.seams {
            let fade = (seam.centreFrame - seam.crossfadeFrames / 2)..<(seam.centreFrame - seam.crossfadeFrames / 2 + seam.crossfadeFrames)
            let verdict = Self.seamVerdict(y: y, base: base, span: spanFull, fade: fade)
            print("ren-b-ratio| \(seam.side.rawValue) seam at \(String(format: "%.3f", Double(seam.centreFrame) / 48_000)) s, ρ \(String(format: "%.3f", seam.correlation)): \(verdict)")
            #expect(verdict.passes, "the \(seam.side.rawValue) seam fails G3: \(verdict)")
        }
    }

    @Test("p2-ren Stage B: two edited notes far apart are TWO spans with their own seams (not one span across the gap); the frames between them are the base's bytes, and all four seams pass G3")
    func twoRegionsAreTwoSpans() throws {
        let dir = try I1Signals.tempDir("ren-b-two")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100 }
        let new = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[8].pitchOffsetCents = -150 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let result = try Self.seamVerdicts(voice: voice.url, dir: dir, baseURL: baseURL, old: old, new: new,
                                           name: "two", tuning: .product)
        let built = result.built
        print("ren-b-two| spans \(built.spanRanges) (\(built.spanFrames) frames), patches \(built.patchedFrames), seams \(built.seams.count)")
        #expect(built.kind == .spliced && built.spanRanges.count == 2 && built.seams.count == 4)
        let base = try I1Signals.read(baseURL).planar[0]
        let y = try I1Signals.read(built.url).planar[0]
        let between = built.patchedFrames[0].upperBound..<built.patchedFrames[1].lowerBound
        #expect(between.count > 48_000, "the gap is not between the patches")
        #expect(between.allSatisfy { y[$0].bitPattern == base[$0].bitPattern }, "the frames between the regions are not the base")
        for (seam, verdict) in result.verdicts {
            print("ren-b-two| \(seam.side.rawValue) seam at \(seam.centreFrame): \(verdict)")
            #expect(verdict.passes)
        }
    }

    /// Builds the provisional for `new` from `base`, and G3's verdict at each
    /// of its seams against the base and the builder's own span.
    static func seamVerdicts(voice: URL, dir: URL, baseURL: URL, old: Params, new: Params, name: String,
                             tuning: ProvisionalRender.Tuning) throws
        -> (built: ProvisionalRender.Built, verdicts: [(ProvisionalRender.Seam, SeamVerdict)]) {
        let built = try Self.built(ProvisionalRender.build(
            Self.job(source: voice, base: Self.base(baseURL, old), params: new, dir: dir, name: name),
            tuning: tuning, isCancelled: { false }))
        guard built.kind == .spliced else { return (built, []) }
        let base = try I1Signals.read(baseURL).planar[0]
        let y = try I1Signals.read(built.url).planar[0]
        let spanFull = try Self.rawSpans(built, voice: voice, params: new, dir: dir, base: base)
        let verdicts = built.seams.map { seam -> (ProvisionalRender.Seam, SeamVerdict) in
            let start = seam.centreFrame - seam.crossfadeFrames / 2
            return (seam, Self.seamVerdict(y: y, base: base, span: spanFull,
                                           fade: start..<(start + seam.crossfadeFrames)))
        }
        return (built, verdicts)
    }

    @Test("p2-ren Stage B §14 measurement — the seam law: every seam of 8 single-note edits on a synthetic voice, G3 under equal-power (the design's) and power-matched below ρ 0.9, and the PRODUCT default passes every seam")
    func seamLawMeasurement() throws {
        let dir = try I1Signals.tempDir("ren-b-law")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        var failures: [String: Int] = [:]
        var seams: [String: Int] = [:]
        for (k, (note, cents)) in [(2, 200.0), (3, -150.0), (4, 200.0), (5, 80.0), (6, -300.0),
                                    (7, 120.0), (8, 250.0), (9, -60.0)].enumerated() where note < notes.count {
            let new = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[note].pitchOffsetCents = cents }
            for law in [ProvisionalRender.Law.equalPower, .powerMatched] {
                var tuning = ProvisionalRender.Tuning.product
                tuning.partialCorrelationLaw = law
                let result = try Self.seamVerdicts(voice: voice.url, dir: dir, baseURL: baseURL, old: old, new: new,
                                                   name: "e\(k)-\(law.rawValue)", tuning: tuning)
                for (seam, verdict) in result.verdicts {
                    seams[law.rawValue, default: 0] += 1
                    if !verdict.passes { failures[law.rawValue, default: 0] += 1 }
                    print(String(format: "ren-b-law| note %d %+.0f c, %@: %@ seam %.3f s, %@ ρ %.2f, rms %.1f/%.1f dB: %@ %@",
                                 note, cents, law.rawValue, seam.side.rawValue, Double(seam.centreFrame) / 48_000,
                                 seam.law.rawValue, seam.correlation, seam.seamRmsDb, seam.activeRmsDb,
                                 verdict.description, verdict.passes ? "PASS" : "FAIL"))
                }
            }
        }
        print("ren-b-law| seams \(seams), G3 failures \(failures)")
        let product = ProvisionalRender.Tuning.product.partialCorrelationLaw.rawValue
        #expect((seams[product] ?? 0) >= 8, "too few seams measured")
        #expect(failures[product, default: 0] == 0, "the product's seam law fails G3 on \(failures[product, default: 0]) seams")
    }

    @Test("p2-ren Stage B: the PATCH MEMO changes no byte — a burst of edits builds from the memo (the earlier region REUSED, the new one rendered) exactly the file a memo-less build writes; a level edit inside a memoised region is a miss")
    func patchMemoIsPure() throws {
        let dir = try I1Signals.tempDir("ren-b-memo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        let old = Self.params(notes) { $0[0].pitchOffsetCents = 100 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let memo = ProvisionalRender.PatchMemo()
        func build(_ params: Params, _ name: String, memo: ProvisionalRender.PatchMemo?) throws -> ProvisionalRender.Built {
            var job = Self.job(source: voice.url, base: Self.base(baseURL, old), params: params, dir: dir, name: name)
            job.memo = memo
            return try Self.built(ProvisionalRender.build(job, isCancelled: { false }))
        }
        let a = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200 }
        let b = Self.params(notes) { $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[8].pitchOffsetCents = -150 }
        let c = Self.params(notes) {
            $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[2].amplitudeDb = -6; $0[8].pitchOffsetCents = -150
        }
        let builtA = try build(a, "a", memo: memo)
        #expect(builtA.reusedSpanFrames == 0 && builtA.renderedSpanFrames > 0)
        let warmB = try build(b, "b-warm", memo: memo)
        let coldB = try build(b, "b-cold", memo: nil)
        print("ren-b-memo| B warm: rendered \(warmB.renderedSpanFrames), reused \(warmB.reusedSpanFrames), \(warmB.millis); cold: rendered \(coldB.renderedSpanFrames), \(coldB.millis); memo \(memo.countForTesting) entries, \(memo.bytesForTesting) bytes")
        #expect(warmB.reusedSpanFrames > 0, "positive control: the memo reused nothing")
        #expect(warmB.renderedSpanFrames < coldB.renderedSpanFrames)
        #expect(try Self.bytes(warmB.url) == Self.bytes(coldB.url), "a memoised build is not the memo-less build's bytes")
        let warmC = try build(c, "c-warm", memo: memo)
        let coldC = try build(c, "c-cold", memo: nil)
        print("ren-b-memo| C warm: rendered \(warmC.renderedSpanFrames), reused \(warmC.reusedSpanFrames)")
        #expect(warmC.renderedSpanFrames > 0, "a level edit inside a memoised region was served from the memo")
        #expect(warmC.reusedSpanFrames > 0, "a level edit in one region re-rendered the other")
        #expect(try Self.bytes(warmC.url) == Self.bytes(coldC.url), "a memoised build is not the memo-less build's bytes")
        // The same note re-edited (a drag): the SAME region with new
        // transposes is a miss, never the previous drag step's audio.
        let d = Self.params(notes) {
            $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[2].amplitudeDb = -6; $0[8].pitchOffsetCents = -250
        }
        let warmD = try build(d, "d-warm", memo: memo)
        let coldD = try build(d, "d-cold", memo: nil)
        print("ren-b-memo| D warm: rendered \(warmD.renderedSpanFrames), reused \(warmD.reusedSpanFrames)")
        #expect(warmD.renderedSpanFrames > 0, "a re-edit of the same note was served from the memo")
        #expect(warmD.reusedSpanFrames > 0, "a re-edit of one note re-rendered the other region")
        #expect(try Self.bytes(warmD.url) == Self.bytes(coldD.url), "a memoised build is not the memo-less build's bytes")
        #expect(try Self.bytes(warmD.url) != Self.bytes(warmC.url), "control: the re-edit changed nothing")
        // The same region's LEVEL changed again (−6 → −3 dB): C's cluster, C's
        // transposes, only the mask differs, so only the key's MASK term can
        // make this a miss. (C's own miss above is also forced by its cluster
        // growing with the mask range, so C alone cannot isolate that term.)
        let e = Self.params(notes) {
            $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[2].amplitudeDb = -3; $0[8].pitchOffsetCents = -250
        }
        let warmE = try build(e, "e-warm", memo: memo)
        let coldE = try build(e, "e-cold", memo: nil)
        print("ren-b-memo| E warm: rendered \(warmE.renderedSpanFrames), reused \(warmE.reusedSpanFrames)")
        #expect(warmE.renderedSpanFrames > 0, "a level-only re-edit of a memoised region was served from the memo")
        #expect(warmE.reusedSpanFrames > 0, "a level re-edit of one region re-rendered the other")
        #expect(try Self.bytes(warmE.url) == Self.bytes(coldE.url), "a memoised build is not the memo-less build's bytes")
        #expect(try Self.bytes(warmE.url) != Self.bytes(warmD.url), "control: the level re-edit changed nothing")
    }

    @Test("p2-ren Stage B: the cap — a change spanning more than 40 % of the file (every note retuned) declines, and the bridge plays on")
    func capDeclinesAWideChange() async throws {
        let dir = try I1Signals.tempDir("ren-b-cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Self.voiceFile(dir, seconds: 5)
        let old = Self.params(voice.notes) { $0[0].pitchOffsetCents = 100 }
        let baseURL = try Self.finalRender(voice.url, old, dir: dir, name: "old")
        let everything = Self.params(voice.notes) { segs in for i in segs.indices { segs[i].pitchOffsetCents = 150 } }
        let outcome = try ProvisionalRender.build(
            Self.job(source: voice.url, base: Self.base(baseURL, old), params: everything, dir: dir, name: "all"),
            isCancelled: { false })
        guard case .declined(let reason) = outcome else {
            Issue.record("a whole-file change built a provisional")
            return
        }
        print("ren-b-cap| declined: \(reason)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("all~prov.caf").path))
    }

    @Test("p2-ren Stage B: the session wipe removes a folder whose process is gone and keeps a live one (pid 1) and a folder that is not a session")
    func sessionWipeKeepsLiveSessions() throws {
        let root = try I1Signals.tempDir("ren-b-wipe")
        defer { try? FileManager.default.removeItem(at: root) }
        // A pid that is not running: well above the pid range in use.
        var dead: pid_t = 99_990
        while kill(dead, 0) == 0 || errno != ESRCH { dead -= 1 }
        let names = ["\(dead)-DEAD", "1-LIVE", "\(getpid())-OURS", "notes"]
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        ProvisionalRenderStore.wipeDeadSessions(in: root, except: "\(getpid())-OURS")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["1-LIVE", "\(getpid())-OURS", "notes"], "left: \(left.sorted())")
    }

    // MARK: - §12 G2/G3 on the user's take (env-gated)

    /// |cents| between two renders' YIN pitch per 2048-frame window (hop 512)
    /// over frames voiced in both, octave-folded: median and p95.
    static func pitchAgreement(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> (median: Double, p95: Double, frames: Int) {
        var d: [Double] = []
        var i = 0
        let n = 2_048
        while i + n <= min(a.count, b.count) {
            let ra = (a.startIndex + i)..<(a.startIndex + i + n), rb = (b.startIndex + i)..<(b.startIndex + i + n)
            if let fa = I1Signals.yinHz(a[ra], sampleRate: 48_000, minHz: 70, maxHz: 1_000),
               let fb = I1Signals.yinHz(b[rb], sampleRate: 48_000, minHz: 70, maxHz: 1_000) {
                var c = I1Signals.cents(fb, from: fa)
                c -= 1_200 * (c / 1_200).rounded()
                d.append(abs(c))
            }
            i += 512
        }
        return (SpanRenderMetrics.percentile(d, 0.5), SpanRenderMetrics.percentile(d, 0.95), d.count)
    }

    /// G2 + G3 on the user's take, per note of I1's 7-note harness, for both
    /// bases (the SOURCE: an untouched take's first edit; a committed RENDER:
    /// a later edit), at a seam window of `REN_B_G2_W` seconds (default the
    /// product's):
    ///
    ///     REN_B_G2_TAKE="$DUR/take/dry-norm.wav" REN_B_G2_OUT=<dir> [REN_B_G2_W=0.5] \
    ///       ./scripts/test.sh --filter provisionalVersusFinalOnTheUsersTake
    ///
    /// Gates (§12 G2): before the patch, the final's bytes where both renders
    /// run the stretcher (the render base; the source base's prefix is the
    /// source, bounded and reported); in the extent, pitch |Δ| median ≤ 5 c
    /// and p95 ≤ 15 c against the final, and LSD mean ≤ max(1 dB, 1.5 × the
    /// phase-carry floor: two whole-file finals that differ only by an extra
    /// edit ≥ 2 s earlier); downstream the same LSD bound. G3 at every seam.
    @Test("p2-ren Stage B G2/G3: the provisional against the final on the user's take, 7 notes × {source base, render base} (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["REN_B_G2_TAKE"] != nil))
    func provisionalVersusFinalOnTheUsersTake() throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["REN_B_G2_TAKE"]))
        let out = URL(fileURLWithPath: try #require(env["REN_B_G2_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var tuning = ProvisionalRender.Tuning.product
        if let w = env["REN_B_G2_W"].flatMap(Double.init) { tuning.seamSearchSeconds = w }
        let work = try I1Signals.tempDir("ren-b-g2")
        defer { try? FileManager.default.removeItem(at: work) }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let loadStart = load
        let table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(take, .product))
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 7)
        let picked = (0..<7).map { candidates[$0 * (candidates.count - 1) / 6] }
        let identity = Params(ratio: 1, semitones: 0, formantPreserve: false)
        func set(_ edits: [(UUID, Double)]) -> Params {
            var segs = table.segments
            for (id, cents) in edits {
                if let i = segs.firstIndex(where: { $0.id == id }) { segs[i].pitchOffsetCents = cents }
            }
            return Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: PitchEditSet(segments: segs))
        }
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for (k, note) in picked.enumerated() {
            // An earlier note ≥ 2 s before (the render base's prior edit, and the floor's extra edit).
            let earlier = table.segments.last { $0.endSeconds < note.startSeconds - 2 && $0.detectedHz > 0 }
            for baseKind in ["source", "render"] {
                if baseKind == "render" && earlier == nil { continue }
                let prior: [(UUID, Double)] = baseKind == "render" ? [(earlier!.id, 100)] : []
                let old = baseKind == "source" ? identity : set(prior)
                let new = set(prior + [(note.id, 200)])
                let baseURL = baseKind == "source" ? take : try Self.finalRender(take, old, dir: work, name: "b\(k)")
                let finalURL = try Self.finalRender(take, new, dir: work, name: "f\(k)\(baseKind)")
                let outcome = try ProvisionalRender.build(
                    ProvisionalRender.Job(source: take,
                                          base: ProvisionalRender.Base(url: baseURL, params: old,
                                                                       name: baseKind == "source" ? "src" : "b\(k)",
                                                                       isSource: baseKind == "source",
                                                                       contourFallback: false),
                                          params: new, newKey: "n\(k)\(baseKind)",
                                          destination: work.appendingPathComponent("p\(k)\(baseKind).caf"),
                                          renderCacheDirectory: work, detector: .product),
                    tuning: tuning, isCancelled: { false })
                guard case .built(let built) = outcome else {
                    rows.append(["note": k, "base": baseKind, "outcome": "\(outcome)"])
                    failures.append("note \(k) \(baseKind): \(outcome)")
                    continue
                }
                let y = try I1Signals.read(built.url).planar[0]
                let final = try I1Signals.read(finalURL).planar[0]
                let base = try I1Signals.read(baseURL).planar[0]
                let patch = built.patchedFrames.first ?? 0..<0
                let prefix = 0..<patch.lowerBound
                let prefixDiffs = prefix.filter { y[$0].bitPattern != final[$0].bitPattern }.count
                let prefixDb = prefix.count > 0 ? SpanRenderMetrics.residualDb(Array(y[prefix]), Array(final[prefix])) : -300
                let extent = (built.extent.pitchRanges.first ?? patch).clamped(to: 0..<y.count)
                let pitch = Self.pitchAgreement(final[extent], y[extent])
                let lsd = SpanRenderMetrics.compare(Array(final[extent]), Array(y[extent]), sampleRate: 48_000,
                                                    minHz: 70, maxHz: 1_000)
                let downstream = patch.upperBound..<min(y.count, patch.upperBound + 96_000)
                let lsdDown = SpanRenderMetrics.compare(Array(final[downstream]), Array(y[downstream]),
                                                        sampleRate: 48_000, minHz: 70, maxHz: 1_000)
                // The phase-carry floor: the final vs the final with an extra edit ≥ 2 s earlier.
                var floorLsd = Double.nan
                var floorDown = Double.nan
                if let earlier {
                    let extra = baseKind == "render" ? set([(earlier.id, 250), (note.id, 200)])
                        : set([(earlier.id, 100), (note.id, 200)])
                    let control = try I1Signals.read(Self.finalRender(take, extra, dir: work, name: "c\(k)\(baseKind)")).planar[0]
                    floorLsd = SpanRenderMetrics.compare(Array(final[extent]), Array(control[extent]), sampleRate: 48_000,
                                                         minHz: 70, maxHz: 1_000).lsdMean
                    floorDown = SpanRenderMetrics.compare(Array(final[downstream]), Array(control[downstream]),
                                                          sampleRate: 48_000, minHz: 70, maxHz: 1_000).lsdMean
                }
                let lsdLimit = max(1, 1.5 * (floorLsd.isNaN ? 0 : floorLsd))
                let downLimit = max(1, 1.5 * (floorDown.isNaN ? 0 : floorDown))
                let spanFull = try Self.rawSpans(built, voice: take, params: new, dir: work, base: base)
                var seamRows: [[String: Any]] = []
                for seam in built.seams {
                    let start = seam.centreFrame - seam.crossfadeFrames / 2
                    let verdict = Self.seamVerdict(y: y, base: base, span: spanFull, fade: start..<(start + seam.crossfadeFrames))
                    seamRows.append(["side": seam.side.rawValue, "atSeconds": Double(seam.centreFrame) / 48_000,
                                     "crossfadeFrames": seam.crossfadeFrames, "law": seam.law.rawValue,
                                     "correlation": seam.correlation, "rmsDb": seam.seamRmsDb,
                                     "activeDb": seam.activeRmsDb, "quiet": seam.isQuiet,
                                     "g3": verdict.description, "g3Pass": verdict.passes])
                    if !verdict.passes { failures.append("note \(k) \(baseKind) \(seam.side.rawValue) seam G3: \(verdict)") }
                }
                let extentWaveDb = SpanRenderMetrics.residualDb(Array(y[extent]), Array(final[extent]))
                let row: [String: Any] = [
                    "note": k, "noteStart": note.startSeconds, "noteEnd": note.endSeconds, "base": baseKind,
                    "kind": built.kind.rawValue, "assembly": built.assembly.rawValue, "prefixExact": built.extent.prefixExact,
                    "patchSeconds": Double(patch.count) / 48_000, "spanFrames": built.spanFrames, "stepMs": built.millis,
                    "prefixDifferingSamples": prefixDiffs, "prefixResidualDb": prefixDb,
                    "pitchMedianC": pitch.median, "pitchP95C": pitch.p95, "pitchFrames": pitch.frames,
                    "lsdMeanDb": lsd.lsdMean, "lsdFloorDb": floorLsd, "lsdLimitDb": lsdLimit,
                    "downstreamLsdDb": lsdDown.lsdMean, "downstreamFloorDb": floorDown, "downstreamLimitDb": downLimit,
                    "extentWaveformResidualDb": extentWaveDb, "seams": seamRows,
                ]
                rows.append(row)
                print(String(format: "ren-b-g2| note %d (%.2f s) %@ base: %@ %@, patch %.2f s, build %.0f ms; prefix %d diffs (%.1f dB); pitch med %.1f / p95 %.1f c (%d fr); LSD %.2f dB vs floor %.2f (limit %.2f); downstream LSD %.2f vs %.2f; waveform %.1f dB; seams %d",
                             k, note.startSeconds, baseKind, built.kind.rawValue, built.assembly.rawValue,
                             Double(patch.count) / 48_000, built.millis.values.reduce(0, +), prefixDiffs, prefixDb,
                             pitch.median, pitch.p95, pitch.frames, lsd.lsdMean, floorLsd, lsdLimit,
                             lsdDown.lsdMean, floorDown, extentWaveDb, built.seams.count))
                if built.extent.prefixExact && prefixDiffs != 0 { failures.append("note \(k) \(baseKind): prefix differs in \(prefixDiffs)") }
                if !(pitch.median <= 5 && pitch.p95 <= 15) { failures.append("note \(k) \(baseKind): pitch \(pitch)") }
                if !(lsd.lsdMean <= lsdLimit) { failures.append("note \(k) \(baseKind): LSD \(lsd.lsdMean) > \(lsdLimit)") }
                if !(lsdDown.lsdMean <= downLimit || lsdDown.lsdFrames == 0) { failures.append("note \(k) \(baseKind): downstream LSD \(lsdDown.lsdMean) > \(downLimit)") }
            }
        }
        getloadavg(&load, 3)
        let report: [String: Any] = ["take": take.path, "seamSearchSeconds": tuning.seamSearchSeconds,
                                     "loadStart": loadStart, "loadEnd": load, "rows": rows, "failures": failures]
        let json = out.appendingPathComponent("g2-w\(tuning.seamSearchSeconds).json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: json)
        print("ren-b-g2| wrote \(json.path); load \(loadStart) → \(load); failures: \(failures)")
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: - R11 and the builder's cost against the take's length (env-gated, TIMED)

    /// R11 (ms of span render per second of span) at the start, middle and end
    /// of each take, the extent's cost, and the whole provisional build's cost
    /// (a RENDER base: clone-and-patch; a SOURCE base: the O(file) rewrite),
    /// against the take's length. Run under the timing lock:
    ///
    ///     REN_B_R11_TAKES="<wav>[,<wav>…]" [REN_B_R11_MANIFEST=<i1lt manifest.json>] \
    ///       REN_B_R11_OUT=<dir> ./scripts/test.sh --filter costAgainstTakeLength
    @Test("p2-ren Stage B: R11, the extent and the provisional build against the take's length (env-gated, timed)",
          .enabled(if: ProcessInfo.processInfo.environment["REN_B_R11_TAKES"] != nil))
    func costAgainstTakeLength() throws {
        let env = ProcessInfo.processInfo.environment
        let takes = try #require(env["REN_B_R11_TAKES"]).split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let out = URL(fileURLWithPath: try #require(env["REN_B_R11_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        struct Manifest: Decodable {
            struct Note: Decodable { let start: Double; let end: Double; let hz: Double }
            struct Take: Decodable { let path: String; let notes: [Note] }
            let takes: [Take]
        }
        let manifest = try env["REN_B_R11_MANIFEST"].map {
            try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let loadStart = load
        var results: [[String: Any]] = []
        for take in takes {
            let work = try I1Signals.tempDir("ren-b-r11")
            defer { try? FileManager.default.removeItem(at: work) }
            let segments: [NoteSegment]
            if let entry = manifest?.takes.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL == take.standardizedFileURL }) {
                segments = entry.notes.map { NoteSegment(startSeconds: $0.start, endSeconds: $0.end, detectedHz: $0.hz, detectedConfidence: 0.95) }
            } else {
                segments = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(take, .product)).segments
            }
            let source = try StretchRenderCache.SpanSource.open(take)
            let seconds = Double(source.frames) / source.sampleRate
            let voiced = segments.filter { $0.durationSeconds >= 0.3 && $0.detectedHz > 0 }
            try #require(voiced.count >= 3)
            let first = voiced[0], middle = voiced[voiced.count / 2], last = voiced[voiced.count - 1]
            func params(_ edits: [(UUID, Double)]) -> Params {
                var segs = segments
                for (id, c) in edits { if let i = segs.firstIndex(where: { $0.id == id }) { segs[i].pitchOffsetCents = c } }
                return Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: PitchEditSet(segments: segs))
            }
            // R11 at three positions.
            var r11: [String: Double] = [:]
            for (label, note) in [("start", first), ("middle", middle), ("end", last)] {
                for spanSeconds in [0.6, 6.0] {
                    let start = max(0, min(Int(note.startSeconds * source.sampleRate), source.frames - Int(spanSeconds * source.sampleRate)))
                    let frames = start..<(start + Int(spanSeconds * source.sampleRate))
                    var times: [Double] = []
                    for _ in 0..<5 {
                        let t0 = ContinuousClock.now
                        _ = try StretchRenderCache.renderOutputFrames(frames, of: source, params: params([(note.id, 200)]),
                                                                     renderCacheDirectory: work, detector: .product,
                                                                     isCancelled: { false })
                        times.append(ms(ContinuousClock.now - t0))
                    }
                    r11["\(label) \(spanSeconds) s"] = median(times) / spanSeconds
                }
            }
            // The extent: the old set (first note +100 c) against it plus the middle note +200 c.
            let old = params([(first.id, 100)])
            let new = params([(first.id, 100), (middle.id, 200)])
            var extentMs: [Double] = []
            for _ in 0..<5 {
                let t0 = ContinuousClock.now
                _ = try RenderDiff.extent(old: .init(params: old, curveContour: nil), new: .init(params: new, curveContour: nil),
                                          sourceFrames: source.frames, channels: source.channels, sampleRate: source.sampleRate)
                extentMs.append(ms(ContinuousClock.now - t0))
            }
            // The whole build, from a committed render and from the source.
            let t0 = ContinuousClock.now
            let baseURL = try Self.finalRender(take, old, dir: work, name: "base")
            let finalMs = ms(ContinuousClock.now - t0)
            var buildMs: [Double] = []
            var steps: [String: Double] = [:]
            for trial in 0..<3 {
                let t1 = ContinuousClock.now
                let built = try Self.built(ProvisionalRender.build(
                    Self.job(source: take, base: Self.base(baseURL, old), params: new, dir: work, name: "r\(trial)"),
                    isCancelled: { false }))
                buildMs.append(ms(ContinuousClock.now - t1))
                steps = built.millis
                #expect(built.kind == .spliced && built.assembly == .clone)
            }
            var sourceBuildMs: [Double] = []
            var sourceSteps: [String: Double] = [:]
            for trial in 0..<3 {
                let t1 = ContinuousClock.now
                let built = try Self.built(ProvisionalRender.build(
                    Self.job(source: take, base: Self.base(take, Params(ratio: 1, semitones: 0, formantPreserve: false), isSource: true),
                             params: params([(middle.id, 200)]), dir: work, name: "s\(trial)"),
                    isCancelled: { false }))
                sourceBuildMs.append(ms(ContinuousClock.now - t1))
                sourceSteps = built.millis
                #expect(built.kind == .spliced && built.assembly == .rewrite)
            }
            let row: [String: Any] = [
                "take": take.lastPathComponent, "seconds": seconds, "channels": source.channels, "notes": segments.count,
                "r11MsPerSecond": r11, "extentMsMedian": median(extentMs),
                "buildFromRenderMsMedian": median(buildMs), "buildFromRenderSteps": steps,
                "buildFromSourceMsMedian": median(sourceBuildMs), "buildFromSourceSteps": sourceSteps,
                "wholeFileFinalMs": finalMs,
            ]
            results.append(row)
            print(String(format: "ren-b-r11| %@ (%.0f s, %d notes): extent %.2f ms; build from render %.0f ms %@; from source %.0f ms %@; whole-file final %.0f ms; R11 %@",
                         take.lastPathComponent, seconds, segments.count, median(extentMs), median(buildMs), "\(steps)",
                         median(sourceBuildMs), "\(sourceSteps)", finalMs, "\(r11.sorted { $0.key < $1.key })"))
        }
        getloadavg(&load, 3)
        let report: [String: Any] = ["loadStart": loadStart, "loadEnd": load, "takes": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("r11-extent-build.json"))
        print("ren-b-r11| load \(loadStart) → \(load)")
    }

    // MARK: - Probe: the FIRST pitch edit on an untouched take (env-gated)

    /// The design's §6 step 1 bases an identity clip's first provisional on
    /// its SOURCE, and its §11 step 9 declines a provisional when the branch
    /// changes. The first pitch edit on a take is both: source → the curve
    /// path. Whether a source base is usable is a measurement: how far is the
    /// curve render, OUTSIDE the edited note (where every chunk transposes by
    /// 0), from the source it was rendered from?
    ///
    ///     REN_B_PROBE_TAKE="$DUR/take/dry-norm.wav" ./scripts/test.sh --filter firstEditColouringProbe
    @Test("p2-ren Stage B probe: the curve render's prefix before a first edit, against the SOURCE (the stretcher at 0 st), on the user's take (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["REN_B_PROBE_TAKE"] != nil))
    func firstEditColouringProbe() async throws {
        let take = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["REN_B_PROBE_TAKE"]))
        let work = try I1Signals.tempDir("ren-b-probe")
        defer { try? FileManager.default.removeItem(at: work) }
        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let table = PitchNoteTable.detected(from: detection)
        let audio = try I1Signals.read(take)
        let sr = audio.sampleRate
        let source = try StretchRenderCache.SpanSource.open(take)
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 7)
        let picked = (0..<7).map { candidates[$0 * (candidates.count - 1) / 6] }
        for (k, note) in picked.enumerated() {
            var set = table
            let index = try #require(set.segments.firstIndex { $0.id == note.id })
            set.segments[index].pitchOffsetCents = 200
            let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                                   pitchEdits: set)
            let end = Int(((note.startSeconds - 0.25) * sr).rounded())
            guard end > Int(sr) else { continue }
            let prefix = try StretchRenderCache.renderOutputFrames(
                0..<end, of: source, params: params, renderCacheDirectory: work,
                detector: .product, isCancelled: { false })
            let src = Array(audio.planar[0][0..<end])
            let db = SpanRenderMetrics.residualDb(prefix.planar[0], src)
            let worst = SpanRenderMetrics.worstDifference(prefix.planar[0], src)
            let peak = src.map { abs($0) }.max() ?? 0
            // The steady part only: past the first 0.2 s (the stretcher's
            // own start-up), where a splice would join.
            let steady = Int(0.2 * sr)
            let steadyDb = SpanRenderMetrics.residualDb(Array(prefix.planar[0][steady...]),
                                                        Array(src[steady...]))
            print(String(format: "ren-b-probe| note %d at %.2f s: curve prefix (%.2f s) vs source: %.1f dB (after 0.2 s: %.1f dB), worst |Δ| %.4f at %.3f s (source peak %.3f)",
                         k, note.startSeconds, Double(end) / sr, db, steadyDb, worst.value,
                         Double(worst.frame) / sr, peak))
        }
    }
}
