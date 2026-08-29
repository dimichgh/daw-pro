import AVFAudio
import Foundation

/// m32-h — the one correct way to get N frames out of an `AVAudioFile`.
///
/// ## The defect this exists to make unrepeatable
///
/// A single `AVAudioFile.read(into:)` **silently short-reads mono files**.
/// It stops at the largest 1024-frame-aligned ABSOLUTE file position at or
/// below the end of the request, returns no error, and leaves the caller a
/// buffer whose `frameLength` is simply smaller than what was asked for.
/// Measured on this machine (`read(into:)`, whole-file, 44.1 kHz float32):
///
/// | frames asked | mono got | lost | stereo got (positive control) |
/// |---|---|---|---|
/// | 22 050 | 21 504 | 546 | 22 050 |
/// | 22 016 | 21 504 | 512 | 22 016 |
/// | 44 100 | 44 032 | 68 | 44 100 |
/// | 66 150 | 65 536 | 614 | 66 150 |
/// | 88 200 | 88 064 | 136 | 88 200 |
/// | 22 528 (1024-aligned) | 22 528 | 0 | 22 528 |
///
/// **Stereo reads fully at every one of those lengths.** That is the positive
/// control, and it is what proves the READER is at fault rather than the
/// writer. Worst case is 1023 lost frames = **23.2 ms at 44.1 kHz**, taken off
/// the TAIL — which on a drum one-shot is a decay that stops early.
/// `read(into:frameCount:)` short-reads identically, including from a non-zero
/// `framePosition` (start 1000 + 21 528 read = 22 528: the aligned position, not
/// an aligned count).
///
/// ## ⚠️ Why the obvious loop is WRONG — measured, not reasoned
///
/// The intuitive fix, "call `read(into:)` again until `frameLength` reaches
/// `file.length`", **does not work and makes things worse**. `read(into:)` does
/// NOT append: it rewrites the buffer from frame 0 and RESETS `frameLength` to
/// the count read by THAT call. Measured on a 22 050-frame mono file:
///
///     read #1: framePosition 0 → 21 504,      frameLength 0 → 21 504
///     read #2: framePosition 21 504 → 22 050, frameLength 21 504 → 546
///              …and buffer[0] is now frame 21 504 of the file, not frame 0.
///
/// So `frameLength` can never reach `file.length`; the loop would run a third
/// time, read 0 frames, and leave `frameLength == 0`. Under a caller's
/// `guard buffer.frameLength > 0` that turns a 23 ms truncation into a
/// **completely skipped file** — strictly worse than the bug being fixed.
///
/// The only correct shape is therefore the one `TransientAnalyzer.readMono`,
/// `StretchRenderCache` and `BoundarySnapper` already use: read into a scratch
/// chunk, copy out at a running offset, and loop on `framePosition` — never on
/// `frameLength`.
///
/// REAL-TIME SAFETY: never call from the render path. It allocates and does
/// file I/O; every caller is load-time or offline-bake code.
enum AudioFileFullRead {

    /// Scratch chunk size. Comfortably above the 1024-frame granularity of the
    /// short read, and small enough that the scratch itself is incidental
    /// (256 KB at stereo float32) next to the destination it fills.
    static let chunkFrames: AVAudioFrameCount = 32_768

    /// Fills `buffer` with up to `frameCount` frames read from `file`'s CURRENT
    /// read position, looping until it has them all or the file stops
    /// advancing. On return `buffer.frameLength` is the count actually placed,
    /// and frames `0..<frameLength` are contiguous file frames in order.
    ///
    /// Returns fewer than `frameCount` only when the file genuinely ran out —
    /// a real end-of-file, not the 1024-alignment artefact. A caller that needs
    /// to distinguish "short file" from "short read" can now trust the
    /// difference, which before this existed it could not.
    ///
    /// Terminates on a file that stops delivering frames (`framePosition` fails
    /// to advance) rather than spinning, so a truncated or corrupt source ends
    /// the loop instead of hanging the load.
    @discardableResult
    static func fill(_ buffer: AVAudioPCMBuffer, from file: AVAudioFile,
                     frameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        buffer.frameLength = 0
        let wanted = min(frameCount, buffer.frameCapacity)
        // Formats must agree: `read` requires the buffer be in the file's
        // processing format, and the per-channel copy below indexes both.
        guard wanted > 0,
              buffer.format.channelCount == file.processingFormat.channelCount,
              let destination = buffer.floatChannelData
        else { return 0 }
        let channelCount = Int(buffer.format.channelCount)

        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: min(chunkFrames, wanted)),
              let source = chunk.floatChannelData
        else { return 0 }

        var filled: AVAudioFrameCount = 0
        while filled < wanted {
            // ⚠️⚠️ NEVER READ **AT** END-OF-FILE. `read` called when
            // `framePosition == length` fails by returning NO **without
            // setting an NSError**, and Swift surfaces that as
            // `Foundation._GenericObjCError.nilError` — an exception carrying
            // no message, no code and no clue what went wrong. (Measured: an
            // over-ask with frames still remaining returns short quite
            // happily; it is only the read AT the end that throws.) This is
            // the real reason every correct loop in this tree gates on
            // `framePosition < length` rather than on a frame count alone —
            // the guard is not an optimisation, it is what keeps a routine
            // "read the whole file" from throwing a blank error.
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { break }
            let toRead = min(wanted - filled,
                             AVAudioFrameCount(min(remaining,
                                                   AVAudioFramePosition(chunk.frameCapacity))))
            guard toRead > 0 else { break }
            let positionBefore = file.framePosition
            try file.read(into: chunk, frameCount: toRead)
            let got = chunk.frameLength
            // Termination guard, defence-in-depth: `read` reports a dry file
            // as a zero-frame SUCCESS, so without this a source that stopped
            // delivering while still claiming length would spin forever.
            guard got > 0, file.framePosition > positionBefore else { break }
            for channel in 0..<channelCount {
                (destination[channel] + Int(filled))
                    .update(from: source[channel], count: Int(got))
            }
            filled += got
        }
        buffer.frameLength = filled
        return filled
    }

    /// Reads a whole file into a freshly allocated buffer, from frame 0.
    /// `nil` when the file is empty or a buffer cannot be allocated.
    static func readWholeFile(_ file: AVAudioFile) throws -> AVAudioPCMBuffer? {
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        file.framePosition = 0
        _ = try fill(buffer, from: file, frameCount: AVAudioFrameCount(file.length))
        return buffer
    }
}
