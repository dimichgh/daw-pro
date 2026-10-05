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
    ///
    /// ⭐ TOTAL, AND WALKS ONLY WHAT IT KEEPS (m23-ap I5-F4 round 4). This used
    /// to list EVERY grid line in the window and then condition the list: a
    /// 1e-20 grid on a 4-beat clip asked `Int(_:)` for 4e20 lines (a trap), and
    /// a 1e-12 grid walked 4e12 of them on the main actor. It now answers the
    /// same question without the list. The lines are still the ones the walk
    /// visited (line `index + t` for `t` = 0 … the old `maxLines`, each position
    /// computed with the old expressions), and their seconds never decrease with
    /// `t`, so each of `condition`'s tests is false-then-true (or true-then-
    /// false) along them: a search finds the next line `condition` would keep,
    /// skipping every line it would drop. For every input the old walk could
    /// finish, every index it visited is an integer below 2^53, and the answer
    /// is the old answer, bit for bit (`SliceGridTotalityTests` compares the two
    /// on a grid of cases). Two things are new, and only past anything the app
    /// can send (the wire's grid is at least 1/1024 beat, its positions at most
    /// 2^20 beats, and `SliceToSamplerSettings` keeps `minSliceSeconds` at least
    /// 1 ms):
    ///  - a window whose grid-line indices do not all fit below 2^53 gives no
    ///    boundaries (there, one Double can no longer tell two lines apart);
    ///  - at most `maximumBoundaries` are returned (default 2^24), the first
    ///    ones. The one app caller refuses a chop of more than 96 pads long
    ///    before, so for it the cap can only change the pad count its refusal
    ///    quotes, for a chop of more than 16,777,216 pads.
    public static func gridDivisions(clipStartBeat: Double,
                                     windowStart: Double, windowEnd: Double,
                                     gridBeats: Double,
                                     tempoMap: TempoMap,
                                     minSliceSeconds: Double,
                                     maximumBoundaries: Int = maximumGridBoundaries) -> [Double] {
        guard gridBeats > 0, windowEnd > windowStart else { return [] }
        let spb = tempoMap.secondsPerBeat(atBeat: clipStartBeat)
        guard spb > 0 else { return [] }
        // Window expressed in ABSOLUTE beats — grid lines are multiples of
        // `gridBeats` on the session grid (the `QuantizeTarget.nearest`
        // domain), not offsets from the clip, so a chop lines up with bars
        // wherever the clip happens to sit.
        let startBeat = clipStartBeat
        let endBeat = clipStartBeat + (windowEnd - windowStart) / spb
        // The lines the old walk visited: index `firstIndex + t` for t = 0 …
        // `lastStep` (its `maxLines`), starting at the last grid line at or
        // before the window start. Kept as Doubles: every one must be an exact
        // integer (below 2^53), or there is no grid to answer with.
        let firstIndex = (startBeat / gridBeats).rounded(.down)
        let lastStep = ((endBeat - startBeat) / gridBeats).rounded(.up) + 2
        let exact = 9_007_199_254_740_992.0   // 2^53
        guard lastStep < exact, firstIndex.magnitude < exact,
              (firstIndex + lastStep).magnitude < exact else { return [] }
        let stepCount = lastStep + 1
        // The old expressions, verbatim: a line's beat, and its source second.
        func beat(_ t: Double) -> Double { (firstIndex + t) * gridBeats }
        func seconds(_ t: Double) -> Double { windowStart + (beat(t) - startBeat) * spb }
        // The walk skipped lines at or before the window start, and stopped at
        // the first line at or after its end: the lines it listed are [from, to).
        guard let from = firstLine(from: 0, below: stepCount, where: { beat($0) > startBeat }) else {
            return []
        }
        let to = firstLine(from: from, below: stepCount, where: { beat($0) >= endBeat }) ?? stepCount
        // `condition`, one kept boundary at a time. A line passes the tests that
        // only get truer as the seconds grow (inside the start, `minSliceSeconds`
        // clear of the start and of the last kept one); the first line that
        // fails a test that only gets falser (inside the end, clear of the end)
        // ends the walk, since no later line can pass it either.
        var boundaries: [Double] = []
        var last: Double?
        var t = from
        while t < to, boundaries.count < maximumBoundaries {
            guard let next = firstLine(from: t, below: to, where: { line in
                let o = seconds(line)
                if !(o > windowStart) || (o - windowStart) < minSliceSeconds { return false }
                if let last, (o - last) < minSliceSeconds { return false }
                return true
            }) else { break }
            let o = seconds(next)
            if !(o < windowEnd) || (windowEnd - o) < minSliceSeconds { break }
            boundaries.append(o)
            last = o
            t = next + 1
        }
        return boundaries
    }

    /// The most boundaries `gridDivisions` returns unless told otherwise: 2^24.
    public static let maximumGridBoundaries = 1 << 24

    /// The first whole `t` in `[start, end)` where `passes` holds, or nil, for a
    /// `passes` that is false and then true along the range (every caller's
    /// test only gets truer as `t` grows). Gallops out from `start`, then
    /// bisects, so a near answer costs a step or two and a far one ~2·log2 of
    /// the distance. All values are whole numbers below 2^53, so exact.
    private static func firstLine(from start: Double, below end: Double,
                                  where passes: (Double) -> Bool) -> Double? {
        guard start < end else { return nil }
        if passes(start) { return start }
        var failing = start
        var reach = 1.0
        var probe = start + 1
        while probe < end, !passes(probe) {
            failing = probe
            reach *= 2
            probe = start + reach
        }
        var passing = min(probe, end)   // passes, or `end` (nothing known to pass)
        while passing - failing > 1 {
            let middle = failing + ((passing - failing) / 2).rounded(.down)
            if passes(middle) { passing = middle } else { failing = middle }
        }
        return passing < end ? passing : nil
    }
}
