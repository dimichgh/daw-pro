import AVFAudio
import Foundation
import Testing
@testable import DAWEngine

/// RecordingWriter is a pure sink: these tests drive it with synthetic ramp
/// buffers and host-time stamps — no microphone, no TCC prompt, no live
/// engine. Alignment, channel mapping, rate preservation, and file lifecycle
/// are all assertion-checked against the written WAV.
@MainActor
@Suite("RecordingWriter — synthetic capture", .serialized)
struct RecordingWriterTests {
    private func takeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-recwriter-\(UUID().uuidString)")
            .appendingPathComponent("take.wav")
    }

    private func format(rate: Double = 48_000, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        if channels > 2 {
            // The channels: initializer is nil above stereo — multichannel
            // formats (4-ch interface fixture) need an explicit layout.
            let layout = try #require(AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            ))
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                 interleaved: false, channelLayout: layout)
        }
        return try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                          channels: channels, interleaved: false))
    }

    private func finalize(_ writer: RecordingWriter) async throws -> RecordingWriter.Result {
        let result: Swift.Result<RecordingWriter.Result, any Error> =
            await withCheckedContinuation { continuation in
                writer.finalize { continuation.resume(returning: $0) }
            }
        return try result.get()
    }

    /// Bit-exact ramp check: file sample i must equal Float(startIndex+i)*1e-4.
    private func expectRamp(_ samples: [Float], startIndex: Int) {
        var firstMismatch: Int? = nil
        for index in samples.indices where samples[index] != Float(startIndex + index) * 1e-4 {
            firstMismatch = index
            break
        }
        #expect(firstMismatch == nil,
                "ramp mismatch at frame \(firstMismatch ?? -1) (expected start \(startIndex))")
    }

    // T1.
    @Test("nil anchor: buffers write in order, bit-exact, offset 0")
    func basicWrite() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)  // accept from the first buffer

        var index = 0
        for _ in 0..<3 {
            let buffer = TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: index)
            writer.append(buffer, at: AVAudioTime(hostTime: TestSignals.hostTime(at: Double(index) / 48_000)))
            index += 4_096
        }

        let result = try await finalize(writer)
        #expect(result.framesWritten == 12_288)
        #expect(result.sampleRate == 48_000)
        #expect(result.channelCount == 1)
        #expect(result.startOffsetSeconds == 0)

        let channels = try TestSignals.readFile(url)
        #expect(channels.count == 1)
        #expect(channels[0].count == 12_288)
        expectRamp(channels[0], startIndex: 0)
    }

    // T2.
    @Test("buffers pend before the anchor, then a straddling buffer trims to it")
    func anchorTrimsStraddlingBuffer() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)

        // One 0.5 s buffer starting at t=0 — appended BEFORE the anchor is
        // known, so it pends, then drains through the alignment path.
        let buffer = TestSignals.makeRampBuffer(format: format, frames: 24_000, startIndex: 0)
        writer.append(buffer, at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))

        let result = try await finalize(writer)
        // skipFrames = round(0.25 * 48_000) = 12_000; the rest is written.
        #expect(result.framesWritten == 12_000)
        // First written frame sits ON the anchor (± one host tick of rounding).
        #expect(abs(result.startOffsetSeconds) < 1e-4)

        let channels = try TestSignals.readFile(url)
        #expect(channels[0].count == 12_000)
        expectRamp(channels[0], startIndex: 12_000)
    }

    // T3.
    @Test("a buffer that ends before the anchor is dropped whole")
    func preAnchorBufferDropped() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))

        // [0, 0.25) ends exactly at the anchor → dropped.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 12_000, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))
        // [0.25, 0.5) starts on the anchor → written whole.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 12_000, startIndex: 12_000),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0.25)))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 12_000)
        #expect(abs(result.startOffsetSeconds) < 1e-4)

        let channels = try TestSignals.readFile(url)
        expectRamp(channels[0], startIndex: 12_000)
    }

    // T3b — regression for the pinned-device empty-take bug: a reconfigured
    // AUHAL can stamp tap buffers with hostTime 0 or no host time at all;
    // alignment math trimming against a real anchor then treated EVERY buffer
    // as pre-anchor and silently dropped the whole take.
    @Test("invalid host timestamps with a target: accepted untrimmed from frame 0, offset 0")
    func invalidTimestampsAcceptUntrimmed() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        // Real anchor: trimming against it with a zero/invalid host clock
        // would have dropped everything.
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))

        // hostTime == 0: "valid" flag set, epoch garbage.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 0),
                      at: AVAudioTime(hostTime: 0))
        // isHostTimeValid == false: sample-time-only stamp.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 4_096),
                      at: AVAudioTime(sampleTime: 4_096, atRate: 48_000))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 8_192)  // every frame fed survives
        #expect(result.startOffsetSeconds == 0)

        let channels = try TestSignals.readFile(url)
        #expect(channels[0].count == 8_192)
        expectRamp(channels[0], startIndex: 0)
    }

    // T3c — mixed clocks: the invalid first stamp triggers the fallback and
    // starts the take; later buffers append whole regardless of their stamps
    // (per-take alignment is decided exactly once, on the first accepted buffer).
    @Test("target set, first buffer invalid-hostTime: fallback starts the take, valid follower appends whole")
    func invalidFirstTimestampThenValid() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))

        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 0),
                      at: AVAudioTime(sampleTime: 0, atRate: 48_000))  // no host time
        // Valid stamp — and a pre-anchor one at that: once started, it must
        // append whole, not re-enter the trim/drop path.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 4_096),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 8_192)
        #expect(result.startOffsetSeconds == 0)

        let channels = try TestSignals.readFile(url)
        expectRamp(channels[0], startIndex: 0)
    }

    // T4.
    @Test("capture starting after the anchor reports the gap as startOffsetSeconds")
    func lateCaptureReportsOffset() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))

        // First buffer arrives 0.1 s late: written whole, offset reported.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_800, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0.35)))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 4_800)
        #expect(abs(result.startOffsetSeconds - 0.1) < 1e-4)

        let channels = try TestSignals.readFile(url)
        expectRamp(channels[0], startIndex: 0)
    }

    // T5.
    @Test("4-channel input maps to a 2-channel file, channels 0/1 bit-equal")
    func fourChannelToStereo() async throws {
        let format = try format(channels: 4)
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)

        // Distinct channels (ramp + channel index) so a mapping error that
        // grabbed channels 2/3 could not pass the bit-equal check.
        let buffer = TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 0)
        let source = try #require(buffer.floatChannelData)
        for channel in 0..<4 {
            for frame in 0..<4_096 {
                source[channel][frame] += Float(channel)
            }
        }
        writer.append(buffer, at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        #expect(result.channelCount == 2)
        #expect(result.framesWritten == 4_096)

        let channels = try TestSignals.readFile(url)
        #expect(channels.count == 2)
        for channel in 0..<2 {
            var mismatches = 0
            for frame in 0..<4_096
            where channels[channel][frame] != Float(frame) * 1e-4 + Float(channel) {
                mismatches += 1
            }
            #expect(mismatches == 0, "channel \(channel) not bit-equal to source")
        }
    }

    // T5b.
    @Test("mono input passes through as a 1-channel file, bit-equal")
    func monoPassthrough() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        #expect(result.channelCount == 1)

        let channels = try TestSignals.readFile(url)
        #expect(channels.count == 1)
        expectRamp(channels[0], startIndex: 0)
    }

    // T6.
    @Test("44.1 kHz input records at 44.1 kHz — no sample-rate conversion")
    func deviceRatePreserved() async throws {
        let format = try format(rate: 44_100)
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 44_100, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        #expect(result.sampleRate == 44_100)
        #expect(result.framesWritten == 44_100)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 44_100)
        #expect(file.length == 44_100)
        let channels = try TestSignals.readFile(url)
        expectRamp(channels[0], startIndex: 0)  // bit-equal ⇒ nothing resampled
    }

    // W1.
    @Test("window end mid-buffer: trailing frames trim at the punch-out point")
    func windowEndTrimsTrailing() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        // Accept from the first buffer; punch out at 0.25 s.
        writer.setAcceptWindow(reference: nil, start: nil, end: TestSignals.hostTime(at: 0.25))

        // One 0.5 s buffer at t = 0 straddles the end → only [0, 0.25) kept.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 24_000, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        // llround at the input rate: 0.25 s × 48_000 = 12_000 frames, ±1 for
        // host-tick rounding.
        #expect(abs(result.framesWritten - 12_000) <= 1)
        #expect(result.startOffsetSeconds == 0)

        let channels = try TestSignals.readFile(url)
        let frames = channels[0].count
        #expect(abs(frames - 12_000) <= 1)
        expectRamp(channels[0], startIndex: 0)
        // The last written frame's ramp value sits at the window end position
        // (frame 0.25 s × 48_000 − 1, ± one frame's ramp step).
        let last = try #require(channels[0].last)
        let windowEndValue: Double = (0.25 * 48_000 - 1) * 1e-4  // frame 11_999's ramp value
        let deviation: Double = abs(Double(last) - windowEndValue)
        #expect(deviation <= 1.01e-4)
    }

    // W2.
    @Test("buffers entirely after the window end are dropped; framesWritten unchanged")
    func buffersAfterWindowEndDropped() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setAcceptWindow(reference: nil, start: nil, end: TestSignals.hostTime(at: 0.25))

        // [0, 0.25) ends exactly at the window end → written whole.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 12_000, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))
        // [0.25, 0.5) starts ON the end → dropped (fires the once-per-take
        // stderr note; framesWritten is the observable assertion here).
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 12_000, startIndex: 12_000),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0.25)))
        // [0.5, 0.75) also after the end → dropped through the same path.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 12_000, startIndex: 24_000),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0.5)))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 12_000)

        let channels = try TestSignals.readFile(url)
        #expect(channels[0].count == 12_000)
        expectRamp(channels[0], startIndex: 0)
    }

    // W3.
    @Test("window start and end inside one buffer: leading and trailing trim together")
    func windowWithinOneBuffer() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        // A 0.1 s window [0.1, 0.2) — smaller than the 0.5 s buffer. No
        // explicit reference → it falls back to the window start, so the
        // reported offset is window-relative here (single-anchor behavior).
        writer.setAcceptWindow(reference: nil,
                               start: TestSignals.hostTime(at: 0.1),
                               end: TestSignals.hostTime(at: 0.2))

        writer.append(TestSignals.makeRampBuffer(format: format, frames: 24_000, startIndex: 0),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))

        let result = try await finalize(writer)
        // Head trim 4_800 frames, tail cut at frame 9_600 → 4_800 kept (±1).
        #expect(abs(result.framesWritten - 4_800) <= 1)
        // First written frame sits ON the window start.
        #expect(abs(result.startOffsetSeconds) < 1e-4)

        let channels = try TestSignals.readFile(url)
        #expect(abs(channels[0].count - 4_800) <= 1)
        expectRamp(channels[0], startIndex: 4_800)
    }

    // W4 — the T3b fallback wins over the window: invalid first stamp means
    // neither bound can be placed on the host clock, so punch degrades to a
    // full take (the clip then lands at the record position — honest fallback).
    @Test("invalid timestamps with a window set: full accept, both bounds ignored")
    func invalidTimestampsIgnoreWindow() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        // Real window + reference (engine-shaped call) — trimming against it
        // with a broken host clock would have dropped or truncated the whole
        // take, and an offset against the reference would be a lie.
        writer.setAcceptWindow(reference: TestSignals.hostTime(at: 0),
                               start: TestSignals.hostTime(at: 0.25),
                               end: TestSignals.hostTime(at: 0.5))

        // hostTime == 0: "valid" flag set, epoch garbage → fallback fires.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 0),
                      at: AVAudioTime(hostTime: 0))
        // isHostTimeValid == false: sample-time-only stamp, appends whole.
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 24_000, startIndex: 4_096),
                      at: AVAudioTime(sampleTime: 4_096, atRate: 48_000))
        // A VALID stamp past the original end bound: the fallback cleared the
        // window, so this must append whole too (per-take alignment is
        // decided exactly once, on the first accepted buffer).
        writer.append(TestSignals.makeRampBuffer(format: format, frames: 4_096, startIndex: 28_096),
                      at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0.6)))

        let result = try await finalize(writer)
        #expect(result.framesWritten == 32_192)  // every frame fed survives
        #expect(result.startOffsetSeconds == 0)

        let channels = try TestSignals.readFile(url)
        #expect(channels[0].count == 32_192)
        expectRamp(channels[0], startIndex: 0)
    }

    // W5 — regression for the live-E2E punched-clip placement bug: the offset
    // must be measured from the RECORD ANCHOR (reference), not the window
    // start. ProjectStore places clips at recordStart + offset × tempo/60, so
    // a window-relative offset (≈ 0) landed a punch [1, 2] clip at beat 0.
    @Test("punch window after the anchor: startOffsetSeconds reports the anchor→punch-in gap")
    func windowOffsetMeasuredFromReference() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        // Anchor (reference) at t = 0; window [0.5, 1.0) — the shape of a
        // punch [1, 2] at 120 BPM recorded from beat 0.
        writer.setAcceptWindow(reference: TestSignals.hostTime(at: 0),
                               start: TestSignals.hostTime(at: 0.5),
                               end: TestSignals.hostTime(at: 1.0))

        // 1.5 s of capture from the anchor in three 0.5 s buffers spanning
        // the window: pre-window (dropped), in-window (kept), post-window
        // (dropped).
        for index in 0..<3 {
            writer.append(
                TestSignals.makeRampBuffer(format: format, frames: 24_000,
                                           startIndex: index * 24_000),
                at: AVAudioTime(hostTime: TestSignals.hostTime(at: Double(index) * 0.5))
            )
        }

        let result = try await finalize(writer)
        // Window length: 0.5 s × 48_000 = 24_000 frames (±1).
        #expect(abs(result.framesWritten - 24_000) <= 1)
        // Offset from the ANCHOR: 0.5 s. Window-relative would read 0 and
        // place the clip at the record position.
        #expect(abs(result.startOffsetSeconds - 0.5) < 1e-3)

        let channels = try TestSignals.readFile(url)
        expectRamp(channels[0], startIndex: 24_000)
    }

    // T6b — the engine's first-buffer watchdog seam: `hasReceivedAudio`
    // records buffer ARRIVAL, not content. A silent, pre-anchor buffer that
    // the alignment path drops whole must still flip the flag — the watchdog
    // aborts only takes where NO delivery ever reached the writer (dead input
    // plumbing), never takes of legitimate silence or trimmed capture.
    @Test("hasReceivedAudio flips on the first append — arrival, not written content")
    func firstBufferFlagSemantics() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(TestSignals.hostTime(at: 0.25))
        #expect(!writer.hasReceivedAudio)

        // All-zero (silent) buffer ending exactly ON the anchor → dropped
        // whole by the trim path; zero frames ever written.
        let silent = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
        silent.frameLength = 12_000
        writer.append(silent, at: AVAudioTime(hostTime: TestSignals.hostTime(at: 0)))
        // Synchronous by contract: the flag is set in append() before the
        // enqueue, so the main actor can never read a stale false after a
        // delivery landed.
        #expect(writer.hasReceivedAudio)

        let result = try await finalize(writer)
        #expect(result.framesWritten == 0)      // arrival ≠ written content
        #expect(writer.hasReceivedAudio)        // finalize never clears it
    }

    // T7.
    @Test("a zero-frame take deletes its file")
    func emptyTakeDeletesFile() async throws {
        let format = try format()
        let url = takeURL()
        let writer = try RecordingWriter(url: url, inputFormat: format)
        writer.setTargetHostTime(nil)
        #expect(FileManager.default.fileExists(atPath: url.path))  // opened on init

        let result = try await finalize(writer)
        #expect(result.framesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // T8.
    @Test("an unwritable destination throws on init")
    func unwritableDestinationThrows() throws {
        let format = try format()
        // /dev/null is a file — creating a directory tree under it must fail.
        let url = URL(fileURLWithPath: "/dev/null/daw-pro-recwriter/take.wav")
        #expect(throws: (any Error).self) {
            _ = try RecordingWriter(url: url, inputFormat: format)
        }
    }
}
