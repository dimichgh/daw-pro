import DAWCore
import Foundation

// MARK: - WAV in and out (no AVFoundation in AIServices)

/// The WAV files a sing job reads (the facade's unit renders) and writes (the assembled take).
///
/// The facade and the stub both write `scripts/sing/singlib/wavio.py`'s layout: RIFF / WAVE / `fmt ` (18
/// bytes, `WAVE_FORMAT_IEEE_FLOAT`, cbSize 0) / `fact` / `data`, float32 little-endian. The reader also takes
/// 16/24/32-bit PCM, 64-bit float and `WAVE_FORMAT_EXTENSIBLE`, skips unknown chunks and honours RIFF's pad
/// byte; the writer writes wavio's exact layout, so its bytes are a pure function of the samples.
public enum SingWAV {

    public struct Audio: Sendable, Equatable {
        public var sampleRate: Int
        /// `[channel][frame]`.
        public var channels: [[Float]]

        public init(sampleRate: Int, channels: [[Float]]) {
            self.sampleRate = sampleRate
            self.channels = channels
        }

        public var frameCount: Int { channels.first?.count ?? 0 }
        /// Channel 0 (the facade renders mono); for more channels, their mean.
        public var mono: [Float] {
            guard channels.count > 1 else { return channels.first ?? [] }
            var out = [Float](repeating: 0, count: frameCount)
            for channel in channels { for i in out.indices { out[i] += channel[i] } }
            let n = Float(channels.count)
            for i in out.indices { out[i] /= n }
            return out
        }
    }

    public enum ReadError: Error, Equatable, LocalizedError {
        case unreadable(String)
        case notWAV
        case missingChunk(String)
        case unsupportedFormat(tag: Int, bits: Int)
        case truncated

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "The audio file could not be read: \(detail)"
            case .notWAV: return "The audio file is not a WAV file."
            case .missingChunk(let name): return "The WAV file has no '\(name)' chunk."
            case .unsupportedFormat(let tag, let bits):
                return "The WAV format \(tag) at \(bits) bits is not one a sing job reads."
            case .truncated: return "The WAV file is cut short."
            }
        }
    }

    public static func read(_ url: URL) throws -> Audio {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ReadError.unreadable(error.localizedDescription) }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Audio {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8)
        else { throw ReadError.notWAV }
        var position = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var dataRange: Range<Int>?
        while position + 8 <= bytes.count {
            let id = String(decoding: bytes[position..<position + 4], as: UTF8.self)
            let size = u32(position + 4)
            let start = position + 8
            if id == "fmt " {
                guard size >= 16, start + size <= bytes.count else { throw ReadError.truncated }
                var tag = u16(start)
                let bits = u16(start + 14)
                if tag == 0xFFFE, size >= 40 { tag = u16(start + 24) }     // EXTENSIBLE: the sub-format's tag
                format = (tag, u16(start + 2), u32(start + 4), bits)
            } else if id == "data" {
                let end = min(bytes.count, start + size)
                guard end - start == size else { throw ReadError.truncated }
                dataRange = start..<end
                break
            }
            position = start + size + (size & 1)
        }
        guard let format else { throw ReadError.missingChunk("fmt ") }
        guard let dataRange else { throw ReadError.missingChunk("data") }
        let channelCount = max(1, format.channels)
        let bytesPerSample: Int
        switch (format.tag, format.bits) {
        case (1, 16): bytesPerSample = 2
        case (1, 24): bytesPerSample = 3
        case (1, 32), (3, 32): bytesPerSample = 4
        case (3, 64): bytesPerSample = 8
        default: throw ReadError.unsupportedFormat(tag: format.tag, bits: format.bits)
        }
        let frameBytes = bytesPerSample * channelCount
        let frames = dataRange.count / frameBytes
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        var offset = dataRange.lowerBound
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let value: Float
                switch (format.tag, bytesPerSample) {
                case (1, 2):
                    value = Float(Int16(bitPattern: UInt16(u16(offset)))) / 32_768
                case (1, 3):
                    let raw = Int32(bitPattern: UInt32(bytes[offset]) << 8 | UInt32(bytes[offset + 1]) << 16
                                    | UInt32(bytes[offset + 2]) << 24)
                    value = Float(raw >> 8) / 8_388_608
                case (1, 4):
                    value = Float(Int32(bitPattern: UInt32(u32(offset)))) / 2_147_483_648
                case (3, 4):
                    value = Float(bitPattern: UInt32(u32(offset)))
                default:
                    let low = UInt64(UInt32(u32(offset)))
                    let high = UInt64(UInt32(u32(offset + 4)))
                    value = Float(Double(bitPattern: low | high << 32))
                }
                channels[channel][frame] = value
                offset += bytesPerSample
            }
        }
        return Audio(sampleRate: format.rate, channels: channels)
    }

    /// wavio's layout exactly: RIFF / WAVE / fmt (18 bytes: IEEE float, cbSize 0) / fact / data, mono float32.
    public static func float32MonoBytes(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 4)
        let body = 4 + (8 + 18) + (8 + 4) + (8 + dataBytes)
        data.append(contentsOf: Array("RIFF".utf8)); le32(body)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(18)
        le16(3); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 4)); le16(4); le16(32); le16(0)
        data.append(contentsOf: Array("fact".utf8)); le32(4); le32(UInt32(samples.count))
        data.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        for sample in samples { le32(sample.bitPattern) }
        return data
    }

    public static func writeFloat32Mono(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try float32MonoBytes(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }
}

// MARK: - One unit, checked (design §4.4, the L1 per-unit half)

/// What a sing job checks on every unit it gets back, BEFORE assembly: design §4.4's "a unit that comes back
/// nonFinite or silent gets one retry with seed + 1". Read from the bytes the facade wrote, never from the
/// facade's own `nonFinite` field alone (the stub's `nan` fault reports `false` over a WAV holding NaN).
public enum SingUnitCheck: Equatable, Sendable {
    case ok
    /// A NaN or an infinity in the samples.
    case nonFinite
    /// Digital silence: every sample at or under `silencePeak`.
    case silent
    /// The WAV the facade said it wrote cannot be read, or is at the wrong rate or length.
    case unreadable

    /// [A] −80 dBFS: well under any sung unit (the stub's quietest sine is −20 dBFS peak) and above float
    /// dither. Only DIGITAL silence is "silent" here; audible-but-unsung audio is gate L2's to refuse.
    public static let silencePeak: Float = 1e-4

    public static func check(_ samples: [Float]) -> SingUnitCheck {
        var peak: Float = 0
        for sample in samples {
            guard sample.isFinite else { return .nonFinite }
            peak = max(peak, abs(sample))
        }
        return peak <= silencePeak ? .silent : .ok
    }
}

// MARK: - Assembly (design §3.4 "Placement", §4.5 step 1)

public enum SingTakeAssembly {

    /// The equal-power crossfade where two units' guards overlap (design §3.4).
    public static let crossfadeSeconds = 0.020

    /// One unit's audio and where it starts in the take (`SingUnit.offsetSeconds`; only unit 0 may be
    /// negative, which cuts that much of its leading silence).
    public struct Placed: Sendable, Equatable {
        public var offsetSeconds: Double
        public var samples: [Float]

        public init(offsetSeconds: Double, samples: [Float]) {
            self.offsetSeconds = offsetSeconds
            self.samples = samples
        }
    }

    /// The take: every unit summed at its offset. Its LENGTH comes from the units' own audio (the furthest
    /// unit end), never from the plan, so gate L1's length check measures something.
    ///
    /// Where unit k+1 starts before unit k ends (a cut at a breath shorter than the two guards), a 20 ms
    /// equal-power crossfade centred on the overlap hands one to the other: unit k fades out (cos) and unit
    /// k+1 fades in (sin) over the window, so cos² + sin² = 1; before it only unit k plays, after it only
    /// unit k+1.
    public static func assemble(_ units: [Placed], sampleRate: Int) -> [Float] {
        let rate = Double(sampleRate)
        let starts = units.map { Int(($0.offsetSeconds * rate).rounded()) }
        let length = zip(starts, units).map { $0 + $1.samples.count }.max() ?? 0
        var out = [Float](repeating: 0, count: max(0, length))
        let fade = max(1, Int((crossfadeSeconds * rate).rounded()))
        for (k, unit) in units.enumerated() {
            // The window this unit fades OUT over (overlap with the next unit), and IN over (with the previous).
            // (Bounds are compared BEFORE a range is formed: `a..<b` with b < a traps.)
            var fadeOut: Range<Int>?
            if k + 1 < units.count {
                let (from, to) = (starts[k + 1], starts[k] + unit.samples.count)
                if to > from { fadeOut = window(centeredIn: from..<to, length: fade) }
            }
            var fadeIn: Range<Int>?
            if k > 0 {
                let (from, to) = (starts[k], starts[k - 1] + units[k - 1].samples.count)
                if to > from { fadeIn = window(centeredIn: from..<to, length: fade) }
            }
            for (i, sample) in unit.samples.enumerated() {
                let t = starts[k] + i
                guard t >= 0, t < out.count else { continue }
                var gain: Float = 1
                if let fadeIn {
                    if t < fadeIn.lowerBound { gain = 0 } else if t < fadeIn.upperBound {
                        gain *= Float(sin(Double.pi / 2 * Double(t - fadeIn.lowerBound) / Double(fadeIn.count)))
                    }
                }
                if let fadeOut {
                    if t >= fadeOut.upperBound { gain = 0 } else if t >= fadeOut.lowerBound {
                        gain *= Float(cos(Double.pi / 2 * Double(t - fadeOut.lowerBound) / Double(fadeOut.count)))
                    }
                }
                out[t] += gain * sample
            }
        }
        return out
    }

    static func window(centeredIn overlap: Range<Int>, length: Int) -> Range<Int> {
        let size = min(length, overlap.count)
        let start = overlap.lowerBound + (overlap.count - size) / 2
        return start..<(start + size)
    }

    /// Seconds from the start of the take to each planned note's start and end (the take starts at
    /// `plan.t0Seconds`).
    public static func noteWindows(_ plan: SingPlan) -> [(start: Double, end: Double)] {
        plan.units.flatMap { unit in
            unit.notes.map { note in
                (unit.onsetSeconds - plan.t0Seconds + note.startSeconds,
                 unit.onsetSeconds - plan.t0Seconds + note.endSeconds)
            }
        }
    }

    /// The take's planned length: from its start to the last unit's trailing guard (design §7.1 L1's
    /// "planned span").
    public static func plannedSeconds(_ plan: SingPlan) -> Double {
        plan.units.map { $0.offsetSeconds + SingPlanner.leadSeconds + $0.spanSeconds + SingPlanner.trailSeconds }
            .max() ?? 0
    }
}

// MARK: - The landing gates (design §7.1)

/// Design §7.1: a take that fails any gate does not land; its units stay in the cache.
public enum SingLandingGate: String, Sendable, Equatable, Codable, CaseIterable {
    /// Every sample finite; the length is the planned span ± 20 ms (the per-unit half, "every unit reported
    /// nonFinite: false after its one retry", runs before assembly: `SingUnitCheck`).
    case physics = "L1"
    /// SwiftF0 voiced coverage ≥ 50% of the planned note time.
    case singingPresent = "L2"
    /// True peak ≤ −1.0 dBTP after gain, measured on the WRITTEN bytes.
    case truePeak = "L3"
    /// Integrated loudness ≥ −30 LUFS after gain.
    case audible = "L4"

    /// What the user reads when this gate keeps a take out. PROVISIONAL copy (design §7.1 names the gates but
    /// gives no sentences; written in §5.7's voice by p2-sing-e).
    public var sentence: String {
        switch self {
        case .physics: return "This take came out damaged, so I didn't add it. Try another take."
        case .singingPresent: return "I couldn't hear singing in this take, so I didn't add it. Try another take."
        case .truePeak: return "This take came out too loud to add safely, so I didn't add it. Try another take."
        case .audible: return "This take came out too quiet to hear, so I didn't add it. Try another take."
        }
    }
}

public struct SingGateReport: Sendable, Equatable, Codable {
    /// The gates that failed, in L1...L4 order; empty = the take lands.
    public var failed: [SingLandingGate]
    /// The measured numbers, for the status and for a test that wants to see WHY.
    public var lengthSeconds: Double
    public var plannedSeconds: Double
    public var allFinite: Bool
    public var voicedCoverage: Double
    public var truePeakDbtp: Double?
    public var integratedLufs: Double?
    /// True when the ceiling held the gain below the −18 LUFS target and the take still landed below it:
    /// the §5.7 "Quiet take" notice.
    public var quieterThanUsual: Bool

    public var passed: Bool { failed.isEmpty }
}

public enum SingLandingGates {

    /// L1's length tolerance (design §7.1).
    public static let lengthToleranceSeconds = 0.020
    /// L2's bar [A] (design §7.1; §1.7's advisory bar is 0.80).
    public static let minimumVoicedCoverage = 0.50
    /// L3 (design §7.1).
    public static let maximumTruePeakDbtp = -1.0
    /// [A] How far over `maximumTruePeakDbtp` a re-measured true peak may read and still pass L3. A take the
    /// ceiling held down lands AT the ceiling (`deliveryNormalized` clamps the gain to exactly
    /// `ceiling − truePeak`), and float rounding of the gained samples can put the re-measure a hair either
    /// side of it. 0.01 dB is far above that rounding and far below anything audible or any real overshoot.
    public static let truePeakToleranceDb = 0.01
    /// L4's bar [A] (design §7.1).
    public static let minimumIntegratedLufs = -30.0
    /// A frame counts as sung when SwiftF0 is at least this sure (the `clip.detectPitch` default).
    public static let confidentFrame = 0.9

    /// Evaluates the four gates over the take AS WRITTEN: `written` is the measurement of the bytes read back
    /// from disk (L3/L4), `samples` those same samples (L1), `frames` the pitch tracker's frames over the same
    /// file (L2). `report` is the gain step's own report, read only for `limitedByCeiling`.
    public static func evaluate(samples: [Float], sampleRate: Int, plan: SingPlan, frames: [ClipPitchFrame],
                                written: LoudnessMeasurement, report: BounceLoudnessReport?) -> SingGateReport {
        let length = Double(samples.count) / Double(sampleRate)
        let planned = SingTakeAssembly.plannedSeconds(plan)
        let finite = samples.allSatisfy { $0.isFinite }
        let coverage = voicedCoverage(frames: frames, windows: SingTakeAssembly.noteWindows(plan))
        var failed: [SingLandingGate] = []
        if !finite || abs(length - planned) > lengthToleranceSeconds { failed.append(.physics) }
        if coverage < minimumVoicedCoverage { failed.append(.singingPresent) }
        if let peak = written.truePeakDbtp, peak > maximumTruePeakDbtp + truePeakToleranceDb { failed.append(.truePeak) }
        if (written.integratedLufs ?? -.infinity) < minimumIntegratedLufs { failed.append(.audible) }
        let limited = report?.limitedByCeiling ?? false
        let quieter = failed.isEmpty && limited
            && (written.integratedLufs ?? -.infinity) < ProjectStore.sungVocalLufsTarget
        return SingGateReport(failed: failed, lengthSeconds: length, plannedSeconds: planned,
                              allFinite: finite, voicedCoverage: coverage, truePeakDbtp: written.truePeakDbtp,
                              integratedLufs: written.integratedLufs, quieterThanUsual: quieter)
    }

    /// The share of the planned note time with a confident pitch: each frame covers the time to the next
    /// frame (the tracker's hop), clipped to the note windows.
    public static func voicedCoverage(frames: [ClipPitchFrame], windows: [(start: Double, end: Double)]) -> Double {
        let total = windows.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard total > 0, frames.count > 1 else { return 0 }
        let hop = (frames[frames.count - 1].timeSeconds - frames[0].timeSeconds) / Double(frames.count - 1)
        var voiced = 0.0
        for frame in frames where frame.frequencyHz != nil && frame.confidence >= confidentFrame {
            let a = frame.timeSeconds
            let b = a + hop
            for window in windows {
                voiced += max(0, min(b, window.end) - max(a, window.start))
            }
        }
        return min(1, voiced / total)
    }
}

// MARK: - The note check (design §4.6 "Notes", the spike's §1.7 metric)

public enum SingNoteCheck {

    /// Hits ≥ 85%, mean |error| ≤ 25 c and coverage ≥ 80% read "In tune" (design §4.6).
    public static let inTuneHitRate = 0.85
    public static let inTuneMeanErrorCents = 25.0
    public static let inTuneCoverage = 0.80
    /// A note is a hit when its middle-50% median is within this many cents of the planned pitch.
    public static let hitCents = 50.0

    /// Scores the take against the plan (§1.7, the spike's metric, the one every render the user heard was
    /// scored with): for each planned note, the median f0 over the MIDDLE 50% of its window (skipping scoops,
    /// consonants and transitions), in cents from the planned TARGET pitch. Hit rate = notes within ±50 c;
    /// mean |error| over the hits; voiced coverage = the share of planned note time with a confident pitch.
    /// `noteBars[i]` is planned note i's 1-based bar, for the amber notice.
    public static func score(frames: [ClipPitchFrame], plan: SingPlan, noteBars: [Int]) -> SungNoteAccuracy {
        let windows = SingTakeAssembly.noteWindows(plan)
        let notes = plan.notes
        var hits = 0
        var errors: [Double] = []
        var offBars: [Int] = []
        for (i, note) in notes.enumerated() {
            let (start, end) = windows[i]
            let quarter = (end - start) / 4
            let pitches = frames.filter {
                $0.timeSeconds >= start + quarter && $0.timeSeconds < end - quarter
                    && $0.confidence >= SingLandingGates.confidentFrame && $0.frequencyHz != nil
            }.compactMap(\.frequencyHz).sorted()
            var hit = false
            if !pitches.isEmpty {
                let median = pitches.count % 2 == 1 ? pitches[pitches.count / 2]
                    : (pitches[pitches.count / 2 - 1] + pitches[pitches.count / 2]) / 2
                let target = 440 * pow(2, (Double(note.midi) - 69) / 12)
                let cents = 1200 * log2(median / target)
                if abs(cents) <= hitCents {
                    hit = true
                    hits += 1
                    errors.append(abs(cents))
                }
            }
            if !hit, i < noteBars.count, !offBars.contains(noteBars[i]) { offBars.append(noteBars[i]) }
        }
        let hitRate = notes.isEmpty ? 0 : Double(hits) / Double(notes.count)
        let meanError = errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
        let coverage = SingLandingGates.voicedCoverage(frames: frames, windows: windows)
        let inTune = hitRate >= inTuneHitRate && (meanError ?? .infinity) <= inTuneMeanErrorCents
            && coverage >= inTuneCoverage
        return SungNoteAccuracy(hitRate: hitRate, meanAbsErrorCents: meanError, voicedCoverage: coverage,
                                inTune: inTune, offBars: inTune ? [] : offBars.sorted())
    }
}

// MARK: - The word check (design §4.6 "Words", §7.3)

public enum SingWordCheck {

    /// Design §7.3's bands [A]: ≤ 0.20 clear; ≤ 0.40 some words unclear; above, hard to understand.
    public static let clearWER = 0.20
    public static let someUnclearWER = 0.40

    /// `SungWordCheck.verdict` values this build writes.
    public enum Verdict {
        public static let clear = "clear"
        public static let someUnclear = "someUnclear"
        public static let unclear = "unclear"
    }

    /// The check for one take. `heard` is nil when no speech model is installed: the check is skipped
    /// honestly. A voice whose own reference the transcriber struggled with reads "hard to judge".
    public static func check(assignment: LyricAssignment, heard: String?, voiceIsReliable: Bool) -> SungWordCheck {
        guard let heard else { return SungWordCheck(state: SungWordCheck.State.skipped) }
        let result = WordErrorRate.measure(reference: WordErrorRate.reference(for: assignment), hypothesis: heard)
        guard voiceIsReliable else {
            return SungWordCheck(state: SungWordCheck.State.hardToJudge, wer: result.wer, heard: heard)
        }
        let wer = result.wer ?? 0
        let verdict = wer <= clearWER ? Verdict.clear : wer <= someUnclearWER ? Verdict.someUnclear : Verdict.unclear
        return SungWordCheck(state: SungWordCheck.State.checked, wer: result.wer, heard: heard, verdict: verdict)
    }

    /// §5.7 "Results" / "Word check skipped" / "Hard-to-judge voice", for one check.
    public static func sentence(_ check: SungWordCheck) -> String {
        switch check.state {
        case SungWordCheck.State.skipped: return "Word check skipped: no speech model is installed."
        case SungWordCheck.State.hardToJudge: return "Word check: hard to judge for this voice."
        default:
            switch check.verdict {
            case Verdict.clear: return "Words clear"
            case Verdict.someUnclear: return "Some words may be hard to make out."
            default:
                return "The words are hard to understand in this take — try another take, or give long words "
                    + "more notes."
            }
        }
    }
}
