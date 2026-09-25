import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// I7a merged with U-C (`docs/design/2026-09-24-pitch-editor-interaction-batch.md`
/// §10, ruled in §17): THE LEVEL MASK, RENDERED.
///
/// `PitchNoteLevelTests` (DAWCore) pins the mask as numbers. This suite asks
/// the RENDER what it wrote, through `StretchRenderCache.performRender`, the
/// body of the cache's detached job and the one function every render runs:
///  * THE PHYSICS GATE. A cleared note is exact zeros between its ramps
///    (numeric `== 0`), and the same gate REJECTS a −72 dB note, so it can
///    fail.
///  * −72 dB is a LEVEL: the plateau is the source × 10^(−72/20).
///  * THE INVARIANCE CONTROLS, which catch the bugs a headline metric passes:
///    outside the edited note a level-only render keeps the SOURCE's own bytes;
///    a stretched clip's and a tuned clip's other frames do not move; no edge
///    clicks; and the timeline the mask uses is the one the audio is on.
///
/// Deliberately NOT `@MainActor`, and nothing here awaits a main-actor type.
/// Every call is nonisolated DSP. The one leg through the real cache
/// (`renderIfNeeded` and its identity bypass) lives in the existing
/// `@MainActor` `StretchEngineTests`, so `MainActorOccupancySiteTests` Leg C
/// does not move.
@Suite("I7a/U-C — a cleared note renders as silence, a level as a level, and nothing else moves")
struct NoteLevelRenderTests {
    static let sampleRate = 48_000.0

    /// The design's ramp, restated as a literal (design §17.1 picked 10 ms).
    /// `rampIsTheDesignsTenMilliseconds` ties it to the product constant.
    static let rampSeconds = 0.010

    /// The note table every render edits. B (index 1) is the note under test.
    /// C ABUTS it (a shared boundary at 0.60 s, the way `PitchNoteSplitter`
    /// leaves a sung phrase), and A and D sit across gaps.
    static let spans: [(start: Double, end: Double)] =
        [(0.10, 0.30), (0.40, 0.60), (0.60, 0.80), (0.85, 0.95)]
    static let noteA = 0, noteB = 1, noteC = 2

    /// Fixed ids, so two tables that differ only in an edit digest differently
    /// only because of that edit.
    static let ids: [UUID] = (1...4).map {
        UUID(uuidString: String(format: "A7A00000-0000-4000-8000-%012d", $0))!
    }

    static func table(cleared: Set<Int> = [], levelsDb: [Int: Double] = [:],
                      cents: [Int: Double] = [:]) -> PitchEditSet {
        var notes: [NoteSegment] = []
        for index in spans.indices {
            notes.append(NoteSegment(
                id: ids[index], startSeconds: spans[index].start, endSeconds: spans[index].end,
                detectedHz: 220.625, detectedConfidence: 0.9,
                pitchOffsetCents: cents[index] ?? 0,
                amplitudeDb: levelsDb[index] ?? 0,
                isCleared: cleared.contains(index)))
        }
        return PitchEditSet(segments: notes)
    }

    // MARK: - Fixtures

    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-i7a-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stereo Float32 WAV at 48 kHz. The channels DIFFER on purpose, so a
    /// pass that processed one channel twice, or swapped them, fails a
    /// per-channel byte compare.
    static func writeStereo(_ left: [Float], _ right: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for frame in left.indices {
            channels[0][frame] = left[frame]
            channels[1][frame] = right[frame]
        }
        buffer.frameLength = AVAudioFrameCount(left.count)
        try file.write(from: buffer)
    }

    /// One second of two sines. Channel 0 is 220.625 Hz, chosen so the note
    /// B start edge (0.40 s = 88.25 cycles) sits on a PEAK: a missing ramp
    /// there is a 0.5 step, not a step that a zero crossing would hide.
    static func writeTone(in dir: URL) throws -> URL {
        let frames = Int(sampleRate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            left[frame] = Float(0.5 * sin(2 * Double.pi * 220.625 * t))
            right[frame] = Float(0.35 * sin(2 * Double.pi * 331.0 * t + 0.7))
        }
        let url = dir.appendingPathComponent("tone.wav")
        try writeStereo(left, right, to: url)
        return url
    }

    /// Planar floats from an audio file. A local copy of `TestSignals.readFile`,
    /// which is `@MainActor` (its enum is). Hopping to the main actor to read
    /// a file would make this DSP suite main-actor work for no reason. The
    /// loop is there because `AVAudioFile.read(into:)` can return short.
    static func readFile(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let channelCount = Int(file.processingFormat.channelCount)
        var result = [[Float]](repeating: [], count: channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: 32_768) else {
            throw EngineError.renderFailed("read buffer allocation failed")
        }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw EngineError.renderFailed("read failed for \(url.path)")
            }
            for channel in 0..<channelCount {
                result[channel].append(contentsOf: UnsafeBufferPointer(
                    start: channels[channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }

    /// One render through `performRender`, read back as planar floats. Nothing
    /// here needs a detected contour, so the outcome must be `.rendered` at
    /// `destination`. A fallback would mean a level edit leaked into
    /// `needsDetectedContour`.
    static func render(_ source: URL, ratio: Double = 1, semitones: Double = 0,
                       edits: PitchEditSet?) throws -> [[Float]] {
        let dir = try tempDir("out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("rendered.caf")
        let outcome = try StretchRenderCache.performRender(
            source: source,
            partial: dir.appendingPathComponent("rendered.partial.caf"),
            destination: destination,
            fallbackDestination: dir.appendingPathComponent("legacy.caf"),
            params: .init(ratio: ratio, semitones: semitones, formantPreserve: false,
                          pitchEdits: edits),
            renderCacheDirectory: dir, detector: .product, isCancelled: { false })
        #expect(outcome == .rendered(destination),
                "a level edit must render at its own key, never as a contour fallback")
        return try Self.readFile(destination)
    }

    // MARK: - Measuring

    /// Output frames whose SOURCE second lies in [from, to) at `ratio`: the
    /// design's one mapping, frame / (ratio × sampleRate), restated here. `trim`
    /// frames come off each end so no assertion leans on how a boundary rounds.
    static func frames(_ from: Double, _ to: Double, ratio: Double = 1,
                       trim: Int = 1) -> Range<Int> {
        let low = Int((from * ratio * sampleRate).rounded(.up)) + trim
        let high = Int((to * ratio * sampleRate).rounded(.down)) - trim
        return low..<max(low, high)
    }

    /// Every output frame OUTSIDE [from, to) at `ratio`, with the same trim.
    static func framesOutside(_ from: Double, _ to: Double, ratio: Double = 1,
                              count: Int, trim: Int = 1) -> [Range<Int>] {
        let low = Int((from * ratio * sampleRate).rounded(.down)) - trim
        let high = Int((to * ratio * sampleRate).rounded(.up)) + trim
        return [0..<max(0, low), min(count, high)..<count]
    }

    static func nonZeroCount(_ audio: [[Float]], in range: Range<Int>) -> Int {
        audio.reduce(0) { total, channel in
            total + channel[range].reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        }
    }

    /// Samples whose BIT PATTERN differs: not "close", the same bytes.
    static func bitMismatches(_ a: [[Float]], _ b: [[Float]], in ranges: [Range<Int>]) -> Int {
        var mismatches = 0
        for channel in 0..<min(a.count, b.count) {
            for range in ranges {
                for frame in range where a[channel][frame].bitPattern != b[channel][frame].bitPattern {
                    mismatches += 1
                }
            }
        }
        return mismatches
    }

    /// NaN, ±Inf and subnormal samples: none may leave the mask pass.
    static func abnormalCount(_ audio: [[Float]]) -> Int {
        audio.reduce(0) { total, channel in
            total + channel.reduce(0) {
                $0 + ((!$1.isFinite || ($1 != 0 && abs($1) < Float.leastNormalMagnitude)) ? 1 : 0)
            }
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
            .squareRoot()
    }

    static func maxFirstDifference(_ audio: [[Float]]) -> Double {
        var worst = 0.0
        for channel in audio {
            for frame in channel.indices.dropFirst() {
                worst = max(worst, abs(Double(channel[frame]) - Double(channel[frame - 1])))
            }
        }
        return worst
    }

    // MARK: - The physics gate

    /// ⭐ THE GATE (design §17.5): `sample == 0`, numerically, between the ramps,
    /// on both channels. A byte compare would be the wrong gate: `x × 0.0` is
    /// −0.0 for negative `x`, which is a zero. The −72 dB render is the gate's
    /// own control. It is the defect this gate exists to catch (a clear
    /// implemented as "very quiet"), and the gate must reject it here, or the
    /// zero count above it proves nothing.
    @Test("physics gate: a cleared note renders as exact zeros between its ramps, and the same gate rejects −72 dB")
    func clearedNoteRendersExactZerosBetweenItsRamps() throws {
        let dir = try Self.tempDir("gate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let cleared = try Self.render(source, edits: Self.table(cleared: [Self.noteB]))
        let quiet = try Self.render(source, edits: Self.table(levelsDb: [Self.noteB: -72]))

        let b = Self.spans[Self.noteB]
        let plateau = Self.frames(b.start + Self.rampSeconds, b.end - Self.rampSeconds)
        #expect(plateau.count > 8_000, "the gate must cover the note's 180 ms plateau")
        let clearedNonZero = Self.nonZeroCount(cleared, in: plateau)
        #expect(clearedNonZero == 0,
                "\(clearedNonZero) non-zero samples between a cleared note's ramps: a clear is silence")

        // ⭐ THE CONTROL: −72 dB is 2.5e-4, not silence, and this gate must see it.
        let quietNonZero = Self.nonZeroCount(quiet, in: plateau)
        #expect(quietNonZero > plateau.count,
                "CONTROL FAILED: the zeros gate passed a −72 dB note (\(quietNonZero) non-zero), so it cannot tell a clear from a quiet note")

        // Denormal / NaN guard over the whole render.
        #expect(Self.abnormalCount(cleared) == 0)
        #expect(Self.abnormalCount(quiet) == 0)
        print("[measured] I7a physics gate: cleared plateau \(plateau.count) frames × 2 ch, "
              + "\(clearedNonZero) non-zero; the −72 dB control has \(quietNonZero) non-zero")
    }

    /// −72 dB is a LEVEL (design §17.2), the same meaning it has on a clip:
    /// 10^(−72/20) = 2.5e-4. A render that floors it to silence (the "−72 dB is
    /// the bottom of the fader, so it is off" defect) fails both the ratio and
    /// the level below.
    @Test("−72 dB renders as the source × 10^(−72/20) between the ramps: a level, measured, never silence")
    func minus72DbPlateauIsTheSourceTimesTheLevel() throws {
        let dir = try Self.tempDir("level")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let quiet = try Self.render(source, edits: Self.table(levelsDb: [Self.noteB: -72]))
        let original = try Self.readFile(source)
        let gain = pow(10.0, -72.0 / 20)

        let b = Self.spans[Self.noteB]
        let plateau = Self.frames(b.start + Self.rampSeconds, b.end - Self.rampSeconds)
        var worstRelative = 0.0
        var checked = 0
        for channel in 0..<2 {
            for frame in plateau where abs(original[channel][frame]) > 1e-3 {
                let ratio = Double(quiet[channel][frame]) / Double(original[channel][frame])
                worstRelative = max(worstRelative, abs(ratio / gain - 1))
                checked += 1
            }
        }
        #expect(checked > 10_000)
        // Float32 rounding of `Float(gain)` and of the product: under 2.4e-7.
        #expect(worstRelative < 1e-6,
                "the −72 dB plateau is not the source × 10^(−72/20): worst relative error \(worstRelative)")
        for channel in 0..<2 {
            let levelDb = 20 * log10(Self.rms(quiet[channel][plateau])
                                     / Self.rms(original[channel][plateau]))
            #expect(abs(levelDb - (-72)) < 0.001,
                    "channel \(channel) plays at \(levelDb) dB relative, not −72 dB")
            print("[measured] I7a −72 dB plateau, channel \(channel): \(levelDb) dB relative to the source")
        }
        #expect(Self.abnormalCount(quiet) == 0)
    }

    // MARK: - Invariance controls

    /// ⭐ THE LEVEL-ONLY PATH (design §17.5): an unstretched, untransposed clip
    /// whose only edits are levels never runs the stretcher. So every sample
    /// outside the edited note is the SOURCE's own bytes, including note C,
    /// which abuts it. The control proves the gate can fail: a stretcher pass
    /// at ratio 1 (what the render would do without the level-only branch)
    /// moves those bytes.
    @Test("level-only render: outside the edited note every sample keeps the source's own bytes, and the stretcher never ran")
    func levelOnlyRenderKeepsTheSourceBytesOutsideTheNote() throws {
        let dir = try Self.tempDir("bytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let original = try Self.readFile(source)
        let count = original[0].count
        let b = Self.spans[Self.noteB]
        let outside = Self.framesOutside(b.start, b.end, count: count)
        let inside = Self.frames(b.start, b.end)

        // ⭐ THE CONTROL, FIRST: a ratio-1 stretch is not its own input, so a
        // render that let the stretcher run could not pass the gate below.
        let stretchedAtIdentity = try OfflineStretcher.stretch(
            input: original, sampleRate: Self.sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)
        let stretcherMoved = Self.bitMismatches(stretchedAtIdentity, original, in: outside)
        #expect(stretcherMoved > 0,
                "CONTROL FAILED: a ratio-1 stretcher pass kept every byte, so the byte gate below could not see one")

        for (label, edits) in [("cleared", Self.table(cleared: [Self.noteB])),
                               ("−72 dB", Self.table(levelsDb: [Self.noteB: -72])),
                               ("+6 dB", Self.table(levelsDb: [Self.noteB: 6]))] {
            let rendered = try Self.render(source, edits: edits)
            #expect(rendered.count == 2)
            #expect(rendered[0].count == count && rendered[1].count == count,
                    "\(label): a level-only render must be exactly the source's length")
            let moved = Self.bitMismatches(rendered, original, in: outside)
            #expect(moved == 0,
                    "\(label): \(moved) samples outside the edited note left the source's bytes")
            // And the edit itself happened, so the equality above is about something.
            #expect(Self.bitMismatches(rendered, original, in: [inside]) > inside.count,
                    "\(label): the edited note did not change")
            #expect(Self.abnormalCount(rendered) == 0)
        }
        print("[measured] I7a level-only path: 0 of \(outside.map(\.count).reduce(0, +)) frames × 2 ch "
              + "moved outside the note; a ratio-1 stretcher pass would have moved \(stretcherMoved)")
    }

    /// No click (design §17.1): y = g·x, so the step between two samples is at
    /// most max(1, plateau)·|Δx| + |x|·|Δg|, and a raised cosine of length T
    /// changes g by at most |plateau − 1|·(π/2)/(T·sr) per sample. A missing or
    /// hard-edged ramp is a step of up to the waveform's own value. Channel 0
    /// sits on a 0.5 peak at the note's start edge.
    @Test("no click: every rendered step stays inside the ramp's own slope bound, for a clear, −72 dB and +6 dB")
    func noClickAtTheNoteEdges() throws {
        let dir = try Self.tempDir("click")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let original = try Self.readFile(source)
        let sourceStep = Self.maxFirstDifference(original)
        let peak = Double(original.flatMap { $0 }.map { abs($0) }.max() ?? 0)
        for (label, plateau, edits) in [
            ("cleared", 0.0, Self.table(cleared: [Self.noteB])),
            ("−72 dB", pow(10.0, -72.0 / 20), Self.table(levelsDb: [Self.noteB: -72])),
            ("+6 dB", pow(10.0, 6.0 / 20), Self.table(levelsDb: [Self.noteB: 6])),
        ] {
            let rendered = try Self.render(source, edits: edits)
            let gainStep = abs(plateau - 1) * (Double.pi / 2) / (Self.rampSeconds * Self.sampleRate)
            let bound = max(1, plateau) * sourceStep + peak * gainStep + 1e-6
            let step = Self.maxFirstDifference(rendered)
            #expect(step <= bound,
                    "\(label): a \(step) step against a bound of \(bound): the note's edge clicks")
            print("[measured] I7a no-click, \(label): max step \(step), bound \(bound), "
                  + "source's own max step \(sourceStep)")
        }
    }

    /// A STRETCHED clip (ratio 1.5, the constant path): the mask runs after the
    /// stretcher on the same output the unedited clip plays, so every frame
    /// outside the note is the unedited render's own. The brief's tolerance is
    /// 0.1 dB, and bit identity is the stronger claim, measured here. The note
    /// is silenced on the STRETCHED timeline: source 0.41..0.59 s is output
    /// 0.615..0.885 s.
    @Test("a stretched clip (ratio 1.5): clearing a note moves no frame outside it, and silences it on the stretched timeline")
    func stretchedClipNeighboursAreUntouched() throws {
        let dir = try Self.tempDir("stretched")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let ratio = 1.5
        let plain = try Self.render(source, ratio: ratio, edits: Self.table())
        let cleared = try Self.render(source, ratio: ratio, edits: Self.table(cleared: [Self.noteB]))
        let count = plain[0].count
        #expect(count == Int(Self.sampleRate * ratio))
        #expect(cleared[0].count == count)

        let b = Self.spans[Self.noteB]
        let outside = Self.framesOutside(b.start, b.end, ratio: ratio, count: count)
        let moved = Self.bitMismatches(cleared, plain, in: outside)
        #expect(moved == 0, "\(moved) samples outside the cleared note moved on a stretched clip")

        // The brief's own criterion: 10 ms windows over the neighbours, within 0.1 dB.
        var worstDb = 0.0
        let window = Int(Self.sampleRate * 0.010)
        for channel in 0..<2 {
            for range in outside {
                var start = range.lowerBound
                while start + window <= range.upperBound {
                    let span = start..<(start + window)
                    let reference = Self.rms(plain[channel][span])
                    if reference > 1e-6 {
                        worstDb = max(worstDb,
                                      abs(20 * log10(Self.rms(cleared[channel][span]) / reference)))
                    }
                    start += window
                }
            }
        }
        #expect(worstDb <= 0.1, "a neighbour window moved \(worstDb) dB")

        let plateau = Self.frames(b.start + Self.rampSeconds, b.end - Self.rampSeconds, ratio: ratio)
        #expect(plateau.lowerBound > Int(b.start * Self.sampleRate) + 5_000,
                "the plateau must be on the STRETCHED timeline, not the source's")
        #expect(Self.nonZeroCount(cleared, in: plateau) == 0,
                "the cleared note is not silent on the stretched timeline")
        #expect(Self.nonZeroCount(plain, in: plateau) > plateau.count,
                "CONTROL FAILED: the unedited stretched render is silent there too")
        #expect(Self.abnormalCount(cleared) == 0)
        print("[measured] I7a stretched clip (ratio 1.5): \(moved) samples moved outside the note, "
              + "worst neighbour window \(worstDb) dB")
    }

    /// The mask assumes output frame n plays source second n / (ratio × sr).
    /// If the audio were somewhere else, a clear would silence the wrong
    /// sound: the note's own edge would leak, and the neighbour would lose a
    /// slice. MEASURED on both render paths, with a tone that starts hard at
    /// source 0.5 s. The tolerance is the ramp: an error smaller than the ramp
    /// lands inside the ramp, which fades that audio anyway.
    @Test("the mask's timeline is where the audio is: a tone starting at source 0.5 s starts at output 0.5 × ratio, on both render paths")
    func theMaskTimelineIsWhereTheAudioIs() throws {
        let dir = try Self.tempDir("align")
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = Int(Self.sampleRate)
        let onsetFrame = Int(0.5 * Self.sampleRate)
        var tone = [Float](repeating: 0, count: frames)
        for frame in onsetFrame..<frames {
            tone[frame] = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame - onsetFrame)
                                          / Self.sampleRate))
        }
        let source = dir.appendingPathComponent("onset.wav")
        try Self.writeStereo(tone, tone, to: source)
        // A tuning far from the onset puts the render on the CURVE path
        // without transposing the tone being timed.
        let farTuning = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.05, endSeconds: 0.15, detectedHz: 440,
                        detectedConfidence: 0.9, pitchOffsetCents: 100)
        ])
        for (label, ratio, edits) in [("constant path, ratio 1.5", 1.5, nil as PitchEditSet?),
                                      ("curve path, ratio 1", 1.0, farTuning),
                                      ("curve path, ratio 1.5", 1.5, farTuning)] {
            let rendered = try Self.render(source, ratio: ratio, edits: edits)
            let expected = Int(0.5 * ratio * Self.sampleRate)
            let onset = try #require(rendered[0].firstIndex { abs($0) >= 0.25 },
                                     "\(label): the tone never reached half amplitude")
            let errorSourceMs = Double(onset - expected) / (ratio * Self.sampleRate) * 1_000
            print("[measured] I7a mask alignment, \(label): half-amplitude onset at output frame "
                  + "\(onset), expected \(expected), error \(errorSourceMs) ms of source time")
            #expect(abs(errorSourceMs) <= Self.rampSeconds * 1_000,
                    "\(label): the audio is \(errorSourceMs) ms from where the mask puts it, more than one ramp")
        }
    }

    /// A TUNED clip takes the curve path. Clearing a different note must not
    /// move the tuning: `clearingLeavesThePitchCurveUnchanged` pins the curve
    /// as numbers, and this pins the rendered bytes.
    @Test("a tuned clip: clearing one note moves no frame outside it, and silences it through the curve path")
    func clearingOneNoteOfATunedClipTouchesOnlyThatNote() throws {
        let dir = try Self.tempDir("tuned")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let original = try Self.readFile(source)
        let tuned = try Self.render(source, edits: Self.table(cents: [Self.noteA: 50]))
        let tunedCleared = try Self.render(
            source, edits: Self.table(cleared: [Self.noteB], cents: [Self.noteA: 50]))
        let count = tuned[0].count
        #expect(tunedCleared[0].count == count)

        // POSITIVE CONTROL: the curve path ran, and it moved note A.
        let a = Self.spans[Self.noteA]
        let aFrames = Self.frames(a.start + 0.05, a.end - 0.05)
        #expect(Self.bitMismatches(tuned, original, in: [aFrames]) > aFrames.count,
                "CONTROL FAILED: a +50 cent tuning did not change note A, so the curve path never ran")

        let b = Self.spans[Self.noteB]
        let outside = Self.framesOutside(b.start, b.end, count: count)
        let moved = Self.bitMismatches(tunedCleared, tuned, in: outside)
        #expect(moved == 0, "clearing note B moved \(moved) samples of the tuned render outside it")
        let plateau = Self.frames(b.start + Self.rampSeconds, b.end - Self.rampSeconds)
        #expect(Self.nonZeroCount(tunedCleared, in: plateau) == 0)
        #expect(Self.nonZeroCount(tuned, in: plateau) > plateau.count)
        #expect(Self.abnormalCount(tunedCleared) == 0)
    }

    /// Two ABUTTING cleared notes (a sung phrase's shared boundary): the
    /// literal "ramp to 1 at each edge" rule would play a 20 ms burst at the
    /// junction. The mask meets at the midpoint of the two plateaus, 0, so the
    /// render stays silent across it (see `PitchNoteLevel.swift`'s banner).
    @Test("two abutting cleared notes render silent ACROSS their shared boundary: no 20 ms burst at the junction")
    func abuttingClearedNotesRenderSilentAcrossTheJunction() throws {
        let dir = try Self.tempDir("junction")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        let both = try Self.render(source, edits: Self.table(cleared: [Self.noteB, Self.noteC]))
        let b = Self.spans[Self.noteB]
        let c = Self.spans[Self.noteC]
        #expect(b.end == c.start, "the fixture's notes must share their boundary bit for bit")
        let junction = Self.frames(b.end - Self.rampSeconds, c.start + Self.rampSeconds)
        let across = Self.frames(b.start + Self.rampSeconds, c.end - Self.rampSeconds)
        #expect(Self.nonZeroCount(both, in: junction) == 0,
                "the junction of two cleared notes is not silent: a burst plays between them")
        #expect(Self.nonZeroCount(both, in: across) == 0)
        // CONTROL: the junction is not silent in the source, so the gate can fail.
        let original = try Self.readFile(source)
        #expect(Self.nonZeroCount(original, in: junction) > junction.count)
    }

    // MARK: - The key and the bypass

    /// A clip whose ONLY edit is a clear must not take the identity bypass
    /// (which plays the source file) and must not share a key with anything
    /// that sounds different. A restore puts it back on the unedited key.
    @Test("a clear alone is not an identity: the cache renders it, under a key of its own, with no pitch analysis")
    func aClearAloneIsNotAnIdentity() throws {
        let dir = try Self.tempDir("key")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeTone(in: dir)
        typealias Params = StretchRenderCache.Params
        let unedited = Params(ratio: 1, semitones: 0, formantPreserve: false,
                              pitchEdits: Self.table())
        #expect(unedited.isIdentity, "CONTROL: an unedited note table must still take the bypass")

        let cleared = Self.table(cleared: [Self.noteB])
        let quiet = Self.table(levelsDb: [Self.noteB: -72])
        var keys: Set<String> = [try StretchRenderCache.cacheKey(source: source, params: unedited)]
        for (label, set) in [("cleared", cleared), ("−72 dB", quiet)] {
            let params = Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: set)
            #expect(!params.isIdentity, "\(label): the cache would play the SOURCE for this clip")
            #expect(params.pitchEdits == set, "\(label): Params normalised a real edit away")
            #expect(!set.needsDetectedContour, "\(label): a level edit must never cost a pitch analysis")
            #expect(StretchRenderCache.needsRender(
                Clip(name: "c", audioFileURL: source, pitchEdits: set)))
            keys.insert(try StretchRenderCache.cacheKey(source: source, params: params))
        }
        #expect(keys.count == 3, "a clear, a −72 dB level and no edit must be three different renders")

        var restored = cleared
        restored.segments[Self.noteB].isCleared = false
        #expect(try StretchRenderCache.cacheKey(
            source: source, params: Params(ratio: 1, semitones: 0, formantPreserve: false,
                                           pitchEdits: restored))
            == (try StretchRenderCache.cacheKey(source: source, params: unedited)),
                "Restore must put the clip back on the unedited key")
    }

    // MARK: - The mask pass on synthetic buffers

    @Test("the product's ramp is the design's 10 ms, and the mask version is 1")
    func rampIsTheDesignsTenMilliseconds() {
        #expect(PitchEditSet.levelRampSeconds == Self.rampSeconds)
        #expect(PitchEditSet.levelMaskVersion == 1)
    }

    /// No level edit, no write: the pass returns before touching a sample,
    /// even for a set that bends pitch. The control proves it CAN write.
    @Test("the mask pass is a byte no-op for a set with no level edit, even one that bends pitch")
    func maskPassIsAByteNoOpWithoutALevelEdit() throws {
        let frames = 1_000
        var buffer: [[Float]] = [
            (0..<frames).map { Float(sin(Double($0) * 0.1)) },
            (0..<frames).map { $0 % 7 == 0 ? -0.0 : Float($0) * 1e-3 },
        ]
        buffer[1][3] = Float.leastNonzeroMagnitude  // a subnormal the pass must not touch
        let before = buffer
        for set in [PitchEditSet.empty, Self.table(), Self.table(cents: [Self.noteB: 50])] {
            try StretchCurvePlan.applyLevelMask(set, to: &buffer, sampleRate: 1_000, ratio: 1)
            #expect(Self.bitMismatches(buffer, before, in: [0..<frames]) == 0)
        }
        try StretchCurvePlan.applyLevelMask(Self.table(cleared: [Self.noteB]), to: &buffer,
                                            sampleRate: 1_000, ratio: 1)
        #expect(Self.bitMismatches(buffer, before, in: [0..<frames]) > 0,
                "CONTROL FAILED: a cleared note wrote nothing")
    }

    /// Denormal guard: a product below `Float.leastNormalMagnitude` becomes +0,
    /// and a cleared plateau is +0 (never −0). A normal product is untouched
    /// by the guard: −72 dB of 0.3 is 7.5e-5, which must survive.
    @Test("the mask pass flushes a denormal product to +0, writes +0 across a cleared plateau, and keeps a normal quiet product")
    func maskPassFlushesDenormalsToPositiveZero() throws {
        let frames = 1_000
        let plateau = 411..<589  // source 0.41..0.59 s at 1 kHz, trimmed
        var quiet: [[Float]] = [[Float](repeating: 1e-35, count: frames),
                                [Float](repeating: -0.3, count: frames)]
        try StretchCurvePlan.applyLevelMask(Self.table(levelsDb: [Self.noteB: -72]), to: &quiet,
                                            sampleRate: 1_000, ratio: 1)
        let factor = Float(pow(10.0, -72.0 / 20))
        #expect(Float(1e-35) * factor < Float.leastNormalMagnitude,
                "the fixture must produce a denormal product, or this proves nothing")
        #expect(quiet[0][plateau].allSatisfy { $0.bitPattern == 0 },
                "a denormal product left the mask pass")
        #expect(quiet[1][plateau].allSatisfy { $0 == Float(-0.3) * factor },
                "a normal −72 dB product was flushed or changed")

        var cleared: [[Float]] = [[Float](repeating: -0.3, count: frames),
                                  [Float](repeating: 0.3, count: frames)]
        try StretchCurvePlan.applyLevelMask(Self.table(cleared: [Self.noteB]), to: &cleared,
                                            sampleRate: 1_000, ratio: 1)
        #expect(cleared[0][plateau].allSatisfy { $0.bitPattern == 0 },
                "a cleared plateau over negative samples must be +0, not −0")
        #expect(cleared[1][plateau].allSatisfy { $0.bitPattern == 0 })
        #expect(Self.abnormalCount(quiet) == 0 && Self.abnormalCount(cleared) == 0)
    }

    /// The pass reads the output-to-source mapping through the ratio: at ratio
    /// 2 a note at source 0.40..0.60 s is output frames 800..1200 of a 1 kHz
    /// buffer, and at ratio 0.5 it is 200..300.
    @Test("the mask pass maps output frames through the ratio, at 2 and at 0.5")
    func maskPassMapsThroughTheRatio() throws {
        for ratio in [2.0, 0.5] {
            let frames = Int(1_000 * ratio)
            var buffer: [[Float]] = [[Float](repeating: 1, count: frames)]
            try StretchCurvePlan.applyLevelMask(Self.table(cleared: [Self.noteB]), to: &buffer,
                                                sampleRate: 1_000, ratio: ratio)
            var plateauNonZero = 0
            var outsideChanged = 0
            var plateauFrames = 0
            for frame in 0..<frames {
                let second = Double(frame) / (ratio * 1_000)
                if second >= 0.41 + 1e-9 && second <= 0.59 - 1e-9 {
                    plateauFrames += 1
                    if buffer[0][frame] != 0 { plateauNonZero += 1 }
                } else if second < 0.40 || second >= 0.60 {
                    if buffer[0][frame] != 1 { outsideChanged += 1 }
                }
            }
            #expect(plateauFrames > Int(0.17 * 1_000 * ratio))
            #expect(plateauNonZero == 0, "ratio \(ratio): the plateau is not silent")
            #expect(outsideChanged == 0, "ratio \(ratio): frames outside the note moved")
        }
    }

    /// Cancellation is polled once per level-edited note, BEFORE it writes, so
    /// a superseded render stops without half-masking a buffer.
    @Test("a cancelled mask pass throws before it writes a sample")
    func cancelledMaskPassWritesNothing() throws {
        var buffer: [[Float]] = [[Float](repeating: 0.5, count: 1_000)]
        #expect(throws: OfflineStretcherError.self) {
            try StretchCurvePlan.applyLevelMask(Self.table(cleared: [Self.noteB]), to: &buffer,
                                                sampleRate: 1_000, ratio: 1, isCancelled: { true })
        }
        #expect(buffer[0].allSatisfy { $0 == 0.5 })
    }
}
