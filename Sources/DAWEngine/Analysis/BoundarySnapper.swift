import AVFAudio
import DAWCore
import Foundation

/// Errors from boundary snapping (m32-b2).
public enum BoundarySnapperError: Error, Equatable, Sendable {
    /// The source file could not be opened, or holds no frames.
    case unreadable(String)
}

/// m32-b2 — resolves a list of candidate slice boundaries against a source
/// file's own PCM, returning `SliceBoundaryGeometry`.
///
/// ## What the snap actually does, named honestly
///
/// For each candidate it searches ±`snapWindowSeconds` and picks the frame `k`
/// that minimises `max_c |x_c[k]|`, tie-broken toward the candidate.
///
/// On a **mono** file that IS the zero crossing. On a **stereo** file a
/// simultaneous zero crossing in both channels usually does not exist inside a
/// 3 ms window, and snapping on the channel SUM can land on a point where L
/// and R are large and opposite — a worse click than not snapping at all.
/// Minimising the per-channel maximum directly minimises the discontinuity in
/// BOTH channels, which is what "no click" physically means.
/// `residualAmplitude` reports what was actually achieved, so a caller can see
/// whether a real crossing was found or merely the quietest available point.
/// That is why this is a "boundary snap" and not a "zero-crossing snap".
///
/// ## Two invariants it enforces rather than assumes
///
/// 1. **Strictly increasing output.** The caller is expected to clamp
///    `snapWindowSeconds ≤ minSliceSeconds / 2` so boundaries cannot reorder,
///    but two candidates exactly `minSlice` apart can still MEET at the
///    limit. Each search range is floored at `previous + 1`, so the result is
///    strictly increasing by construction — a collapsed pair would otherwise
///    produce a zero-length zone that the model's `endFrame` clamp would then
///    silently widen by one frame.
/// 2. **Clamped to the file.** No search below frame 0 or at/above
///    `frameCount - 1`.
///
/// ## Reading
///
/// Frames are streamed in bounded chunks and only the small search window
/// around each candidate is retained, so chopping a 4-minute rip costs
/// kilobytes rather than the ~80 MB a whole-file read would hold.
///
/// ⚠️ The chunk loop reads until `framePosition` stops advancing rather than
/// trusting one `read(into:)` — a single read SHORT-READS mono files whose
/// frame count is not a multiple of 1024 (m32-h, silent data loss). The loop
/// shape here is the same one `TransientAnalyzer.readMono` already uses, and
/// it is immune.
///
/// REAL-TIME SAFETY: never referenced from the render path. It allocates and
/// does file I/O freely because it only ever runs inside a detached task (see
/// `AudioEngine.resolveSliceBoundaries`).
public enum BoundarySnapper {

    /// Chunk size for the streaming read (frames). Comfortably above the
    /// 1024-frame granularity of the m32-h short read, and large enough that
    /// a typical ±3 ms search window never straddles more than two chunks.
    static let readChunkFrames: AVAudioFrameCount = 32_768

    /// Two candidate frames whose peak magnitudes differ by less than this are
    /// treated as EQUALLY quiet, and the one nearer the detected onset wins.
    /// 1e-6 is about −120 dBFS: inaudible as a discontinuity, while the timing
    /// it buys back (up to a whole snap window) is not.
    static let tieToleranceAmplitude = 1e-6

    public static func resolve(fileAt url: URL,
                               boundarySeconds: [Double],
                               snapWindowSeconds: Double) throws -> SliceBoundaryGeometry {
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw BoundarySnapperError.unreadable(
                "\(url.path): \(error.localizedDescription)")
        }
        let format = reader.processingFormat          // deinterleaved float32
        let channelCount = Int(format.channelCount)
        let frameCount = Int(reader.length)
        let sampleRate = format.sampleRate
        guard frameCount > 0, channelCount > 0, sampleRate > 0 else {
            throw BoundarySnapperError.unreadable("empty source \(url.path)")
        }

        // No candidates: the rate and length are still real answers, and a
        // caller asking only "how long is this file, in its own units?" gets
        // them without a second seam.
        guard !boundarySeconds.isEmpty else {
            return SliceBoundaryGeometry(sampleRate: sampleRate, frameCount: frameCount,
                                         boundaryFrames: [], snapOffsetFrames: [],
                                         residualAmplitude: [])
        }

        let lastFrame = frameCount - 1
        let halfWindow = max(0, Int((max(0, snapWindowSeconds) * sampleRate).rounded(.down)))

        // Candidate frames, and each one's inclusive search range. Ranges are
        // floored at `previous candidate range low + 1` only AFTER a choice is
        // made (below) — here they are just the raw ±window clamped to the file.
        var candidates: [Int] = []
        var searchLow: [Int] = []
        var searchHigh: [Int] = []
        candidates.reserveCapacity(boundarySeconds.count)
        for seconds in boundarySeconds {
            let k = min(max(Int((seconds * sampleRate).rounded()), 0), lastFrame)
            candidates.append(k)
            searchLow.append(max(0, k - halfWindow))
            searchHigh.append(min(lastFrame, k + halfWindow))
        }

        // Best (value, frame) per candidate, filled by the streaming pass.
        var bestValue = [Double](repeating: .infinity, count: candidates.count)
        var bestFrame = candidates

        guard let chunk = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: readChunkFrames) else {
            throw BoundarySnapperError.unreadable("buffer allocation failed")
        }

        // The lowest frame any candidate still needs, so the scan can stop
        // once every search window is behind the read head.
        let highestNeeded = searchHigh.max() ?? 0
        var chunkStart = 0
        // ⚠️ m32-h: loop until the reader stops advancing. A single
        // `read(into:)` silently truncates mono files to a multiple of 1024.
        while reader.framePosition < reader.length, chunkStart <= highestNeeded {
            let positionBefore = reader.framePosition
            try reader.read(into: chunk)
            let frames = Int(chunk.frameLength)
            guard frames > 0, reader.framePosition > positionBefore,
                  let data = chunk.floatChannelData else { break }
            let chunkEnd = chunkStart + frames - 1

            for c in candidates.indices {
                let lo = max(searchLow[c], chunkStart)
                let hi = min(searchHigh[c], chunkEnd)
                guard lo <= hi else { continue }
                let candidate = candidates[c]
                for frame in lo...hi {
                    let offset = frame - chunkStart
                    var peak = 0.0
                    for channel in 0..<channelCount {
                        peak = max(peak, Double(abs(data[channel][offset])))
                    }
                    // Tie-break toward the candidate, so an equally quiet frame
                    // nearer the detected onset preserves the timing.
                    //
                    // ⚠️ The tie test is a TOLERANCE, not `==`. A 441 Hz sine
                    // at 44.1 kHz crosses zero exactly on frames 0/50/100/…,
                    // and five of those can sit inside one 3 ms window; with a
                    // bit-exact comparison the winner is decided by which
                    // `sin(kπ)` rounded closest to zero, which moved a boundary
                    // 125 frames when 25 was available. Below −120 dBFS the
                    // difference between two candidates is not audible as a
                    // click, but 2.8 ms of timing is audible as flam — so
                    // treat them as tied and let timing decide.
                    let nearer = abs(frame - candidate) < abs(bestFrame[c] - candidate)
                    if peak < bestValue[c] - tieToleranceAmplitude
                        || (peak <= bestValue[c] + tieToleranceAmplitude && nearer) {
                        bestValue[c] = peak
                        bestFrame[c] = frame
                    }
                }
            }
            chunkStart += frames
        }

        // Invariant 1: strictly increasing. Re-check in order and push any
        // collision forward; `bestValue` at a pushed frame is no longer the
        // minimum, so re-measure the residual there rather than reporting a
        // number from a frame we did not choose.
        var boundaryFrames: [Int] = []
        boundaryFrames.reserveCapacity(bestFrame.count)
        var previous = -1
        var needsResidualRefresh: [Int] = []
        for c in bestFrame.indices {
            var frame = bestFrame[c]
            if frame <= previous {
                frame = min(previous + 1, lastFrame)
                needsResidualRefresh.append(c)
            }
            boundaryFrames.append(frame)
            previous = frame
        }
        if !needsResidualRefresh.isEmpty {
            try refreshResiduals(reader: reader, format: format, channelCount: channelCount,
                                 frames: boundaryFrames, indices: needsResidualRefresh,
                                 into: &bestValue)
        }

        var snapOffsetFrames: [Int] = []
        var residualAmplitude: [Double] = []
        snapOffsetFrames.reserveCapacity(boundaryFrames.count)
        residualAmplitude.reserveCapacity(boundaryFrames.count)
        for c in boundaryFrames.indices {
            snapOffsetFrames.append(boundaryFrames[c] - candidates[c])
            // `.infinity` can only survive if a candidate's window fell
            // entirely past the readable end — report 0 rather than a value
            // that would encode as `null`/`inf` on the wire.
            residualAmplitude.append(bestValue[c].isFinite ? bestValue[c] : 0)
        }

        return SliceBoundaryGeometry(sampleRate: sampleRate, frameCount: frameCount,
                                     boundaryFrames: boundaryFrames,
                                     snapOffsetFrames: snapOffsetFrames,
                                     residualAmplitude: residualAmplitude)
    }

    /// Re-measures `max_c |x_c[k]|` at specific frames after the
    /// strictly-increasing fix-up moved them. Rare (it needs two candidates to
    /// land on the same frame), so a small seek-and-read per frame is the
    /// right cost — and it keeps `residualAmplitude` an honest measurement of
    /// the frame actually chosen instead of the one originally found.
    private static func refreshResiduals(reader: AVAudioFile, format: AVAudioFormat,
                                         channelCount: Int, frames: [Int],
                                         indices: [Int], into values: inout [Double]) throws {
        guard let one = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return }
        for index in indices {
            let frame = frames[index]
            guard frame >= 0, frame < Int(reader.length) else { continue }
            reader.framePosition = AVAudioFramePosition(frame)
            try reader.read(into: one, frameCount: 1)
            guard one.frameLength >= 1, let data = one.floatChannelData else { continue }
            var peak = 0.0
            for channel in 0..<channelCount {
                peak = max(peak, Double(abs(data[channel][0])))
            }
            values[index] = peak
        }
    }
}
