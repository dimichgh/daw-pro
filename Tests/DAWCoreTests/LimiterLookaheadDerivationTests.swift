import DAWCore
import Testing

/// m23-ab-1 — the ONE HOME for the built-in limiter's fixed 5 ms lookahead
/// delay, expressed in samples at a given rate. `LimiterEffect.prepare` and
/// every test that needs the expected `latencySamples`/`outputLatencySamples`
/// MUST route through `LimiterParams.lookaheadSamples(sampleRate:)` rather
/// than hardcoding a rate-specific constant — 240 is only
/// `round(0.005 × 48_000)`, true at 48 kHz and nowhere else.
///
/// This suite exercises the derivation DIRECTLY, as a pure function, at
/// three rates that never involve the machine's audio device (no
/// `AudioEngine`, no `AVAudioEngine`, no hardware). It is therefore honest
/// regardless of what device is plugged in when it runs — unlike a
/// full-suite pass on a machine whose device happens to sit at 48 kHz,
/// which cannot distinguish the correct derivation from the literal-240
/// bug it replaces (`ReferenceLaneTransparencyTests:390/425`, fixed
/// alongside this suite).
@Suite("Limiter lookahead sample derivation (m23-ab-1)")
struct LimiterLookaheadDerivationTests {
    /// Expected sample counts are independently stated per rate — NOT
    /// re-derived from the production formula here — so a mutation that
    /// restores the 48 kHz literal (240) into `lookaheadSamples` reddens
    /// this leg at 44100 and 96000 while staying accidentally correct at
    /// 48000. 44100 is included specifically because it is the rate that
    /// exposed the original bug: round(0.005 × 44100) = 221, not 240.
    @Test(
        "delaySamples = round(5ms lookahead × rate), pinned per rate",
        arguments: [
            (sampleRate: 44_100.0, expectedSamples: 221),
            (sampleRate: 48_000.0, expectedSamples: 240),
            (sampleRate: 96_000.0, expectedSamples: 480),
        ]
    )
    func lookaheadSamplesAtRate(sampleRate: Double, expectedSamples: Int) {
        #expect(LimiterParams.lookaheadSamples(sampleRate: sampleRate) == expectedSamples)
    }
}
