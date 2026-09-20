import Foundation
import Testing
@testable import DAWCore

/// m23-dj — `StereoWidthParams`, the laws that live in DAWCore so the DSP, the
/// tests, the demo note and `fx.describe` all read ONE home.
///
/// ⚠️ NOTHING HERE MEASURES AUDIO. The rendered claims — the mono-sum oracle,
/// the per-channel ripple, the crossover slope, the bit-exact bypass — are in
/// `DAWEngineTests/StereoWidthTests`, and they are where the effect is actually
/// proved. This suite pins the arithmetic those legs quote, plus the two things
/// a struct can get wrong on its own: clamping and an invariant between
/// constants.
@Suite("Stereo width — DAWCore laws (m23-dj)")
struct StereoWidthParamsTests {

    // MARK: - Clamping, and the non-finite guard ahead of it

    @Test("every field clamps to its range, and a NaN falls back to the default rather than propagating")
    func clampingAndNonFiniteGuards() {
        let hot = StereoWidthParams(width: 99, spread: 5, bassMonoHz: 20_000,
                                    bassMonoAmount: 12)
        #expect(hot.width == 2)
        #expect(hot.spread == 1)
        #expect(hot.bassMonoHz == 500)
        #expect(hot.bassMonoAmount == 1)

        let cold = StereoWidthParams(width: -4, spread: -1, bassMonoHz: 0,
                                     bassMonoAmount: -7)
        #expect(cold.width == 0)
        #expect(cold.spread == 0)
        #expect(cold.bassMonoHz == 20)
        #expect(cold.bassMonoAmount == 0)

        // ⚠️ `clamped(to:)` on a NaN RETURNS the NaN — both comparisons inside
        // `min(max(…))` are false against NaN — so the guard has to sit AHEAD
        // of the clamp, not inside it. These values reach a filter coefficient
        // and three gain multiplies on the render thread.
        let nan = StereoWidthParams(width: .nan, spread: .nan, bassMonoHz: .nan,
                                    bassMonoAmount: .nan)
        #expect(nan.width == 1)
        #expect(nan.spread == 0.3)
        #expect(nan.bassMonoHz == 120)
        #expect(nan.bassMonoAmount == 1)

        let infinite = StereoWidthParams(width: .infinity, spread: -.infinity,
                                         bassMonoHz: .infinity,
                                         bassMonoAmount: -.infinity)
        #expect(infinite.width == 1)
        #expect(infinite.spread == 0.3)
        #expect(infinite.bassMonoHz == 120)
        #expect(infinite.bassMonoAmount == 1)
    }

    @Test("the shipped defaults are the documented ones, and they are NOT the neutral position")
    func defaultsAreWhatTheDocsSay() {
        let p = StereoWidthParams()
        #expect(p.width == 1)
        #expect(p.spread == 0.3)
        #expect(p.bassMonoHz == 120)
        #expect(p.bassMonoAmount == 1)
        // ⭐ DELIBERATE: adding this insert with defaults DOES something —
        // it opens a mono source out and it centres the bass. An effect whose
        // default is its own bypass is an effect a user adds and then reports
        // as broken.
        #expect(!StereoWidthParams.isNeutral(width: p.width, spread: p.spread,
                                             bassMonoAmount: p.bassMonoAmount))
    }

    // MARK: - The neutral predicate, which is also the bit-exact bypass

    @Test("isNeutral is exactly width 1 + spread 0 + bassMonoAmount 0, and bassMonoHz is not in it")
    func neutralPredicateIsExact() {
        #expect(StereoWidthParams.isNeutral(width: 1, spread: 0, bassMonoAmount: 0))
        #expect(!StereoWidthParams.isNeutral(width: 1.0000001, spread: 0, bassMonoAmount: 0))
        #expect(!StereoWidthParams.isNeutral(width: 1, spread: 0.0000001, bassMonoAmount: 0))
        #expect(!StereoWidthParams.isNeutral(width: 1, spread: 0, bassMonoAmount: 0.0000001))
        #expect(!StereoWidthParams.isNeutral(width: 0, spread: 0, bassMonoAmount: 0))
        #expect(!StereoWidthParams.isNeutral(width: 2, spread: 0, bassMonoAmount: 0))
        // ⚠️ `bassMonoHz` is absent BY DESIGN: with the amount at 0 the
        // crossover contributes nothing whatever its corner is. Anything
        // positive-controlling the bit-exactness must perturb one of the three
        // above — perturbing the frequency correctly changes nothing, and a
        // gate built on it would read as one that cannot fail.
        #expect(StereoWidthParams.isNeutral(width: 1, spread: 0, bassMonoAmount: 0),
                "the predicate takes no frequency, so no frequency can leave neutral")
    }

    // MARK: - The decorrelator constants and the invariant between them

    /// ⭐ THE INVARIANT THAT MAKES A CONSTANT SAFE TO CHANGE. `prepare()` hands
    /// the longest stage delay to a line declared at `lineCapacitySeconds`, and
    /// the shortest as `minDelaySamples`. Lengthening a stage past the capacity
    /// would truncate silently at 48 kHz and read the write head at 96; this
    /// check is why that is a red test instead of a bug report.
    @Test("decorrelation invariant: the longest stage fits the declared capacity and the shortest is the declared floor")
    func decorrelationInvariantHolds() {
        let delays = StereoWidthParams.decorrelationDelaysMs
        #expect(delays.count == 4)
        let longest = try! #require(delays.max())
        let shortest = try! #require(delays.min())
        print("[measured] m23-dj decorrelator — stages \(delays) ms, "
              + "capacity \(StereoWidthParams.lineCapacitySeconds * 1000) ms, "
              + "floor \(StereoWidthParams.minimumDelayMs) ms")
        #expect(longest * 0.001 <= StereoWidthParams.lineCapacitySeconds,
                "stage \(longest) ms does not fit a \(StereoWidthParams.lineCapacitySeconds) s line")
        #expect(shortest == StereoWidthParams.minimumDelayMs,
                "the declared floor must BE the shortest stage, not a number near it")
        // Not in simple ratios: a chain whose delays share small factors piles
        // its echoes up at one spacing and reads as a slap rather than width.
        for i in 0..<delays.count {
            for j in (i + 1)..<delays.count {
                let ratio = delays[i] / delays[j]
                #expect(abs(ratio - ratio.rounded()) > 0.05,
                        "stages \(delays[i]) and \(delays[j]) are within 5% of an integer ratio")
            }
        }
        // The coefficient has to be inside the stable, non-degenerate band: at
        // 0 the chain is a plain delay (no decorrelation at all) and at 1 it
        // never decays.
        #expect(StereoWidthParams.decorrelationCoefficient > 0.3)
        #expect(StereoWidthParams.decorrelationCoefficient < 0.9)
    }

    @Test("the declared delay floor clears .linear's 1-sample stencil at every rate CoreAudio delivers")
    func delayFloorClearsTheStencil() {
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0] {
            let samples = StereoWidthParams.minimumDelayMs * 0.001 * rate
            #expect(samples >= 1,
                    "at \(rate) Hz the shortest stage is \(samples) samples, below the stencil floor")
        }
        // …and the refusal is only reachable at a nonsense rate, which is what
        // makes the DSP's `decorrelationReady` an honesty valve rather than a
        // branch anyone hits.
        #expect(StereoWidthParams.minimumDelayMs * 0.001 * 300 < 1)
    }

    // MARK: - The one-pole law

    @Test("onePoleCoefficient follows 1 - exp(-2*pi*f/fs), clamps its frequency, and refuses a nonsense rate")
    func onePoleCoefficientIsTheTextbookMapping() {
        let c = StereoWidthParams.onePoleCoefficient(cutoffHz: 120, sampleRate: 48_000)
        let expected = 1 - exp(-2 * Double.pi * 120 / 48_000)
        #expect(abs(c - expected) < 1e-15)
        // Monotone in frequency: a higher corner lets more through the LOW
        // path, which is what makes the high-pass complement steeper.
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: 500, sampleRate: 48_000)
                > StereoWidthParams.onePoleCoefficient(cutoffHz: 20, sampleRate: 48_000))
        // Out-of-range frequencies clamp rather than producing a coefficient
        // outside 0…1, which would be an unstable pole on the render thread.
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: 1e9, sampleRate: 48_000)
                == StereoWidthParams.onePoleCoefficient(cutoffHz: 500, sampleRate: 48_000))
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: -5, sampleRate: 48_000)
                == StereoWidthParams.onePoleCoefficient(cutoffHz: 20, sampleRate: 48_000))
        // Non-finite in, 0 out — a NaN coefficient would poison the crossover
        // state with no path back.
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: .nan, sampleRate: 48_000) == 0)
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: 120, sampleRate: 0) == 0)
        #expect(StereoWidthParams.onePoleCoefficient(cutoffHz: 120, sampleRate: .nan) == 0)
    }

    // MARK: - ⭐ THE MEASURABLE CLAIM: the per-channel ripple `spread` costs

    /// The closed forms the `spread` note quotes, the wire echoes as
    /// `channelPeakDb`/`channelNotchDb`, and `DAWEngineTests/StereoWidthTests`
    /// L3d measures OUT OF A RENDER. Three independent statements of one
    /// number is the point: if the DSP drifts from the law, that leg reddens.
    @Test("channelPeakDb / channelNotchDb are 20*log10(1 +/- spread), with the documented figures")
    func rippleClosedFormsMatchTheDocumentedFigures() {
        #expect(StereoWidthParams.channelPeakDb(spread: 0) == 0)
        #expect(StereoWidthParams.channelNotchDb(spread: 0) == 0)

        // The default, which is the number the note and the MCP text both say.
        #expect(abs(StereoWidthParams.channelPeakDb(spread: 0.3) - 2.2789) < 0.001)
        #expect(abs(StereoWidthParams.channelNotchDb(spread: 0.3) + 3.0980) < 0.001)

        #expect(abs(StereoWidthParams.channelPeakDb(spread: 1) - 6.0206) < 0.001)
        // ⚠️ The true notch at spread 1 is minus infinity — a complete null —
        // and no JSON number can carry that, so it FLOORS at -120 dB. The
        // floor is only ever reached at the exact endpoint: 0.99 already reads
        // -40 dB, which is honest rather than floored.
        #expect(StereoWidthParams.channelNotchDb(spread: 1) == -120)
        #expect(abs(StereoWidthParams.channelNotchDb(spread: 0.99) + 40) < 0.001)

        // Monotone, so an agent can reason about "less ripple" without a table.
        var previousPeak = -1.0
        var previousNotch = 1.0
        for step in 0...20 {
            let s = Double(step) / 20
            let peak = StereoWidthParams.channelPeakDb(spread: s)
            let notch = StereoWidthParams.channelNotchDb(spread: s)
            #expect(peak >= previousPeak)
            #expect(notch <= previousNotch)
            previousPeak = peak
            previousNotch = notch
        }

        // Non-finite and out-of-range inputs are guarded, because a
        // field-by-field automation poke bypasses the init.
        #expect(StereoWidthParams.channelPeakDb(spread: .nan) == 0)
        #expect(StereoWidthParams.channelNotchDb(spread: .nan) == 0)
        #expect(StereoWidthParams.channelPeakDb(spread: 99)
                == StereoWidthParams.channelPeakDb(spread: 1))
    }

    // MARK: - Codable

    @Test("a partial object decodes through the clamping init, filling absent fields with defaults")
    func partialDecodeFillsDefaults() throws {
        let json = Data(#"{"spread":0.75}"#.utf8)
        let decoded = try JSONDecoder().decode(StereoWidthParams.self, from: json)
        #expect(decoded.spread == 0.75)
        #expect(decoded.width == 1)
        #expect(decoded.bassMonoHz == 120)
        #expect(decoded.bassMonoAmount == 1)

        // An out-of-range stored value re-clamps on the way in rather than
        // reaching the render thread.
        let hot = Data(#"{"width":50,"spread":-3,"bassMonoHz":9000,"bassMonoAmount":4}"#.utf8)
        let clamped = try JSONDecoder().decode(StereoWidthParams.self, from: hot)
        #expect(clamped.width == 2)
        #expect(clamped.spread == 0)
        #expect(clamped.bassMonoHz == 500)
        #expect(clamped.bassMonoAmount == 1)
    }

    @Test("a NON-DEFAULT value in every field round-trips — a defaults-only fixture proves nothing")
    func fullRoundTripUsesNonDefaultValues() throws {
        let original = StereoWidthParams(width: 1.63, spread: 0.71,
                                         bassMonoHz: 87.5, bassMonoAmount: 0.42)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(StereoWidthParams.self, from: data)
        #expect(back == original)
        // Every field must differ from its default, or this test would pass
        // with any one of them dropped.
        let defaults = StereoWidthParams()
        #expect(original.width != defaults.width)
        #expect(original.spread != defaults.spread)
        #expect(original.bassMonoHz != defaults.bassMonoHz)
        #expect(original.bassMonoAmount != defaults.bassMonoAmount)
    }
}
