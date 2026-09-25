import AVFAudio
import DAWCore
import Foundation
import os

// I1: HEAR THE NOTE WHILE EDITING IT. THE AUDITION VOICE'S BUFFER.
//
// Design: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §4 and §11
// ("Render thread"). The engine plays one span of one clip, once, from the file
// playback resolves for that clip. This file builds the buffer it plays:
// read the span, convert it to the graph's format, fade both ends, apply the
// level, guard against NaN and denormals.
//
// ⛔ ALL OF IT RUNS OFF THE RENDER THREAD, in a detached task. File I/O,
// allocation, the sample-rate converter and the fades are heap and syscall
// traffic; none of it may ever reach an audio callback. The render thread only
// ever sees the finished buffer, through a stock `AVAudioPlayerNode`.
//
// ⛔ NO PITCH DSP HERE. The pitch the user hears was put there by the OFFLINE
// render, the one playback plays. This only cuts and fades.
//
// I1-F1 adds the SPAN RENDER source: instead of reading the whole-file render,
// the span is rendered on its own through the ONE render loop
// (`StretchRenderCache.renderSpan`), still off the render thread, in the same
// detached task, and then shaped here exactly as a file read is. The pitch is
// still put there by the offline render loop, never by anything live.

enum ClipSpanAuditionError: Error, Equatable {
    /// Nothing of the span lies inside the file.
    case emptySpan
    case allocationFailed
    case conversionFailed(String)
    /// A newer request, a stop, a transport start or a rebuild cancelled the
    /// read before it finished (RT review H4).
    case cancelled
}

/// One audition's recipe, built on the main actor and read off it.
struct ClipSpanAuditionRequest: Sendable, Equatable {
    /// The file playback resolves for the clip: its render, or its source when
    /// the clip does not render.
    let fileURL: URL
    /// The output-duration multiplier the file was rendered at: the clip's
    /// stretch ratio for a render, exactly 1 for a source file.
    let ratio: Double
    /// The SOURCE-second span to play.
    let startSourceSeconds: Double
    let endSourceSeconds: Double
    /// Linear level: the clip's gain × the track fader.
    let gain: Double
    /// Each end's fade (`ClipNoteAuditionPolicy.fadeSeconds`).
    let fadeSeconds: Double
}

/// I1-F1: one SPAN RENDER audition's recipe, built on the main actor and read
/// off it: render `sourceURL`'s span with `params` (the clip's stored edits or
/// a draft) through `StretchRenderCache.renderSpan`, then shape it like a read.
struct ClipSpanRenderRequest: Sendable, Equatable {
    /// The clip's SOURCE file (the render loop's input, and the contour's key).
    let sourceURL: URL
    /// The clip's ratio, transpose and formant flag, with the stored or draft
    /// edit set. Never identity: an identity plan reads the source instead.
    let params: StretchRenderCache.Params
    /// The SOURCE-second span to play.
    let startSourceSeconds: Double
    let endSourceSeconds: Double
    /// Linear level: the clip's gain × the track fader.
    let gain: Double
    /// Each end's fade (`ClipNoteAuditionPolicy.fadeSeconds`).
    let fadeSeconds: Double
}

/// What one audition job does off the main actor: read the file playback
/// plays, or render the span through the one render loop (I1-F1).
enum ClipAuditionWork: Sendable, Equatable {
    case file(ClipSpanAuditionRequest)
    case render(ClipSpanRenderRequest)
}

/// RT review H4: the flag an audition job's read or render polls between
/// chunks and blocks. Set by the main actor when a newer request, a stop, a
/// transport start or a rebuild cancels the job; read by the job's detached
/// task. The lock is taken only by those two, never by the render thread.
final class ClipAuditionCancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    func cancel() { flag.withLock { $0 = true } }
    var isCancelled: Bool { flag.withLock { $0 } }
}

/// TEST LEDGER (RT review H4): how many audition jobs STARTED their work, and
/// how each one ended: FINISHED (a buffer, or a failure of its own) or ABORTED
/// by cancellation. A superseded job that ran to the end would count as
/// finished, so "the first of two back-to-back requests aborted" is a count.
final class ClipAuditionWorkLedger: Sendable {
    struct Counts: Sendable, Equatable {
        var started = 0
        var finished = 0
        var aborted = 0
    }
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    var snapshot: Counts { counts.withLock { $0 } }
    func started() { counts.withLock { $0.started += 1 } }
    func ended(aborted: Bool) {
        counts.withLock { aborted ? ($0.aborted += 1) : ($0.finished += 1) }
    }
}

/// Hands a finished buffer from the detached read back to the main actor.
///
/// `@unchecked` because `AVAudioPCMBuffer` is not `Sendable`. The safety is
/// OWNERSHIP TRANSFER, not sharing: the detached task creates the buffer, puts
/// it in this box as its last act and keeps no reference, so after the hop the
/// main actor is its only owner (and then the player node, which retains it).
struct ClipSpanAuditionBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// I1-F2: a span render that played the CONSTANT-OFFSET curve because the
    /// contour was unavailable says why (`StretchRenderCache.SpanRender`); nil
    /// for a file read and for a render that got its contour.
    var contourFallbackReason: String? = nil
}

enum ClipSpanAuditionReader {

    /// The FILE frames `[start, end)` a request plays, through
    /// `StretchCurvePlan` and nothing else (the one output↔source home), then
    /// clamped to the file.
    static func frameRange(for request: ClipSpanAuditionRequest, fileLength: Int,
                           fileSampleRate: Double) -> Range<Int> {
        let start = StretchCurvePlan.outputFrame(
            forSourceSecond: request.startSourceSeconds, ratio: request.ratio,
            sampleRate: fileSampleRate)
        let end = StretchCurvePlan.outputFrame(
            forSourceSecond: request.endSourceSeconds, ratio: request.ratio,
            sampleRate: fileSampleRate)
        let lower = min(max(0, start), fileLength)
        let upper = min(max(lower, end), fileLength)
        return lower..<upper
    }

    /// The buffer the audition player schedules, in `outputFormat` (the graph's
    /// standard format: deinterleaved Float32 at the graph rate). BLOCKING:
    /// call it from a detached task only. `isCancelled` is polled between read
    /// chunks and before and after the sample-rate converter (RT review H4);
    /// a cancelled read throws `ClipSpanAuditionError.cancelled`.
    static func makeBuffer(_ request: ClipSpanAuditionRequest, outputFormat: AVAudioFormat,
                           isCancelled: () -> Bool = { false }) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: request.fileURL)
        let fileFormat = file.processingFormat
        let range = frameRange(for: request, fileLength: Int(file.length),
                               fileSampleRate: fileFormat.sampleRate)
        guard !range.isEmpty else { throw ClipSpanAuditionError.emptySpan }

        // 1. Read the span, looping: `AVAudioFile.read(into:)` can return
        //    short (measured elsewhere in this codebase).
        let channelCount = Int(fileFormat.channelCount)
        var planar = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount { planar[channel].reserveCapacity(range.count) }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 16_384) else {
            throw ClipSpanAuditionError.allocationFailed
        }
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        var remaining = range.count
        while remaining > 0 {
            if isCancelled() { throw ClipSpanAuditionError.cancelled }
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(remaining, 16_384)))
            let got = Int(chunk.frameLength)
            guard got > 0, let data = chunk.floatChannelData else { break }
            for channel in 0..<channelCount {
                planar[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel],
                                                                       count: got))
            }
            remaining -= got
        }
        return try shape(planar, sampleRate: fileFormat.sampleRate, gain: request.gain,
                         fadeSeconds: request.fadeSeconds, outputFormat: outputFormat,
                         isCancelled: isCancelled)
    }

    /// I1-F1: the buffer for a SPAN RENDER audition. The span is rendered
    /// through the one render loop (`StretchRenderCache.renderSpan`: the same
    /// curve, mask, stretcher configuration and schedule as the whole-file
    /// render, from the same source frames), then shaped exactly as a file
    /// read is (`shape`). BLOCKING and allocating: a detached task only.
    /// Cancellation is polled per render block and per read chunk; a cancelled
    /// render throws `OfflineStretcherError.cancelled` or
    /// `ClipSpanAuditionError.cancelled`. I1-F2: returns the render's contour
    /// fallback reason with the buffer (`SpanRender.contourFallbackReason`),
    /// so the engine can say what it played.
    static func makeBuffer(_ request: ClipSpanRenderRequest, outputFormat: AVAudioFormat,
                           renderCacheDirectory: URL, detector: PitchContourCache.Detector,
                           isCancelled: () -> Bool)
        throws -> (buffer: AVAudioPCMBuffer, contourFallbackReason: String?) {
        let rendered = try StretchRenderCache.renderSpan(
            source: request.sourceURL, params: request.params,
            startSourceSeconds: request.startSourceSeconds,
            endSourceSeconds: request.endSourceSeconds,
            renderCacheDirectory: renderCacheDirectory, detector: detector,
            isCancelled: isCancelled)
        let buffer = try shape(rendered.planar, sampleRate: rendered.sampleRate, gain: request.gain,
                               fadeSeconds: request.fadeSeconds, outputFormat: outputFormat,
                               isCancelled: isCancelled)
        return (buffer, rendered.contourFallbackReason)
    }

    /// Planar samples at `sampleRate` → the voice's buffer: converted to the
    /// graph rate, mapped onto the output channels, faded at both ends and
    /// levelled, NaN- and denormal-safe. Shared by the file read and the span
    /// render, so the two sources can only differ in the samples they hand in.
    static func shape(_ input: [[Float]], sampleRate: Double, gain requestGain: Double,
                      fadeSeconds: Double, outputFormat: AVAudioFormat,
                      isCancelled: () -> Bool) throws -> AVAudioPCMBuffer {
        guard let firstChannel = input.first, !firstChannel.isEmpty else {
            throw ClipSpanAuditionError.emptySpan
        }
        var planar = input

        // 2. Convert to the graph rate when the file is at another one. The
        //    player assumes a buffer is already at its output rate.
        if sampleRate != outputFormat.sampleRate {
            if isCancelled() { throw ClipSpanAuditionError.cancelled }
            planar = try resample(planar, from: sampleRate, to: outputFormat.sampleRate)
        }
        if isCancelled() { throw ClipSpanAuditionError.cancelled }

        // 3. Map channels onto the output: mono feeds every output channel at
        //    unity, which is what the strip's own mixer does with a mono clip
        //    (MEASURED 2026-09-24: AVAudioMixerNode, mono 0.5 in → L 0.5, R 0.5).
        let frames = planar.first?.count ?? 0
        guard frames > 0 else { throw ClipSpanAuditionError.emptySpan }
        let outChannels = Int(outputFormat.channelCount)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let outData = out.floatChannelData else {
            throw ClipSpanAuditionError.allocationFailed
        }
        let fadeFrames = min(frames / 2,
                             max(0, Int((fadeSeconds * outputFormat.sampleRate).rounded())))
        let gain = requestGain.isFinite ? Float(max(0, requestGain)) : 0
        for channel in 0..<outChannels {
            let source = planar[min(channel, planar.count - 1)]
            let target = outData[channel]
            for frame in 0..<frames {
                target[frame] = shaped(source[frame], frame: frame, frames: frames,
                                       fadeFrames: fadeFrames, gain: gain)
            }
        }
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }

    /// One output sample: the fade window × the level, NaN- and denormal-safe.
    ///
    /// The fades are raised-cosine and reach exactly 0 at the span's first and
    /// last sample, so a span cut from the middle of a sung phrase starts and
    /// ends in silence. A non-finite input becomes 0; a product below
    /// `Float.leastNormalMagnitude` is flushed to +0 (the level mask's guard,
    /// `StretchCurvePlan.applyLevelMask`).
    static func shaped(_ sample: Float, frame: Int, frames: Int, fadeFrames: Int,
                       gain: Float) -> Float {
        guard sample.isFinite else { return 0 }
        var window: Float = 1
        if fadeFrames > 0 {
            let fromEnd = frames - 1 - frame
            let edge = min(frame, fromEnd)
            if edge < fadeFrames {
                window = Float(0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fadeFrames)))
            }
        }
        let value = sample * window * gain
        guard value.isFinite, abs(value) >= Float.leastNormalMagnitude else { return 0 }
        return value
    }

    /// Sample-rate conversion through `AVAudioConverter`, channel count kept.
    static func resample(_ planar: [[Float]], from inputRate: Double,
                         to outputRate: Double) throws -> [[Float]] {
        let channels = AVAudioChannelCount(planar.count)
        let frames = planar.first?.count ?? 0
        guard frames > 0,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate,
                                           channels: channels),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate,
                                            channels: channels),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat,
                                           frameCapacity: AVAudioFrameCount(frames)),
              let inData = input.floatChannelData else {
            throw ClipSpanAuditionError.conversionFailed("could not set up \(inputRate) → \(outputRate) Hz")
        }
        for (channel, samples) in planar.enumerated() {
            samples.withUnsafeBufferPointer { src in
                inData[channel].update(from: src.baseAddress!, count: frames)
            }
        }
        input.frameLength = AVAudioFrameCount(frames)
        let capacity = AVAudioFrameCount(
            (Double(frames) * outputRate / inputRate).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity),
              let outData = output.floatChannelData else {
            throw ClipSpanAuditionError.allocationFailed
        }
        let feeder = SingleShotInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            feeder.next(outStatus)
        }
        guard status != .error, conversionError == nil else {
            throw ClipSpanAuditionError.conversionFailed(
                conversionError?.localizedDescription ?? "status \(status.rawValue)")
        }
        let produced = Int(output.frameLength)
        return (0..<Int(channels)).map { channel in
            Array(UnsafeBufferPointer(start: outData[channel], count: produced))
        }
    }
}

/// Hands one input buffer to `AVAudioConverter`, then reports end of stream.
/// `@unchecked` for the reason `PitchTracker`'s twin gives: the converter's
/// input block is typed `@Sendable`, but `convert(to:error:withInputFrom:)`
/// calls it SYNCHRONOUSLY on the calling thread; an instance is created inside
/// `resample`, handed to one converter, and never outlives that call.
private final class SingleShotInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
