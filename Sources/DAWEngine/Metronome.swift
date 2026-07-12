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
    /// True only after scheduleClicks (open-ended click run). A count-in-only
    /// schedule leaves this false so the player just drains and goes silent.
    private var topUpEnabled = false

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
    static func countInPlan(
        countInBars: Int, beatsPerBar: Int, tempoMap: TempoMap, atBeat beat: Double
    ) -> (delaySeconds: Double, clickBeats: Int) {
        let clickBeats = max(0, countInBars) * max(1, beatsPerBar)
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
        var beat = fromBeat.rounded(.up)
        while beat < throughBeat {
            // Downbeat = the click sits on a MeterMap barline (design row 43;
            // click beats are integers, so beatInBar is exact — 0.0 on the
            // barline, identical to the old `beat % beatsPerBar == 0`).
            let isDownbeat = meterMap.barBeat(atBeat: beat.rounded()).beatInBar == 0
            schedule(downbeat: isDownbeat,
                     atSeconds: tempoMap.seconds(from: playerStartBeat, to: beat))
            beat += 1
        }
        scheduledThroughBeat = max(scheduledThroughBeat, throughBeat)
        topUpEnabled = true
    }

    /// Schedules `clickBeats` count-in clicks player-relative from time 0 —
    /// the count-in bar pattern is position-independent (the first click of
    /// each count-in bar is the downbeat), unlike scheduleClicks' absolute
    /// transport-beat pattern. Click spacing uses the record-beat segment's
    /// tempo (the countInPlan LOOKUP policy, m12-b design row 44). Does NOT
    /// enable top-up: a count-in-only run (metronome disabled) simply ends
    /// after the last click.
    func scheduleCountIn(clickBeats: Int, tempoMap: TempoMap, atBeat recordBeat: Double,
                         beatsPerBar: Int) {
        let secondsPerBeat = tempoMap.secondsPerBeat(atBeat: recordBeat)
        let bar = max(1, beatsPerBar)
        for beat in 0..<max(0, clickBeats) {
            schedule(downbeat: beat % bar == 0, atSeconds: Double(beat) * secondsPerBeat)
        }
    }

    /// Called from the live engine's playhead task (~30 Hz): extends the
    /// click queue by `topUpChunkBeats` whenever the playhead is within
    /// `topUpThresholdBeats` of the scheduled end. No-op for count-in-only
    /// runs and after stop().
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
    /// queue and reset player time to 0, which the restart primitive relies on.
    func stop() {
        guard player.engine != nil else { return }
        player.stop()
        scheduledThroughBeat = 0
        topUpEnabled = false
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
