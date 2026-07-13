import DAWCore
import Foundation

/// One precomputed automation breakpoint. POD, 24 bytes. `sampleTime` is in
/// frames at the schedule's sample rate, RELATIVE to the schedule anchor
/// (anchor ≡ the transport beat the schedule was built from). Points that lie
/// BEFORE the anchor keep their NEGATIVE times, so a linear segment straddling
/// the start beat interpolates exactly instead of snapping to a boundary
/// value. `holdsSegment` mirrors `AutomationCurve`: true = the segment LEAVING
/// this point holds flat until the next point steps; false = linear ramp.
struct AutomationBreakpoint: Equatable {
    var sampleTime: Int64
    var value: Double
    var holdsSegment: Bool
}

/// One built-in effect-param automation track (M4 vii-c): the breakpoints
/// driving ONE `(effectID, paramSlot)` pair. `paramSlot` is the parameter's
/// index in `EffectParamSpec.specs(for: kind)` — resolved ONCE at build time
/// on the main actor so the render side never touches a String. POD struct;
/// `points` memory is owned by the schedule (freed in its deinit).
struct AutomationEffectParamTrack {
    var effectID: UUID
    var paramSlot: Int32
    var points: UnsafeBufferPointer<AutomationBreakpoint>
}

/// Immutable, render-thread-readable automation schedule for ONE strip
/// (volume + pan lanes, M4 vii-b; built-in effect-param lanes, M4 vii-c).
/// The exact `MIDIEventSchedule` pattern: breakpoints live in memory the
/// schedule allocates in init and frees in deinit — no Swift Array machinery
/// on the render thread. Published to the render side via
/// `AutomationRenderer`'s `daw_atomic_ptr` slot (retained by the slot);
/// displaced schedules are kept alive ≥ 1 s in a main-actor retire bin before
/// release.
///
/// An EMPTY target array means "no automation on this target" (the mixer node
/// keeps that role), never "value 0" — the render side checks `count > 0`
/// before evaluating.
final class AutomationSchedule {
    enum Mode {
        case live(anchorHostTime: UInt64)   // schedule t=0 sounds at this host time
        case offline                        // schedule t=0 ≡ first pulled sample (latched epoch)
    }

    /// A main-actor-side effect-param lane resolved for the build: the target
    /// decomposed to `(effectID, paramSlot)` plus the lane's canonical points.
    /// See `resolveEffectParamLanes(automation:effects:)`.
    struct EffectParamLaneSpec: Equatable {
        var effectID: UUID
        var paramSlot: Int
        var points: [AutomationPoint]
    }

    /// Hard cap on effect-param tracks per strip schedule — must match the
    /// renderer's PREALLOCATED cursor capacity
    /// (`AutomationRenderer.maxEffectParamTracks`); build drops the excess
    /// (64 concurrently automated params on one strip is beyond any real
    /// session).
    static let maxEffectParamTracks = 64

    let generation: UInt64                  // monotonic; render side re-seeks its cursors on change
    /// Timeline identity (m14-b L-2, the `MIDIEventSchedule.timelineID`
    /// contract): schedules sharing a `timelineID` share ONE anchor/epoch —
    /// on a generation change with an UNCHANGED id the renderer re-seeks its
    /// cursors but KEEPS the latched offline epoch (a mid-render loop
    /// extension or lane edit must not shift the timeline); a CHANGED id
    /// re-latches (fresh anchor — every restart). Defaults to `generation`,
    /// so every schedule built without an explicit family id is its own
    /// fresh timeline — the pre-L-2 behavior verbatim.
    let timelineID: UInt64
    let mode: Mode
    let sampleRate: Double
    let volumePoints: UnsafeBufferPointer<AutomationBreakpoint>  // sorted, owned
    let panPoints: UnsafeBufferPointer<AutomationBreakpoint>     // sorted, owned
    /// Effect-param tracks (each with sorted, owned points). Empty when the
    /// strip has no active effect-param lanes.
    let effectParamTracks: UnsafeBufferPointer<AutomationEffectParamTrack>

    init(generation: UInt64, mode: Mode, sampleRate: Double,
         volumePoints: [AutomationBreakpoint], panPoints: [AutomationBreakpoint],
         effectParamTracks: [(effectID: UUID, paramSlot: Int, points: [AutomationBreakpoint])] = [],
         timelineID: UInt64? = nil) {
        self.generation = generation
        self.timelineID = timelineID ?? generation
        self.mode = mode
        self.sampleRate = sampleRate
        self.volumePoints = Self.own(volumePoints)
        self.panPoints = Self.own(panPoints)
        let tracks = effectParamTracks
            .prefix(Self.maxEffectParamTracks)
            .filter { !$0.points.isEmpty }
            .map { track in
                AutomationEffectParamTrack(effectID: track.effectID,
                                           paramSlot: Int32(track.paramSlot),
                                           points: Self.own(track.points))
            }
        self.effectParamTracks = Self.own(tracks)
    }

    deinit {
        if volumePoints.baseAddress != nil {
            UnsafeMutableBufferPointer(mutating: volumePoints).deallocate()
        }
        if panPoints.baseAddress != nil {
            UnsafeMutableBufferPointer(mutating: panPoints).deallocate()
        }
        for track in effectParamTracks where track.points.baseAddress != nil {
            UnsafeMutableBufferPointer(mutating: track.points).deallocate()
        }
        if effectParamTracks.baseAddress != nil {
            UnsafeMutableBufferPointer(mutating: effectParamTracks).deallocate()
        }
    }

    private static func own<Element>(_ elements: [Element]) -> UnsafeBufferPointer<Element> {
        guard !elements.isEmpty else { return UnsafeBufferPointer(start: nil, count: 0) }
        let storage = UnsafeMutableBufferPointer<Element>.allocate(capacity: elements.count)
        _ = storage.initialize(from: elements)
        return UnsafeBufferPointer(storage)
    }

    // MARK: - Build math (main actor / headless-testable, pure)

    /// Maps one lane's canonical points to schedule-relative sample times
    /// under the tempo map (m12-b: the integral from the schedule anchor —
    /// the `MIDIEventSchedule.buildEvents` rule; a tempo change still
    /// restarts → rebuilds). Values arrive store-clamped; beats arrive
    /// canonically ordered and distinct — two beats that round onto the SAME
    /// sample dedupe last-wins here so segments always have positive span.
    static func buildBreakpoints(points: [AutomationPoint], fromBeat: Double,
                                 tempoMap: TempoMap, sampleRate: Double) -> [AutomationBreakpoint] {
        var result: [AutomationBreakpoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            let time = Int64((tempoMap.seconds(from: fromBeat, to: point.beat) * sampleRate).rounded())
            let breakpoint = AutomationBreakpoint(
                sampleTime: time, value: point.value,
                holdsSegment: point.curve == .hold)
            if result.last?.sampleTime == time {
                result[result.count - 1] = breakpoint  // sample-grid dedupe, last wins
            } else {
                result.append(breakpoint)
            }
        }
        return result
    }

    // MARK: - Loop unroll build math (m14-b L-2, design §4-A "Automation")

    /// Pure evaluator over a lane's canonical points — the
    /// `AutomationLane.value(atBeat:)` contract verbatim (before first =
    /// first value, at/after last = last value, `.hold` holds, `.linear`
    /// interpolates), duplicated here as a STATIC over raw points because
    /// effect-param lanes reach the build as `EffectParamLaneSpec.points`.
    /// `points` must be non-empty (the callers' guard).
    static func pointValue(_ points: [AutomationPoint], atBeat beat: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if beat <= first.beat { return first.value }
        if beat >= last.beat { return last.value }
        for i in 0..<(points.count - 1) {
            let lo = points[i]
            let hi = points[i + 1]
            guard beat >= lo.beat, beat < hi.beat else { continue }
            switch lo.curve {
            case .hold:
                return lo.value
            case .linear:
                let span = hi.beat - lo.beat
                guard span > 0 else { return lo.value }
                let t = (beat - lo.beat) / span
                return lo.value + (hi.value - lo.value) * t
            }
        }
        return last.value
    }

    /// Curve of the segment LEAVING `beat`: the last point at/before it
    /// rules; before the first point the region is flat at the first value,
    /// so `.linear` between equal values is exact.
    private static func governingCurve(_ points: [AutomationPoint],
                                       atBeat beat: Double) -> AutomationCurve {
        var curve = AutomationCurve.linear
        for point in points where point.beat <= beat { curve = point.curve }
        return curve
    }

    /// One loop cycle's self-contained breakpoint block: reproduces the lane
    /// curve over the WINDOW [loopStart, loopEnd) with `offsetSeconds` added
    /// in the SECOND DOMAIN before the single rounding (the absolute-integral
    /// discipline, design §8.2/C3). Shape:
    ///  · a synthesized START point at the cycle's first frame — the wrapped
    ///    lane value at `loopStartBeat` with the governing segment's curve
    ///    (points outside the window must never leak across cycles, so every
    ///    cycle re-states its entry value; the loopEnd → loopStart step this
    ///    creates against the previous block IS loop semantics, design §5);
    ///  · the interior points, mapped as ever;
    ///  · a synthesized END point ON the cycle-boundary frame — the exact
    ///    interpolation target for a linear segment leaving the window (both
    ///    endpoints sit on the original beat-domain line). The NEXT block's
    ///    start lands on the same frame after it; `value(at:)` reads the
    ///    last point ≤ t, so the boundary frame belongs to the next cycle.
    /// Same-frame collisions inside the block dedupe last-wins (the
    /// `buildBreakpoints` rule).
    static func buildLoopCycleBreakpoints(
        points: [AutomationPoint], loopStartBeat: Double, loopEndBeat: Double,
        tempoMap: TempoMap, sampleRate: Double, offsetSeconds: Double
    ) -> [AutomationBreakpoint] {
        guard !points.isEmpty else { return [] }
        var result: [AutomationBreakpoint] = []
        func append(beat: Double, value: Double, holds: Bool) {
            let time = Int64(((offsetSeconds
                + tempoMap.seconds(from: loopStartBeat, to: beat)) * sampleRate).rounded())
            let breakpoint = AutomationBreakpoint(sampleTime: time, value: value,
                                                  holdsSegment: holds)
            if result.last?.sampleTime == time {
                result[result.count - 1] = breakpoint  // sample-grid dedupe, last wins
            } else {
                result.append(breakpoint)
            }
        }
        append(beat: loopStartBeat,
               value: pointValue(points, atBeat: loopStartBeat),
               holds: governingCurve(points, atBeat: loopStartBeat) == .hold)
        for point in points where point.beat > loopStartBeat && point.beat < loopEndBeat {
            append(beat: point.beat, value: point.value, holds: point.curve == .hold)
        }
        append(beat: loopEndBeat,
               value: pointValue(points, atBeat: loopEndBeat), holds: false)
        return result
    }

    /// The HEAD pass of a loop-unrolled lane build: linear from `fromBeat`
    /// (points before the anchor keep their negative times — the straddle
    /// interpolation contract), WINDOWED at the loop end (points at/past it
    /// belong to no cycle's timeline), closed by the synthesized boundary
    /// point on the head's end frame — which is exactly cycle 1's start
    /// frame, `round(headSeconds · rate)`.
    static func buildLoopHeadBreakpoints(
        points: [AutomationPoint], fromBeat: Double, loopEndBeat: Double,
        tempoMap: TempoMap, sampleRate: Double
    ) -> [AutomationBreakpoint] {
        guard !points.isEmpty else { return [] }
        var result = buildBreakpoints(points: points.filter { $0.beat < loopEndBeat },
                                      fromBeat: fromBeat, tempoMap: tempoMap,
                                      sampleRate: sampleRate)
        let time = Int64((tempoMap.seconds(from: fromBeat, to: loopEndBeat) * sampleRate).rounded())
        let boundary = AutomationBreakpoint(
            sampleTime: time, value: pointValue(points, atBeat: loopEndBeat),
            holdsSegment: false)
        if result.last?.sampleTime == time {
            result[result.count - 1] = boundary
        } else {
            result.append(boundary)
        }
        return result
    }

    /// Builds one strip's LOOP-UNROLLED schedule: the head block plus one
    /// self-contained block per cycle 1...`throughCycle`, appended in cycle
    /// order — deterministic, so a later build with a larger `throughCycle`
    /// is the previous array plus appended strictly-future blocks (the C2
    /// append-only shape; the renderer re-seeks by value on the generation
    /// change and, with the shared `timelineID`, keeps its offline epoch).
    /// Adjacent blocks deliberately DUPLICATE the boundary frame (end point
    /// then next start point): the pair is load-bearing — the end point is
    /// the interpolation target of the final in-window segment, the start
    /// point owns the boundary frame itself.
    ///
    /// `fromCycle` (§8.6 containment, m14-d L-4): the first cycle to
    /// materialize — 0 (default, pre-containment behavior verbatim) includes
    /// the head block; ≥ 1 drops the head and every earlier cycle's block.
    /// Because each block re-states its entry value on its own first frame,
    /// every value at/after cycle `fromCycle`'s start is identical to the
    /// full build — the suffix-identity law's automation half.
    static func buildLoopUnrolled(
        volumeLane: AutomationLane?, panLane: AutomationLane?,
        effectParamLanes: [EffectParamLaneSpec] = [],
        fromBeat: Double, loopStartBeat: Double, loopEndBeat: Double,
        headSeconds: Double, cycleSeconds: Double,
        fromCycle: Int = 0, throughCycle: Int,
        tempoMap: TempoMap, sampleRate: Double,
        generation: UInt64, mode: Mode, timelineID: UInt64
    ) -> AutomationSchedule? {
        func unrolled(_ points: [AutomationPoint]) -> [AutomationBreakpoint] {
            guard !points.isEmpty else { return [] }
            var result: [AutomationBreakpoint] = []
            if fromCycle <= 0 {
                result = buildLoopHeadBreakpoints(
                    points: points, fromBeat: fromBeat, loopEndBeat: loopEndBeat,
                    tempoMap: tempoMap, sampleRate: sampleRate)
            }
            let firstCycle = max(1, fromCycle)
            guard throughCycle >= firstCycle else { return result }
            for cycle in firstCycle...throughCycle {
                // THE ANCHOR LAW (design §8.2): every cycle offset is the
                // absolute integral from the state constants, never
                // `previous + cycleFrames`.
                let offset = headSeconds + Double(cycle - 1) * cycleSeconds
                result.append(contentsOf: buildLoopCycleBreakpoints(
                    points: points, loopStartBeat: loopStartBeat,
                    loopEndBeat: loopEndBeat, tempoMap: tempoMap,
                    sampleRate: sampleRate, offsetSeconds: offset))
            }
            return result
        }
        let volume = volumeLane.map { unrolled($0.points) } ?? []
        let pan = panLane.map { unrolled($0.points) } ?? []
        let effectTracks = effectParamLanes.map { lane in
            (effectID: lane.effectID, paramSlot: lane.paramSlot,
             points: unrolled(lane.points))
        }
        guard !volume.isEmpty || !pan.isEmpty
            || effectTracks.contains(where: { !$0.points.isEmpty }) else { return nil }
        return AutomationSchedule(generation: generation, mode: mode,
                                  sampleRate: sampleRate,
                                  volumePoints: volume, panPoints: pan,
                                  effectParamTracks: effectTracks,
                                  timelineID: timelineID)
    }

    /// Builds one strip's schedule from its ACTIVE volume/pan lanes and
    /// resolved effect-param lanes, or nil when nothing is automated (nothing
    /// to publish — the mixer node and effect knobs behave exactly as today).
    static func build(volumeLane: AutomationLane?, panLane: AutomationLane?,
                      effectParamLanes: [EffectParamLaneSpec] = [],
                      fromBeat: Double, tempoMap: TempoMap, sampleRate: Double,
                      generation: UInt64, mode: Mode,
                      timelineID: UInt64? = nil) -> AutomationSchedule? {
        let volume = volumeLane.map {
            buildBreakpoints(points: $0.points, fromBeat: fromBeat,
                             tempoMap: tempoMap, sampleRate: sampleRate)
        } ?? []
        let pan = panLane.map {
            buildBreakpoints(points: $0.points, fromBeat: fromBeat,
                             tempoMap: tempoMap, sampleRate: sampleRate)
        } ?? []
        let effectTracks = effectParamLanes.map { lane in
            (effectID: lane.effectID, paramSlot: lane.paramSlot,
             points: buildBreakpoints(points: lane.points, fromBeat: fromBeat,
                                      tempoMap: tempoMap, sampleRate: sampleRate))
        }
        guard !volume.isEmpty || !pan.isEmpty
            || effectTracks.contains(where: { !$0.points.isEmpty }) else { return nil }
        return AutomationSchedule(generation: generation, mode: mode,
                                  sampleRate: sampleRate,
                                  volumePoints: volume, panPoints: pan,
                                  effectParamTracks: effectTracks,
                                  timelineID: timelineID)
    }

    /// Resolves a track's ACTIVE `.effectParam` lanes against its live effect
    /// list to `(effectID, paramSlot)` build specs. UNRESOLVABLE lanes are
    /// silently skipped — INERT by construction (guard rail): a stale lane
    /// whose effect was deleted, an `.audioUnit` effect (empty
    /// `EffectParamSpec` surface in v0, so `firstIndex` misses), or an unknown
    /// param name never reaches the schedule, so the render side cannot even
    /// see it. Main actor / headless-testable, pure.
    static func resolveEffectParamLanes(
        automation: [AutomationLane], effects: [EffectDescriptor]
    ) -> [EffectParamLaneSpec] {
        automation.compactMap { lane in
            guard lane.isEnabled, !lane.points.isEmpty,
                  case .effectParam(let effectID, let paramName) = lane.target,
                  let effect = effects.first(where: { $0.id == effectID }),
                  let slot = EffectParamSpec.specs(for: effect.kind)
                      .firstIndex(where: { $0.name == paramName })
            else { return nil }
            return EffectParamLaneSpec(effectID: effectID, paramSlot: slot,
                                       points: lane.points)
        }
    }

    // MARK: - Evaluation (render thread; also pure/headless-testable)

    /// Greatest index whose breakpoint time is ≤ `t` (0 when `t` precedes the
    /// first point). Bounded binary search — the post-republish re-seek.
    static func seek(points: UnsafeBufferPointer<AutomationBreakpoint>, to t: Int64) -> Int {
        var lo = 0
        var hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].sampleTime <= t { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Evaluates the breakpoint curve at `t` — the sample-domain mirror of
    /// `AutomationLane.value(atBeat:)`: before first = first value, at/after
    /// last = last value, `.hold` holds, `.linear` interpolates. `cursor` is
    /// the caller's per-target segment cursor: pass < 0 (the generation-change
    /// reset) to force a binary-search re-seek; otherwise it only advances —
    /// amortized O(1) per quantum on the monotonic render timeline. A stale
    /// cursor AHEAD of `t` (never expected live; defensive) also re-seeks.
    /// `points` must be non-empty — the empty-target guard is the caller's.
    static func value(at t: Int64, points: UnsafeBufferPointer<AutomationBreakpoint>,
                      cursor: inout Int) -> Double {
        if cursor < 0 || cursor >= points.count || points[cursor].sampleTime > t {
            cursor = seek(points: points, to: t)
        }
        while cursor + 1 < points.count, points[cursor + 1].sampleTime <= t {
            cursor += 1
        }
        let lo = points[cursor]
        if t <= lo.sampleTime { return lo.value }              // before/at segment start
        guard cursor + 1 < points.count else { return lo.value }  // after last
        if lo.holdsSegment { return lo.value }
        let hi = points[cursor + 1]
        let span = hi.sampleTime - lo.sampleTime
        guard span > 0 else { return lo.value }
        let fraction = Double(t - lo.sampleTime) / Double(span)
        return lo.value + (hi.value - lo.value) * fraction
    }
}

extension Array where Element == AutomationLane {
    /// The single ACTIVE lane driving `target`: enabled AND non-empty (an
    /// empty lane is inert — the vii-a contract). At most one lane per target
    /// is store-enforced, so the first match is THE match. This predicate is
    /// the ONE definition of "automation replaces the manual control" — the
    /// schedule build and the `applyParameters` override rule both use it, so
    /// they can never disagree.
    func activeLane(for target: AutomationTarget) -> AutomationLane? {
        first { $0.target == target && $0.isEnabled && !$0.points.isEmpty }
    }
}
