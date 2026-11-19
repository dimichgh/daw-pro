import AVFAudio
import DAWCore
import Foundation
import os
import Testing
@testable import DAWEngine

// Input-only capture (p2-sing-e, "Add your voice"): the recorder's engine side.
//
// Every test here drives SYNTHETIC buffers through the same `RecordingWriter`
// the take path uses (the `RecordingWriterTests` precedent): no microphone, no
// TCC prompt, no device. The engine-level tests swap the engine's capture
// source for `SyntheticInputSource`, which hands buffers to the writer exactly
// as `InputCapture`'s tap does (`writer.append(buffer, at:)`), so a real
// `InputCapture` is never constructed and no input or output ever starts.
//
// ISOLATION: the writer and meter tests are a NEW nonisolated suite. The
// engine tests need the main actor (`AudioEngine` is `@MainActor`), and the
// rule is "no new @MainActor suite", so they are APPENDED to the existing
// `@MainActor` `RecordingWriterTests` suite through an extension below — no new
// `@Suite` line, which is what `MainActorOccupancySiteTests` Leg C counts.

// MARK: - Synthetic signal and WAV reading (pure, nonisolated)

private enum CaptureSignal {
    /// Deterministic content that differs per channel AND per frame, so a
    /// swapped channel, a shifted frame or a lost buffer each change the bytes.
    /// 24 hashed bits mapped into (-0.9, 0.9): exact in Float32, never NaN.
    static func sample(channel: Int, frame: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: frame) &* 0x9E37_79B1
            &+ UInt32(truncatingIfNeeded: channel) &* 0x85EB_CA77 &+ 1
        x ^= x >> 15
        x &*= 0x2C1B_3C6D
        x ^= x >> 12
        x &*= 0x297A_2D39
        x ^= x >> 15
        return (Float(x >> 8) / Float(1 << 24) * 2 - 1) * 0.9
    }

    static func format(rate: Double = 48_000, channels: AVAudioChannelCount = 2) throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: channels, interleaved: false))
    }

    /// `frames` frames of `sample(channel:frame:)` starting at global frame
    /// `startFrame`, in the device-style non-interleaved layout.
    static func buffer(_ format: AVAudioFormat, frames: Int, startFrame: Int) throws -> AVAudioPCMBuffer {
        try filled(format, frames: frames) { channel, frame in
            sample(channel: channel, frame: startFrame + frame)
        }
    }

    static func filled(_ format: AVAudioFormat, frames: Int,
                       _ value: (_ channel: Int, _ frame: Int) -> Float) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames {
                channels[channel][frame] = value(channel, frame)
            }
        }
        return buffer
    }

    /// What the file's `data` chunk must hold for global frames `frames`:
    /// interleaved little-endian Float32, the writer's on-disk layout.
    static func interleavedBytes(channels: Int, frames: Range<Int>) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(frames.count * channels * 4)
        for frame in frames {
            for channel in 0..<channels {
                let bits = sample(channel: channel, frame: frame).bitPattern.littleEndian
                withUnsafeBytes(of: bits) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }

    struct WAV {
        var formatTag: UInt16
        var channels: Int
        var sampleRate: Int
        var bitsPerSample: Int
        var data: [UInt8]
    }

    /// Reads the RIFF chunks directly: the bytes on disk, not a decoder's view.
    static func wav(at url: URL) throws -> WAV {
        let bytes = [UInt8](try Data(contentsOf: url))
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func tag(_ o: Int) -> String { String(decoding: bytes[o..<(o + 4)], as: UTF8.self) }
        let isWAV = bytes.count >= 12 && tag(0) == "RIFF" && tag(8) == "WAVE"
        try #require(isWAV, "not a RIFF/WAVE file")
        var offset = 12
        var fmt: (tag: UInt16, channels: Int, rate: Int, bits: Int)?
        var data: [UInt8]?
        while offset + 8 <= bytes.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count else { break }
            if id == "fmt " {
                fmt = (u16(body), Int(u16(body + 2)), Int(u32(body + 4)), Int(u16(body + 14)))
            } else if id == "data" {
                data = Array(bytes[body..<(body + size)])
            }
            offset = body + size + (size & 1)
        }
        let format = try #require(fmt, "no fmt chunk")
        let samples = try #require(data, "no data chunk")
        return WAV(formatTag: format.tag, channels: format.channels, sampleRate: format.rate,
                   bitsPerSample: format.bits, data: samples)
    }

    /// nil when equal; otherwise the first differing byte (or the shorter length).
    static func firstMismatch(_ a: [UInt8], _ b: [UInt8]) -> Int? {
        if a.count != b.count { return min(a.count, b.count) }
        return a.indices.first { a[$0] != b[$0] }
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-inputonly-\(UUID().uuidString)")
            .appendingPathComponent("voice.wav")
    }

    static func hostTime(at seconds: Double) -> UInt64 {
        baseHostTime + AVAudioTime.hostTime(forSeconds: seconds)
    }

    static let baseHostTime: UInt64 = mach_absolute_time()
}

/// Counts a writer-queue callback from any thread.
private final class SignalCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private func finalizeWriter(_ writer: RecordingWriter) async throws -> RecordingWriter.Result {
    let result: Swift.Result<RecordingWriter.Result, any Error> = await withCheckedContinuation { continuation in
        writer.finalize { continuation.resume(returning: $0) }
    }
    return try result.get()
}

// MARK: - Writer: the frame limit and the level meter (nonisolated)

@Suite("Input-only capture — writer frame limit and level meter")
struct InputOnlyCaptureWriterTests {
    @Test("the frame limit trims the buffer that crosses it, ignores the rest, and signals once")
    func frameLimitTrimsTheStraddlingBufferAndSignalsOnce() async throws {
        let format = try CaptureSignal.format(channels: 1)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, inputFormat: format)
        let ended = SignalCounter()
        writer.setTargetHostTime(nil)
        writer.setFrameLimit(10_000) { ended.bump() }
        // 4 × 4096 = 16_384 fed: buffer 3 crosses 10_000 (keeps 1_808), buffer 4 is past it.
        for index in 0..<4 {
            writer.append(try CaptureSignal.buffer(format, frames: 4_096, startFrame: index * 4_096),
                          at: AVAudioTime(hostTime: CaptureSignal.hostTime(at: Double(index) * 0.1)))
        }
        let result = try await finalizeWriter(writer)

        #expect(result.framesWritten == 10_000)
        #expect(ended.value == 1)
        let wav = try CaptureSignal.wav(at: url)
        let expected = CaptureSignal.interleavedBytes(channels: 1, frames: 0..<10_000)
        #expect(wav.data.count == expected.count)
        #expect(CaptureSignal.firstMismatch(wav.data, expected) == nil)
    }

    @Test("a limit on a buffer boundary signals as soon as it is reached, not on the next buffer")
    func frameLimitOnABufferBoundarySignalsWithoutWaitingForMore() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, inputFormat: format)
        let ended = SignalCounter()
        writer.setTargetHostTime(nil)
        writer.setFrameLimit(8_192) { ended.bump() }
        for index in 0..<2 {
            writer.append(try CaptureSignal.buffer(format, frames: 4_096, startFrame: index * 4_096),
                          at: AVAudioTime(hostTime: CaptureSignal.hostTime(at: Double(index) * 0.1)))
        }
        let result = try await finalizeWriter(writer)

        #expect(result.framesWritten == 8_192)
        #expect(ended.value == 1)
        let wav = try CaptureSignal.wav(at: url)
        #expect(CaptureSignal.firstMismatch(wav.data,
                                            CaptureSignal.interleavedBytes(channels: 2, frames: 0..<8_192)) == nil)
    }

    @Test("INVARIANCE CONTROL: with no limit and no meter the writer keeps every fed frame")
    func noLimitKeepsEveryFrame() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)
        for index in 0..<4 {
            writer.append(try CaptureSignal.buffer(format, frames: 4_096, startFrame: index * 4_096),
                          at: AVAudioTime(hostTime: CaptureSignal.hostTime(at: Double(index) * 0.1)))
        }
        let result = try await finalizeWriter(writer)

        #expect(result.framesWritten == 16_384)
        let wav = try CaptureSignal.wav(at: url)
        #expect(CaptureSignal.firstMismatch(wav.data,
                                            CaptureSignal.interleavedBytes(channels: 2, frames: 0..<16_384)) == nil)
    }

    @Test("the meter publishes per window of ≥ 50 ms, keeps its reading on read, and ignores non-finite peaks")
    func meterWindowsSmallBuffersAndIgnoresNonFinite() {
        let meter = InputLevelMeter(sampleRate: 48_000)
        #expect(meter.windowFrames == 2_400)
        #expect(meter.peakDbfs == InputLevelMeter.floorDbfs)

        // Three 1_000-frame chunks: nothing publishes until 2_400 frames have arrived.
        meter.fold(peak: 0.1, frames: 1_000)
        meter.fold(peak: 0.8, frames: 1_000)
        #expect(meter.peakDbfs == InputLevelMeter.floorDbfs)
        meter.fold(peak: 0.2, frames: 1_000)
        let loudest = 20 * log10(Double(Float(0.8)))
        #expect(abs(meter.peakDbfs - loudest) < 1e-9)
        #expect(abs(meter.peakDbfs - loudest) < 1e-9)  // a second read sees the same value

        // A long chunk publishes on its own.
        meter.fold(peak: 0.5, frames: 4_096)
        #expect(abs(meter.peakDbfs - 20 * log10(0.5)) < 1e-9)

        // NaN and infinity never enter: the window publishes as silence.
        meter.fold(peak: .nan, frames: 4_096)
        #expect(meter.peakDbfs == InputLevelMeter.floorDbfs)
        meter.fold(peak: .infinity, frames: 4_096)
        #expect(meter.peakDbfs == InputLevelMeter.floorDbfs)
        #expect(meter.peakDbfs.isFinite)

        // An empty chunk changes nothing.
        meter.fold(peak: 0.5, frames: 4_096)
        meter.fold(peak: 0.9, frames: 0)
        #expect(abs(meter.peakDbfs - 20 * log10(0.5)) < 1e-9)
    }

    @Test("through the writer, the meter reads the loudest written sample on any channel and skips NaN")
    func meterThroughTheWriterReportsTheWrittenPeak() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try RecordingWriter(url: url, inputFormat: format)
        let meter = InputLevelMeter(sampleRate: format.sampleRate)
        writer.setTargetHostTime(nil)
        writer.setLevelMeter(meter)
        // Left peaks at 0.125 with one NaN sample; right peaks at 0.25.
        let buffer = try CaptureSignal.filled(format, frames: 4_096) { channel, frame in
            if channel == 0 { return frame == 100 ? .nan : (frame == 2_000 ? -0.125 : 0.01) }
            return frame == 3_000 ? 0.25 : -0.02
        }
        writer.append(buffer, at: AVAudioTime(hostTime: CaptureSignal.hostTime(at: 0)))
        _ = try await finalizeWriter(writer)

        #expect(abs(meter.peakDbfs - 20 * log10(0.25)) < 1e-9)
    }
}

// MARK: - Engine-level test doubles (main actor, like the protocol)

/// Stands in for `InputCapture`. `deliver` is the tap's hand-off verbatim
/// (`writer.append(buffer, at:)`); nothing here touches audio hardware.
@MainActor
private final class SyntheticInputSource: InputCaptureSource {
    static let untouchedUID = "synthetic-source:untouched"
    var deviceUID: String? = SyntheticInputSource.untouchedUID
    var configurationChangeHandler: (() -> Void)?
    let format: AVAudioFormat
    var prepareError: (any Error)?
    var startError: (any Error)?
    private(set) var writer: RecordingWriter?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(format: AVAudioFormat) {
        self.format = format
    }

    func prepare() throws -> AVAudioFormat {
        prepareCount += 1
        if let prepareError { throw prepareError }
        return format
    }

    func start(writer: RecordingWriter) throws {
        startCount += 1
        if let startError { throw startError }
        self.writer = writer
    }

    func stop() {
        stopCount += 1
    }

    func deliver(_ buffer: AVAudioPCMBuffer, atSeconds seconds: Double) {
        writer?.append(buffer, at: AVAudioTime(hostTime: CaptureSignal.hostTime(at: seconds)))
    }

    /// Delivers `count` 4_096-frame signal buffers continuing from global frame `from`.
    func deliverSignal(buffers count: Int, from startFrame: Int = 0) throws {
        for index in 0..<count {
            let first = startFrame + index * 4_096
            deliver(try CaptureSignal.buffer(format, frames: 4_096, startFrame: first),
                    atSeconds: Double(first) / format.sampleRate)
        }
    }
}

private struct SyntheticSourceFailure: Error {}

/// Collects completions on the main actor.
@MainActor
private final class OutcomeLog {
    private(set) var outcomes: [InputOnlyCaptureOutcome] = []

    var completion: @MainActor (InputOnlyCaptureOutcome) -> Void {
        { [self] outcome in outcomes.append(outcome) }
    }

    func waitForFirst(seconds: Double = 10) async throws -> InputOnlyCaptureOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while outcomes.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(outcomes.first, "no completion within \(seconds) s")
    }

    /// Long enough for a second report already in flight (writer queue, then
    /// a hop to the main actor) to land, so "exactly once" is a measurement.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// The minimal conformance (the `LiveLoudnessCommandTests.BareEngine` shape):
/// it implements NONE of the input-only capture members, so the protocol
/// defaults are what a caller gets.
@MainActor
private final class BareCaptureEngine: AudioEngineControlling {
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.engineUnavailable
    }
    func stopRecording() {}
}

@MainActor
private func captureEngine(_ source: SyntheticInputSource) -> AudioEngine {
    let engine = AudioEngine()
    engine.makeInputCaptureSource = { source }
    // Long, so a slow run never trips it; the watchdog test shortens it.
    engine.inputOnlyCaptureFirstBufferSeconds = 60
    return engine
}

@MainActor
private func pollUntil(seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(seconds))
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// After any ending: nothing is running, and the engine takes a new capture.
@MainActor
private func expectIdleAndReusable(_ engine: AudioEngine, _ source: SyntheticInputSource) throws {
    #expect(!engine.stopInputOnlyCapture(), "a capture is still running after its completion")
    #expect(!engine.cancelInputOnlyCapture(), "a capture is still running after its completion")
    #expect(engine.inputOnlyCapturePeakDbfs() == nil, "the meter still reads after the capture ended")
    let url = CaptureSignal.tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try engine.startInputOnlyCapture(to: url, maxSeconds: 5) { _ in }
    #expect(engine.cancelInputOnlyCapture())
}

// MARK: - Engine: appended to the existing @MainActor suite (no new @Suite line)

extension RecordingWriterTests {
    @Test("input-only capture: the file's bytes equal the fed frames, and the transport never moves")
    func inputOnlyCaptureFileBytesEqualTheFedFrames() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        final class Pushes { var count = 0 }
        let playheadPushes = Pushes()
        engine.playheadHandler = { _ in playheadPushes.count += 1 }
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        #expect(source.startCount == 1)
        #expect(source.deviceUID == nil, "the engine passes its own input selection (unset here)")
        #expect(engine.inputOnlyCapturePeakDbfs() != nil)
        // Three deliveries, then Stop with NO await in between: the writer must
        // drain all three before it closes the file.
        try source.deliverSignal(buffers: 3)
        #expect(engine.stopInputOnlyCapture())

        let outcome = try await log.waitForFirst()
        guard case .recorded(let recording) = outcome else {
            Issue.record("expected .recorded, got \(outcome)")
            return
        }
        #expect(recording.fileURL == url)
        #expect(recording.frameCount == 12_288)
        #expect(recording.endedBy == .stopped)
        #expect(recording.info.sampleRate == 48_000)
        #expect(recording.info.channelCount == 2)
        #expect(abs(recording.info.durationSeconds - 12_288.0 / 48_000) < 1e-12)
        let wav = try CaptureSignal.wav(at: url)
        #expect(wav.formatTag == 3 || wav.formatTag == 0xFFFE)
        #expect(wav.channels == 2 && wav.sampleRate == 48_000 && wav.bitsPerSample == 32)
        let expected = CaptureSignal.interleavedBytes(channels: 2, frames: 0..<12_288)
        #expect(wav.data.count == expected.count)
        #expect(CaptureSignal.firstMismatch(wav.data, expected) == nil)

        try await log.settle()
        #expect(log.outcomes.count == 1)
        #expect(source.stopCount >= 1)
        #expect(!engine.isRunning, "the playback engine must not start")
        #expect(playheadPushes.count == 0, "the transport must not move")
        try expectIdleAndReusable(engine, source)
    }

    @Test("input-only capture stops by itself at maxSeconds, frame-exact")
    func inputOnlyCaptureStopsByItselfAtMaxSeconds() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        // 0.25 s at 48 kHz = 12_000 frames; 16_384 are fed. Nobody calls stop.
        try engine.startInputOnlyCapture(to: url, maxSeconds: 0.25, completion: log.completion)
        try source.deliverSignal(buffers: 4)

        let outcome = try await log.waitForFirst()
        guard case .recorded(let recording) = outcome else {
            Issue.record("expected .recorded, got \(outcome)")
            return
        }
        #expect(recording.endedBy == .reachedMaxSeconds)
        #expect(recording.frameCount == 12_000)
        let wav = try CaptureSignal.wav(at: url)
        #expect(CaptureSignal.firstMismatch(wav.data,
                                            CaptureSignal.interleavedBytes(channels: 2, frames: 0..<12_000)) == nil)
        #expect(source.stopCount >= 1, "the engine stops the input itself at the limit")

        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    @Test("input-only capture: cancel reports .cancelled once and deletes the file")
    func inputOnlyCaptureCancelDeletesTheFileAndReportsCancelled() async throws {
        let format = try CaptureSignal.format(channels: 1)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        try source.deliverSignal(buffers: 2)
        #expect(engine.cancelInputOnlyCapture())
        #expect(!engine.cancelInputOnlyCapture())

        #expect(try await log.waitForFirst() == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    @Test("input-only capture: racing ends report exactly once, and a late signal never ends a newer capture")
    func inputOnlyCaptureCompletionFiresExactlyOnceUnderRacingEnds() async throws {
        let format = try CaptureSignal.format(channels: 1)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        let firstURL = CaptureSignal.tempURL()
        let secondURL = CaptureSignal.tempURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let first = OutcomeLog()
        let second = OutcomeLog()

        // Capture A reaches its limit (8_192 frames) on the writer queue while,
        // in this same main-actor turn, stop and cancel both arrive, and
        // capture B starts. A's limit signal lands after all of that.
        try engine.startInputOnlyCapture(to: firstURL, maxSeconds: 8_192.0 / 48_000,
                                         completion: first.completion)
        try source.deliverSignal(buffers: 3)
        #expect(engine.stopInputOnlyCapture())
        #expect(!engine.cancelInputOnlyCapture())
        try engine.startInputOnlyCapture(to: secondURL, maxSeconds: 10, completion: second.completion)

        let outcome = try await first.waitForFirst()
        guard case .recorded(let recording) = outcome else {
            Issue.record("expected .recorded, got \(outcome)")
            return
        }
        #expect(recording.endedBy == .stopped, "stop ran first; the limit signal must not re-end it")
        #expect(recording.frameCount == 8_192)
        try await first.settle()
        #expect(first.outcomes.count == 1)
        // A's stale limit signal has landed by now; B must still be running.
        #expect(second.outcomes.isEmpty, "a stale signal from capture A ended capture B")
        #expect(engine.inputOnlyCapturePeakDbfs() != nil)
        #expect(engine.cancelInputOnlyCapture())
        #expect(try await second.waitForFirst() == .cancelled)
        try await second.settle()
        #expect(second.outcomes.count == 1)
    }

    @Test("input-only capture refuses, with nothing started and no completion, when it cannot run")
    func inputOnlyCaptureRefusals() async throws {
        let format = try CaptureSignal.format(channels: 1)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        let log = OutcomeLog()
        func refusal(_ body: () throws -> Void) -> InputOnlyCaptureError? {
            do { try body() } catch let error as InputOnlyCaptureError { return error } catch {
                Issue.record("unexpected error type: \(error)")
            }
            return nil
        }

        // Unusable lengths and URLs: refused before the source is even prepared.
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for seconds in [0, -1, Double.nan, .infinity, AudioEngine.inputOnlyCaptureMaxSecondsCeiling + 1] {
            let error = refusal { try engine.startInputOnlyCapture(to: url, maxSeconds: seconds,
                                                                   completion: log.completion) }
            #expect(error?.kind == .invalidRequest, "maxSeconds \(seconds)")
        }
        let web = try #require(URL(string: "https://example.com/voice.wav"))
        #expect(refusal { try engine.startInputOnlyCapture(to: web, maxSeconds: 5,
                                                           completion: log.completion) }?.kind == .invalidRequest)

        // An existing file is never overwritten.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let keep = Data("keep me".utf8)
        try keep.write(to: url)
        let exists = refusal { try engine.startInputOnlyCapture(to: url, maxSeconds: 5,
                                                                completion: log.completion) }
        #expect(exists?.kind == .invalidRequest)
        #expect(exists?.message.contains("voice.wav") == true)
        #expect(try Data(contentsOf: url) == keep)
        try FileManager.default.removeItem(at: url)
        #expect(source.prepareCount == 0)

        // The input will not prepare: no file, and the engine stays free.
        source.prepareError = SyntheticSourceFailure()
        #expect(refusal { try engine.startInputOnlyCapture(to: url, maxSeconds: 5,
                                                           completion: log.completion) }?.kind == .inputUnavailable)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        source.prepareError = nil

        // The input will not start: the writer's file is removed BEFORE the
        // throw returns, so an immediate retry at the same URL is not refused.
        source.startError = SyntheticSourceFailure()
        #expect(refusal { try engine.startInputOnlyCapture(to: url, maxSeconds: 5,
                                                           completion: log.completion) }?.kind == .inputUnavailable)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        source.startError = nil

        // Busy: a second start while one runs is refused and leaves the first alone.
        try engine.startInputOnlyCapture(to: url, maxSeconds: 5, completion: log.completion)
        let otherURL = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        #expect(refusal { try engine.startInputOnlyCapture(to: otherURL, maxSeconds: 5,
                                                           completion: log.completion) }?.kind == .busy)
        #expect(engine.inputOnlyCapturePeakDbfs() != nil)
        try await log.settle()
        #expect(log.outcomes.isEmpty, "a refused start must never report")
        #expect(engine.cancelInputOnlyCapture())
        #expect(try await log.waitForFirst() == .cancelled)
        try await log.settle()
        #expect(log.outcomes.count == 1)
    }

    @Test("input-only capture fails with a teaching message when no audio ever arrives")
    func inputOnlyCaptureWatchdogFailsADeadInput() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        engine.inputOnlyCaptureFirstBufferSeconds = 0.1
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        let outcome = try await log.waitForFirst()
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("microphone"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    @Test("input-only capture: a device that dies mid-capture fails it and deletes the partial file")
    func inputOnlyCaptureFailsWhenTheInputDies() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        try source.deliverSignal(buffers: 1)
        let fatalChange = try #require(source.configurationChangeHandler)
        fatalChange()

        let outcome = try await log.waitForFirst()
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("stopped working"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(source.configurationChangeHandler == nil)
        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    @Test("input-only capture: Stop before any audio is a failure, never a .recorded with no file")
    func inputOnlyCaptureStopBeforeAnyAudioFails() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        #expect(engine.stopInputOnlyCapture())
        let outcome = try await log.waitForFirst()
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("Nothing was recorded"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await log.settle()
        #expect(log.outcomes.count == 1)
    }

    @Test("input-only capture: shutdown cancels a running capture, once")
    func inputOnlyCaptureShutdownCancels() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        try source.deliverSignal(buffers: 1)
        engine.shutdown()

        #expect(try await log.waitForFirst() == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await log.settle()
        #expect(log.outcomes.count == 1)
        #expect(engine.inputOnlyCapturePeakDbfs() == nil)
    }

    @Test("input-only capture: the level reads while recording and is nil once it ends")
    func inputOnlyCapturePeakReadsWhileRecording() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        #expect(engine.inputOnlyCapturePeakDbfs() == InputLevelMeter.floorDbfs)

        source.deliver(try CaptureSignal.filled(format, frames: 4_096) { _, _ in 0.5 }, atSeconds: 0)
        let half = 20 * log10(0.5)
        #expect(try await pollUntil { abs((engine.inputOnlyCapturePeakDbfs() ?? 0) - half) < 1e-9 })

        source.deliver(try CaptureSignal.filled(format, frames: 4_096) { _, _ in 0 }, atSeconds: 0.1)
        #expect(try await pollUntil { engine.inputOnlyCapturePeakDbfs() == InputLevelMeter.floorDbfs })

        #expect(engine.stopInputOnlyCapture())
        _ = try await log.waitForFirst()
        #expect(engine.inputOnlyCapturePeakDbfs() == nil)
    }

    @Test("input-only capture: other conformers get the refusing default; the real engine overrides it through the protocol")
    func inputOnlyCaptureDefaultAndRealEngineDispatch() async throws {
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        // The default, through the protocol.
        let bare: any AudioEngineControlling = BareCaptureEngine()
        do {
            try bare.startInputOnlyCapture(to: url, maxSeconds: 5, completion: log.completion)
            Issue.record("the default must refuse")
        } catch let error as InputOnlyCaptureError {
            #expect(error.kind == .unsupported)
            #expect(error.errorDescription == error.message && !error.message.isEmpty)
        }
        #expect(!bare.stopInputOnlyCapture())
        #expect(!bare.cancelInputOnlyCapture())
        #expect(bare.inputOnlyCapturePeakDbfs() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // The real engine, through the SAME existential: the requirement must
        // dispatch to `AudioEngine`'s implementation, not the default.
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let real: any AudioEngineControlling = captureEngine(source)
        try real.startInputOnlyCapture(to: url, maxSeconds: 5, completion: log.completion)
        #expect(source.startCount == 1)
        #expect(real.inputOnlyCapturePeakDbfs() != nil)
        #expect(real.cancelInputOnlyCapture())
        #expect(try await log.waitForFirst() == .cancelled)
        try await log.settle()
        #expect(log.outcomes.count == 1)
    }
}

// MARK: - W8-RTFIX (RT review F2/F3): one recording at a time, and the stall backstop

/// The refusal a take meets while a voice recording runs (`beginTake`).
private let voiceRecordingRunsRefusal = "Your voice is being recorded. Stop that recording first."

/// A transport for the takes below: no count-in and NO METRONOME, so a test
/// that does start the playback engine plays nothing at all.
@MainActor
private func silentTransport() -> TransportState {
    var transport = TransportState()
    transport.positionBeats = 0
    transport.countInBars = 0
    transport.isMetronomeEnabled = false
    return transport
}

extension RecordingWriterTests {
    /// F2, forward. ⛔ AUDIO-LESS, MIDI-LESS TAKES ONLY, in every test here:
    /// with the guard planted out, a take given an audio URL would open the
    /// REAL microphone (`startTakeBody` builds its own `InputCapture`). The
    /// audio branch is covered by reading: the guard is `beginTake`'s first
    /// statement, ahead of every branch.
    @Test("W8-RTFIX F2: a take refuses to start while a voice recording runs, and leaves the recording alone")
    func inputOnlyCaptureBlocksATake() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        defer { engine.shutdown() }
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()
        final class Takes { var completions = 0 }
        let takes = Takes()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        try source.deliverSignal(buffers: 2)
        var refusal: String?
        do {
            try engine.startTake(silentTransport(), audioURL: nil, captureMIDI: false) { _ in
                takes.completions += 1
            }
        } catch EngineError.recordingFailed(let reason) {
            refusal = reason
        }
        #expect(refusal == voiceRecordingRunsRefusal, "startTake was not refused: \(refusal ?? "no throw")")
        #expect(engine.activeTakeKeepsPlaybackForTesting == nil, "a take started anyway")
        #expect(!engine.isRunning, "the playback engine started")
        #expect(source.stopCount == 0, "the refusal touched the voice recording's input")
        #expect(engine.inputOnlyCapturePeakDbfs() != nil, "the voice recording stopped")

        #expect(engine.stopInputOnlyCapture())
        let outcome = try await log.waitForFirst()
        guard case .recorded(let recording) = outcome else {
            Issue.record("expected .recorded, got \(outcome)")
            return
        }
        #expect(recording.frameCount == 8_192)
        try await log.settle()
        #expect(log.outcomes.count == 1)
        #expect(takes.completions == 0)
    }

    /// F2, forward, through `startTakeInPlayback` — the path `looper.*` takes.
    /// ⚠️ STARTS THE PLAYBACK ENGINE (no tracks, no metronome: silence), the
    /// `LoopRecordEngineTests` shape, because that path refuses anything that
    /// is not already playing before it reaches `beginTake`.
    @Test("W8-RTFIX F2: a layer take (the looper's path) refuses to start while a voice recording runs")
    func inputOnlyCaptureBlocksALayerTake() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        do {
            try engine.prepare()
        } catch {
            Issue.record("the engine would not prepare — FAILURE, not a skip: \(error)")
            return
        }
        defer { engine.shutdown() }
        engine.startPlayback(silentTransport())
        #expect(engine.transportRollingForTesting, "nothing is playing, so this test proves nothing")
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 10, completion: log.completion)
        try source.deliverSignal(buffers: 1)
        var layer = silentTransport()
        layer.positionBeats = engine.derivedLinearBeats()
        var refusal: String?
        do {
            try engine.startTakeInPlayback(layer, audioURL: nil, captureMIDI: false) { _ in }
        } catch EngineError.recordingFailed(let reason) {
            refusal = reason
        }
        #expect(refusal == voiceRecordingRunsRefusal,
                "startTakeInPlayback was not refused by the guard: \(refusal ?? "no throw")")
        #expect(engine.activeTakeKeepsPlaybackForTesting == nil, "a layer take started anyway")
        #expect(engine.inputOnlyCapturePeakDbfs() != nil, "the voice recording stopped")

        #expect(engine.stopInputOnlyCapture())
        guard case .recorded = try await log.waitForFirst() else {
            Issue.record("the voice recording did not finish as .recorded")
            return
        }
        try await log.settle()
        #expect(log.outcomes.count == 1)
        engine.stopPlayback()
    }

    /// F2, the reverse direction, which `startInputOnlyCapture` already had.
    /// ⚠️ STARTS THE PLAYBACK ENGINE (an audio-less, MIDI-less take; silence).
    @Test("W8-RTFIX F2: the reverse still holds — a voice recording refuses to start while a take rolls")
    func aRollingTakeBlocksAnInputOnlyCapture() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        do {
            try engine.prepare()
        } catch {
            Issue.record("the engine would not prepare — FAILURE, not a skip: \(error)")
            return
        }
        defer { engine.shutdown() }
        final class Takes { var completions = 0 }
        let takes = Takes()
        try engine.startTake(silentTransport(), audioURL: nil, captureMIDI: false) { _ in
            takes.completions += 1
        }
        #expect(engine.activeTakeKeepsPlaybackForTesting != nil, "no take is rolling, so this test proves nothing")
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        var refusal: InputOnlyCaptureError?
        do {
            try engine.startInputOnlyCapture(to: url, maxSeconds: 5, completion: log.completion)
        } catch let error as InputOnlyCaptureError {
            refusal = error
        }
        #expect(refusal?.kind == .busy)
        #expect(refusal?.message == "A recording is already running. Stop it, then record your voice.")
        #expect(source.prepareCount == 0, "the refused start touched the input")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await log.settle()
        #expect(log.outcomes.isEmpty, "a refused start must never report")

        // Control: once the take is over, the same start is accepted.
        engine.stopRecording()
        #expect(try await pollUntil { takes.completions == 1 })
        try engine.startInputOnlyCapture(to: url, maxSeconds: 5, completion: log.completion)
        #expect(source.prepareCount == 1)
        #expect(engine.cancelInputOnlyCapture())
        #expect(try await log.waitForFirst() == .cancelled)
    }

    /// F3: ONE buffer arrives, then the input goes quiet for good (no more
    /// deliveries, no configuration change, the source still "running"). Only
    /// the backstop can end this capture, and it must do so ONCE, as
    /// `.failed`, deleting the partial file.
    @Test("W8-RTFIX F3: an input that stops after its first buffer is ended by the backstop, as .failed, once")
    func inputOnlyCaptureBackstopEndsAStalledInput() async throws {
        let source = SyntheticInputSource(format: try CaptureSignal.format(channels: 1))
        let engine = captureEngine(source)
        defer { engine.shutdown() }  // a red (no backstop) must not leave it recording
        engine.inputOnlyCaptureStallGraceSeconds = 0.2
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()
        let clock = ContinuousClock()
        let started = clock.now

        // 0.5 s at 48 kHz is a 24 000-frame limit; 4 096 frames arrive.
        try engine.startInputOnlyCapture(to: url, maxSeconds: 0.5, completion: log.completion)
        try source.deliverSignal(buffers: 1)
        let outcome = try await log.waitForFirst(seconds: 15)
        let elapsed = started.duration(to: clock.now)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("stopped sending sound"), "reason: \(reason)")
        // A LOWER bound only: a sleep never ends early. An upper bound would be
        // an assumption about the scheduler, not a fact about the capture.
        #expect(elapsed >= .milliseconds(700), "the backstop ended it after \(elapsed), before maxSeconds + grace")
        #expect(!FileManager.default.fileExists(atPath: url.path), "the partial file survived")
        #expect(source.stopCount >= 1, "the input was not stopped")
        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    /// F3's invariance control: with NO grace at all, a capture that reached
    /// its length is still `.recorded(.reachedMaxSeconds)`, byte for byte —
    /// whichever of the backstop and the frame limit lands first.
    @Test("W8-RTFIX F3: the backstop never cuts a capture that reached its length")
    func inputOnlyCaptureBackstopKeepsACompleteCapture() async throws {
        let format = try CaptureSignal.format(channels: 2)
        let source = SyntheticInputSource(format: format)
        let engine = captureEngine(source)
        engine.inputOnlyCaptureStallGraceSeconds = 0
        let url = CaptureSignal.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = OutcomeLog()

        try engine.startInputOnlyCapture(to: url, maxSeconds: 0.25, completion: log.completion)
        try source.deliverSignal(buffers: 4)
        let outcome = try await log.waitForFirst()
        guard case .recorded(let recording) = outcome else {
            Issue.record("expected .recorded, got \(outcome)")
            return
        }
        #expect(recording.endedBy == .reachedMaxSeconds)
        #expect(recording.frameCount == 12_000)
        let wav = try CaptureSignal.wav(at: url)
        #expect(CaptureSignal.firstMismatch(wav.data,
                                            CaptureSignal.interleavedBytes(channels: 2, frames: 0..<12_000)) == nil)
        try await log.settle()
        #expect(log.outcomes.count == 1)
        try expectIdleAndReusable(engine, source)
    }

    /// F3, the mapping, deterministically (the race above cannot be forced):
    /// when the backstop wins against a limit signal still on its way, the
    /// finalize result decides — full length is kept, anything short fails,
    /// and a write failure keeps its own sentence.
    @Test("W8-RTFIX F3: the backstop's mapping keeps a full-length file and fails a short one")
    func inputOnlyCaptureStalledMapping() {
        let url = URL(fileURLWithPath: "/nonexistent/w8-rtfix-mapping.wav")
        func written(_ frames: Int64) -> Swift.Result<RecordingWriter.Result, any Error> {
            .success(RecordingWriter.Result(url: url, framesWritten: frames, sampleRate: 48_000,
                                            channelCount: 1, startOffsetSeconds: 0))
        }
        let full = AudioEngine.inputOnlyCaptureOutcome(for: .stalled(frameLimit: 12_000),
                                                       result: written(12_000))
        if case .recorded(let recording) = full {
            #expect(recording.endedBy == .reachedMaxSeconds)
            #expect(recording.frameCount == 12_000)
            #expect(recording.fileURL == url)
        } else {
            Issue.record("a full-length file under the backstop became \(full)")
        }
        for frames: Int64 in [0, 1, 4_096, 11_999] {
            let short = AudioEngine.inputOnlyCaptureOutcome(for: .stalled(frameLimit: 12_000),
                                                            result: written(frames))
            if case .failed(let reason) = short {
                #expect(reason.contains("stopped sending sound"), "\(frames) frames: \(reason)")
            } else {
                Issue.record("\(frames) of 12 000 frames under the backstop became \(short)")
            }
        }
        struct WriteFailure: Error {}
        let failure = AudioEngine.inputOnlyCaptureOutcome(for: .stalled(frameLimit: 12_000),
                                                          result: .failure(WriteFailure()))
        if case .failed(let reason) = failure {
            #expect(reason.contains("couldn't be saved"), "reason: \(reason)")
        } else {
            Issue.record("a write failure under the backstop became \(failure)")
        }
    }
}
