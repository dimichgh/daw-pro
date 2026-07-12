import AVFAudio
import DAWCore
import Foundation

/// Schedule-time fade bake for audio clips (M5 i-b). Pure window math plus an
/// in-place envelope multiply — ALL of it runs on the main actor at schedule
/// time, never on the render thread (the settled i-b property: zero new
/// render-thread code).
///
/// The envelope authority is `Clip.envelopeGain(atBeat:)` — the single domain
/// evaluator shared by UI drawing, tests, and this bake. The bake applies only
/// the NORMALIZED fade shape (gainDb is zeroed before evaluation): the static
/// clip gain rides `AVAudioPlayerNode.volume` downstream of the baked buffers,
/// so gain edits never force a re-bake.
///
/// MIDI clips never reach this code: gain/fades are audio-clip-only in v0
/// (instrument strips have no per-clip player to bake onto).
enum ClipFadeBake {
    /// The three-piece split of one clip's scheduled region, in CLIP-RELATIVE
    /// file-rate frames (frame 0 ≡ the clip's head, independent of
    /// `startOffsetSeconds` — that offset shifts the FILE read position, not
    /// the envelope timeline).
    ///
    /// Contiguity is guaranteed by construction:
    /// `segmentStart <= fadeInEnd <= fadeOutStart <= segmentEnd`, so
    /// `fadeInFrames + middleFrames + fadeOutFrames == segmentFrameCount`
    /// exactly — the three pieces partition the scheduled region with no gap
    /// and no overlap, whatever the playhead or fade lengths.
    struct PiecePlan: Equatable {
        /// First scheduled frame (the playhead's clip-relative position; > 0
        /// when scheduling starts mid-clip).
        let segmentStart: Int64
        /// End of the baked fade-in piece == start of the streamed middle.
        let fadeInEnd: Int64
        /// Start of the baked fade-out piece == end of the streamed middle.
        let fadeOutStart: Int64
        /// One past the last scheduled frame.
        let segmentEnd: Int64

        var fadeInFrames: Int64 { fadeInEnd - segmentStart }
        var middleFrames: Int64 { fadeOutStart - fadeInEnd }
        var fadeOutFrames: Int64 { segmentEnd - fadeOutStart }
        /// False ⇒ the caller takes the pre-i-b single-`scheduleSegment` path
        /// byte for byte (the null-test guarantee).
        var needsBake: Bool { fadeInFrames > 0 || fadeOutFrames > 0 }
    }

    /// Splits the scheduled region `[segmentStart, segmentStart +
    /// segmentFrameCount)` (clip-relative file-rate frames) into fade-in /
    /// middle / fade-out pieces. Fade windows are computed ONCE from the
    /// clip's beats (each length clamped to the clip length, matching the
    /// domain evaluator's use-time clamp), then intersected with the region —
    /// so scheduling from a playhead INSIDE a fade window yields a partial
    /// fade piece whose envelope starts at the correct analytic value.
    ///
    /// Beats→frames (m12-c, design rows 40–41): a clip whose whole span sits
    /// in ONE tempo segment uses the constant `framesPerBeat` fast path —
    /// `TempoMap.framesPerBeat(atBeat:sampleRate:)` keeps the legacy
    /// `fileRate * 60.0 / bpm` op order verbatim, so trivial maps stay
    /// BIT-IDENTICAL to the scalar era (the Phase-A byte-gate contract,
    /// re-proven by the m12-c null-case gate). A clip crossing a boundary
    /// takes the piecewise path: every window edge is the map integral from
    /// the clip's start beat (`seconds(from:to:) · fileRate`, `.rounded()`),
    /// the SAME frame convention `scheduleAll` uses for the region itself, so
    /// fades warp in wall time exactly with the audio they shape.
    ///
    /// Overlapping fades (fadeIn + fadeOut > length, only constructible
    /// outside the store) collapse the middle to zero and both baked pieces
    /// still evaluate the full domain envelope per frame, so the multiplied
    /// overlap region renders exactly what `envelopeGain` defines.
    static func piecePlan(
        clip: Clip, tempoMap: TempoMap, fileRate: Double,
        segmentStart: Int64, segmentFrameCount: Int64
    ) -> PiecePlan {
        let inLenBeats = min(max(0, clip.fadeInBeats), clip.lengthBeats)
        let outLenBeats = min(max(0, clip.fadeOutBeats), clip.lengthBeats)
        let clipLengthFrames: Int64
        let fadeInFrames: Int64
        let fadeOutFrames: Int64
        if tempoMap.isConstant(from: clip.startBeat,
                               to: clip.startBeat + clip.lengthBeats) {
            // Constant-tempo fast path — the pre-m12-c arithmetic verbatim.
            let perBeat = tempoMap.framesPerBeat(atBeat: clip.startBeat,
                                                 sampleRate: fileRate)
            clipLengthFrames = Int64((clip.lengthBeats * perBeat).rounded())
            fadeInFrames = Int64((inLenBeats * perBeat).rounded())
            fadeOutFrames = Int64((outLenBeats * perBeat).rounded())
        } else {
            // Piecewise: integrate each window's beat span from the clip
            // start. The fade-out span integrates over ITS OWN beat window
            // (the clip's last `outLenBeats`), so a boundary inside either
            // fade lands the frame edges on the true wall-clock positions.
            let start = clip.startBeat
            let end = clip.startBeat + clip.lengthBeats
            clipLengthFrames = Int64((tempoMap.seconds(from: start, to: end) * fileRate).rounded())
            fadeInFrames = Int64((tempoMap.seconds(from: start, to: start + inLenBeats)
                                  * fileRate).rounded())
            fadeOutFrames = Int64((tempoMap.seconds(from: end - outLenBeats, to: end)
                                   * fileRate).rounded())
        }

        let segStart = segmentStart
        let segEnd = segmentStart + max(0, segmentFrameCount)
        // Window edges on the clip's own timeline...
        let inEnd = min(fadeInFrames, clipLengthFrames)
        let outStart = max(clipLengthFrames - fadeOutFrames, 0)
        // ...clamped into the region, monotonically, so the three boundaries
        // can never cross (contiguity by construction).
        let b1 = min(max(inEnd, segStart), segEnd)
        let b2 = min(max(outStart, b1), segEnd)
        return PiecePlan(segmentStart: segStart, fadeInEnd: b1,
                         fadeOutStart: b2, segmentEnd: segEnd)
    }

    /// Multiplies `buffer` in place by the clip's NORMALIZED fade shape,
    /// evaluated per frame from `Clip.envelopeGain(atBeat:)` with `gainDb`
    /// zeroed (static gain rides `player.volume`). `clipRelativeStartFrame`
    /// is the clip-relative frame of the buffer's sample 0, so arbitrary
    /// segment starts (mid-fade playheads) evaluate the correct partial ramp
    /// from the very first frame. Main-actor schedule-time math only.
    ///
    /// Frame→beat (m12-c): single-segment clips divide by the constant
    /// `framesPerBeat` (bit-identical to the scalar era); a clip crossing a
    /// tempo boundary inverts the map per frame —
    /// `beat(from: clip.startBeat, elapsedSeconds: frame / fileRate)` — so
    /// the envelope stays BEAT-normalized while its wall-clock realization
    /// warps with the tempo (equal-power complementarity of a crossfaded
    /// pair is pointwise in beat progress and both sides warp identically:
    /// design §3.5.3, proven by the m12-c seam-continuity gate).
    static func applyEnvelope(
        buffer: AVAudioPCMBuffer, clip: Clip,
        clipRelativeStartFrame: Int64, tempoMap: TempoMap, fileRate: Double
    ) {
        guard let channels = buffer.floatChannelData else { return }
        var shape = clip
        shape.gainDb = 0
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let constantTempo = tempoMap.isConstant(from: clip.startBeat,
                                                to: clip.startBeat + clip.lengthBeats)
        let perBeat = constantTempo
            ? tempoMap.framesPerBeat(atBeat: clip.startBeat, sampleRate: fileRate)
            : 0
        for frame in 0..<frames {
            let clipFrame = clipRelativeStartFrame + Int64(frame)
            let beat = constantTempo
                ? Double(clipFrame) / perBeat
                : tempoMap.beat(from: clip.startBeat,
                                elapsedSeconds: Double(clipFrame) / fileRate) - clip.startBeat
            let gain = Float(shape.envelopeGain(atBeat: beat))
            for channel in 0..<channelCount {
                channels[channel][frame] *= gain
            }
        }
    }

    /// Reads `frameCount` frames from `file` at `sourceStartFrame` (absolute
    /// FILE frames, `startOffsetSeconds` already folded in by the caller) into
    /// a fresh buffer at the file's processing format, then applies the
    /// envelope. `file` must be a bake-owned reader — never the instance a
    /// player is streaming segments from (AVAudioFile's read position is
    /// stateful and not shareable).
    static func bakePiece(
        file: AVAudioFile, sourceStartFrame: Int64, frameCount: Int64,
        clip: Clip, clipRelativeStartFrame: Int64, tempoMap: TempoMap
    ) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        guard frameCount > 0, frameCount <= Int64(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else {
            throw EngineError.renderFailed(
                "cannot allocate a \(frameCount)-frame fade buffer")
        }
        file.framePosition = AVAudioFramePosition(sourceStartFrame)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        applyEnvelope(buffer: buffer, clip: clip,
                      clipRelativeStartFrame: clipRelativeStartFrame,
                      tempoMap: tempoMap, fileRate: format.sampleRate)
        return buffer
    }
}
