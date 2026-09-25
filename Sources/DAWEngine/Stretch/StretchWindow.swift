import Foundation
import os

// I1-F1 (design `2026-09-24-pitch-editor-interaction-batch.md` §4 follow-up):
// THE SECOND ENTRY INTO THE ONE RENDER LOOP.
//
// A whole-file stretch render (`OfflineStretcher.stretch(input:…)` /
// `stretchTransposeCurve(input:…)`, driven by `StretchRenderCache`) runs ONE
// schedule over the whole source: an `outputSeek` pre-roll, then fixed-size
// output blocks, each consuming the input the cumulative schedule assigns it,
// then a flush. A WINDOW runs THE SAME LOOP ON THE SAME SCHEDULE, starting at
// one of the whole-file render's own block boundaries instead of at frame 0 and
// stopping after the block that reaches the window's end. So:
//
//  * every output frame of a window IS a whole-file output frame, at the same
//    index, fed by the same input frames in the same block sizes, with the
//    transpose curve read at the same frames;
//  * the ONLY thing a window cannot reproduce is the stretcher's STATE when the
//    window begins. The whole-file render arrives there with a history; a
//    window starts from a fresh `outputSeek`.
//
// ⚠️ **WHAT THAT STATE IS, MEASURED 2026-09-25.** signalsmith predicts each
// output frame's phase from the previous OUTPUT frame (and from neighbouring
// bins of the same frame), and only digital silence resets it (input energy
// below 1e-15 for two blocks, `signalsmith-stretch.h` `process`). At ratio 1
// with an untransposed history, "output phase = input phase" is preserved by
// every prediction, so a window converges on the whole-file render after about
// one output latency. On the user's 33 s take, with THIS window code and the
// default 0.12 s pre-roll, one edited note's span matched the whole-file render
// at −119 to −138 dB on all 7 test notes
// (`ClipSpanRenderTests.spanRenderMeasurementsOnTheUsersTake`; the earlier
// slice probe, `phaseMemoryProbe`, read −120 to −145 dB from 60 ms). A history
// that contains a TRANSPOSED note (or a ratio ≠ 1, whose phase advance runs
// ahead of the input's) leaves per-partial phase offsets that never decay in a
// take with no digital silence (the user's has none: one +200 c note's wake in
// the whole-file render is still +5.7 dB 5 s after it), and a window then
// differs from the whole-file render by −7 to +6 dB at any pre-roll up to 2 s
// (the probe: −3 to +6 dB up to 4 s). Same pitch, same level; different
// partial phases. Making those windows exact needs the
// stretcher's state at the window start (a snapshot of the whole-file render's
// stretcher), which the vendored library cannot copy today (its Accelerate FFT
// is non-copyable and its state private).

/// Where a stretch loop's input comes from.
enum StretchSource {
    /// The whole source, in memory: the whole-file render and every caller that
    /// predates I1-F1.
    case whole([[Float]])
    /// A window of a whole-file render, whose input is read on demand.
    case window(StretchWindow)

    var entry: StretchLoopTrace.Entry {
        switch self {
        case .whole: return .whole
        case .window: return .window
        }
    }

    /// `(channels, whole-source frames)`, validated. The `.whole` checks are
    /// the ones the whole-file entry always made, in the same order.
    func validatedShape() throws -> (channels: Int, frames: Int) {
        switch self {
        case .whole(let input):
            let channels = input.count
            guard channels >= 1 else {
                throw OfflineStretcherError.invalidInput("no channels")
            }
            let frames = input[0].count
            guard frames >= 1 else {
                throw OfflineStretcherError.invalidInput("empty input")
            }
            guard input.allSatisfy({ $0.count == frames }) else {
                throw OfflineStretcherError.invalidInput("channels differ in length")
            }
            return (channels, frames)
        case .window(let window):
            guard window.channels >= 1 else {
                throw OfflineStretcherError.invalidInput("no channels")
            }
            guard window.sourceFrames >= 1 else {
                throw OfflineStretcherError.invalidInput("empty input")
            }
            guard window.startOutputFrame >= 0, window.endOutputFrame > window.startOutputFrame else {
                throw OfflineStretcherError.invalidInput(
                    "empty window \(window.startOutputFrame)..<\(window.endOutputFrame)")
            }
            return (window.channels, window.sourceFrames)
        }
    }
}

/// One window of a whole-file stretch render, in the WHOLE-FILE render's
/// output frames.
///
/// Not `Sendable`: it carries the caller's reader, and is used synchronously
/// inside one render call on one thread (a detached task, never the render
/// thread).
struct StretchWindow {
    /// The source's channel count.
    let channels: Int
    /// The WHOLE source's length in frames. The schedule (output length, seek
    /// length, every block's input target) is derived from it exactly as the
    /// whole-file render derives it from its input's length.
    let sourceFrames: Int
    /// The first whole-file output frame the caller needs. The loop starts at
    /// its block boundary at or before this frame.
    let startOutputFrame: Int
    /// One past the last whole-file output frame the caller needs; clamped to
    /// the whole-file output length.
    let endOutputFrame: Int
    /// Reads source frames `range` (always inside `0..<sourceFrames`), one
    /// array per channel, each exactly `range.count` long. Called once.
    let readSource: (Range<Int>) throws -> [[Float]]
}

/// What a loop produced: planar output for whole-file output frames
/// `firstOutputFrame ..< firstOutputFrame + planar[0].count`.
struct StretchWindowOutput {
    var planar: [[Float]]
    let firstOutputFrame: Int
}

/// **THE SCHEDULE OF A WHOLE-FILE STRETCH RENDER: every index both stretch
/// loops use, derived in one place.** Both entries (whole and window) and both
/// loops (constant and curve) read it, so a window cannot run on a schedule of
/// its own. The expressions are the ones the loops used inline before I1-F1,
/// verbatim (`wholeFileGoldenCapture` diffs the whole-file bytes across the
/// move).
struct StretchSchedule: Equatable, Sendable {
    let sourceFrames: Int
    /// `round(sourceFrames × ratio)`: the whole-file render's length.
    let outputFrames: Int
    /// `1 / ratio`.
    let playbackRate: Double
    /// Upstream `outputSeekLength(1/ratio)`, truncation and all.
    let seekLength: Int
    /// The input the whole-file render pads to: at least `seekLength`.
    let totalIn: Int
    /// Input consumed by the chunked middle.
    let processIn: Int
    /// Output the seek pre-roll accounts for (upstream truncation).
    let seekOut: Int
    /// Output produced by the chunked middle; the flush produces the rest.
    let processOut: Int
    /// The chunked middle's block: `OfflineStretcher.blockFrames` for the
    /// constant loop, the stretcher's own hop for the curve loop.
    let blockFrames: Int

    init(sourceFrames: Int, ratio: Double, inputLatency: Int, outputLatency: Int,
         blockFrames: Int) {
        self.sourceFrames = sourceFrames
        outputFrames = Int((Double(sourceFrames) * ratio).rounded())
        let playbackRate = 1.0 / ratio
        self.playbackRate = playbackRate
        let seekLength = Int(Double(inputLatency) + playbackRate * Double(outputLatency))
        self.seekLength = seekLength
        totalIn = max(sourceFrames, seekLength)
        processIn = totalIn - seekLength
        seekOut = Int(Double(seekLength) / playbackRate)  // upstream truncation
        processOut = max(0, outputFrames - seekOut)
        self.blockFrames = blockFrames
    }

    /// The input consumed once the chunked middle has produced output up to
    /// `outputFrame` (a block boundary): the loop's `inTarget`, verbatim.
    func inputTarget(afterOutputFrame outputFrame: Int) -> Int {
        Int((Double(outputFrame) * Double(processIn) / Double(processOut)).rounded())
    }

    /// The part of the schedule a source runs: all of it for `.whole`, one
    /// window for `.window`.
    func span(for source: StretchSource) -> StretchSpan {
        switch source {
        case .whole:
            return span(startOutputFrame: 0, endOutputFrame: outputFrames)
        case .window(let window):
            return span(startOutputFrame: window.startOutputFrame,
                        endOutputFrame: window.endOutputFrame)
        }
    }

    /// The loop's plan for whole-file output frames `start ..< end`. For the
    /// whole file (`0 ..< outputFrames`) it is exactly the plan the loops ran
    /// before windows existed: every block, then the flush, over input
    /// `0 ..< totalIn`.
    func span(startOutputFrame requestedStart: Int, endOutputFrame requestedEnd: Int) -> StretchSpan {
        let end = min(max(1, requestedEnd), outputFrames)
        // Start on a block boundary of the chunked middle (the whole-file
        // render's own), never inside the flush tail: a span that begins there
        // starts at the last block and runs through the flush.
        var start = (max(0, min(requestedStart, end - 1)) / blockFrames) * blockFrames
        if processOut > 0 {
            start = min(start, ((processOut - 1) / blockFrames) * blockFrames)
        } else {
            start = 0
        }
        let loopEnd: Int
        if processOut == 0 {
            loopEnd = 0
        } else if end >= processOut {
            loopEnd = processOut
        } else {
            let blocks = (end - start + blockFrames - 1) / blockFrames
            loopEnd = min(processOut, start + blocks * blockFrames)
        }
        let flushes = end > processOut
        let inputStart = start == 0 ? 0 : inputTarget(afterOutputFrame: start)
        let inputEnd: Int
        if loopEnd >= processOut {
            // The whole chunked middle to its end: the whole-file render's own
            // input length (never less than the schedule's last target).
            inputEnd = max(totalIn,
                           seekLength + (processOut > 0 ? inputTarget(afterOutputFrame: processOut) : 0))
        } else {
            inputEnd = seekLength + inputTarget(afterOutputFrame: loopEnd)
        }
        return StretchSpan(startOutputFrame: start, endOutputFrame: end,
                           loopEndOutputFrame: loopEnd, flushes: flushes,
                           bufferEndOutputFrame: flushes ? outputFrames : loopEnd,
                           inputStart: inputStart, inputEnd: inputEnd)
    }
}

/// One run of the loop over a part of the schedule.
struct StretchSpan: Equatable, Sendable {
    /// The first whole-file output frame produced: a block boundary.
    let startOutputFrame: Int
    /// One past the last whole-file output frame returned.
    let endOutputFrame: Int
    /// Where the chunked middle stops: a block boundary, or `processOut`.
    let loopEndOutputFrame: Int
    /// Whether the span reaches past the chunked middle, so the flush runs.
    let flushes: Bool
    /// One past the last output frame the loop writes.
    let bufferEndOutputFrame: Int
    /// The first source frame the loop reads (the seek's first frame).
    let inputStart: Int
    /// One past the last source frame the loop reads; frames past the source's
    /// end read as silence, exactly as the whole-file render pads them.
    let inputEnd: Int
}

/// The two loops' working buffers: input `span.inputStart ..< span.inputEnd`
/// (silence past the source's end) and output `span.startOutputFrame ..<
/// span.bufferEndOutputFrame`. Manual allocation gives the C shim stable base
/// pointers. Offline only; it allocates freely.
struct StretchBuffers {
    private let inputStart: Int
    private let outputStart: Int
    private let inChans: [UnsafeMutableBufferPointer<Float>]
    private let outChans: [UnsafeMutableBufferPointer<Float>]
    private let inBase: [UnsafePointer<Float>]
    private let outBase: [UnsafeMutablePointer<Float>]

    init(source: StretchSource, channels: Int, schedule: StretchSchedule,
         span: StretchSpan) throws {
        inputStart = span.inputStart
        outputStart = span.startOutputFrame
        let inCount = span.inputEnd - span.inputStart
        let outCount = span.bufferEndOutputFrame - span.startOutputFrame
        guard inCount >= 1, outCount >= 1 else {
            throw OfflineStretcherError.invalidInput(
                "empty loop span: input \(inCount), output \(outCount)")
        }
        // The source frames the span reads; the rest is silence.
        let readEnd = min(schedule.sourceFrames, span.inputEnd)
        let readCount = max(0, readEnd - span.inputStart)
        let provided: [[Float]]
        let providedOffset: Int
        switch source {
        case .whole(let input):
            provided = input
            providedOffset = span.inputStart
        case .window(let window):
            provided = readCount > 0
                ? try window.readSource(span.inputStart..<readEnd)
                : [[Float]](repeating: [], count: channels)
            providedOffset = 0
            guard provided.count == channels,
                  provided.allSatisfy({ $0.count == readCount }) else {
                throw OfflineStretcherError.invalidInput(
                    "window read returned the wrong shape for \(readCount) frames")
            }
        }
        var ins: [UnsafeMutableBufferPointer<Float>] = []
        var outs: [UnsafeMutableBufferPointer<Float>] = []
        for channel in 0..<channels {
            let inBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: inCount)
            inBuf.initialize(repeating: 0)
            if readCount > 0 {
                provided[channel].withUnsafeBufferPointer { src in
                    inBuf.baseAddress!.update(from: src.baseAddress! + providedOffset,
                                              count: readCount)
                }
            }
            ins.append(inBuf)
            let outBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: outCount)
            outBuf.initialize(repeating: 0)
            outs.append(outBuf)
        }
        inChans = ins
        outChans = outs
        inBase = ins.map { UnsafePointer($0.baseAddress!) }
        outBase = outs.map { $0.baseAddress! }
    }

    func deallocate() {
        for buffer in inChans { buffer.deallocate() }
        for buffer in outChans { buffer.deallocate() }
    }

    /// Per-channel input pointers at SOURCE frame `sourceFrame`.
    func withInPointers<R>(atSourceFrame sourceFrame: Int,
                           _ body: (UnsafePointer<UnsafePointer<Float>>) -> R) -> R {
        let offset = sourceFrame - inputStart
        let shifted = inBase.map { $0 + offset }
        return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// Per-channel output pointers at whole-file OUTPUT frame `outputFrame`.
    func withOutPointers<R>(atOutputFrame outputFrame: Int,
                            _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> R) -> R {
        let offset = outputFrame - outputStart
        let shifted = outBase.map { $0 + offset }
        return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// Whole-file output frames `span.startOutputFrame ..< span.endOutputFrame`.
    func output(_ span: StretchSpan) -> StretchWindowOutput {
        let count = span.endOutputFrame - span.startOutputFrame
        return StretchWindowOutput(
            planar: outBase.map { Array(UnsafeBufferPointer(start: $0, count: count)) },
            firstOutputFrame: span.startOutputFrame)
    }
}

/// TEST SPY (I1-F1): which stretch loop ran, and through which entry.
/// Task-local, so parallel tests never see each other's renders, and never
/// bound in production (one optional read per render call, off the render
/// thread). It is how a test proves the span render runs THE loop rather than
/// a copy of it: a copied loop never records here.
final class StretchLoopTrace: @unchecked Sendable {
    enum Loop: String, Sendable { case constant, curve }
    enum Entry: String, Sendable { case whole, window }

    @TaskLocal static var current: StretchLoopTrace?

    private let lock = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ loop: Loop, _ entry: Entry) {
        lock.withLock { $0.append("\(loop.rawValue)/\(entry.rawValue)") }
    }

    /// Every loop run seen, in order, as `"curve/window"` and the like.
    var records: [String] { lock.withLock { $0 } }
}
