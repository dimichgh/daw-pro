import DAWCore
import Foundation

// m39-w4-4 — THE MUSICAL CLOCK (design `docs/design/2026-10-07-loop-drum-depth.md` §4.2).
//
// A tempo-synced step source needs the WHOLE tempo map for its phase, not one
// tempo for its rate: after a tempo change a rate drifts off the bar lines, and
// inside a loop the roll position keeps counting up. The render thread may not
// consult a `TempoMap` (the TempoSync law), so the main actor compiles the roll
// into a short list of plain values — one `ClockSegment` per stretch of constant
// tempo and constant pattern origin — and the render thread does a binary
// search plus a multiply-add on them.
//
// WHERE THE NUMBERS COME FROM, and why that is the whole design. A MIDI note on
// beat `b` lands on frame `round((offsetSeconds + tempoMap.seconds(from: fromBeat,
// to: b)) · rate)` (`MIDIEventSchedule.buildEvents`), where `offsetSeconds` is 0
// for the head pass and `headSeconds + (k − 1) · cycleSeconds` for loop cycle k
// (`PlaybackGraph.extendLoopMIDI`, `AutomationSchedule.buildLoopUnrolled`). A
// segment stores the SAME `seconds(from:to:)` value for its start, and the render
// thread adds the SAME cycle offset with the SAME expression before the one
// multiply by the rate. So the clock's edge and the MIDI note share their
// arithmetic, and the half-sample offset (`n + 0.5`) turns the MIDI schedule's
// `round` into the clock's boundary: the frame a note lands on reads the step
// that note was written on.
//
// ⚠️ DEPARTURE D1 from §4.2 (recorded in the lane report): loop cycles are NOT
// unrolled into the array. The snapshot keeps the head segments plus ONE cycle
// template and the loop's `headSeconds` / `cycleSeconds`, and the render thread
// derives cycle k's offset from them. An unrolled array would need a republish on
// every loop top-up, and a republish zeroes the envelope follower's published
// levels for one quantum and makes the drum machine re-adopt its targets; it
// would also grow without the §8.6 prune. Evaluating the same expression lazily
// covers every cycle by construction.

extension ModulationSnapshot {
    /// One stretch of the roll with a constant tempo and a constant pattern
    /// origin. POD: no references, no ARC.
    struct ClockSegment: Equatable {
        /// Seconds from the BLOCK's own start beat to this segment's start:
        /// from `fromBeat` for a head segment, from the loop start for a
        /// cycle-template segment. Exactly `tempoMap.seconds(from:to:)`, the
        /// value the MIDI schedule rounds.
        var startSeconds: Double
        /// Project beat at the segment start.
        var startBeat: Double
        /// Constant inside the segment (the tempo map has no ramps).
        var beatsPerSample: Double
        /// Where step 0 sits: song beat 0, or the beat of the last meter change
        /// at or before this segment.
        var patternOriginBeat: Double
    }

    /// The compiled clock a snapshot carries. `segments` holds the head
    /// segments first (`headCount` of them), then the cycle template (the rest)
    /// when the roll loops.
    struct Clock: Equatable {
        var segments: [ClockSegment]
        var headCount: Int
        /// The loop constants the MIDI and automation builders use; 0 when the
        /// roll does not loop.
        var loopHeadSeconds: Double
        var loopCycleSeconds: Double

        /// No clock: every synced source holds neutral.
        static let empty = Clock(segments: [], headCount: 0, loopHeadSeconds: 0, loopCycleSeconds: 0)
    }

    /// Render thread. The musical position of roll sample `n` (`p − originSample`,
    /// never the project-absolute `p`: index the clock by `p` and every roll that
    /// does not start at beat 0 reads the wrong segment).
    ///
    /// Evaluated at the frame CENTRE, `n + 0.5`, for both the segment pick and the
    /// beat (DEPARTURE D2: §4.2 picks the last segment with `floor(start) <= n`,
    /// which at a loop wrap whose exact anchor has a fraction above 0.5 reads the
    /// new cycle one frame before its anchor note, at a negative step position).
    ///
    /// RT-SAFE: integer and Double arithmetic on plain stored values, reads from
    /// an `UnsafeBufferPointer` the snapshot owns, and bounded `while` loops only
    /// (no `for … in` range: at -Onone a range iteration mallocs). Nothing is
    /// carried between calls, so a seek and a loop wrap read exactly what a
    /// playthrough reads. Returns `(0, 0, 0)` with `valid == false` when this
    /// snapshot has no clock.
    @inline(__always)
    func clockPosition(atRollSample n: Int64)
        -> (valid: Bool, beat: Double, beatsPerSample: Double, patternOriginBeat: Double) {
        let headCount = clockHeadCount
        guard headCount > 0, let base = clock.baseAddress else { return (false, 0, 0, 0) }
        let t = Double(n) + 0.5
        let rate = sampleRate
        var first = 0
        var count = headCount
        var blockOffsetSeconds = 0.0
        let cycleCount = clock.count - headCount
        if cycleCount > 0, t >= clockLoopHeadSeconds * rate {
            // Cycle k ≥ 1 starts at (headSeconds + (k − 1)·cycleSeconds)·rate, the
            // builders' own expression. Estimate, then settle with that exact
            // expression (at most two steps each way: the estimate is off by
            // rounding only).
            let estimate = ((t / rate - clockLoopHeadSeconds) / clockLoopCycleSeconds).rounded(.down)
            var cycle: Int64 = estimate.isFinite && estimate >= 0
                ? Int64(min(estimate, 4.0e15)) &+ 1 : 1
            var settle = 0
            while cycle > 1, settle < 2,
                  (clockLoopHeadSeconds + Double(cycle &- 1) * clockLoopCycleSeconds) * rate > t {
                cycle &-= 1
                settle += 1
            }
            settle = 0
            while settle < 2,
                  (clockLoopHeadSeconds + Double(cycle) * clockLoopCycleSeconds) * rate <= t {
                cycle &+= 1
                settle += 1
            }
            blockOffsetSeconds = clockLoopHeadSeconds + Double(cycle &- 1) * clockLoopCycleSeconds
            first = headCount
            count = cycleCount
        }
        // The last segment in [first, first + count) whose exact start is at or
        // before t. The block's first segment starts at the block start, so it is
        // the answer for t before every later start (and extrapolates for t < 0).
        var result = first
        var low = first + 1
        var high = first + count - 1
        while low <= high {
            let mid = (low + high) >> 1
            if (blockOffsetSeconds + base[mid].startSeconds) * rate <= t {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let segment = base[result]
        let start = (blockOffsetSeconds + segment.startSeconds) * rate
        return (true, segment.startBeat + (t - start) * segment.beatsPerSample,
                segment.beatsPerSample, segment.patternOriginBeat)
    }
}

/// Everything a strip's clock is derived from — the publish key's clock
/// fingerprint (§4.2: "the tempo-map events, meter-map events, loop region and
/// on/off, and `fromBeat`"). nil in the key when the strip has no synced
/// source, so every strip without one keeps exactly its old publish behaviour.
struct ModulationClockSpec: Equatable {
    struct Loop: Equatable {
        var startBeat: Double
        var endBeat: Double
        /// `LoopUnrollState.headSeconds` / `.cycleSeconds`, the SAME Doubles the
        /// MIDI cycle blocks are placed with — never recomputed here.
        var headSeconds: Double
        var cycleSeconds: Double
    }

    var fromBeat: Double
    var tempoMap: TempoMap
    var meterMap: MeterMap
    var loop: Loop?
    var sampleRate: Double
}

extension ModulationSnapshotBuilder {
    /// Whether any source on the strip is tempo-synced — the one question that
    /// decides whether the publish key carries a clock. Asked of `TempoSync`'s
    /// sibling table (m39-w4-4), which registers the step sequencer only.
    static func hasSyncedSource(_ strip: Strip) -> Bool {
        strip.sources.prefix(ModulationLimits.maxSources).contains { source in
            TempoSync.syncedDivision(of: source.params) != nil
        }
    }

    /// Compiles the clock on the main actor (§4.2). Segments split at the roll
    /// anchor, every tempo change and every meter change (which also moves the
    /// pattern origin) inside the head pass; a looping roll adds one cycle
    /// template split the same way inside [loop start, loop end). Returns
    /// `.empty` for anything the render thread could not use (a non-finite or
    /// non-positive rate, an empty span), so a synced source holds neutral
    /// rather than reading garbage.
    static func compileClock(_ spec: ModulationClockSpec) -> ModulationSnapshot.Clock {
        guard spec.sampleRate.isFinite, spec.sampleRate > 0, spec.fromBeat.isFinite else { return .empty }
        var usableLoop = spec.loop
        if let candidate = usableLoop {
            let usable = candidate.headSeconds.isFinite && candidate.headSeconds > 0
                && candidate.cycleSeconds.isFinite && candidate.cycleSeconds > 0
                && candidate.endBeat > candidate.startBeat && candidate.endBeat > spec.fromBeat
            if !usable { usableLoop = nil }
        }
        let head = segments(from: spec.fromBeat, to: usableLoop?.endBeat ?? .infinity, spec: spec)
        guard !head.isEmpty else { return .empty }
        guard let loop = usableLoop else {
            return ModulationSnapshot.Clock(segments: head, headCount: head.count,
                                            loopHeadSeconds: 0, loopCycleSeconds: 0)
        }
        let cycle = segments(from: loop.startBeat, to: loop.endBeat, spec: spec)
        guard !cycle.isEmpty else {
            return ModulationSnapshot.Clock(segments: head, headCount: head.count,
                                            loopHeadSeconds: 0, loopCycleSeconds: 0)
        }
        return ModulationSnapshot.Clock(segments: head + cycle, headCount: head.count,
                                        loopHeadSeconds: loop.headSeconds,
                                        loopCycleSeconds: loop.cycleSeconds)
    }

    /// One block's segments over [start, end): a boundary at `start`, then one at
    /// every tempo change and meter change strictly inside. Seconds are measured
    /// from `start` with `tempoMap.seconds(from:to:)`, the MIDI schedule's own
    /// call; the rate per segment comes from `framesPerBeat`, the tempo file's
    /// sanctioned frames-per-beat (no tempo arithmetic is written here).
    private static func segments(from start: Double, to end: Double,
                                 spec: ModulationClockSpec) -> [ModulationSnapshot.ClockSegment] {
        var boundaries: [Double] = [start]
        for segment in spec.tempoMap.segments where segment.startBeat > start && segment.startBeat < end {
            boundaries.append(segment.startBeat)
        }
        for change in spec.meterMap.changes where change.startBeat > start && change.startBeat < end {
            boundaries.append(change.startBeat)
        }
        boundaries.sort()
        var result: [ModulationSnapshot.ClockSegment] = []
        for beat in boundaries where result.last?.startBeat != beat {
            let framesPerBeat = spec.tempoMap.framesPerBeat(atBeat: beat, sampleRate: spec.sampleRate)
            guard framesPerBeat.isFinite, framesPerBeat > 0 else { return [] }
            // m39-w4-4c: the pattern origin's one home, which `mod.describe`
            // reads too (`ModulationMath.syncedStepValue`).
            let origin = spec.meterMap.patternOriginBeat(atBeat: beat)
            result.append(ModulationSnapshot.ClockSegment(
                startSeconds: spec.tempoMap.seconds(from: start, to: beat),
                startBeat: beat,
                beatsPerSample: 1 / framesPerBeat,
                patternOriginBeat: origin))
        }
        return result
    }
}
