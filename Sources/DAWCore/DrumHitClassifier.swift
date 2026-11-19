import Foundation

// m39-w4-6 — which drum a chopped hit is. Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2 step 2.
//
// FOUR ROLES AND "OTHER". Ableton's "Convert Drums to New MIDI Track" "attempts to identify kick, snare and
// hihat sounds" and names no others (its manual, fetched by the design lane 2026-10-07). Toms against snares
// and cymbals against open hats are where classifiers go wrong, so this one does not try: anything that is
// not clearly a kick, a snare or a hat is "other" (nil), and "other" is never folded into a role. A person
// relabels it with `zonePatches`.

/// Pure: a `SliceTimbre` in, a role out. No audio, no state.
public enum DrumHitClassifier {

    /// A verdict: the role (kick, snare, closedHat or openHat), or nil for "other", and how sure.
    public struct Verdict: Sendable, Equatable {
        public var role: DrumVoice?
        /// 0.5…1: 0.5 when the deciding feature sits exactly on its threshold, 1 when it is as far past it as
        /// the feature can go. A margin, not a probability.
        public var confidence: Double

        public init(role: DrumVoice?, confidence: Double) {
            self.role = role
            self.confidence = confidence
        }
    }

    /// THE FROZEN THRESHOLDS — fitted ONCE, then frozen (design §10.3; gates C3 and C4 hold them).
    ///
    /// **The fit** (W8-W46, 2026-10-07; `KitSliceFitW46Tests`, `W46_FIT=1`): `SliceTimbreAnalyzer` features on
    /// (C3) the five synthetic one-shots of `KitSliceCorpus`, truth known, and (C4) our drum machine, all five
    /// factory kits, all eight voices, one hit per fresh offline render at velocity 100, each slice 0.5 s
    /// (0.25 s measured too: the spectral features are taken over the first 80 ms and did not move). Each
    /// threshold is the middle of the gap between the classes it separates, on that data:
    ///
    /// | Threshold | Value | Below the gap | Above the gap |
    /// |---|---|---|---|
    /// | `kickLowShare` | 0.878 | toms 0.842–0.852 (the acoustic tom 0.118) | kicks 0.904 (909)–0.978 (C3) |
    /// | `hatHighShare` | 0.48 | snares ≤ 0.195 (C3; C4 ≤ 0.186), every other non-hat ≤ 0.072 | hats 0.766 (lofi)–1.000 |
    /// | `openHatDecaySeconds` | 0.044 | closed hats 0.014–0.028 | open hats 0.060 (trap)–0.154 |
    /// | `snareFlatness` | 1.1e-4 | toms ≤ 5.02e-5, the 1 kHz tone 3.42e-5 | snares 2.43e-4 (lofi)–0.147 (C3) |
    /// | `snareMaxDecaySeconds` | 0.138 | snares 0.032–0.082 | cymbals 0.194 (trap)–0.482 |
    ///
    /// (`snareFlatness` is the geometric middle: flatness spans decades.) On the fit data: C3 5 of 5; C4
    /// kick, snare, closed hat, open hat 5 of 5 each; claps and rims land on snare (their nearest role); toms
    /// and cymbals on "other". REPORTED ONLY, not fitted: the Mac's General MIDI kit sorts its kick, snare and
    /// open hat right, and its closed hat as OPEN (its decay, 0.060 s, equals the trap kit's open hat); its
    /// cymbal goes to open hat. Real-world loops were not measured (design §13.2).
    public enum Thresholds {
        /// Kick: the attack's share of power below 150 Hz is at least this.
        public static let kickLowShare = 0.878
        /// Hi-hat: the attack's share of power above 5 kHz is at least this.
        public static let hatHighShare = 0.48
        /// An open hat: its decay to −20 dB takes at least this long, or it is still ringing when the slice
        /// ends. Otherwise closed.
        public static let openHatDecaySeconds = 0.044
        /// Snare: the attack's spectral flatness is at least this (noise, not a tone)…
        public static let snareFlatness = 1.1e-4
        /// …and its decay to −20 dB takes no longer than this (a snare, not a cymbal).
        public static let snareMaxDecaySeconds = 0.138
    }

    /// The decision, in order; the first rule that holds wins:
    /// 1. **kick** — `lowEnergyShare ≥ kickLowShare`;
    /// 2. **hat** — `highEnergyShare ≥ hatHighShare`: **open** when still ringing at the slice's end or when
    ///    `decaySeconds ≥ openHatDecaySeconds`, else **closed**;
    /// 3. **snare** — `spectralFlatness ≥ snareFlatness` and `decaySeconds ≤ snareMaxDecaySeconds`;
    /// 4. **other** (nil).
    /// A non-finite feature reads as 0 (a NaN can only fall through to "other", never become a role).
    public static func classify(_ timbre: SliceTimbre) -> Verdict {
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
        let low = finite(timbre.lowEnergyShare)
        let high = finite(timbre.highEnergyShare)
        let decay = finite(timbre.decaySeconds)
        let flatness = log10(max(finite(timbre.spectralFlatness), 1e-12))
        let flatnessThreshold = log10(Thresholds.snareFlatness)

        if low >= Thresholds.kickLowShare {
            return Verdict(role: .kick, confidence: margin(low, past: Thresholds.kickLowShare, toward: 1))
        }
        if high >= Thresholds.hatHighShare {
            let hat = margin(high, past: Thresholds.hatHighShare, toward: 1)
            if !timbre.decayReachedFloor || decay >= Thresholds.openHatDecaySeconds {
                let open = timbre.decayReachedFloor
                    ? margin(decay, past: Thresholds.openHatDecaySeconds,
                             toward: 4 * Thresholds.openHatDecaySeconds)
                    : 1
                return Verdict(role: .openHat, confidence: min(hat, open))
            }
            return Verdict(role: .closedHat,
                           confidence: min(hat, margin(decay, past: Thresholds.openHatDecaySeconds, toward: 0)))
        }
        if flatness >= flatnessThreshold, decay <= Thresholds.snareMaxDecaySeconds {
            return Verdict(role: .snare,
                           confidence: min(margin(flatness, past: flatnessThreshold, toward: 0),
                                           margin(decay, past: Thresholds.snareMaxDecaySeconds, toward: 0)))
        }
        // "Other": as sure as the closest call it missed.
        let missedKick = margin(low, past: Thresholds.kickLowShare, toward: 0)
        let missedHat = margin(high, past: Thresholds.hatHighShare, toward: 0)
        let missedSnare = flatness < flatnessThreshold
            ? margin(flatness, past: flatnessThreshold, toward: -6)
            : margin(decay, past: Thresholds.snareMaxDecaySeconds, toward: 1)
        return Verdict(role: nil, confidence: min(missedKick, missedHat, missedSnare))
    }

    /// 0.5 at the threshold, 1 at `end` (either side of the threshold), clamped.
    static func margin(_ value: Double, past threshold: Double, toward end: Double) -> Double {
        let span = end - threshold
        guard span != 0, value.isFinite else { return 0.5 }
        return 0.5 + 0.5 * min(1, max(0, (value - threshold) / span))
    }
}
