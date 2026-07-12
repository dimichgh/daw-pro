import Foundation

/// Audio-quantize v0 knobs (M5 iii-f, spec §5b). Mirrors `QuantizeSettings`
/// (grid / interpolation `strength` / MPC `swingPercent`) and adds the audio-only
/// concerns: the detector `sensitivity`, the join `crossfadeSeconds`, and the
/// `minSliceSeconds` floor that both merges too-close onsets and keeps every
/// emitted slice (including the head/tail) at least that wide in time.
///
/// v0 is slice-and-nudge: NO per-slice time-stretch (the full-source-file stretch
/// cache model forbids N per-span renders — elastic audio v1 is the flagged
/// future mode). The GROOVE SEAM (M5 iii-g) plugs in the same way it does on
/// `QuantizeSettings`: an additive `groove: GrooveTemplate?` field with a `nil`
/// default, routed through `QuantizeTarget.nearest`. It is intentionally omitted
/// here until iii-g lands `GrooveTemplate`.
public struct AudioQuantizeSettings: Sendable, Equatable {
    /// Grid resolution in beats; must be `> 0` (a grid `<= 0` makes the target
    /// evaluator a no-op, so nudges collapse to zero and only slicing happens).
    public var gridBeats: Double
    /// Interpolation toward the grid target, `0...1`: `new = old + strength·(target − old)`.
    public var strength: Double
    /// MPC-style swing percent, `50...75` (see `QuantizeSettings.swingPercent`).
    public var swingPercent: Double
    /// When set, per-slot targets come from the GROOVE (M5 iii-g, spec §6)
    /// instead of the straight/swing grid — the same seam as
    /// `QuantizeSettings.groove`, forwarded through `targetSettings` so every
    /// onset routes through `QuantizeTarget.nearest` unchanged. Groove wins over
    /// `swingPercent`. Additive with a `nil` default.
    public var groove: GrooveTemplate?
    /// Transient-detector knob, `0...1` (higher finds more onsets).
    public var sensitivity: Double
    /// Join crossfade width in SECONDS, clamped to `crossfadeSecondsRange`.
    public var crossfadeSeconds: Double
    /// Onsets closer together than this MERGE; also the minimum time-width of
    /// every emitted slice (the monotone nudge clamp keeps slices this far apart).
    public var minSliceSeconds: Double

    /// Join-crossfade width bounds (seconds) — half the take-comp range, since a
    /// slice join is finer-grained than a comp join.
    public static let crossfadeSecondsRange: ClosedRange<Double> = 0...0.05
    /// Default join-crossfade width (seconds).
    public static let defaultCrossfadeSeconds: Double = 0.010
    /// Default minimum slice width (seconds).
    public static let defaultMinSliceSeconds: Double = 0.05

    public init(
        gridBeats: Double,
        strength: Double = 1,
        swingPercent: Double = 50,
        groove: GrooveTemplate? = nil,
        sensitivity: Double = 0.5,
        crossfadeSeconds: Double = AudioQuantizeSettings.defaultCrossfadeSeconds,
        minSliceSeconds: Double = AudioQuantizeSettings.defaultMinSliceSeconds
    ) {
        self.gridBeats = gridBeats
        self.strength = strength.clamped(to: 0...1)
        self.swingPercent = max(50, swingPercent)
        self.groove = groove
        self.sensitivity = sensitivity.clamped(to: 0...1)
        self.crossfadeSeconds = crossfadeSeconds.clamped(to: Self.crossfadeSecondsRange)
        self.minSliceSeconds = max(0.001, minSliceSeconds)
    }

    /// The shared straight/swing target evaluator's settings — the audio and MIDI
    /// paths compute onset targets through the exact same `QuantizeTarget.nearest`
    /// so grid/swing semantics never drift between them.
    var targetSettings: QuantizeSettings {
        QuantizeSettings(gridBeats: gridBeats, strength: strength,
                         swingPercent: swingPercent, groove: groove)
    }
}

/// Pure, headless audio-quantize planner (M5 iii-f, spec §5b). Given an audio
/// clip's geometry, a list of transient onsets in SOURCE-FILE seconds, the tempo,
/// and the settings, it returns the replacement slice layout as ordinary clips.
///
/// The layout, in timeline order:
///  - HEAD slice: source `[windowStart, onset₀)` (the pre-onset material only),
///    placed at `clipStart`, keeping the clip's `fadeIn`.
///  - SLICE i (i = 0…n−2): source span `[onsetᵢ, onsetᵢ₊₁)` placed so that onset
///    lands on its (strength-interpolated, monotone-clamped) grid target `newᵢ`.
///  - TAIL slice (i = n−1): source `[onsetₙ₋₁, windowEnd)` placed at `newₙ₋₁`,
///    keeping the clip's `fadeOut`.
///
/// Each slice plays its OWN inter-onset material at natural speed (NO stretch) and
/// NEVER reads past the next onset — so a moved slice can never replay its
/// neighbour's attack (the doubled-transient trap of naive source-continuation).
/// This is the authentic Recycle/early-Logic slice behavior the spec cites.
///
/// Joins are the settled representational equal-power crossfade (the
/// `CompFlattener` pattern, ratio 1): where quantization COMPRESSES a pair (the
/// slices would overlap), the left extends `xf/2` past the boundary with an
/// equal-power `fadeOut` and the right starts `xf/2` early (offset pulled back)
/// with an equal-power `fadeIn`, and the mixer's overlapping-clips sum makes the
/// constant-power crossfade. Where quantization EXPANDS a pair (a gap opens), the
/// left cannot extend without reading its neighbour's attack, so the join stays a
/// CLEAN CUT into honest silence (the spec's gap rule) — the crossfade width
/// self-clamps to zero there.
///
/// MONOTONE guarantee (spec §5b): nudged onsets never reorder — each placement is
/// clamped to at least `minSliceBeats` past the previous one, so slices only ever
/// overlap by their crossfade, never cross.
public enum AudioQuantizePlan {

    /// One emitted slice with the base geometry the crossfade pass reads from.
    private struct Slice {
        var clip: Clip
        let placedStart: Double        // grid-target placement (pre-crossfade)
        let sourceOffset: Double       // seconds into the file
        let sourceEnd: Double          // seconds — the natural span end (next onset / windowEnd)
        var naturalLenBeats: Double    // (sourceEnd − sourceOffset)/spb — the source it may read
        var baseLenBeats: Double       // min(natural, spacing-to-next); tail = to clip end
    }

    /// Computes the slice layout. Throws (all `ProjectError`, engine-free):
    ///  - `quantizeRequiresAudioClip` for a MIDI clip,
    ///  - `audioQuantizeStretchUnsupported` for a non-identity stretch (v0 cut),
    ///  - `audioQuantizeTempoBoundaryUnsupported` when the clip's span crosses
    ///    a tempo-map segment boundary (m12-c cut — see below),
    ///  - `audioQuantizeNoTransients` when fewer than 2 usable onsets fall inside
    ///    the clip's source window.
    public static func compute(clip: Clip,
                               transientsSourceSeconds: [Double],
                               tempoMap: TempoMap,
                               settings: AudioQuantizeSettings) throws -> [Clip] {
        guard !clip.isMIDI else {
            throw ProjectError.quantizeRequiresAudioClip(clip.id)
        }
        // v0 cut: transient times live in SOURCE seconds and the slice math
        // assumes 1:1 source↔timeline; a non-identity stretch would need the
        // windowed per-slice render mode (elastic audio v1).
        guard clip.isStretchIdentity else {
            throw ProjectError.audioQuantizeStretchUnsupported(clip.id)
        }
        // m12-c cut (design row 24, settled): the slice algorithm assumes ONE
        // constant source↔timeline factor across the whole clip (`spb` below
        // scales onsets, minimum widths, AND crossfade extents uniformly — a
        // per-transient integral would leave slice widths/joins internally
        // inconsistent), so a clip crossing a tempo boundary is REJECTED with
        // a teaching error, the `audioQuantizeStretchUnsupported` precedent.
        // Split the clip at the boundary first; each side then quantizes.
        guard tempoMap.isConstant(from: clip.startBeat,
                                  to: clip.startBeat + clip.lengthBeats) else {
            throw ProjectError.audioQuantizeTempoBoundaryUnsupported(clip.id)
        }

        // Clip-local seconds-per-beat from the map at the clip's position —
        // exact across the whole clip (constant-tempo span guarded above).
        let spb = tempoMap.secondsPerBeat(atBeat: clip.startBeat)
        let clipStart = clip.startBeat
        let clipEnd = clip.startBeat + clip.lengthBeats
        let windowStart = clip.startOffsetSeconds
        let windowEnd = windowStart + clip.sourceWindowSeconds(tempoMap: tempoMap)
        let minSlice = settings.minSliceSeconds
        // minSliceSeconds mapped to beats (ratio 1 → 1:1 source↔timeline).
        let minSliceBeats = minSlice / spb

        // 1. Onsets: strictly inside the window, sorted, merged when closer than
        //    minSlice, and kept at least minSlice from both window edges so the
        //    head and tail spans are never sub-minSlice in the SOURCE domain.
        var onsets: [Double] = []
        for o in transientsSourceSeconds.sorted() where o > windowStart && o < windowEnd {
            if (o - windowStart) < minSlice || (windowEnd - o) < minSlice { continue }
            if let last = onsets.last, (o - last) < minSlice { continue }
            onsets.append(o)
        }
        guard onsets.count >= 2 else {
            throw ProjectError.audioQuantizeNoTransients(clip.id)
        }
        let n = onsets.count

        // 2. Map onsets to timeline beats, take grid targets, interpolate by
        //    strength, then clamp MONOTONE forward (never reorder; head ≥ minSlice)
        //    and into the clip body.
        let qs = settings.targetSettings
        let lo = clipStart + minSliceBeats
        let hi = max(lo, clipEnd - minSliceBeats)
        var placed: [Double] = []
        placed.reserveCapacity(n)
        var prev = clipStart
        for o in onsets {
            let beat = clipStart + (o - windowStart) / spb
            let target = QuantizeTarget.nearest(toBeat: beat, settings: qs)
            var newBeat = beat + settings.strength * (target - beat)
            newBeat = newBeat.clamped(to: lo...hi)
            newBeat = max(newBeat, prev + minSliceBeats)
            placed.append(newBeat)
            prev = newBeat
        }

        // 3. Base slices (head, onset slices, tail). Each reads only its own
        //    inter-onset material; baseLen never overruns the next placement.
        var slices: [Slice] = []
        slices.reserveCapacity(n + 1)
        // Head: pre-onset material [windowStart, onset₀).
        slices.append(makeSlice(from: clip, placedStart: clipStart,
                                sourceOffset: windowStart, sourceEnd: onsets[0],
                                nextStart: placed[0], clipEnd: clipEnd, spb: spb,
                                fadeInBeats: clip.fadeInBeats, fadeInCurve: clip.fadeInCurve,
                                fadeOutBeats: 0, fadeOutCurve: .linear))
        for i in 0..<n {
            let isTail = (i == n - 1)
            let sourceEnd = isTail ? windowEnd : onsets[i + 1]
            let nextStart = isTail ? clipEnd : placed[i + 1]
            slices.append(makeSlice(from: clip, placedStart: placed[i],
                                    sourceOffset: onsets[i], sourceEnd: sourceEnd,
                                    nextStart: nextStart, clipEnd: clipEnd, spb: spb,
                                    fadeInBeats: 0, fadeInCurve: .linear,
                                    fadeOutBeats: isTail ? clip.fadeOutBeats : 0,
                                    fadeOutCurve: isTail ? clip.fadeOutCurve : .linear))
        }

        // 4. Representational equal-power crossfades at COMPRESSED joins; expanded
        //    joins self-clamp to a clean cut (no reading past the next attack).
        applyCrossfades(&slices, crossfadeSeconds: settings.crossfadeSeconds,
                        spb: spb, windowStart: windowStart)
        return slices.map(\.clip)
    }

    /// Builds a base slice. `baseLen = min(natural source span, spacing to the
    /// next placement)` so the slice never overruns its neighbour nor reads past
    /// its own source span; the tail is capped to the clip's original end AND its
    /// owned source. A plain audio clip (never a comp member — audio quantize runs
    /// on ordinary clips and yields ordinary clips), ratio 1.
    private static func makeSlice(from clip: Clip, placedStart: Double,
                                  sourceOffset: Double, sourceEnd: Double,
                                  nextStart: Double, clipEnd: Double, spb: Double,
                                  fadeInBeats: Double, fadeInCurve: FadeCurve,
                                  fadeOutBeats: Double, fadeOutCurve: FadeCurve) -> Slice {
        let natural = max(0, (sourceEnd - sourceOffset) / spb)
        let spacing = max(0, nextStart - placedStart)
        let baseLen = min(natural, spacing)
        let c = Clip(
            id: UUID(), name: clip.name,
            startBeat: placedStart, lengthBeats: baseLen,
            audioFileURL: clip.audioFileURL, notes: nil,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: sourceOffset, gainDb: clip.gainDb,
            fadeInBeats: fadeInBeats, fadeOutBeats: fadeOutBeats,
            fadeInCurve: fadeInCurve, fadeOutCurve: fadeOutCurve,
            stretchRatio: 1, pitchShiftSemitones: 0,
            formantPreserve: clip.formantPreserve)
        return Slice(clip: c, placedStart: placedStart, sourceOffset: sourceOffset,
                     sourceEnd: sourceEnd, naturalLenBeats: natural, baseLenBeats: baseLen)
    }

    /// Applies equal-power crossfades at each join (the `CompFlattener` pattern,
    /// ratio 1). The left-extension room is the source the left slice has NOT yet
    /// consumed (`natural − base`): it is `> 0` only where the pair was COMPRESSED
    /// (the slice was trimmed below its natural span), so an EXPANDED pair — where
    /// the left already spans its full material and any extension would read the
    /// neighbour's attack — self-clamps to a clean cut.
    private static func applyCrossfades(_ slices: inout [Slice], crossfadeSeconds: Double,
                                        spb: Double, windowStart: Double) {
        guard slices.count >= 2, crossfadeSeconds > 0 else { return }
        for i in 1..<slices.count {
            let left = slices[i - 1]
            let right = slices[i]
            let boundary = right.placedStart
            var xf = crossfadeSeconds / spb   // seconds → beats (ratio 1)
            // Never wider than half the shorter base slice.
            xf = min(xf, min(left.baseLenBeats, right.baseLenBeats) / 2)
            // Left may extend only into source it has NOT consumed (0 for an
            // expanded/gap join → clean cut, never the neighbour's attack).
            xf = min(xf, 2 * (left.naturalLenBeats - left.baseLenBeats))
            // Right head extension (xf/2 before b) must not pull the source offset
            // below the clip's owned source start.
            xf = min(xf, 2 * (right.sourceOffset - windowStart) / spb)
            guard xf > 0 else { continue }
            let half = xf / 2

            // Left extends half past b, equal-power fade-out.
            slices[i - 1].clip.lengthBeats = left.baseLenBeats + half
            slices[i - 1].clip.fadeOutBeats = xf
            slices[i - 1].clip.fadeOutCurve = .equalPower

            // Right starts half before b, offset reduced by the source equivalent,
            // equal-power fade-in — its onset still lands exactly on `boundary`.
            slices[i].clip.startBeat = boundary - half
            slices[i].clip.lengthBeats = right.baseLenBeats + half
            slices[i].clip.startOffsetSeconds = max(windowStart, right.sourceOffset - half * spb)
            slices[i].clip.fadeInBeats = xf
            slices[i].clip.fadeInCurve = .equalPower
        }
    }
}
