import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Metronome proof, fully offline: clicks render through the same Metronome
/// the live engine uses, then get assertion-checked for placement (±10 ms),
/// pitch (downbeat 1600 Hz vs beat 1000 Hz via zero crossings), meter
/// (downbeat every beatsPerBar), and count-in arithmetic.
@MainActor
@Suite("Metronome — offline render", .serialized)
struct MetronomeTests {
    // M1.
    @Test("2 s @120 BPM: click energy at 0/0.5/1.0/1.5 s, near-silence between")
    func clickPlacement() throws {
        let audio = try OfflineRenderer().render(
            tracks: [], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.0,
            metronomeEnabled: true
        )
        let left = audio.channelData[0]
        let rate = audio.sampleRate
        #expect(rate == 48_000)
        #expect(left.count == 96_000)

        // Denormal/NaN guard: every rendered sample must be finite.
        #expect(left.allSatisfy { $0.isFinite })
        // Stereo click: identical channels by construction.
        #expect(left == audio.channelData[1])

        for (index, seconds) in [0.0, 0.5, 1.0, 1.5].enumerated() {
            let center = Int(seconds * rate)
            let window = max(0, center - 480)..<min(left.count, center + 480)  // ±10 ms
            let peak = TestSignals.peak(left, in: window)
            #expect(peak > 0.1, "click \(index) at \(seconds)s: peak \(peak)")

            // Measured onset: first frame above 0.05 near the expected click.
            let search = max(0, center - 480)..<min(left.count, center + 1_440)
            if let onset = left[search].firstIndex(where: { abs($0) > 0.05 }) {
                let deltaMs = Double(onset - center) / rate * 1_000
                print("[measured] metronome click \(index) onset: frame \(onset) "
                      + "(expected \(center)), delta \(onset - center) frames "
                      + String(format: "(%.3f ms)", deltaMs))
                #expect(abs(onset - center) <= Int(0.010 * rate))
            } else {
                Issue.record("no onset found near click \(index) at \(seconds)s")
            }
        }

        // Between-click windows: click tails (30 ms + exp decay) are long gone.
        for (start, end) in [(0.15, 0.45), (0.65, 0.95), (1.15, 1.45), (1.65, 1.95)] {
            let window = Int(start * rate)..<Int(end * rate)
            let peak = TestSignals.peak(left, in: window)
            #expect(peak < 0.01, "expected near-silence in \(start)–\(end)s, peak \(peak)")
        }
    }

    // M2.
    @Test("downbeat clicks at 1600 Hz, other beats at 1000 Hz")
    func downbeatPitch() throws {
        let audio = try OfflineRenderer().render(
            tracks: [], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.0,
            metronomeEnabled: true
        )
        let left = audio.channelData[0]

        // Windows sit inside each 30 ms click (2–25 ms past the onset); the
        // envelope is strictly positive there, so zero crossings are the pure
        // sine's — the estimator reads the true frequency.
        let downbeat = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: 48_000, in: 96..<1_200
        )
        let beat = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: 48_000, in: 24_096..<25_200
        )
        print("[measured] metronome downbeat \(downbeat) Hz (expected 1600), "
              + "beat \(beat) Hz (expected 1000)")
        #expect(abs(downbeat - 1_600) < 10)
        #expect(abs(beat - 1_000) < 10)
    }

    // M3.
    @Test("3/4 time: downbeats every 3 beats")
    func threeFourDownbeats() throws {
        let audio = try OfflineRenderer().render(
            tracks: [], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.5,
            metronomeEnabled: true, beatsPerBar: 3
        )
        let left = audio.channelData[0]

        // Beats 0..4 land at 0/0.5/1.0/1.5/2.0 s; in 3/4, beats 0 and 3 are
        // downbeats (1600 Hz), the rest are 1000 Hz.
        let expectations: [(beat: Int, hz: Double)] = [
            (0, 1_600), (1, 1_000), (2, 1_000), (3, 1_600), (4, 1_000),
        ]
        for (beat, hz) in expectations {
            let start = beat * 24_000
            let frequency = TestSignals.dominantFrequency(
                byZeroCrossings: left, sampleRate: 48_000, in: (start + 96)..<(start + 1_200)
            )
            print("[measured] 3/4 beat \(beat): \(frequency) Hz (expected \(hz))")
            #expect(abs(frequency - hz) < 10, "beat \(beat)")
        }
    }

    @Test("click buffer: 30 ms stereo, peak bounded by amplitude, all finite")
    func clickBufferSynthesis() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(Metronome.makeClickBuffer(
            format: format, frequency: 1_600, amplitude: 0.5
        ))
        #expect(buffer.frameLength == 1_440)  // 30 ms at 48 kHz

        let channels = try #require(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        let leftSamples = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let rightSamples = Array(UnsafeBufferPointer(start: channels[1], count: frames))
        #expect(leftSamples == rightSamples)  // identical channels
        #expect(leftSamples.allSatisfy { $0.isFinite })
        let peak = leftSamples.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak <= 0.5)  // 5 ms attack reaches ≈ full amplitude
        // Decay leaves no audible cutoff step at the buffer edge.
        #expect(abs(leftSamples[frames - 1]) < 0.01)
    }

    /// Count-in arithmetic (pure): the delayed-anchor gap and click count the
    /// live engine derives in startPlayers. The full count-in path (delayed
    /// writer anchor + audible pre-roll) is covered by live E2E.
    @Test("countInPlan: delay = bars × beatsPerBar × 60/tempo, one click per beat")
    func countInPlan() {
        let two44 = Metronome.countInPlan(countInBars: 2, beatsPerBar: 4, tempoMap: TempoMap(constantBPM: 120), atBeat: 0)
        #expect(two44.delaySeconds == 4.0)  // 8 beats × 0.5 s
        #expect(two44.clickBeats == 8)

        let one34 = Metronome.countInPlan(countInBars: 1, beatsPerBar: 3, tempoMap: TempoMap(constantBPM: 90), atBeat: 0)
        #expect(abs(one34.delaySeconds - 2.0) < 1e-12)  // 3 beats × ⅔ s
        #expect(one34.clickBeats == 3)

        let zero = Metronome.countInPlan(countInBars: 0, beatsPerBar: 4, tempoMap: TempoMap(constantBPM: 120), atBeat: 0)
        #expect(zero.delaySeconds == 0)
        #expect(zero.clickBeats == 0)

        // Defensive: nonsense inputs never produce a negative delay.
        let negative = Metronome.countInPlan(countInBars: -2, beatsPerBar: 4, tempoMap: TempoMap(constantBPM: 120), atBeat: 0)
        #expect(negative.delaySeconds == 0)
        #expect(negative.clickBeats == 0)
    }
}
