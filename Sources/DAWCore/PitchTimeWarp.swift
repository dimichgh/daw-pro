import Foundation

// m23-ap C2-1 — THE TIME MAP BEHIND PER-NOTE TIMING (making a sung note
// longer or shorter).
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §3.2
// (decision A1), §3.5 (the digest), §3.10 (failure modes 4 and 5).
//
// Pure: no clock, no I/O, no store, no engine, no actor. It is evaluated in the
// offline render task, in the store and in the editor, never on the audio
// render thread (design §3.11).
//
// WHAT C2-1 DOES AND DOES NOT DO: it adds this representation, the one
// predicate (`NoteSegment.hasTimeEdits` / `PitchEditSet.hasTimeEdits`), the
// curve's stored `timeWarp`, the generator's edited-time branch and the
// digest's time-warp block. **Nothing builds a W for the render yet.**
// `StretchCurvePlan` still passes no warp, so every render is exactly
// today's; C2-2 measures the warped input schedule's lookahead and C2-3 wires
// W into the render.

/// **W: the one map from SOURCE seconds to EDITED seconds** for a clip's
/// per-note timing edits.
///
/// A note's timing is stored in `NoteSegment.timeStartDeltaSeconds` and
/// `timeEndDeltaSeconds`, read as EDITED seconds. The note's edited start is
/// `startSeconds + timeStartDeltaSeconds` and its edited end is
/// `endSeconds + timeEndDeltaSeconds`. "Edited seconds" is the clip-source time
/// axis AFTER retiming and BEFORE the clip's own `stretchRatio`. With no time
/// edits it IS the source axis, bit for bit, and then this type does not
/// exist: `make` returns `nil`, and every caller keeps today's code path.
///
/// **W is monotone, piecewise linear, total, and pinned at both ends:**
/// `W(0) = 0` and `W(D) = D`, where `D` is the source file's duration. So the
/// rendered file's length never changes, and the gap beside a moved edge gives
/// or takes the time (design §3.6, the neighbour rule). Outside `[0, D]`, W is
/// the identity. That is continuous, because both anchors are fixed points.
///
/// Render, display and store all build W through `make` and nothing else, so
/// they cannot disagree about where a note is. `PitchCorrectionCurve` stores the
/// W it was built with, so the curve's `Equatable` compares W too: a display
/// that forgot to pass W would fail an equality gate against the render.
public struct PitchTimeWarp: Sendable, Equatable {
    /// Strictly ascending. First element 0, last element D.
    public let sourceKnots: [Double]
    /// Strictly ascending, index-for-index with `sourceKnots`. First 0, last D.
    public let editedKnots: [Double]

    /// **True when this W does not honour every knot the set asked for.**
    ///
    /// Precisely: some requested knot `(s, s + δ)`, one per note edge, has
    /// `|W(s) − (s + δ)| > healToleranceSeconds`. That one definition covers
    /// every way construction can change a request: a moved edge at or past
    /// the file's edges, the second of two abutting edges that asked for
    /// different positions, an edge the monotone and slope-bounded heal had to
    /// move, and a request that overflowed to infinity.
    ///
    /// ⚠️ It is deliberately NOT "construction dropped a knot". A note that
    /// starts at source second 0 with an untouched start asks for `(0, 0)`,
    /// which W honours exactly although the knot merges into the anchor.
    /// The note builders (`PitchNoteSplitter` over `PitchAutoCorrect.voicedRuns`)
    /// emit such notes whenever a vocal starts on the file's first frame — a
    /// part at a run's edge IS at that edge. Under the literal "dropped" reading, every
    /// such clip that was retimed anywhere else would read as healed, and the
    /// render would post a warning on a set the setter wrote.
    ///
    /// A caller that finds this true must SAY so (a render notice, an editor
    /// caption) and must never adjust silently (design §3.10, mode 4).
    public let healed: Bool

    /// Structural bound on every piece's slope (edited length over source
    /// length). **This is NOT the audio-quality clamp.** That one depends on the
    /// clip's ratio and lives in the setter (design §3.7, limit 1).
    ///
    /// ⚠️ **The setter must intersect its clean band with this range.** The
    /// clean band is `ρ · localFactor ∈ [0.5, 2]`, so `localFactor ∈
    /// [0.5/ρ, 2/ρ]`. `Clip.stretchRatioRange` is `0.25...4`, and for any ρ
    /// outside `[0.5, 2]` that band reaches past `[0.25, 4]` (at ρ = 0.25 it
    /// admits factors up to 8). Without the intersection, the heal would clamp,
    /// and flag, a set the setter itself wrote.
    public static let structuralFactorRange: ClosedRange<Double> = 0.25...4

    /// Re-keys every retimed render when bumped (design §3.5). It is hashed in
    /// the digest's time-warp block, which only retimed sets emit. Bump it when
    /// the warped input schedule's lookahead or its flush rule changes, or when
    /// anything that decides W's KNOTS changes: `make`'s heal and merge rules,
    /// `structuralFactorRange`, `minimumKnotSpacingSeconds`. Then exactly the
    /// retimed renders re-render. (`healToleranceSeconds` decides only the
    /// `healed` flag, never a knot, so it does not need a bump.)
    /// `StretchRenderCache.stretchEngineVersion` would re-render every
    /// stretched clip on every disk instead.
    public static let scheduleVersion = 1

    /// Two requested knots closer than this in source seconds are ONE knot
    /// (the first wins), and a knot this close to either end of the file
    /// merges into that end's anchor. 1 µs is a fifth of one sample at 192 kHz.
    ///
    /// ⚠️ **A FLOATING-POINT AMENDMENT TO THE DESIGN, NOT A TASTE PICK.** The
    /// heal's proof (design §3.2 step 4) is real arithmetic. In IEEE doubles,
    /// two knots one ulp apart give a lower bound `e[k−1] + 0.25 · Δs` that
    /// ROUNDS BACK to `e[k−1]`, which is a zero-length edited piece, the one
    /// thing the heal promises never to make. `PitchTimeWarpTests` builds
    /// exactly that set. With this spacing, `0.25 · Δs` is at least 2.5e-7 s,
    /// which is larger than the rounding of any edited position under 10⁸ s by
    /// orders of magnitude. No set a setter writes has knots this close:
    /// detected notes are separated by at least half a 16 ms frame, and a split
    /// makes edges that coincide exactly.
    public static let minimumKnotSpacingSeconds: Double = 1e-6

    /// A requested knot that W misses by no more than this is honoured.
    /// One nanosecond is three orders of magnitude below one sample at any
    /// rate. It exists so that a knot the setter placed exactly on a
    /// structural bound, which this file's own arithmetic may recompute one ulp
    /// away, is not reported as a heal.
    public static let healToleranceSeconds: Double = 1e-9

    private init(sourceKnots: [Double], editedKnots: [Double], healed: Bool) {
        self.sourceKnots = sourceKnots
        self.editedKnots = editedKnots
        self.healed = healed
    }

    /// `D`, the source file's duration this W is pinned to.
    public var sourceDurationSeconds: Double { sourceKnots[sourceKnots.count - 1] }

    /// Build W for an edit set and its source file's duration.
    ///
    /// Returns `nil` when the set has no time edits (`PitchEditSet.hasTimeEdits`
    /// is false), or when `sourceDurationSeconds` is not finite and positive.
    /// ⚠️ A caller that holds time edits and gets `nil` must SAY so. It must
    /// never render or draw the edits as if they were absent (design §3.10,
    /// mode 5).
    ///
    /// **Where D comes from: ONE expression,**
    /// `Double(file.length) / file.processingFormat.sampleRate`.
    /// `AudioFileImporter` computes `media.audioFileInfo(at:).durationSeconds`
    /// with it (the store and the editor), and the render must compute it with
    /// `StretchCurvePlan.sourceDurationSeconds(of:)` (C2-3). A test pins the
    /// two bit-identical on fixture files. If they ever differ, the display's W
    /// and the render's W differ in their last piece.
    ///
    /// Construction is deterministic, so every site gets the same knots from
    /// the same inputs (design §3.2):
    ///  1. The requested knots: for each canonical segment in order,
    ///     `(startSeconds, startSeconds + timeStartDeltaSeconds)` and
    ///     `(endSeconds, endSeconds + timeEndDeltaSeconds)`.
    ///  2. The file's edges are fixed. A knot within
    ///     `minimumKnotSpacingSeconds` of source 0, or of `D`, or past `D`,
    ///     merges into that anchor.
    ///  3. Two knots at the same source position (abutting notes, §3.6) merge,
    ///     and **the first wins**: the left note's end, which is
    ///     `PitchEditSet.canonical`'s own rule. "The same position" means
    ///     closer than `minimumKnotSpacingSeconds`.
    ///  4. One forward pass heals the rest into a total, monotone,
    ///     slope-bounded map. Each edited knot is clamped into the envelope
    ///     reachable from both anchors, `lo(s) = max(fMin·s, D − fMax·(D − s))`
    ///     and `hi(s) = min(fMax·s, D − fMin·(D − s))`, and into the slope
    ///     bounds from the previous (already healed) knot. Because the previous
    ///     knot lies inside its own envelope, the interval is never empty in
    ///     real arithmetic. In IEEE arithmetic the two bounds can cross by an
    ///     ulp, so the clamp is `min(max(e, lower), upper)`, which never traps.
    ///  5. A final guard drops any interior knot that is not strictly between
    ///     its kept neighbours or is not finite. After steps 2 to 4 this is
    ///     unreachable for any file shorter than about 10⁸ s. It is here so the
    ///     invariant does not rest on that arithmetic.
    ///  6. `healed` is computed against the finished map (see `healed`).
    public static func make(editSet: PitchEditSet,
                            sourceDurationSeconds: Double) -> PitchTimeWarp? {
        guard editSet.hasTimeEdits else { return nil }
        let duration = sourceDurationSeconds
        guard duration.isFinite, duration > 0 else { return nil }
        let fMin = structuralFactorRange.lowerBound
        let fMax = structuralFactorRange.upperBound
        let spacing = minimumKnotSpacingSeconds

        // (1) The knots the set asks for, in canonical order. `canonical` is a
        // no-op on a set that came through `PitchEditSet.init`, and it keeps a
        // set whose `segments` were assigned directly from reaching the heal
        // unsorted.
        var requested: [(source: Double, edited: Double)] = []
        let segments = PitchEditSet.canonical(editSet.segments)
        requested.reserveCapacity(segments.count * 2)
        for segment in segments {
            requested.append((segment.startSeconds,
                              segment.startSeconds + segment.timeStartDeltaSeconds))
            requested.append((segment.endSeconds,
                              segment.endSeconds + segment.timeEndDeltaSeconds))
        }

        // (2) + (3) The anchors are fixed, and the first of two coincident
        // knots wins.
        var sources: [Double] = [0]
        var edits: [Double] = [0]
        sources.reserveCapacity(requested.count + 2)
        edits.reserveCapacity(requested.count + 2)
        for knot in requested {
            guard knot.source >= spacing,
                  knot.source <= duration - spacing,
                  knot.source - sources[sources.count - 1] >= spacing else { continue }
            sources.append(knot.source)
            edits.append(knot.edited)
        }
        sources.append(duration)
        edits.append(duration)

        // (4) The heal: one forward pass over the interior knots.
        let last = sources.count - 1
        for k in 1..<last {
            let s = sources[k]
            let step = s - sources[k - 1]
            let lower = max(fMin * s, duration - fMax * (duration - s), edits[k - 1] + fMin * step)
            let upper = min(fMax * s, duration - fMin * (duration - s), edits[k - 1] + fMax * step)
            edits[k] = min(max(edits[k], lower), upper)
        }

        // (5) The strictness guard.
        var keptSources: [Double] = [0]
        var keptEdits: [Double] = [0]
        keptSources.reserveCapacity(sources.count)
        keptEdits.reserveCapacity(sources.count)
        for k in 1..<last {
            let e = edits[k]
            guard e.isFinite, e > keptEdits[keptEdits.count - 1], e < duration else { continue }
            keptSources.append(sources[k])
            keptEdits.append(e)
        }
        keptSources.append(duration)
        keptEdits.append(duration)

        // (6) Against the finished map. `!(… <= tol)` rather than `… > tol`
        // so a NaN could never read as honoured.
        let map = PitchTimeWarp(sourceKnots: keptSources, editedKnots: keptEdits, healed: false)
        let healed = requested.contains { knot in
            !(abs(map.editedSecond(forSourceSecond: knot.source) - knot.edited)
                <= healToleranceSeconds)
        }
        return PitchTimeWarp(sourceKnots: keptSources, editedKnots: keptEdits, healed: healed)
    }

    /// `W(s)`. Linear between knots (binary search), the identity outside
    /// `[0, D]`, and a knot's own edited position exactly at a knot. A
    /// non-finite input returns itself.
    ///
    /// Monotone in IEEE arithmetic too, not only in real arithmetic: the
    /// interpolated value is clamped to its piece's two edited knots, so
    /// rounding can never step backwards across a knot.
    public func editedSecond(forSourceSecond s: Double) -> Double {
        Self.interpolate(s, along: sourceKnots, onto: editedKnots)
    }

    /// `W⁻¹(e)`, the source second heard at edited second `e`. The same rules
    /// as `editedSecond(forSourceSecond:)`, with the axes swapped. Exists
    /// because W is strictly increasing, and the render needs it (C2-3: the
    /// curve lookup and the input schedule).
    public func sourceSecond(forEditedSecond e: Double) -> Double {
        Self.interpolate(e, along: editedKnots, onto: sourceKnots)
    }

    /// The slope of W, edited length over source length, for the piece
    /// containing source second `s`.
    ///
    /// Pieces are `[s_k, s_(k+1))`, and the last piece also owns `D`, so
    /// `localFactor(atSourceSecond: D)` is the last piece's slope. The render's
    /// flush needs that (design §3.4 step 3). Outside `[0, D]`, and for a
    /// non-finite input, the factor is 1 (W is the identity there).
    public func localFactor(atSourceSecond s: Double) -> Double {
        let end = sourceDurationSeconds
        guard s.isFinite, s >= 0, s <= end else { return 1 }
        let i = Self.pieceIndex(of: s, in: sourceKnots)
        return (editedKnots[i + 1] - editedKnots[i]) / (sourceKnots[i + 1] - sourceKnots[i])
    }

    private static func interpolate(_ x: Double, along xs: [Double],
                                    onto ys: [Double]) -> Double {
        guard x.isFinite else { return x }
        // Both anchors are fixed points, so the identity outside (0, D) meets
        // the map continuously.
        guard x > 0, x < xs[xs.count - 1] else { return x }
        let i = pieceIndex(of: x, in: xs)
        let x0 = xs[i], x1 = xs[i + 1]
        let y0 = ys[i], y1 = ys[i + 1]
        let y = y0 + (x - x0) * ((y1 - y0) / (x1 - x0))
        return min(max(y, y0), y1)
    }

    /// The largest `i` in `0...(xs.count − 2)` with `xs[i] <= x`, for
    /// `x >= xs[0]`. `x` at or beyond the last knot answers the last piece.
    private static func pieceIndex(of x: Double, in xs: [Double]) -> Int {
        var low = 0
        var high = xs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if xs[mid] <= x { low = mid } else { high = mid }
        }
        return low
    }
}
