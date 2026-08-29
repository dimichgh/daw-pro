import Foundation

/// m32-b0 — the ONE HOME for slice-boundary conditioning and generation.
///
/// Three consumers share this module so the "where does a slice start?"
/// question has exactly one answer in the tree:
///  1. `AudioQuantizePlan.compute` (M5 iii-f) — chop-to-timeline,
///  2. `clip.quantizeAudio`'s fixed-division mode (m32-b1),
///  3. `SliceToSamplerPlan` (m32-b2) — chop-to-sampler-zones.
///
/// Everything here is in **SOURCE-FILE SECONDS** and is pure: no engine, no
/// UI, no file I/O, no tempo assumptions except where a signature says so.
///
/// ⚠️ `condition` is an EXTRACTION, not a rewrite. Its body is the verbatim
/// step 1 of `AudioQuantizePlan.compute` (the `sorted()`, the strict `>`/`<`
/// window test, the two-sided `minSlice` edge rule, and the predecessor
/// merge, in that order). The extraction gate is that `AudioQuantizePlan`
/// produces byte-identical output before and after, so nothing here may be
/// "improved" — a different comparison order or a `<=` would silently move
/// every existing quantize result.
///
/// ⚠️ The minimum-COUNT rule deliberately lives with each consumer, not here:
/// `AudioQuantizePlan` needs ≥ 2 onsets (it always emits a head and a tail),
/// while `SliceToSamplerPlan` is legal with 1 boundary (one boundary, no
/// head, one zone). A shared count guard would be wrong for one of them.
public enum SliceBoundaries {

    /// Conditions a raw onset list into usable boundaries. EXTRACTED VERBATIM
    /// from `AudioQuantizePlan.compute` step 1 (`AudioQuantize.swift`) —
    /// sorted, strictly inside the window, at least `minSliceSeconds` from
    /// BOTH window edges, and merged when closer than `minSliceSeconds` to
    /// their surviving predecessor.
    ///
    /// Returns SOURCE-FILE SECONDS, ascending and strictly increasing.
    ///
    /// The two-sided edge rule is what makes the head span
    /// `[windowStart, first)` and the tail span `[last, windowEnd)` at least
    /// `minSliceSeconds` wide in the SOURCE domain — a property both
    /// consumers rely on (the quantizer for its monotone clamp, the sampler
    /// chopper so no pad is a sub-millisecond click).
    public static func condition(onsetsSourceSeconds: [Double],
                                 windowStart: Double,
                                 windowEnd: Double,
                                 minSliceSeconds minSlice: Double) -> [Double] {
        var onsets: [Double] = []
        for o in onsetsSourceSeconds.sorted() where o > windowStart && o < windowEnd {
            if (o - windowStart) < minSlice || (windowEnd - o) < minSlice { continue }
            if let last = onsets.last, (o - last) < minSlice { continue }
            onsets.append(o)
        }
        return onsets
    }

    /// `divisions` equal parts of `[windowStart, windowEnd)`: the INTERIOR
    /// boundaries only (at most `divisions - 1` of them), so the result has
    /// the same SHAPE as a conditioned onset list and both feed the same span
    /// builder.
    ///
    /// `divisions` must be >= 2; anything smaller yields no boundaries (one
    /// undivided span). Boundaries too close to a window edge, or to each
    /// other, are dropped by `condition`'s exact rule — so asking for 64
    /// divisions of a 1 s window at the default 50 ms floor honestly returns
    /// fewer boundaries rather than a list of sub-audible slivers.
    public static func equalDivisions(windowStart: Double, windowEnd: Double,
                                      divisions: Int,
                                      minSliceSeconds: Double) -> [Double] {
        guard divisions >= 2, windowEnd > windowStart else { return [] }
        let span = windowEnd - windowStart
        var raw: [Double] = []
        raw.reserveCapacity(divisions - 1)
        for i in 1..<divisions {
            raw.append(windowStart + span * Double(i) / Double(divisions))
        }
        return condition(onsetsSourceSeconds: raw, windowStart: windowStart,
                         windowEnd: windowEnd, minSliceSeconds: minSliceSeconds)
    }

    /// Musical-grid boundaries: every multiple of `gridBeats` strictly inside
    /// the clip's window, mapped to SOURCE SECONDS through the tempo map at
    /// the clip's position. Same conditioning rule applied on the way out.
    ///
    /// ⚠️⚠️ THIS TAKES A SINGLE seconds-per-beat, read at `clipStartBeat`, so
    /// **the CALLER must reject a window that crosses a tempo-map boundary**
    /// (`tempoMap.isConstant(from:to:)` →
    /// `ProjectError.audioQuantizeTempoBoundaryUnsupported`, the m12-c
    /// precedent that `AudioQuantizePlan.compute` already carries). With a
    /// tempo change inside the window every boundary after it is silently
    /// misplaced — plausible-looking wrong frames, which is exactly the
    /// failure class this module exists to make impossible.
    ///
    /// ⭐ Only the GRID mode has this constraint. Transient and equal-division
    /// boundaries are computed entirely in the SOURCE-SECONDS domain and never
    /// consult the tempo map, so they stay correct across a tempo change and
    /// must NOT be rejected.
    public static func gridDivisions(clipStartBeat: Double,
                                     windowStart: Double, windowEnd: Double,
                                     gridBeats: Double,
                                     tempoMap: TempoMap,
                                     minSliceSeconds: Double) -> [Double] {
        guard gridBeats > 0, windowEnd > windowStart else { return [] }
        let spb = tempoMap.secondsPerBeat(atBeat: clipStartBeat)
        guard spb > 0 else { return [] }
        // Window expressed in ABSOLUTE beats — grid lines are multiples of
        // `gridBeats` on the session grid (the `QuantizeTarget.nearest`
        // domain), not offsets from the clip, so a chop lines up with bars
        // wherever the clip happens to sit.
        let startBeat = clipStartBeat
        let endBeat = clipStartBeat + (windowEnd - windowStart) / spb
        var raw: [Double] = []
        var index = (startBeat / gridBeats).rounded(.down)
        // Walk forward from the last grid line at or before the window start.
        // Bounded by the beat span, so a pathological gridBeats cannot spin.
        let maxLines = Int(((endBeat - startBeat) / gridBeats).rounded(.up)) + 2
        var emitted = 0
        while emitted <= maxLines {
            let beat = index * gridBeats
            index += 1
            emitted += 1
            if beat <= startBeat { continue }
            if beat >= endBeat { break }
            raw.append(windowStart + (beat - startBeat) * spb)
        }
        return condition(onsetsSourceSeconds: raw, windowStart: windowStart,
                         windowEnd: windowEnd, minSliceSeconds: minSliceSeconds)
    }
}
