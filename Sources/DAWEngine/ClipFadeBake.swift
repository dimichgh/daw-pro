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
        // Gain envelope (m13-e): a non-empty breakpoint envelope makes the
        // whole-region bake the CONSERVATIVE meaning of this three-piece plan
        // — ONE full-region "fade-in" piece (middle = 0, fade-out = 0) whose
        // `applyEnvelope` folds the fade-in, the envelope, AND the fade-out.
        // The scheduler does NOT take this path anymore: `scheduleAll` routes
        // enveloped clips through `envelopedPiecePlan` (m13-h2), which bakes
        // only the spans the envelope actually shapes. This branch stays as
        // the safe fallback contract for any caller that treats PiecePlan as
        // the single plan shape. When the envelope is EMPTY this branch is
        // skipped and the fade-only three-piece plan below stays
        // byte-identical to the pre-m13-e era — the null-case byte gate.
        if !clip.gainEnvelope.isEmpty {
            let segEnvEnd = segmentStart + max(0, segmentFrameCount)
            return PiecePlan(segmentStart: segmentStart, fadeInEnd: segEnvEnd,
                             fadeOutStart: segEnvEnd, segmentEnd: segEnvEnd)
        }
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

    /// One piece of an ENVELOPED clip's scheduled region (m13-h2), in
    /// clip-relative file-rate frames: either baked through `bakePiece`
    /// (the envelope or a fade shapes it) or streamed straight off the file.
    /// A streamed piece is only ever emitted where the envelope evaluates to
    /// EXACTLY unity, so its file bytes pass through bit-identical to what
    /// the old full-region bake produced there (a `× 1.0` multiply is an
    /// IEEE-754 identity).
    struct EnvelopedPiece: Equatable {
        /// Clip-relative first frame.
        let start: Int64
        let frameCount: Int64
        let bake: Bool
    }

    /// No streamed piece shorter than this may appear in an enveloped plan
    /// (~170 ms at 48 kHz): a sliver gap between two shaped spans folds into
    /// the surrounding bake instead of costing an extra player-queue entry.
    /// Folding is always byte-safe — baked frames evaluate the true envelope,
    /// so a folded unity frame multiplies by exactly 1.0.
    static let minStreamRunFrames: Int64 = 8_192

    /// Splits an ENVELOPED clip's scheduled region into alternating
    /// baked/streamed pieces (m13-h2 — the perf fix for the m13-e whole-region
    /// bake): only the spans where `Clip.envelopeGain` can differ from unity
    /// are baked. Requires `!clip.gainEnvelope.isEmpty` (empty envelopes take
    /// the fade-only `piecePlan`, byte-identical to the pre-m13-e era).
    ///
    /// Baked spans are the union of:
    ///  - the fade-in window `[0, fadeInFrames)` and fade-out window
    ///    `[outStart, clipEnd)` (same beats→frames math as `piecePlan`), and
    ///  - every inter-breakpoint span whose linear-in-dB interpolation is not
    ///    identically 0 dB — i.e. either endpoint's `gainDb != 0` — plus the
    ///    constant head (before the first point) / tail (after the last) when
    ///    that point's `gainDb != 0`. Between two 0 dB points the
    ///    interpolation is `0 + 0·t == 0` exactly, and `pow(10, 0) == 1`
    ///    exactly, so those spans are provably unity.
    ///
    /// Each shaped span's frame window is expanded by ONE guard frame on both
    /// sides (`floor − 1` / `ceil + 1`): correctness only requires STREAMED
    /// frames to be provably unity — over-baking a boundary frame is byte-
    /// neutral (the bake evaluates the true envelope there), while the guard
    /// makes the streamed side's frame→beat inversion (`applyEnvelope`'s own
    /// mapping) land strictly inside the unity beat interval regardless of
    /// `.rounded()` boundary placement. Spans are then clamped to the region,
    /// merged (any streamed gap `< minStreamRunFrames` folds), and emitted as
    /// a contiguous exact partition of
    /// `[segmentStart, segmentStart + segmentFrameCount)`.
    static func envelopedPiecePlan(
        clip: Clip, tempoMap: TempoMap, fileRate: Double,
        segmentStart: Int64, segmentFrameCount: Int64
    ) -> [EnvelopedPiece] {
        let segStart = segmentStart
        let segEnd = segmentStart + max(0, segmentFrameCount)
        guard segEnd > segStart else { return [] }
        // A zero-length clip evaluates `envelopeGain` to the static gain
        // (normalized: exactly 1.0) at every frame — stream everything.
        guard clip.lengthBeats > 0 else {
            return [EnvelopedPiece(start: segStart,
                                   frameCount: segEnd - segStart, bake: false)]
        }

        // Beat → clip-relative frame, the same convention `piecePlan` uses:
        // constant-tempo clips use the verbatim `framesPerBeat` product, a
        // boundary-crossing clip integrates the map from the clip's start.
        let constantTempo = tempoMap.isConstant(
            from: clip.startBeat, to: clip.startBeat + clip.lengthBeats)
        let perBeat = constantTempo
            ? tempoMap.framesPerBeat(atBeat: clip.startBeat, sampleRate: fileRate)
            : 0
        func frames(atBeat beat: Double) -> Double {
            constantTempo
                ? beat * perBeat
                : tempoMap.seconds(from: clip.startBeat,
                                   to: clip.startBeat + beat) * fileRate
        }
        // Guard-framed span edges (see doc comment): baked windows round
        // OUTWARD by one extra frame so every possibly-shaped frame bakes.
        func bakedLo(_ beat: Double) -> Int64 { Int64(frames(atBeat: beat).rounded(.down)) - 1 }
        func bakedHi(_ beat: Double) -> Int64 { Int64(frames(atBeat: beat).rounded(.up)) + 1 }

        // Shaped intervals in clip-relative frames, unclamped.
        var shaped: [(lo: Int64, hi: Int64)] = []
        let inLen = min(max(0, clip.fadeInBeats), clip.lengthBeats)
        if inLen > 0 { shaped.append((lo: segStart, hi: bakedHi(inLen))) }
        let outLen = min(max(0, clip.fadeOutBeats), clip.lengthBeats)
        if outLen > 0 { shaped.append((lo: bakedLo(clip.lengthBeats - outLen), hi: segEnd)) }
        let points = clip.gainEnvelope
        if let first = points.first, first.gainDb != 0 {
            shaped.append((lo: segStart, hi: bakedHi(first.beat)))
        }
        for i in 0..<max(0, points.count - 1)
        where points[i].gainDb != 0 || points[i + 1].gainDb != 0 {
            shaped.append((lo: bakedLo(points[i].beat), hi: bakedHi(points[i + 1].beat)))
        }
        if let last = points.last, last.gainDb != 0 {
            shaped.append((lo: bakedLo(last.beat), hi: segEnd))
        }

        // Clamp to the region, sort, merge — folding overlaps AND any streamed
        // gap too short to be worth a separate player-queue entry.
        var merged: [(lo: Int64, hi: Int64)] = []
        for span in shaped
            .map({ (lo: max($0.lo, segStart), hi: min($0.hi, segEnd)) })
            .filter({ $0.hi > $0.lo })
            .sorted(by: { $0.lo < $1.lo }) {
            if var current = merged.last, span.lo - current.hi < minStreamRunFrames {
                current.hi = max(current.hi, span.hi)
                merged[merged.count - 1] = current
            } else {
                merged.append(span)
            }
        }
        // Head/tail streamed runs obey the same floor: a sliver before the
        // first baked span (or after the last) folds into it.
        if var head = merged.first, head.lo - segStart < minStreamRunFrames, head.lo > segStart {
            head.lo = segStart
            merged[0] = head
        }
        if var tail = merged.last, segEnd - tail.hi < minStreamRunFrames, tail.hi < segEnd {
            tail.hi = segEnd
            merged[merged.count - 1] = tail
        }

        // Emit the exact partition, alternating streamed gaps and baked spans.
        var pieces: [EnvelopedPiece] = []
        var cursor = segStart
        for span in merged {
            if span.lo > cursor {
                pieces.append(EnvelopedPiece(start: cursor,
                                             frameCount: span.lo - cursor, bake: false))
            }
            pieces.append(EnvelopedPiece(start: span.lo,
                                         frameCount: span.hi - span.lo, bake: true))
            cursor = span.hi
        }
        if cursor < segEnd {
            pieces.append(EnvelopedPiece(start: cursor,
                                         frameCount: segEnd - cursor, bake: false))
        }
        return pieces
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
