import AVFAudio
import Foundation

/// Deterministic audio fixtures + signal-analysis helpers for the playback
/// render tests. Fixtures are generated once per test run into a unique temp
/// dir; all are STEREO (identical channels), WAV Float32.
@MainActor
enum TestSignals {
    struct FixtureSet {
        let dir: URL
        /// 2.0 s, 1 kHz cosine (first frame = peak), amp 0.5, 48 kHz.
        let cos1k48: URL
        /// 2.0 s, 1 kHz cosine (first frame = peak), amp 0.25, 48 kHz —
        /// the two-track summing test needs 0.25 + 0.25 = 0.5 headroom.
        let cos1k48Quarter: URL
        /// 2.0 s, 440 Hz sine, amp 0.5, 44.1 kHz.
        let sine440_44k1: URL
    }

    private static var cached: FixtureSet?

    static func fixtures() throws -> FixtureSet {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cos1k48 = dir.appendingPathComponent("cos1k_48k.wav")
        try write(.cosine, to: cos1k48, frequency: 1_000, amplitude: 0.5,
                  sampleRate: 48_000, seconds: 2.0)
        let cos1k48Quarter = dir.appendingPathComponent("cos1k_48k_amp025.wav")
        try write(.cosine, to: cos1k48Quarter, frequency: 1_000, amplitude: 0.25,
                  sampleRate: 48_000, seconds: 2.0)
        let sine440_44k1 = dir.appendingPathComponent("sine440_44k1.wav")
        try write(.sine, to: sine440_44k1, frequency: 440, amplitude: 0.5,
                  sampleRate: 44_100, seconds: 2.0)

        let set = FixtureSet(dir: dir, cos1k48: cos1k48,
                             cos1k48Quarter: cos1k48Quarter, sine440_44k1: sine440_44k1)
        cached = set
        return set
    }

    enum Waveform {
        case sine
        case cosine
    }

    /// Writes a stereo Float32 WAV with identical channels. Scoped so the
    /// AVAudioFile deallocates (flushes and closes) before anyone reads it.
    private static func write(_ waveform: Waveform, to url: URL, frequency: Double,
                              amplitude: Float, sampleRate: Double, seconds: Double) throws {
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
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(seconds * sampleRate)),
              let channels = buffer.floatChannelData else {
            throw NSError(domain: "TestSignals", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        let frames = Int(seconds * sampleRate)
        for frame in 0..<frames {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
            let value = amplitude * Float(waveform == .cosine ? cos(phase) : sin(phase))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// Reads a whole audio file back as deinterleaved [channel][frame] floats
    /// in its native processing format (no rate conversion). Reads in a loop:
    /// AVAudioFile.read(into:) fills "up to" the buffer's capacity and CAN
    /// return short (measured: 31_744 of 32_192 frames — exactly 31 full
    /// 4 KiB blocks — on a multi-write take file), so a single call would
    /// silently truncate the tail.
    static func readFile(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let channelCount = Int(file.processingFormat.channelCount)
        var result = [[Float]](repeating: [], count: channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: 32_768) else {
            throw NSError(domain: "TestSignals", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw NSError(domain: "TestSignals", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "read failed for \(url.path)"])
            }
            let frames = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                result[channel].append(contentsOf:
                    UnsafeBufferPointer(start: channels[channel], count: frames))
            }
        }
        return result
    }

    // MARK: - Recording fixtures

    /// Shared base for synthetic capture timestamps, so writer-alignment tests
    /// reason in "seconds since base" instead of raw host ticks.
    static let baseHostTime: UInt64 = mach_absolute_time()

    /// Host time `seconds` past the shared base, converted with the same
    /// AVAudioTime tick math the writer uses.
    static func hostTime(at seconds: Double) -> UInt64 {
        baseHostTime + AVAudioTime.hostTime(forSeconds: seconds)
    }

    /// Deterministic ramp buffer: sample = Float(globalIndex) * 1e-4 on every
    /// channel, where globalIndex = startIndex + frame. Makes bit-exact
    /// content checks across buffer boundaries trivial.
    static func makeRampBuffer(format: AVAudioFormat, frames: Int, startIndex: Int) -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            fatalError("ramp buffer allocation failed (\(frames) frames)")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let value = Float(startIndex + frame) * 1e-4
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }

    // MARK: - Analysis helpers

    static func rms(_ samples: [Float], in range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Double = 0
        for index in range {
            sum += Double(samples[index]) * Double(samples[index])
        }
        return Float((sum / Double(range.count)).squareRoot())
    }

    static func peak(_ samples: [Float], in range: Range<Int>) -> Float {
        var maximum: Float = 0
        for index in range {
            maximum = max(maximum, abs(samples[index]))
        }
        return maximum
    }

    /// First frame whose absolute value exceeds `threshold`, or nil.
    static func firstFrame(in samples: [Float], exceeding threshold: Float) -> Int? {
        samples.firstIndex { abs($0) > threshold }
    }

    /// Dominant frequency estimated from interpolated zero-crossing spacing
    /// over `range`. Assumes a single steady tone within the window.
    static func dominantFrequency(byZeroCrossings samples: [Float],
                                  sampleRate: Double, in range: Range<Int>) -> Double {
        var crossings: [Double] = []
        for index in range.dropFirst() {
            let previous = samples[index - 1]
            let current = samples[index]
            if (previous < 0 && current >= 0) || (previous >= 0 && current < 0) {
                // Linear interpolation of the crossing position between frames.
                let fraction = Double(previous) / Double(previous - current)
                crossings.append(Double(index - 1) + fraction)
            }
        }
        guard crossings.count >= 2, let first = crossings.first, let last = crossings.last,
              last > first else { return 0 }
        let halfPeriods = Double(crossings.count - 1)
        return halfPeriods / (2.0 * (last - first) / sampleRate)
    }
}
