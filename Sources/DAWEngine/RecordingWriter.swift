import AVFAudio
import DAWCore
import Foundation
import os

/// Pure recording sink: accepts input-tap buffers from any thread and drains
/// them into a Float32 WAV on a private serial queue. Knows nothing about
/// engines, tracks, or transport — synthetic buffers exercise it fully in
/// tests (no microphone, no TCC).
///
/// File format: WAV, Float32, interleaved on disk (mirrors
/// `OfflineRenderer.renderToWAV` including `AVLinearPCMIsNonInterleaved:
/// false`), at the device-native input rate — no sample-rate conversion in the
/// capture path. File channel count = min(input channels, 2).
///
/// RIFF/WAV carries a 4 GiB size ceiling (~3.1 h of stereo Float32 at 48 kHz);
/// takes that long are out of scope for Stage A, so there is no guard.
///
/// `@unchecked Sendable` justification: everything mutable after `init` is
/// confined to the private serial `queue`; `append` and the public entry
/// points only enqueue.
final class RecordingWriter: @unchecked Sendable {
    /// Facts about one finalized take file.
    struct Result: Sendable, Equatable {
        let url: URL
        let framesWritten: Int64
        let sampleRate: Double
        let channelCount: Int
        /// Seconds between the offset REFERENCE (the record anchor — see
        /// `setAcceptWindow(reference:start:end:)`) and the first written
        /// frame, >= 0. Anchor-relative BY CONTRACT: for punched takes this
        /// includes the anchor → punch-in gap, which is exactly what
        /// ProjectStore's clip-placement formula (recordStart + offset ×
        /// tempo/60) needs — a window-relative offset (≈ 0) would land the
        /// clip at the record position. Latency is not compensated (M4 PDC).
        let startOffsetSeconds: Double
    }

    private let queue = DispatchQueue(label: "com.dawpro.recording.writer", qos: .userInitiated)
    private let url: URL
    private let sampleRate: Double
    private let fileChannels: Int
    private let fileFormat: AVAudioFormat

    /// Flipped by the FIRST `append` call — buffer ARRIVAL, not content:
    /// silent, pre-anchor, or invalid-timestamp buffers all count. Lock-backed
    /// (not queue-confined) so the engine's first-buffer watchdog can read it
    /// from the main actor without racing the tap thread; set synchronously in
    /// `append` before the enqueue so a reader never sees a stale false after
    /// a delivery landed.
    private let receivedAudio = OSAllocatedUnfairLock(initialState: false)

    /// True once any tap delivery has reached this writer. The engine's
    /// watchdog uses this to tell dead input hardware (no deliveries at all)
    /// from legitimate silence (silence still produces buffers).
    var hasReceivedAudio: Bool {
        receivedAudio.withLock { $0 }
    }

    // MARK: Queue-confined state (never touched off `queue` after init)

    private var file: AVAudioFile?
    /// Three-state anchor: window not yet set → buffers pend; start set to
    /// nil → accept from the first buffer (tests); set to a host time → align
    /// to it.
    private var targetSet = false
    private var targetHostTime: UInt64?
    /// Host time `startOffsetSeconds` is measured FROM (the record anchor).
    /// Distinct from `targetHostTime` (the accept-window start): a punch
    /// window starts after the anchor, and clip placement needs the offset
    /// from the anchor, not from the window. Falls back to the window start
    /// when no explicit reference was given (single-anchor behavior).
    private var referenceHostTime: UInt64?
    /// Exclusive end of the accept window (punch-out) on the host clock; nil =
    /// no trailing bound. Cleared by the invalid-timestamp fallback: when the
    /// first buffer cannot be placed on the host clock, punch degrades to a
    /// full take (the clip then lands at the record position — honest fallback).
    private var windowEndHostTime: UInt64?
    /// Set once a buffer has been trimmed or dropped against the window end;
    /// everything delivered after is ignored.
    private var punchOutReached = false
    /// One-time diagnostic flag: post-window drops are expected, but a take
    /// must never lose buffers with zero stderr trace.
    private var notedPunchOut = false
    /// Buffers that arrived before the anchor was known, bounded to ~8 s
    /// (oldest dropped with a stderr note).
    private var pendingBuffers: [(buffer: AVAudioPCMBuffer, when: AVAudioTime)] = []
    private var pendingFrames = 0
    private var started = false
    /// One-time diagnostic flag: pre-anchor drops are expected in small
    /// numbers, but a take must never lose buffers with zero stderr trace.
    private var notedPreAnchorDrop = false
    private var startOffsetSeconds: Double = 0
    private var framesWritten: Int64 = 0
    private var writeError: Error?
    private var finalized = false
    /// Reused channel-mapping scratch buffer; reallocated only on growth.
    private var scratch: AVAudioPCMBuffer?

    /// Opens the take file (creating parent directories) for the given
    /// device-native input format. Throws with no file left behind on failure.
    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.url = url
        self.sampleRate = inputFormat.sampleRate
        self.fileChannels = min(Int(inputFormat.channelCount), 2)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: fileChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(fileChannels), interleaved: false
        ) else {
            throw EngineError.recordingFailed(
                "invalid capture format \(sampleRate) Hz × \(fileChannels) ch"
            )
        }
        fileFormat = format
    }

    /// Sets the host-time accept window [start, end) and the offset
    /// reference: capture before `start` is trimmed, capture at/after `end`
    /// is dropped (punch-out), and `Result.startOffsetSeconds` is measured
    /// from `reference` — the record anchor, which for a punch window lies
    /// BEFORE the window start (nil falls back to `start`). Pass nil `start`
    /// to accept from the first buffer (tests); nil `end` for no trailing
    /// bound. Buffers appended before this call pend and are drained here, in
    /// arrival order. First call wins.
    func setAcceptWindow(reference: UInt64?, start: UInt64?, end: UInt64?) {
        queue.async { [self] in
            guard !targetSet else { return }
            targetSet = true
            referenceHostTime = reference ?? start
            targetHostTime = start
            windowEndHostTime = end
            let pending = pendingBuffers
            pendingBuffers = []
            pendingFrames = 0
            for entry in pending {
                process(entry.buffer, at: entry.when)
            }
        }
    }

    /// Sets the alignment anchor (the shared player-start host time) with no
    /// trailing bound; the anchor doubles as the offset reference. Pass nil
    /// to accept from the first buffer (tests).
    func setTargetHostTime(_ hostTime: UInt64?) {
        setAcceptWindow(reference: hostTime, start: hostTime, end: nil)
    }

    /// One tap delivery crossing onto the writer queue. `@unchecked Sendable`
    /// justification: the tap hands over a freshly allocated buffer it never
    /// touches again, and exactly one consumer (the serial queue) reads it.
    private struct TapDelivery: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let when: AVAudioTime
    }

    /// Callable from the input tap's thread: the tap owns `buffer`, so
    /// enqueueing it (no copy) is legal. Buffers are dropped after a write
    /// failure and after finalize.
    func append(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        receivedAudio.withLock { $0 = true }
        let delivery = TapDelivery(buffer: buffer, when: when)
        queue.async { [self] in
            guard !finalized, writeError == nil, file != nil else { return }
            guard targetSet else {
                pend(delivery.buffer, at: delivery.when)
                return
            }
            process(delivery.buffer, at: delivery.when)
        }
    }

    /// Drains everything already appended, closes the file (released by
    /// scope so AVAudioFile flushes its header), deletes it when zero frames
    /// were written, and reports exactly once. Idempotent.
    func finalize(_ completion: @escaping @Sendable (Swift.Result<Result, Error>) -> Void) {
        queue.async { [self] in
            guard !finalized else { return }
            finalized = true
            pendingBuffers = []
            pendingFrames = 0
            // Deallocation flushes and closes; the explicit pool keeps any
            // autoreleased reference from deferring that — the completion's
            // consumers read this file immediately.
            autoreleasepool { file = nil }
            if let writeError {
                completion(.failure(writeError))
                return
            }
            if framesWritten == 0 {
                try? FileManager.default.removeItem(at: url)
            }
            completion(.success(Result(
                url: url,
                framesWritten: framesWritten,
                sampleRate: sampleRate,
                channelCount: fileChannels,
                startOffsetSeconds: startOffsetSeconds
            )))
        }
    }

    // MARK: - Queue internals

    private func pend(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        pendingBuffers.append((buffer, when))
        pendingFrames += Int(buffer.frameLength)
        let bound = Int(sampleRate * 8)  // ~8 s of pre-anchor audio, max
        while pendingFrames > bound, !pendingBuffers.isEmpty {
            let dropped = pendingBuffers.removeFirst()
            pendingFrames -= Int(dropped.buffer.frameLength)
            FileHandle.standardError.write(Data(
                "RecordingWriter: pending buffer bound exceeded — dropping oldest buffer\n".utf8
            ))
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let hasValidStamp = when.isHostTimeValid && when.hostTime != 0
        var skipFrames = 0
        if !started {
            if let target = targetHostTime, hasValidStamp {
                // skipFrames = round(seconds(target − when) * rate), clamped
                // 0...frameLength. A buffer that ends before the target drops.
                let deltaSeconds = when.hostTime >= target
                    ? -AVAudioTime.seconds(forHostTime: when.hostTime - target)
                    : AVAudioTime.seconds(forHostTime: target - when.hostTime)
                skipFrames = Int((deltaSeconds * sampleRate).rounded())
                    .clamped(to: 0...frames)
                if skipFrames >= frames {  // ends at/before the target
                    // Never drop silently: a broken clock relationship here
                    // used to eat ENTIRE takes with no trace on stderr.
                    if !notedPreAnchorDrop {
                        notedPreAnchorDrop = true
                        FileHandle.standardError.write(Data(
                            "recording: dropping pre-anchor input buffer(s) — capture started before the take anchor\n".utf8
                        ))
                    }
                    return
                }
                let firstWrittenHostTime = when.hostTime
                    + AVAudioTime.hostTime(forSeconds: Double(skipFrames) / sampleRate)
                // Offset measured from the REFERENCE (record anchor), not the
                // window start: with a punch window the first written frame
                // sits ~punch-in past the anchor, and that gap is what places
                // the clip at the punch-in point downstream.
                let reference = referenceHostTime ?? target
                startOffsetSeconds = firstWrittenHostTime >= reference
                    ? max(0, AVAudioTime.seconds(forHostTime: firstWrittenHostTime - reference))
                    : 0
            } else {
                if !hasValidStamp, targetHostTime != nil || windowEndHostTime != nil {
                    // A window exists but this first candidate buffer carries
                    // no usable host time (seen live after pinning a capture
                    // device: the reconfigured AUHAL stamped taps with
                    // hostTime 0). Trimming against the anchor would treat
                    // every buffer as pre-anchor and silently drop the whole
                    // take — accept untrimmed instead: alignment degrades to
                    // "first delivered frame", but the audio is real. BOTH
                    // window bounds are ignored: punch degrades to a full
                    // take on timestamp-broken devices, and the clip then
                    // lands at the record position — honest fallback.
                    FileHandle.standardError.write(Data(
                        "recording: input timestamps invalid — accepting untrimmed\n".utf8
                    ))
                    windowEndHostTime = nil
                }
                // No start bound (or unusable stamp): accept from this
                // buffer's first frame. With a valid stamp and an explicit
                // reference the anchor gap is still honest; otherwise 0.
                if hasValidStamp, let reference = referenceHostTime,
                   when.hostTime >= reference {
                    startOffsetSeconds = AVAudioTime.seconds(
                        forHostTime: when.hostTime - reference)
                } else {
                    startOffsetSeconds = 0
                }
            }
            started = true
        }

        var keepFrames = frames - skipFrames
        // Trailing bound (punch-out): a buffer entirely at/after the window
        // end drops; a straddling buffer keeps only the frames before it.
        if let end = windowEndHostTime {
            if punchOutReached {
                notePunchOutOnce()
                return
            }
            if hasValidStamp {
                if when.hostTime >= end {
                    punchOutReached = true
                    notePunchOutOnce()
                    return
                }
                let secondsUntilEnd = AVAudioTime.seconds(forHostTime: end - when.hostTime)
                let framesUntilEnd = Int(llround(secondsUntilEnd * sampleRate))
                if framesUntilEnd <= skipFrames {
                    // Window narrower than the head trim: nothing survives —
                    // a sub-buffer punch window is legal, just already over.
                    punchOutReached = true
                    notePunchOutOnce()
                    return
                }
                if framesUntilEnd < frames {
                    punchOutReached = true
                    keepFrames = min(keepFrames, framesUntilEnd - skipFrames)
                }
            }
            // Invalid mid-take stamps with the end bound intact: the buffer
            // cannot be placed against the window — accept it whole, matching
            // the start-side fallback (never silently drop real audio).
        }
        // After the first accepted frame, buffers append whole up to the
        // window end.
        // TODO(hardening): detect input dropouts (host-time gaps between
        // consecutive buffers) and insert silence to keep alignment.
        write(buffer, from: skipFrames, count: keepFrames)
    }

    /// Once per take: input keeps arriving after the punch-out point, and
    /// dropped buffers must never vanish with zero stderr trace.
    private func notePunchOutOnce() {
        guard !notedPunchOut else { return }
        notedPunchOut = true
        FileHandle.standardError.write(Data(
            "recording: punch-out reached — subsequent input ignored\n".utf8
        ))
    }

    /// Channel-maps `buffer` (dropping channels beyond `fileChannels`) into
    /// the reusable scratch buffer and appends it to the file. Writes at most
    /// `keepFrames` frames starting at `skipFrames`.
    private func write(_ buffer: AVAudioPCMBuffer, from skipFrames: Int, count keepFrames: Int) {
        guard writeError == nil, let file else { return }
        let frames = min(keepFrames, Int(buffer.frameLength) - skipFrames)
        guard frames > 0 else { return }
        guard let source = buffer.floatChannelData else {
            writeError = EngineError.recordingFailed("input buffer has no float channel data")
            return
        }

        if scratch == nil || Int(scratch!.frameCapacity) < frames {
            scratch = AVAudioPCMBuffer(pcmFormat: fileFormat,
                                       frameCapacity: AVAudioFrameCount(max(frames, 4_096)))
        }
        guard let scratch, let destination = scratch.floatChannelData else {
            writeError = EngineError.recordingFailed("could not allocate a capture scratch buffer")
            return
        }

        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        for channel in 0..<fileChannels {
            let dst = destination[channel]
            if interleaved {
                let base = source[0]
                for frame in 0..<frames {
                    dst[frame] = base[(skipFrames + frame) * stride + channel]
                }
            } else {
                let base = source[channel]
                for frame in 0..<frames {
                    dst[frame] = base[skipFrames + frame]
                }
            }
        }
        scratch.frameLength = AVAudioFrameCount(frames)

        do {
            // Per-call pool: ObjC write machinery autoreleases into the
            // queue's root pool, which drains at unspecified times — bound
            // that per buffer so a long take can't accumulate, and so no
            // lingering file reference can defer the dealloc-close.
            try autoreleasepool { try file.write(from: scratch) }
            framesWritten += Int64(frames)
        } catch {
            writeError = error
            FileHandle.standardError.write(Data(
                "RecordingWriter: write failed, dropping the rest of the take: \(error)\n".utf8
            ))
        }
    }
}
