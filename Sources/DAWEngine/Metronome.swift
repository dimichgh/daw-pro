import AVFAudio
import DAWCore
import Foundation

/// Metronome click source: one `AVAudioPlayerNode` fed from two precomputed
/// click buffers (downbeat / other beat), scheduled at player-relative sample
/// times with the SAME timeline convention as clips — player time 0 ≡ the
/// `playerStartBeat` transport position. Drives both the live `AudioEngine`
/// (started on the shared player anchor) and the `OfflineRenderer` (nil
/// anchor), so click placement is testable sample-accurately offline.
///
/// All scheduling is main-actor control-thread work, exactly like clip
/// scheduling in `PlaybackGraph` — nothing here ever runs on the render
/// thread. Buffers are synthesized once per sample rate (no per-click
/// allocation while rolling; top-ups only enqueue existing buffers).
@MainActor
final class Metronome {
    /// Downbeat: bright and louder. Other beats: lower and softer.
    private static let downbeatHz = 1_600.0
    private static let downbeatAmp: Float = 0.5
    private static let beatHz = 1_000.0
    private static let beatAmp: Float = 0.35
    /// 30 ms tick, 5 ms linear attack, exponential decay (τ = 5 ms) after.
    private static let clickSeconds = 0.030
    private static let attackSeconds = 0.005
    private static let decayTau = 0.005

    /// How far ahead the live engine keeps clicks scheduled, and the
    /// remaining-schedule threshold below which the playhead task tops up.
    static let topUpChunkBeats = 64.0
    static let topUpThresholdBeats = 16.0

    private let player = AVAudioPlayerNode()
    private weak var attachedEngine: AVAudioEngine?
    private var downbeatBuffer: AVAudioPCMBuffer?
    private var beatBuffer: AVAudioPCMBuffer?
    /// Sample rate the click buffers (and the player connection) were built
    /// for; buffers regenerate when `attach` sees a different graph rate.
    private var sampleRate: Double = 0

    // Scheduling state remembered from the last scheduleClicks call so
    // topUp(currentBeat:) can extend the queue with identical parameters.
    // m12-b (design row 45): the MAP values (tempo + meter) are cached
    // instead of scalars so top-ups extend under the same mapping the run
    // started with.
    private(set) var scheduledThroughBeat: Double = 0
    private var playerStartBeat: Double = 0
    private var tempoMap = TempoMap(constantBPM: 120)
    private var meterMap = MeterMap(constant: TimeSignature())
    /// Test seam (m15-a): the meter map the last schedule call handed this
    /// player — lets the plumbing pin prove production passes the REAL map
    /// (the m14-c unit pins prove a real map renders correct clicks).
    var receivedMeterMap: MeterMap { meterMap }
    /// True only after scheduleClicks (open-ended LINEAR click run). A
    /// count-in-only schedule leaves this false so the player just drains and
    /// goes silent; a loop-mode run (`scheduleLoopClicks`) leaves it false
    /// too — its queue is bounded by the loop end BY DESIGN (the timeline
    /// law) and extends per cycle via `topUpLoopCycles`, never per beat.
    private var topUpEnabled = false

    /// Loop click plan (m14-c L-3, design-m13f-gapless-loop §4-A
    /// "Metronome"): armed by `scheduleLoopClicks`, consumed by
    /// `topUpLoopCycles` on the same playhead cadence as the audio/MIDI
    /// unroll. Cycle placement derives from `headSeconds`/`cycleSeconds` —
    /// map integrals evaluated ONCE, so every click anchor is the absolute
    /// integral (design §8.2, the m12-c discipline), never
    /// `previous + cycleFrames`.
    private struct LoopClickPlan {
        let startBeat: Double
        let endBeat: Double
        /// Player-relative seconds at which cycle 1 begins (integral from
        /// `playerStartBeat` to the loop end — the cycle-0 head pass).
        let headSeconds: Double
        /// Exact loop period: the map integral over [startBeat, endBeat).
        let cycleSeconds: Double
        /// Whole unrolled cycles queued so far (0 = only the head pass).
        var scheduledThroughCycle: Int
    }

    private var loopPlan: LoopClickPlan?

    /// Test seam (the `PlaybackGraph.loopScheduledThroughCycle` twin): how
    /// many full click cycles are queued; nil = no loop plan armed.
    var loopScheduledThroughCycle: Int? { loopPlan?.scheduledThroughCycle }
    /// Test seam (m15-b G6): the armed loop plan's head — under a count-in
    /// loop record this must be `delaySeconds + integral(recordBeat →
    /// loopEnd)` (the LOOKUP pre-roll policy), never an integral across the
    /// pre-roll span. nil = no loop plan armed.
    var loopPlanHeadSecondsForTesting: Double? { loopPlan?.headSeconds }

    // MARK: - Graph membership

    /// Attaches the player to `engine`, connected to mainMixerNode at the
    /// graph rate (same explicit-format rule as PlaybackGraph's track mixers:
    /// `format: nil` would force a second SRC and break sample accuracy).
    /// Click buffers are (re)built here when the rate changed. Idempotent.
    func attach(to engine: AVAudioEngine) {
        guard player.engine == nil else { return }
        let graphRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = graphRate > 0 ? graphRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        attachedEngine = engine
        if rate != sampleRate {
            sampleRate = rate
            downbeatBuffer = Self.makeClickBuffer(
                format: format, frequency: Self.downbeatHz, amplitude: Self.downbeatAmp
            )
            beatBuffer = Self.makeClickBuffer(
                format: format, frequency: Self.beatHz, amplitude: Self.beatAmp
            )
        }
    }

    func detach() {
        guard let engine = attachedEngine, player.engine != nil else { return }
        player.stop()
        engine.detach(player)
        attachedEngine = nil
    }

    // MARK: - Scheduling (control thread only)

    /// Pure count-in arithmetic, extracted for headless testing: how long the
    /// record anchor is delayed and how many count-in clicks fill the gap.
    /// m12-b (design row 42): the pre-roll runs at the SEGMENT AT THE RECORD
    /// BEAT's tempo — a LOOKUP by policy (count-in precedes the record beat
    /// in wall time; the beat domain does not extend backward across it).
    /// m15-a: bar LENGTH anchors the same way — the METER AT THE RECORD BEAT
    /// (`meterMap.beatsPerBar(atBeat:)`, the real map, not the base scalar):
    /// recording into a 3/4 region counts one 3-beat bar per `countInBars`,
    /// wherever that region sits in the map.
    static func countInPlan(
        countInBars: Int, meterMap: MeterMap, tempoMap: TempoMap, atBeat beat: Double
    ) -> (delaySeconds: Double, clickBeats: Int) {
        let clickBeats = max(0, countInBars) * max(1, meterMap.beatsPerBar(atBeat: beat))
        return (Double(clickBeats) * tempoMap.secondsPerBeat(atBeat: beat), clickBeats)
    }

    /// Schedules one click per integer beat in [ceil(fromBeat), throughBeat)
    /// at player-relative sample time = the tempo-map integral from
    /// `playerStartBeat` to the click beat, × rate (m12-b, design row 43;
    /// trivial-map arithmetic identical to the old fixed spb). Downbeat
    /// buffer when the click falls on a MeterMap barline. Remembers the
    /// parameters so `topUp` can extend the run.
    func scheduleClicks(fromBeat: Double, throughBeat: Double, tempoMap: TempoMap,
                        meterMap: MeterMap, playerStartBeat: Double) {
        self.tempoMap = tempoMap
        self.meterMap = meterMap
        self.playerStartBeat = playerStartBeat
        enqueueClicks(fromBeat: fromBeat, throughBeat: throughBeat,
                      baseBeat: playerStartBeat, offsetSeconds: 0)
        scheduledThroughBeat = max(scheduledThroughBeat, throughBeat)
        topUpEnabled = true
    }

    /// One click per integer beat in [ceil(fromBeat), throughBeat) at
    /// player-relative seconds `offsetSeconds + integral(baseBeat → beat)` —
    /// the shared body of the linear run (base = playerStartBeat, offset 0;
    /// arithmetic bit-identical to the pre-m14-c inline loop: `0 + x == x`)
    /// and the per-cycle loop unroll (base = loop start, offset = the cycle's
    /// absolute start). ONE `.rounded()` happens downstream in `schedule`.
    private func enqueueClicks(fromBeat: Double, throughBeat: Double,
                               baseBeat: Double, offsetSeconds: Double) {
        var beat = fromBeat.rounded(.up)
        while beat < throughBeat {
            // Downbeat = the click sits on a MeterMap barline (design row 43;
            // click beats are integers, so beatInBar is exact — 0.0 on the
            // barline, identical to the old `beat % beatsPerBar == 0`).
            let isDownbeat = meterMap.barBeat(atBeat: beat.rounded()).beatInBar == 0
            schedule(downbeat: isDownbeat,
                     atSeconds: offsetSeconds + tempoMap.seconds(from: baseBeat, to: beat))
            beat += 1
        }
    }

    /// Loop-mode click run (m14-c L-3): schedules the head pass
    /// [fromBeat, loopEndBeat) and arms the per-cycle unroll — cycle k ≥ 1
    /// re-schedules the clicks of [loopStartBeat, loopEndBeat) at the
    /// absolute integral `headSeconds + (k − 1) · cycleSeconds`. The queue
    /// deliberately stops at the loop end (the timeline law: the map past
    /// the boundary never leaks into clicks); `topUpLoopCycles` extends it
    /// whole cycles at a time on the playhead cadence. Downbeat selection
    /// uses ABSOLUTE transport beats, so the meter pattern of every cycle is
    /// identical to the head pass by construction.
    ///
    /// `countInDelaySeconds` (m15-b, design-m15b §5.4b): a count-in loop
    /// RECORD start pre-rolls the click player by the count-in before the
    /// transport anchor. The pre-roll is a record-beat LOOKUP by policy
    /// (`countInPlan`) — the beat domain does not extend backward across it —
    /// so it arrives here as an explicit player-time offset, NEVER as a map
    /// integral across the pre-roll span: every head-pass click sits at
    /// `delay + integral(playerStartBeat → beat)` and every cycle anchor at
    /// `delay + integral(playerStartBeat → loopEnd) + (k − 1) · L`. 0 (the
    /// default) is arithmetic-identical to the m14-c shape (`0 + x == x`).
    func scheduleLoopClicks(fromBeat: Double, loopStartBeat: Double, loopEndBeat: Double,
                            tempoMap: TempoMap, meterMap: MeterMap,
                            playerStartBeat: Double, countInDelaySeconds: Double = 0) {
        self.tempoMap = tempoMap
        self.meterMap = meterMap
        self.playerStartBeat = playerStartBeat
        enqueueClicks(fromBeat: fromBeat, throughBeat: loopEndBeat,
                      baseBeat: playerStartBeat, offsetSeconds: countInDelaySeconds)
        loopPlan = LoopClickPlan(
            startBeat: loopStartBeat,
            endBeat: loopEndBeat,
            headSeconds: countInDelaySeconds
                + tempoMap.seconds(from: playerStartBeat, to: loopEndBeat),
            cycleSeconds: tempoMap.seconds(from: loopStartBeat, to: loopEndBeat),
            scheduledThroughCycle: 0
        )
    }

    /// Extends the click queue whole loop cycles at a time (m14-c L-3),
    /// with the SAME eager target arithmetic as the graph's audio/MIDI
    /// unroll (`PlaybackGraph.topUpLoopCycles`): ≥ sounding-cycle + 2 AND
    /// horizon coverage. The design §8 modes 8–9 containment applies to THIS
    /// player too — it is an AVAudioPlayerNode: the eager rule keeps its
    /// queue holding ≥ one full future cycle (never drained), and for short
    /// cycles the coverage term puts every enqueue ≥ horizon − tick ahead of
    /// its anchor (above the ~2.5k-frame mid-flight lead cliff). No-op
    /// without an armed plan (linear runs ride `topUp`; a disabled metronome
    /// cleared the plan in `stop`).
    func topUpLoopCycles(elapsedPlayerSeconds: Double, horizonSeconds: Double) {
        guard let plan = loopPlan else { return }
        let soundingCycle = elapsedPlayerSeconds < plan.headSeconds
            ? 0
            : 1 + Int(((elapsedPlayerSeconds - plan.headSeconds) / plan.cycleSeconds)
                .rounded(.down))
        var target = soundingCycle + 2
        // Cycles needed so coverage (head + k·cycle) reaches elapsed + horizon.
        let coverage = elapsedPlayerSeconds + horizonSeconds
        if plan.headSeconds + Double(target) * plan.cycleSeconds < coverage {
            target = Int(((coverage - plan.headSeconds) / plan.cycleSeconds)
                .rounded(.up))
        }
        guard target > plan.scheduledThroughCycle else { return }
        for cycle in (plan.scheduledThroughCycle + 1)...target {
            // THE ANCHOR LAW (design §8.2, C3): the cycle start is the
            // absolute integral headSeconds + (cycle − 1) · cycleSeconds —
            // computed fresh from the plan constants every time, never
            // accumulated from a previous anchor.
            enqueueClicks(
                fromBeat: plan.startBeat, throughBeat: plan.endBeat,
                baseBeat: plan.startBeat,
                offsetSeconds: plan.headSeconds
                    + Double(cycle - 1) * plan.cycleSeconds)
        }
        loopPlan?.scheduledThroughCycle = target
    }

    /// Schedules `clickBeats` count-in clicks player-relative from time 0 —
    /// the count-in bar pattern is position-independent (the first click of
    /// each count-in bar is the downbeat), unlike scheduleClicks' absolute
    /// transport-beat pattern. Click spacing uses the record-beat segment's
    /// tempo, and bar length the record-beat METER (both the countInPlan
    /// LOOKUP policy — m12-b design row 44, m15-a). Does NOT enable top-up:
    /// a count-in-only run (metronome disabled) simply ends after the last
    /// click.
    func scheduleCountIn(clickBeats: Int, tempoMap: TempoMap, atBeat recordBeat: Double,
                         meterMap: MeterMap) {
        let secondsPerBeat = tempoMap.secondsPerBeat(atBeat: recordBeat)
        let bar = max(1, meterMap.beatsPerBar(atBeat: recordBeat))
        for beat in 0..<max(0, clickBeats) {
            schedule(downbeat: beat % bar == 0, atSeconds: Double(beat) * secondsPerBeat)
        }
    }

    /// Called from the live engine's playhead task (~30 Hz): extends the
    /// click queue by `topUpChunkBeats` whenever the playhead is within
    /// `topUpThresholdBeats` of the scheduled end. No-op for count-in-only
    /// runs, after stop(), and for loop-mode runs (those extend whole cycles
    /// via `topUpLoopCycles` instead — m14-c L-3).
    func topUp(currentBeat: Double) {
        guard topUpEnabled,
              currentBeat > scheduledThroughBeat - Self.topUpThresholdBeats else { return }
        scheduleClicks(
            fromBeat: scheduledThroughBeat,
            throughBeat: scheduledThroughBeat + Self.topUpChunkBeats,
            tempoMap: tempoMap, meterMap: meterMap, playerStartBeat: playerStartBeat
        )
    }

    /// Starts the player against the shared anchor (nil for manual rendering:
    /// player time 0 ≡ the first rendered sample, same as clip players).
    func start(at anchor: AVAudioTime?) {
        guard player.engine != nil else { return }
        player.prepare(withFrameCount: 8_192)
        player.play(at: anchor)
    }

    /// Stops the player — AVAudioPlayerNode semantics clear the scheduled
    /// queue and reset player time to 0, which the restart primitive relies
    /// on. Also disarms the loop plan (m14-c): a stopped click player must
    /// never keep unrolling — the live disable path is exactly this call,
    /// player-local, clip audio untouched (design §6).
    func stop() {
        guard player.engine != nil else { return }
        player.stop()
        scheduledThroughBeat = 0
        topUpEnabled = false
        loopPlan = nil
    }

    private func schedule(downbeat: Bool, atSeconds seconds: Double) {
        guard let buffer = downbeat ? downbeatBuffer : beatBuffer, sampleRate > 0 else { return }
        let sampleTime = AVAudioFramePosition((seconds * sampleRate).rounded())
        guard sampleTime >= 0 else { return }  // clicks before player time 0 can't sound
        // completionHandler stays nil by design — same rule as clip
        // scheduling: callbacks fire on non-main threads and we never need
        // end-of-click signals.
        player.scheduleBuffer(
            buffer,
            at: AVAudioTime(sampleTime: sampleTime, atRate: sampleRate),
            options: [],
            completionHandler: nil
        )
    }

    // MARK: - Click synthesis

    /// One stereo (identical channels) Float32 click: 30 ms sine, 5 ms linear
    /// attack, exponential decay (τ = 5 ms → last sample ≈ −43 dB relative to
    /// the peak, no audible cutoff step). Generated once per sample rate.
    static func makeClickBuffer(
        format: AVAudioFormat, frequency: Double, amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frameCount = AVAudioFrameCount((clickSeconds * rate).rounded())
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / rate
            let envelope: Double = time < attackSeconds
                ? time / attackSeconds
                : exp(-(time - attackSeconds) / decayTau)
            let sample = amplitude * Float(envelope * sin(2.0 * .pi * frequency * time))
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }
}
