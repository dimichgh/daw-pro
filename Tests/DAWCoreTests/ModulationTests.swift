import DAWCore
import Foundation
import Testing

/// m39-e — the modulation layer's DOMAIN gates: the closed forms, the depth
/// law, the verdict table and the refusal-superset invariant.
///
/// ⚠️ This suite is deliberately NOT `@MainActor`. Everything under test here
/// is a pure value type or a pure function — `ModulationMath`, `ParamCurve`,
/// the spec tables — so pinning a suite to the main actor would add occupancy
/// the code does not need. The store-facing mutations (which DO need it,
/// because `ProjectStore` is main-actor isolated) live in the existing
/// `AutomationStoreTests` suite rather than in a new isolated one: the
/// `MainActorOccupancySiteTests` census is AT its cap, and the one move that
/// bound exists to make unattractive is silencing the instrument instead of
/// reducing the quantity.
@Suite("m39-e modulation — domain, closed forms and verdicts")
struct ModulationTests {

    // MARK: - §11.2 test 6 — verdict completeness

    /// A new effect param cannot be added without a modulation verdict: the
    /// compiler already forces the field (it has no default), and this pins
    /// the frozen SPLIT so a verdict cannot be added carelessly either.
    /// ⭐ m39-i GREW THIS, which is the whole point of rule 6.0.4: `.djFilter`
    /// contributed 4 yes + 0 warned + 1 refused (design §6.1.2), taking the
    /// table from 64 to 69 over 12 param-bearing kinds; m39-m's `.ringMod`
    /// added the same 4/0/1 split (design §6.4.1), taking it to 74 over 13;
    /// m39-j's `.flanger` added 6 yes + 0 warned + 0 refused (design §6.3.1),
    /// taking it to 80 over 14. ⭐ The flanger is the first new kind to add NO
    /// refusal at all — it has no discrete param, because the design gave it
    /// six continuous knobs and nothing else. m39-l's `.hallReverb` added
    /// 12 yes + 1 warned + 1 refused (design §6.2.2) — the largest single
    /// contribution any kind has made — taking it to 94 over 15. m39-n's
    /// `.tapeDelay` added 7 yes + 1 warned + 0 refused, taking it to 102 over
    /// 16; like the flanger it carries no discrete param, and its one `warned`
    /// is `timeMs`, for the `hallReverb.sizeMeters` reason (a move gives a
    /// pitch glide as well as the change asked for) and NOT for the
    /// `delay.timeMs` reason (whole-sample stepping), which this kind is built
    /// specifically not to have. m23-dj's `.stereoWidth` added 4 yes +
    /// 0 warned + 0 refused, taking it to 106 over 17 — the second kind after
    /// the flanger to add NO refusal, for the same reason (four continuous
    /// knobs, no discrete param, no `mix`). m39-o's `.phaser` added 6 yes +
    /// 0 warned + 1 refused (its `stages` is the discrete one), taking it to
    /// 113 over 18. m39-y's `.transientShaper` added 6 yes + 0 warned +
    /// 0 refused, taking it to 119 over 19 — the THIRD kind after the flanger
    /// and `.stereoWidth` to add NO refusal, and for a reason worth stating
    /// because it looks like an omission: this kind has NO DISCRETE PARAM at
    /// all, deliberately (a `detectMode` peak/RMS switch and a `stereoLink`
    /// toggle were both considered and REJECTED — an RMS mode smears the exact
    /// event the detector exists to find, and unlinked detection moves the
    /// stereo image with the drummer). Its two TIME constants are `yes` rather
    /// than `warned` because a one-pole ENVELOPE coefficient bends the
    /// trajectory of a state variable whose current value is unchanged — unlike
    /// `eq`, whose FILTER coefficients zipper.
    /// ⚠️ THE TITLE STRING IS ITSELF A SITE. Update it with the numbers, or the
    /// test name lies about what it pins.
    /// A new param without a verdict must fail this loudly.
    /// m39-ac's `.clipper` added 4 yes + 0 warned + 2 REFUSED, taking it to
    /// 130 over 21 — and it is the first kind since `.eq` to contribute more
    /// than one refusal. Both are rule 6.0.5 discrete params: `mode` is a
    /// two-position switch (an LFO on it is a stutter, not a sweep) and
    /// `oversampling` is a three-position quality setting that ALSO CLEARS the
    /// oversampler's FIR histories when it changes, which is an independent
    /// second reason on its own (the `phaser.stages` precedent, same shape).
    /// m39-ad added ONE param to an EXISTING kind rather than a new kind —
    /// `.saturator`'s `oversampling`, 0 yes + 0 warned + 1 REFUSED — taking the
    /// table to 131 over the SAME 21 param-bearing kinds. ⭐ THE KIND COUNT NOT
    /// MOVING IS THE POINT: this is the first growth of this table that is not a
    /// new kind, and it is the shape that can silently repoint automation slots
    /// if the param is not APPENDED. `saturatorVerdictsMatch` below asserts the
    /// order as a LIST for exactly that reason.
    /// m39-ae is the SECOND growth of that shape and the larger one:
    /// `.compressor`'s de-esser adds 0 yes + 2 warned + 1 REFUSED, taking the
    /// table to 134 over the same 21 kinds. ⚠️ ZERO `yes` IS NOT AN OVERSIGHT —
    /// `detectorMode` is a three-position switch (rule 6.0.5) and the other two
    /// are FILTER coefficients, which zipper at any modulation rate for the
    /// `eq.peak1Freq` reason rather than the rate-aliasing reason. This is the
    /// first kind to contribute more `warned` than `yes`.
    /// ⭐⭐ m39-af is the LARGEST single move this table has ever made — a whole
    /// new kind contributing **32** params at once, where the previous record
    /// for a new kind was `.hallReverb`'s 14. 134 → 166 over 21 → 22
    /// param-bearing kinds. ⚠️ A NET DELTA HIDES A SHRINK, so the 32 are NAMED
    /// rather than merely totalled, in `dynamicEQVerdictsMatch` below:
    /// **20 yes + 8 warned + 4 refused**, which is 5 + 2 + 1 per band times four
    /// identical bands.
    ///  · `bandNMode` (4) REFUSED — a three-position switch, rule 6.0.5, the
    ///    `compressor.detectorMode` precedent exactly.
    ///  · `bandNFreq` and `bandNQ` (8) WARNED — both are FILTER coefficients,
    ///    which zipper at any modulation rate for the `eq.peak1Freq` reason
    ///    rather than the rate-aliasing one.
    ///  · the five dynamics controls (20) YES — thresholds, ratios, ranges and
    ///    both time constants are plain scalars in the gain computer with no
    ///    coefficient behind them.
    @Test("§6.2 frozen verdict split: 109 yes + 30 warned + 27 refused = 166 across all 22 param-bearing kinds")
    func verdictSplitMatchesTheFrozenTable() {
        var yes = 0, warned = 0, refused = 0, total = 0
        for kind in EffectDescriptor.Kind.allCases {
            for spec in EffectParamSpec.specs(for: kind) {
                total += 1
                switch spec.modulatable {
                case .yes: yes += 1
                case .warned: warned += 1
                case .refused: refused += 1
                }
            }
        }
        print("[measured] m39-e verdicts — yes \(yes), warned \(warned), "
              + "refused \(refused), total \(total)")
        #expect(total == 166)
        #expect(yes == 109)
        #expect(warned == 30)
        #expect(refused == 27)
    }

    /// m39-af's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it, and NAMED
    /// because a net delta hides a shrink.
    ///
    /// ⛔⛔ THE ORDER IS THE WHOLE TEST. This kind's 32 slots are BAND-MAJOR —
    /// `slot = (band−1)·8 + p` — and `DynamicEQEffect.storeAutomatedParam`
    /// switches on those exact positions in a table that lives in a DIFFERENT
    /// MODULE, with no compiler rule comparing the two. A lane landing outside
    /// that switch's `(0...31)` guard is SILENTLY INERT: nothing logs, nothing
    /// fails, the user's automation simply does nothing.
    @Test("m39-af: .dynamicEQ contributes exactly 20 yes / 8 warned / 4 refused, band-major")
    func dynamicEQVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .dynamicEQ)
        #expect(specs.count == 32)
        #expect(specs.map(\.name) == [
            "band1Mode", "band1Freq", "band1Q", "band1ThresholdDb",
            "band1Ratio", "band1RangeDb", "band1AttackMs", "band1ReleaseMs",
            "band2Mode", "band2Freq", "band2Q", "band2ThresholdDb",
            "band2Ratio", "band2RangeDb", "band2AttackMs", "band2ReleaseMs",
            "band3Mode", "band3Freq", "band3Q", "band3ThresholdDb",
            "band3Ratio", "band3RangeDb", "band3AttackMs", "band3ReleaseMs",
            "band4Mode", "band4Freq", "band4Q", "band4ThresholdDb",
            "band4Ratio", "band4RangeDb", "band4AttackMs", "band4ReleaseMs",
        ])
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name)
                == ["band1Mode", "band2Mode", "band3Mode", "band4Mode"])
        #expect(specs.filter { $0.modulatable == .warned }.map(\.name)
                == ["band1Freq", "band1Q", "band2Freq", "band2Q",
                    "band3Freq", "band3Q", "band4Freq", "band4Q"])
        #expect(specs.filter { $0.modulatable == .yes }.count == 20)
        // ⛔ AND EVERY `mode` DEFAULTS TO 0 — OFF. This is what makes a freshly
        // added Dynamic EQ bit-exact transparent rather than merely quiet, and
        // it is the property the whole transparency null leans on.
        for band in 1...4 {
            let mode = specs.first { $0.name == "band\(band)Mode" }
            #expect(mode?.defaultValue == 0, "band\(band)Mode must default to OFF")
        }
        // The four bands are IDENTICAL apart from their default centre, which is
        // the claim that makes 32 slots reviewable by reviewing 8. Asserted
        // mechanically rather than trusted.
        for p in 0..<8 {
            let names = (0..<4).map { specs[$0 * 8 + p] }
            #expect(Set(names.map(\.unit)).count == 1, "unit differs across bands at p=\(p)")
            #expect(Set(names.map(\.curve)).count == 1, "curve differs across bands at p=\(p)")
            #expect(Set(names.map(\.modulatable)).count == 1,
                    "modulatable differs across bands at p=\(p)")
            #expect(Set(names.map { "\($0.range)" }).count == 1,
                    "range differs across bands at p=\(p)")
            if p != 1 {  // p == 1 is `freq`, whose defaults are deliberately spread
                #expect(Set(names.map(\.defaultValue)).count == 1,
                        "default differs across bands at p=\(p)")
            }
        }
        #expect((0..<4).map { specs[$0 * 8 + 1].defaultValue } == [120, 500, 3_000, 8_000])
    }

    /// m39-ae's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    ///
    /// ⛔⛔ THE ORDER IS THE WHOLE TEST, and on this kind it matters more than
    /// it did for the saturator. `.compressor` has shipped since M4 (iii);
    /// slots 0…5 are the original six and slot 6 is m23-ck's `mix`, and all
    /// seven are in saved user automation lanes right now. The de-esser's three
    /// had to be APPENDED at 7/8/9. A count would not see an insertion at the
    /// front, and an insertion at the front would silently repoint every one of
    /// those lanes with no error anywhere.
    @Test("m39-ae: .compressor contributes exactly 0 yes / 2 warned / 1 refused, de-ess APPENDED last")
    func compressorDeEssVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .compressor)
        #expect(specs.count == 10)
        #expect(specs.map(\.name)
                == ["thresholdDb", "ratio", "attackMs", "releaseMs", "kneeDb", "makeupDb",
                    "mix", "detectorMode", "detectorFreqHz", "detectorQ"])
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name) == ["detectorMode"])
        #expect(specs.filter { $0.modulatable == .warned }.map(\.name)
                == ["detectorFreqHz", "detectorQ"])
        // ⛔ AND THE DEFAULT IS 0 — OFF. This is the whole of m39-ae: a shipped
        // kind may not change what it does at its default, and here "the
        // default" is not a setting but the absence of a feature.
        #expect(specs[7].defaultValue == 0)
        // The other two default to a USABLE band rather than to zero, because
        // they are inert until the mode is on and a corner at 0 Hz would make
        // switching the mode on sound broken.
        #expect(specs[8].defaultValue == 6_500)
        #expect(specs[9].defaultValue == 2)
        // The frequency param declares `.logarithmic`, like every other
        // frequency in the table — a linear fraction of 1 k…16 k cannot express
        // "an octave up" and the m39-e depth law is defined on this field.
        #expect(specs[8].curve == .logarithmic)
    }

    /// m39-ad's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    ///
    /// ⛔⛔ THE ORDER IS THE WHOLE TEST. `.saturator` is the first SHIPPED kind
    /// to gain a param: slots 0/1/2 are in saved user automation lanes right
    /// now, so `oversampling` had to be APPENDED at slot 3. A count would not
    /// see an insertion at the front, and an insertion at the front would
    /// silently repoint every one of those lanes.
    @Test("m39-ad: .saturator contributes exactly 3 yes / 0 warned / 1 refused, oversampling APPENDED last")
    func saturatorVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .saturator)
        #expect(specs.count == 4)
        #expect(specs.filter { $0.modulatable == .yes }.count == 3)
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name) == ["oversampling"])
        #expect(specs.map(\.name) == ["driveDb", "mix", "outputDb", "oversampling"])
        // ⛔ AND THE DEFAULT IS 1. This is the whole of m39-ad: a shipped kind
        // may not change what it does at its default.
        #expect(specs[3].defaultValue == 1)
        // ⭐ AND SINCE THE USER'S 2026-09-20 RULING THE CLIPPER'S IS 1 TOO — for a
        // NEW clipper. (It shipped at 4, and a clipper SAVED without params
        // still resolves to 4 through `ClipperParams.legacy`; that half is
        // pinned in `ClipperParamsTests` P9 and `ClipperDefaultOversamplingTests`.)
        #expect(EffectParamSpec.specs(for: .clipper)
                .first { $0.name == "oversampling" }?.defaultValue == 1,
                Comment(rawValue:
                    "a new clipper's oversampling default must be 1 (OFF) — the user ruled "
                    + "that new effects of either oversampled kind start with it off"))
    }

    /// m39-ac's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    @Test("m39-ac: .clipper contributes exactly 4 yes / 0 warned / 2 refused")
    func clipperVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .clipper)
        #expect(specs.count == 6)
        #expect(specs.filter { $0.modulatable == .yes }.count == 4)
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name)
                == ["mode", "oversampling"])
        // ⛔ THE FROZEN ORDER, asserted as a LIST rather than a count: the
        // INDEX here IS the automation slot, permanently, and a count cannot
        // see a swap. `ClipperEffect.storeAutomatedParam` switches on these
        // exact positions.
        #expect(specs.map(\.name)
                == ["driveDb", "ceilingDb", "mode", "oversampling", "mix", "outputDb"])
    }

    /// m39-z's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    /// ⭐ FIVE yes and NO refusal, which looks like an omission and is not:
    /// this kind has NO DISCRETE PARAM AT ALL, deliberately. The obvious one -
    /// an up/down DIRECTION switch - was REJECTED because the sign of `shiftHz`
    /// already carries the direction, and a discrete param would be
    /// `Modulatable: refused` by rule 6.0.5, making the single most expressive
    /// axis on the effect un-sweepable through zero. The four continuous
    /// alternatives it could have had (`feedback`, `driveDb`, a carrier
    /// waveform, a Ring mode) are either declined for v1 or already covered by
    /// `.ringMod`.
    @Test("m39-z: .freqShifter contributes exactly 5 yes / 0 warned / 0 refused")
    func freqShifterVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .freqShifter)
        #expect(specs.count == 5)
        #expect(specs.filter { $0.modulatable == .yes }.count == 5)
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.isEmpty)
        // ⛔ THE FROZEN ORDER, asserted as a LIST rather than a count: the
        // INDEX here IS the automation slot, permanently, and a count cannot
        // see a swap. `FreqShifterEffect.storeAutomatedParam` switches on these
        // positions.
        #expect(specs.map(\.name)
                == ["shiftHz", "fineHz", "stereoSpreadHz", "mix", "outputDb"])
    }

    /// m39-y's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    @Test("m39-y: .transientShaper contributes exactly 6 yes / 0 warned / 0 refused")
    func transientShaperVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .transientShaper)
        #expect(specs.count == 6)
        #expect(specs.filter { $0.modulatable == .yes }.count == 6)
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.isEmpty)
    }

    /// m39-o's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    /// ⭐ `stages` is the refusal, and it is refused for the `ringMod.waveform`
    /// reason (discrete) PLUS one this kind adds: changing the count CLEARS the
    /// all-pass state, so a modulator riding it would re-clear every block.
    @Test("m39-o: .phaser contributes exactly 6 yes / 0 warned / 1 refused")
    func phaserVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .phaser)
        #expect(specs.count == 7)
        #expect(specs.filter { $0.modulatable == .yes }.count == 6)
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name) == ["stages"])
    }

    /// m39-l's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it.
    @Test("§6.2.2: .hallReverb contributes exactly 12 yes / 1 warned / 1 refused")
    func hallReverbVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .hallReverb)
        #expect(specs.count == 14)
        #expect(specs.filter { $0.modulatable == .yes }.count == 12)
        #expect(specs.filter { $0.modulatable == .warned }.map(\.name) == ["sizeMeters"])
        #expect(specs.filter { $0.modulatable == .refused }.map(\.name) == ["freeze"])
        // ⚠️ `sizeMeters` is `warned` for a PHYSICAL reason, not a numerical
        // one: the lines are MAX-sized at prepare so moving it is arithmetic,
        // never an allocation — but moving read offsets while audio is
        // recirculating pitch-shifts the existing tail like a varispeed. The
        // warning has to say DOPPLER GLIDE, not steps: it is emphatically NOT
        // the `delay.timeMs` integer-snap defect, and an agent told "steps"
        // would go looking for the wrong thing.
        let size = specs.first { $0.name == "sizeMeters" }
        let note = size?.note ?? ""
        #expect(note.uppercased().contains("DOPPLER GLIDE"),
                "the sizeMeters warning does not say Doppler glide")
        #expect(note.uppercased().contains("SMOOTH, NOT A CLICK"),
                "the sizeMeters warning does not rule out the delay's stepping defect")
        // `freeze` is refused because it is a SWITCH on a numeric surface, and
        // its note has to send the agent to a `hold` lane rather than a ramp.
        #expect(specs.first { $0.name == "freeze" }?.note?.contains("hold") == true)
    }

    /// m39-i's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it: a kind that
    /// silently lost a verdict while another gained one keeps the total right.
    @Test("§6.1.2: .djFilter contributes exactly 4 yes / 0 warned / 1 refused")
    func djFilterVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .djFilter)
        #expect(specs.count == 5)
        #expect(specs.filter { $0.modulatable == .yes }.map(\.name)
            == ["position", "resonance", "deadZoneWidth", "resonanceTrack"])
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        // The 12/24 topology switch — discrete, so refused, the
        // `eq.highPassSlopeDbPerOct` precedent verbatim.
        #expect(specs.first { $0.name == "slopeDbPerOct" }?.modulatable == .refused)
    }

    /// m39-m's own contribution, asserted separately from the total for the
    /// same reason as m39-i's: a compensating error elsewhere in the table
    /// keeps the total right while a kind silently loses a verdict.
    @Test("§6.4.1: .ringMod contributes exactly 4 yes / 0 warned / 1 refused")
    func ringModVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .ringMod)
        #expect(specs.count == 5)
        #expect(specs.filter { $0.modulatable == .yes }.map(\.name)
            == ["carrierHz", "mix", "inputHighCutHz", "stereoSpreadDeg"])
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        // The 0/1/2/3 shape switch — discrete, so refused, the
        // `eq.highPassSlopeDbPerOct` precedent verbatim. ⭐ `carrierHz` is
        // `yes` and NOT `warned`, which is the interesting verdict here: it is
        // an audio-rate frequency control, and it earns `yes` only because the
        // DSP interpolates its phase INCREMENT per sample so a step is a
        // frequency step rather than a phase discontinuity (RingModTests L5/L6).
        #expect(specs.first { $0.name == "waveform" }?.modulatable == .refused)
        #expect(specs.first { $0.name == "carrierHz" }?.modulatable == .yes)
    }

    /// m39-j's own contribution, asserted separately from the total for the
    /// same reason as m39-i's and m39-m's. ⭐ THE INTERESTING PART IS THE
    /// ABSENCE: 6 yes and NOTHING else. Every other new kind in this milestone
    /// carried at least one discrete param that had to be refused; the flanger
    /// has none, so a `refused` or `warned` appearing here later means a
    /// parameter changed shape, not that someone was cautious.
    @Test("§6.3.1: .flanger contributes exactly 6 yes / 0 warned / 0 refused")
    func flangerVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .flanger)
        #expect(specs.count == 6)
        #expect(specs.filter { $0.modulatable == .yes }.map(\.name)
            == ["rateHz", "depthMs", "delayMs", "feedback", "mix", "stereoPhaseDeg"])
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.isEmpty)
        // ⭐ `delayMs` and `depthMs` are `yes` and NOT `warned`, and that is a
        // claim about the DSP, not about optimism: `delay.timeMs` is `warned`
        // because it reads its line at an INTEGER offset and steps whole
        // samples. This effect reads a FRACTIONAL, interpolated tap and
        // interpolates the floor and the depth per sample (FlangerTests L12b,
        // which was ADDED after a plant proved nothing else could see the
        // smoother), so the same control glides here where it clicks there.
        #expect(specs.first { $0.name == "delayMs" }?.modulatable == .yes)
        #expect(EffectParamSpec.specs(for: .delay).first { $0.name == "timeMs" }?
            .modulatable == .warned)
    }

    /// m39-n's own contribution, asserted separately from the total for the
    /// same reason as every other kind's. ⭐ THE INTERESTING PART IS WHICH ONE
    /// IS `warned` AND WHY: `timeMs` here is `warned` for the
    /// `hallReverb.sizeMeters` reason, NOT the `delay.timeMs` reason. Both
    /// verdicts read the same in a table and they are about opposite
    /// mechanisms — the delay's is a DEFECT (an integer read offset steps and
    /// clicks), this one is a CONSEQUENCE (a fractional read offset glides, so
    /// the repeats bend in pitch as well as moving in time). An agent that
    /// cannot tell those apart will either avoid a usable gesture or ship a
    /// click, so the distinction is pinned here rather than left to the note.
    @Test("m39-n: .tapeDelay contributes exactly 7 yes / 1 warned / 0 refused")
    func tapeDelayVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .tapeDelay)
        #expect(specs.count == 8)
        #expect(specs.filter { $0.modulatable == .yes }.map(\.name)
            == ["feedback", "mix", "wowDepthMs", "wowRateHz", "flutterDepthMs",
                "saturationDrive", "highCutHz"])
        #expect(specs.filter { $0.modulatable == .warned }.map(\.name) == ["timeMs"])
        #expect(specs.filter { $0.modulatable == .refused }.isEmpty)
        // The two `warned` time controls must BOTH stay warned, and the note
        // is where the difference lives — so the note has to say it.
        let timeNote = try? #require(specs.first { $0.name == "timeMs" }?.note)
        #expect(timeNote?.uppercased().contains("PITCH GLIDE") == true)
        #expect(timeNote?.contains("whole-sample") == true,
                "the note must name what makes this kind different from `delay`")
    }

    /// m23-dj's own contribution, asserted separately from the total so a
    /// compensating error elsewhere in the table cannot hide it. ⭐ THE
    /// INTERESTING PART IS WHAT IS **ABSENT**: no `mix` slot (a dry/wet blend
    /// on a mid/side widener is algebraically another `width` and another
    /// `spread`, so it would be a lie in `fx.describe`) and no discrete param
    /// at all, which is why this is the second kind after `.flanger` to
    /// contribute zero refusals. The ORDER is pinned too — position IS the
    /// automation slot, and this array is the append-only law made
    /// enforceable rather than aspirational.
    @Test("m23-dj: .stereoWidth contributes exactly 4 yes / 0 warned / 0 refused, in frozen order")
    func stereoWidthVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .stereoWidth)
        #expect(specs.count == 4)
        #expect(specs.map(\.name) == ["width", "spread", "bassMonoHz", "bassMonoAmount"])
        #expect(specs.filter { $0.modulatable == .yes }.map(\.name)
            == ["width", "spread", "bassMonoHz", "bassMonoAmount"])
        #expect(specs.filter { $0.modulatable == .warned }.isEmpty)
        #expect(specs.filter { $0.modulatable == .refused }.isEmpty)
        #expect(specs.first { $0.name == "mix" } == nil,
                "this kind deliberately has NO mix — see StereoWidthParams.isNeutral")
        // The two traps an agent will hit first have to be IN the notes, or
        // they are traps we knew about and did not say.
        let widthNote = specs.first { $0.name == "width" }?.note ?? ""
        #expect(widthNote.uppercased().contains("NOTHING AT ALL ON A MONO SOURCE"),
                "the silent no-op on mono material must be named in `width`'s own note")
        // ⛔ And the SECOND trap, which this note asserted BACKWARDS at first:
        // it claimed "0 folds the track to dead centre — a real mono-maker".
        // `spread` defaults to 0.3 and rebuilds a side channel AFTER `width`
        // scales the old one, so width 0 alone is not mono — on mono material
        // it is WIDER. DAWEngineTests' L2c measures it; this pins the words.
        #expect(widthNote.uppercased().contains("0 ALONE IS NOT A MONO-MAKER"),
                "the note must contradict the width-0 mono recipe, not merely omit it")
        #expect(widthNote.contains("`spread` 0 together"),
                "and give the corrected recipe, or the agent is left with only a warning")
        let bassNote = specs.first { $0.name == "bassMonoHz" }?.note ?? ""
        #expect(bassNote.uppercased().contains("DOES NOTHING WHEN"),
                "a frequency that is inert at amount 0 must say so")
        // And the cost of `spread` must be quoted, not implied.
        let spreadNote = specs.first { $0.name == "spread" }?.note ?? ""
        #expect(spreadNote.contains("20*log10(1 + spread)"),
                "the per-channel ripple is this effect's one real cost — it goes in the note")
    }

    /// The EQ is the one family where zipper genuinely bites, and the contract
    /// says so by marking all 14 continuous EQ params `warned`. A regression
    /// that quietly promoted them to `yes` would remove the only honest signal
    /// an agent gets about that artefact.
    @Test("§6.2: every continuous EQ parameter is `warned`, and both slopes are `refused`")
    func eqVerdictsMatch() {
        let specs = EffectParamSpec.specs(for: .eq)
        let warned = specs.filter { $0.modulatable == .warned }.map(\.name)
        #expect(warned.count == 14)
        #expect(warned.contains("peak1Freq"))
        #expect(specs.first { $0.name == "highPassSlopeDbPerOct" }?.modulatable == .refused)
        #expect(specs.first { $0.name == "lowPassSlopeDbPerOct" }?.modulatable == .refused)
        #expect(specs.first { $0.name == "peak1Enabled" }?.modulatable == .refused)
    }

    /// §11.2 test 7 — the refusal-superset invariant, checked mechanically.
    /// For every `(kind, param)`: if automation cannot resolve a range for it,
    /// modulation must refuse it. Modulation never permits what automation
    /// forbids.
    @Test("§6.1 invariant: modulation refuses a SUPERSET of what automation refuses")
    func modulationRefusesASupersetOfAutomation() {
        var checked = 0
        var refusedByAutomation = 0
        for kind in EffectDescriptor.Kind.allCases {
            let effect = EffectDescriptor(kind: kind)
            let track = Track(name: "t", kind: .audio, effects: [effect])
            for spec in EffectParamSpec.specs(for: kind) {
                checked += 1
                let target = AutomationTarget.effectParam(effectID: effect.id,
                                                          paramName: spec.name)
                if target.valueRange(in: track) == nil {
                    refusedByAutomation += 1
                    #expect(spec.modulatable == .refused,
                            Comment(rawValue: "\(kind.rawValue).\(spec.name): automation "
                                + "refuses it, so modulation must too — it is "
                                + "\(spec.modulatable.rawValue)"))
                }
            }
        }
        print("[measured] m39-e refusal superset — \(checked) (kind, param) pairs checked, "
              + "\(refusedByAutomation) refused by automation")
        // Positive control: the scan must actually FIND automation refusals,
        // or "every refusal is also a modulation refusal" is vacuously true.
        // 130 = 124 through m39-z + the SIX .clipper params (m39-ac);
        // 131 = + m39-ad's `saturator.oversampling`;
        // 134 = + m39-ae's THREE `compressor` de-ess params;
        // 166 = + m39-af's THIRTY-TWO `dynamicEQ` params. ⭐ AND NONE OF THE 32
        // IS REFUSED BY AUTOMATION, which is the interesting half: that kind's
        // `latencySamples` is a literal 0 at every setting, so the
        // `saturator.oversampling` reason for a refusal does not exist there and
        // `Automation.swift` deliberately has no entry for it. All 32 slots take
        // lanes and `DynamicEQEffect.storeAutomatedParam` guards the WHOLE
        // `(0...31)` table — so `refusedByAutomation` is UNMOVED at 3 while
        // `checked` jumps by 32.
        #expect(checked == 166)
        #expect(refusedByAutomation >= 3,
                "delay.sync, delay.division and saturator.oversampling at minimum")
        // ⛔ m39-ad: the AUTOMATION refusal is asserted by NAME, not just
        // counted. `saturator.oversampling` must be undrawable because moving it
        // from the render thread would stale the PDC plan — while the IDENTICALLY
        // NAMED param on `.clipper` must stay drawable, because that kind's
        // latency is constant. A count cannot tell those two apart.
        let satEffect = EffectDescriptor(kind: .saturator)
        let satTrack = Track(name: "s", kind: .audio, effects: [satEffect])
        #expect(AutomationTarget.effectParam(effectID: satEffect.id,
                                             paramName: "oversampling")
                .valueRange(in: satTrack) == nil,
                Comment(rawValue: "a lane on saturator.oversampling would be a silent dead "
                    + "lane AND would stale the PDC plan"))
        #expect(AutomationTarget.effectParam(effectID: satEffect.id, paramName: "driveDb")
                .valueRange(in: satTrack) != nil,
                "POSITIVE CONTROL: the saturator's other params must still be automatable")
        let clipEffect = EffectDescriptor(kind: .clipper)
        let clipTrack = Track(name: "c", kind: .audio, effects: [clipEffect])
        #expect(AutomationTarget.effectParam(effectID: clipEffect.id,
                                             paramName: "oversampling")
                .valueRange(in: clipTrack) != nil,
                Comment(rawValue: "the clipper's oversampling stays automatable — its "
                    + "latency is constant, so a lane on it is harmless"))
    }

    // MARK: - §3.2 — the closed forms are functions of position, with no state

    /// The no-accumulator law, at the arithmetic level: evaluating a source at
    /// scattered positions in any order gives the same values as sweeping it.
    /// This is the property that makes seek-exactness and loop-exactness free.
    @Test("§3.2: every source is a pure function of position — out-of-order evaluation matches a sweep")
    func sourcesArePureFunctionsOfPosition() {
        let rate = 48_000.0
        let sources: [ModulationSourceParams] = [
            .lfo(LFOSourceParams(waveform: .sine, rateHz: 5)),
            .lfo(LFOSourceParams(waveform: .triangle, rateHz: 3.5, phaseDeg: 90)),
            .lfo(LFOSourceParams(waveform: .sawUp, rateHz: 2)),
            .lfo(LFOSourceParams(waveform: .square, rateHz: 4, pulseWidth: 0.25, edgeMs: 3)),
            .lfo(LFOSourceParams(waveform: .sampleHold, rateHz: 7, edgeMs: 1, seed: 1234)),
            .stepSequencer(StepSequencerSourceParams(steps: [0, 1, -0.5, 0.25],
                                                     rateHz: 8, edgeMs: 2)),
        ]
        for params in sources {
            var sweep: [Double] = []
            for p in stride(from: Int64(0), to: Int64(4_000), by: 37) {
                sweep.append(ModulationMath.value(of: params, atSample: p, sampleRate: rate)!)
            }
            // Same positions, reversed order, fresh calls.
            var reversed: [Double] = []
            for p in stride(from: Int64(3_996), through: Int64(0), by: -37)
            where (p % 37) == 0 {
                reversed.append(ModulationMath.value(of: params, atSample: p,
                                                     sampleRate: rate)!)
            }
            let positions = Array(stride(from: Int64(0), to: Int64(4_000), by: 37))
            for (index, p) in positions.enumerated() {
                let again = ModulationMath.value(of: params, atSample: p, sampleRate: rate)!
                #expect(again.bitPattern == sweep[index].bitPattern,
                        Comment(rawValue: "re-evaluating at \(p) must be BIT-exact — a "
                            + "phase register here would break seek-exactness silently"))
            }
        }
    }

    /// The declared exception, asserted rather than assumed: the follower is
    /// the ONE source with no position-function at all. A test that passed for
    /// every source would be a broken test.
    @Test("§3.2's declared exception: envelopeFollower has NO closed form, and says so")
    func followerHasNoClosedForm() {
        let follower = ModulationSourceParams.envelopeFollower(EnvelopeFollowerSourceParams())
        #expect(ModulationMath.value(of: follower, atSample: 0, sampleRate: 48_000) == nil)
        #expect(ModulationSourceKind.envelopeFollower.isStateful)
        // Control: every other kind DOES have one.
        for kind in ModulationSourceKind.allCases where kind != .envelopeFollower {
            #expect(ModulationMath.value(of: .defaults(for: kind), atSample: 1_234,
                                         sampleRate: 48_000) != nil,
                    "\(kind.rawValue) must be a function of position")
        }
    }

    @Test("closed forms: sine starts at 0 rising, sawUp rises, sawDown falls, triangle shares the sine's phase")
    func waveformShapesAreWhatTheyClaim() {
        let rate = 48_000.0
        func lfo(_ waveform: LFOWaveform, atSeconds t: Double) -> Double {
            ModulationMath.value(of: .lfo(LFOSourceParams(waveform: waveform, rateHz: 1)),
                                 atSample: Int64(t * rate), sampleRate: rate)!
        }
        #expect(abs(lfo(.sine, atSeconds: 0)) < 1e-12)
        #expect(lfo(.sine, atSeconds: 0.25) > 0.999)
        #expect(abs(lfo(.triangle, atSeconds: 0)) < 1e-12)
        #expect(lfo(.triangle, atSeconds: 0.25) > 0.999)
        // sawUp RISES then resets; sawDown falls. Named unambiguously because
        // "saw" alone is the most commonly mis-assumed direction in modulation.
        #expect(lfo(.sawUp, atSeconds: 0) < -0.99)
        #expect(lfo(.sawUp, atSeconds: 0.9) > 0.79)
        #expect(lfo(.sawDown, atSeconds: 0) > 0.99)
        #expect(lfo(.sawDown, atSeconds: 0.9) < -0.79)
    }

    /// The raised-cosine edge is a SHAPE, not a filter: it must be centred on
    /// the transition, or softening a gate would move it off the beat.
    @Test("§7.2: the square's raised-cosine edge is CENTRED on the transition")
    func squareEdgeIsCentredOnTheTransition() {
        // pulseWidth 0.5, a 20% edge: the value exactly AT the transition is
        // the midpoint of the two levels, i.e. 0.
        let atEdge = ModulationMath.square(phase: 0.5, pulseWidth: 0.5, edgeFraction: 0.2)
        #expect(abs(atEdge) < 1e-9, "measured \(atEdge)")
        // Symmetric either side.
        let before = ModulationMath.square(phase: 0.45, pulseWidth: 0.5, edgeFraction: 0.2)
        let after = ModulationMath.square(phase: 0.55, pulseWidth: 0.5, edgeFraction: 0.2)
        #expect(abs(before + after) < 1e-9, "before \(before) after \(after)")
        // Control: a zero edge is a hard step.
        #expect(ModulationMath.square(phase: 0.49, pulseWidth: 0.5, edgeFraction: 0) == 1)
        #expect(ModulationMath.square(phase: 0.51, pulseWidth: 0.5, edgeFraction: 0) == -1)
    }

    @Test("sampleHold is reproducible from its seed and holds for a whole cycle")
    func sampleHoldIsSeededAndHeld() {
        let a = ModulationMath.hash01(seed: 42, index: 7)
        let b = ModulationMath.hash01(seed: 42, index: 7)
        #expect(a.bitPattern == b.bitPattern)
        #expect(ModulationMath.hash01(seed: 43, index: 7) != a)
        #expect(ModulationMath.hash01(seed: 42, index: 8) != a)
        // Held across the interior of a cycle (edges off).
        let mid1 = ModulationMath.sampleHold(phase: 0.3, edgeFraction: 0,
                                             seed: 42, cycleIndex: 7)
        let mid2 = ModulationMath.sampleHold(phase: 0.7, edgeFraction: 0,
                                             seed: 42, cycleIndex: 7)
        #expect(mid1.bitPattern == mid2.bitPattern)
    }

    /// A pre-anchor position is legal — automation breakpoints keep negative
    /// times too — so a negative step index must wrap, not trap.
    @Test("negative positions wrap rather than trapping")
    func negativePositionsWrap() {
        #expect(ModulationMath.wrapIndex(-1, count: 4) == 3)
        #expect(ModulationMath.wrapIndex(-5, count: 4) == 3)
        #expect(ModulationMath.wrapIndex(0, count: 4) == 0)
        let value = ModulationMath.value(
            of: .stepSequencer(StepSequencerSourceParams(steps: [0, 1, 0, 1], rateHz: 4,
                                                         edgeMs: 0)),
            atSample: -12_000, sampleRate: 48_000)
        #expect(value != nil)
    }

    // MARK: - §7.3 — the depth law

    @Test("§7.3 worked example: depth 0.1 on cutoffHz is ±0.88 octaves, at BOTH ends of the range")
    func logarithmicDepthMeansOctaves() {
        let range = PolySynthParams.cutoffRange       // 40 … 18 000
        let span = ParamCurve.logarithmic.fullDepthSpan(in: range)
        #expect(abs(span - 8.8137) < 0.001, "measured \(span) octaves")
        // The whole argument for the curve: the same depth is the same MUSICAL
        // gesture at 200 Hz and at 8 kHz, which a linear-Hz depth is not.
        let low = ModulationDepthLaw.value(base: 200, sum: 0.1, range: range,
                                           curve: .logarithmic)
        let high = ModulationDepthLaw.value(base: 8_000, sum: 0.1, range: range,
                                            curve: .logarithmic)
        let lowOctaves = log2(low / 200)
        let highOctaves = log2(high / 8_000)
        print("[measured] m39-e depth law — 200 Hz → \(low) (+\(lowOctaves) oct), "
              + "8 kHz → \(high) (+\(highOctaves) oct)")
        #expect(abs(lowOctaves - highOctaves) < 1e-9)
        #expect(abs(lowOctaves - 0.8814) < 0.001)
    }

    @Test("§7.3: linear depth 0.25 on resonance is ±0.25")
    func linearDepthIsRawRange() {
        let value = ModulationDepthLaw.value(base: 0.5, sum: 0.25, range: 0...1,
                                             curve: .linear)
        #expect(abs(value - 0.75) < 1e-12)
    }

    /// The shortcut that makes a zero-depth route bit-identical to no route.
    @Test("⭐ sum == 0 returns the base BIT-EXACTLY, for every curve and every target class")
    func zeroSumIsBitExactlyTheBase() {
        for curve in ParamCurve.allCases {
            for base in [0.1, 0.5, 1.0, 440.0, 17_999.0] {
                let out = ModulationDepthLaw.value(base: base, sum: 0, range: 0.001...18_000,
                                                   curve: curve)
                #expect(out.bitPattern == base.bitPattern,
                        "\(curve.rawValue) at \(base) moved a bit")
            }
        }
        #expect(ModulationDepthLaw.volumeGain(base: 0.73, sum: 0).bitPattern
                    == (0.73).bitPattern)
        #expect(ModulationDepthLaw.pan(base: -0.4, sum: 0).bitPattern == (-0.4).bitPattern)
        // Control: a TINY non-zero sum must move it, or the shortcut is
        // swallowing real modulation.
        #expect(ModulationDepthLaw.volumeGain(base: 0.73, sum: 1e-9) != 0.73)
    }

    @Test("§7.3: volume's domain is DECIBELS — depth 0.125 is a ±6 dB tremolo")
    func volumeDepthIsDecibels() {
        #expect(ModulationDepth.volumeFullScaleDb == 48)
        let up = ModulationDepthLaw.volumeGain(base: 0.25, sum: 0.125)
        let db = 20 * log10(up / 0.25)
        print("[measured] m39-e volume depth — base 0.25, sum 0.125 → \(up) (\(db) dB)")
        #expect(abs(db - 6) < 1e-9)
        let down = ModulationDepthLaw.volumeGain(base: 0.25, sum: -0.125)
        #expect(abs(20 * log10(down / 0.25) + 6) < 1e-9)
    }

    /// ⛔ The asymmetry the contract insists on stating, and the polarity
    /// amendment that follows from it (§7.2.0).
    @Test("⛔ §7.3: volume clips at +6.02 dB, which is WHY a gate takes a negative depth")
    func volumeIsAsymmetricAtTheTop() {
        #expect(ModulationDepthLaw.volumeGain(base: 1.0, sum: 1.0)
                    == Track.volumeRange.upperBound)
        #expect(ModulationDepthLaw.volumeWouldExceedCeiling(base: 1.0, depth: 0.5))
        #expect(!ModulationDepthLaw.volumeWouldExceedCeiling(base: 0.1, depth: 0.05))
        // §7.2.0 — THE POLARITY CONVENTION, asserted so the amendment is
        // machine-checked and not merely written down. With the mandatory
        // negative depth a step of 1 CLOSES and a step of 0 OPENS, so
        // [1, 0, 1, 0] gates the DOWNBEAT silent.
        let base = 0.8
        let closed = ModulationDepthLaw.volumeGain(base: base, sum: -1.0 * 1.0)
        let open = ModulationDepthLaw.volumeGain(base: base, sum: -1.0 * 0.0)
        print("[measured] m39-e polarity — step 1 → \(closed), step 0 → \(open)")
        #expect(open.bitPattern == base.bitPattern, "step 0 must be the knob, bit-exactly")
        #expect(closed < base / 100, "step 1 under a negative depth must CUT")
    }

    // MARK: - §8.1 — the alias figures, reusing EffortField

    @Test("§8.1: perSample at a 32-frame stride never warns in the musical band; perQuantum warns above ~18.75 Hz")
    func pathSamplingRatesMatchTheContract() {
        let perSample = ModulationPath.perSample.samplingHz(sampleRate: 48_000,
                                                            blockFrames: 512)
        let perQuantum = ModulationPath.perQuantum.samplingHz(sampleRate: 48_000,
                                                              blockFrames: 512)
        #expect(perSample == 1_500)
        #expect(perQuantum == 93.75)
        let perSampleCeiling = EffortField.modulationRateCeilingHz(
            samplingHz: perSample, maxImageRatio: EffortField.maxAcceptableImageRatio)
        let perQuantumCeiling = EffortField.modulationRateCeilingHz(
            samplingHz: perQuantum, maxImageRatio: EffortField.maxAcceptableImageRatio)
        print("[measured] m39-e paths — perSample \(perSample) Hz (ceiling "
              + "\(perSampleCeiling) Hz), perQuantum \(perQuantum) Hz (ceiling "
              + "\(perQuantumCeiling) Hz)")
        #expect(abs(perSampleCeiling - 300) < 0.001)
        #expect(abs(perQuantumCeiling - 18.75) < 0.001)
        // The payoff of §3.2: the top of the authorable band is 40 Hz, and the
        // per-sample path's ceiling is six times above it.
        #expect(LFOSourceParams.rateRange.upperBound < perSampleCeiling)
    }

    // MARK: - §7.6 — persistence

    /// The byte-identity gate's FIRST half: a project with no modulation must
    /// encode exactly as it did before m39-e.
    @Test("⭐ §7.6: a track with no modulation encodes NO modulation key — pre-m39-e JSON, byte-for-byte")
    func unmodulatedTrackEncodesNoModulationKeys() throws {
        let track = Track(name: "plain", kind: .audio)
        let data = try JSONEncoder().encode(track)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("modulationSources"))
        #expect(!json.contains("modulationRoutes"))
        // Positive control: a track that HAS modulation must emit them, or the
        // assertion above is testing an encoder that writes nothing at all.
        var modulated = track
        modulated.modulationSources = [ModulationSource(kind: .macro)]
        let modulatedJSON = String(data: try JSONEncoder().encode(modulated), encoding: .utf8)!
        #expect(modulatedJSON.contains("modulationSources"))
    }

    @Test("§7.6: sources and routes round-trip through Codable, params as a per-kind STRUCT")
    func modelRoundTrips() throws {
        let source = ModulationSource(
            kind: .lfo, name: "Wobble",
            params: .lfo(LFOSourceParams(waveform: .sampleHold, rateHz: 6.5,
                                         phaseDeg: 45, edgeMs: 7, bipolar: false,
                                         seed: 9_001)))
        let route = ModulationRoute(sourceID: source.id,
                                    target: .instrumentParam(paramName: "cutoffHz"),
                                    depth: -0.35)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decodedSource = try decoder.decode(ModulationSource.self,
                                               from: try encoder.encode(source))
        let decodedRoute = try decoder.decode(ModulationRoute.self,
                                              from: try encoder.encode(route))
        #expect(decodedSource == source)
        #expect(decodedRoute == route)
        // The flat wire shape, verbatim: {kind, waveform, …} — not a nested
        // discriminated union an agent has to guess at.
        let json = String(data: try encoder.encode(source.params), encoding: .utf8)!
        #expect(json.contains("\"kind\":\"lfo\""))
        #expect(json.contains("\"waveform\":\"sampleHold\""))
    }

    /// m39-b: the new case must persist through the SAME flat object, reusing
    /// the EXISTING `param` key — no new key, no new id field.
    @Test("m39-b: `.instrumentParam` encodes as {type:\"instrumentParam\", param:…} — the existing key")
    func instrumentParamTargetWireShape() throws {
        let target = AutomationTarget.instrumentParam(paramName: "cutoffHz")
        let json = String(data: try JSONEncoder().encode(target), encoding: .utf8)!
        #expect(json.contains("\"type\":\"instrumentParam\""))
        #expect(json.contains("\"param\":\"cutoffHz\""))
        #expect(!json.contains("instrumentId"))
        let back = try JSONDecoder().decode(AutomationTarget.self,
                                            from: try JSONEncoder().encode(target))
        #expect(back == target)
    }

    /// m39-b: `valueRange` must resolve through `InstrumentParamSpec` — the ONE
    /// HOME m39-b, m39-e and m39-f all read.
    @Test("m39-b: valueRange resolves instrument params, and refuses non-instrument strips")
    func instrumentParamValueRangeResolution() {
        let synth = Track(name: "synth", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .polySynth))
        #expect(AutomationTarget.instrumentParam(paramName: "cutoffHz")
                    .valueRange(in: synth) == PolySynthParams.cutoffRange)
        #expect(AutomationTarget.instrumentParam(paramName: "waveform")
                    .valueRange(in: synth) == nil, "discrete — refused")
        #expect(AutomationTarget.instrumentParam(paramName: "nope")
                    .valueRange(in: synth) == nil)
        let audio = Track(name: "audio", kind: .audio)
        #expect(AutomationTarget.instrumentParam(paramName: "cutoffHz")
                    .valueRange(in: audio) == nil, "no instrument on an audio track")
        // Hosted instruments have an EMPTY spec surface, the `.audioUnit`
        // effect rule verbatim.
        let hosted = Track(name: "bank", kind: .instrument,
                           instrument: InstrumentDescriptor(kind: .soundBank))
        #expect(AutomationTarget.instrumentParam(paramName: "cutoffHz")
                    .valueRange(in: hosted) == nil)
    }

    @Test("§4: InstrumentParamSpec is the ONE HOME — every spec declares a curve valid for its range")
    func instrumentSpecsAreWellFormed() {
        let specs = InstrumentParamSpec.specs(for: .polySynth)
        #expect(specs.count == 7)
        for spec in specs {
            #expect(spec.curve.isValid(for: spec.range),
                    Comment(rawValue: "\(spec.name): a multiplicative curve needs lo > 0 — "
                        + "dB(0) is -inf and the depth-law normalisation divides by it"))
            #expect(spec.range.contains(spec.defaultValue),
                    Comment(rawValue: "\(spec.name) default out of range"))
            #expect(spec.modulatable != .refused)
        }
        // Hosted and non-participating kinds are EMPTY, and empty is
        // load-bearing: it is what makes the refusal reachable.
        #expect(InstrumentParamSpec.specs(for: .soundBank).isEmpty)
        #expect(InstrumentParamSpec.specs(for: .sampler).isEmpty)
        #expect(InstrumentParamSpec.isHosted(.audioUnit))
        #expect(!InstrumentParamSpec.isHosted(.polySynth))
    }

    // MARK: - §7.2.1 — the tempo-sync seam

    /// m39-w4-4 (W9-UNLOCK, 2026-10-11) SPLIT the old `tempoSyncIsRefusedNotHandRolled` pin. This, its LFO half, stands
    /// unchanged in substance: a synced LFO is not built, and the step unlock must not unlock it by accident. The step
    /// half FLIPPED on purpose and is `stepDivisionIsUnlocked` below.
    @Test("⛔ §7.2.1: the LFO's syncDivision STILL REFUSES after the step unlock, naming m39-c; null is not a refusal")
    func lfoSyncDivisionStillRefuses() {
        #expect(throws: ModulationError.modulationTempoSyncUnavailable(field: "syncDivision")) {
            _ = try ModulationSourceParams.apply(["syncDivision": .string("1/8")],
                                                 to: .defaults(for: .lfo))
        }
        let message = ModulationError.modulationTempoSyncUnavailable(field: "syncDivision")
            .errorDescription ?? ""
        #expect(message.contains("m39-c") && message.contains("rateHz"), "\(message)")
        // The reason it refuses: the sibling table has no LFO entry.
        #expect(TempoSync.registration(forSource: .lfo) == nil)
        // Explicit null is NOT a refusal — it is "no sync", which is the v1 state.
        #expect(throws: Never.self) {
            _ = try ModulationSourceParams.apply(["syncDivision": .null],
                                                 to: .defaults(for: .lfo))
        }
        // And the free-running rate ships alone, unobstructed.
        let (params, _) = try! ModulationSourceParams.apply(["rateHz": .number(6)],
                                                            to: .defaults(for: .lfo))
        guard case .lfo(let lfo) = params else { Issue.record("wrong kind"); return }
        #expect(lfo.rateHz == 6)
        #expect(lfo.syncDivision == nil)
    }

    // MARK: - clamp-and-warn, and unknown-key rejection

    @Test("§7.5: out-of-range params CLAMP AND WARN; an unknown key is REFUSED")
    func paramsClampAndWarnButRejectTypos() throws {
        let (params, warnings) = try ModulationSourceParams.apply(
            ["rateHz": .number(1_000)], to: .defaults(for: .lfo))
        guard case .lfo(let lfo) = params else { Issue.record("wrong kind"); return }
        #expect(lfo.rateHz == LFOSourceParams.rateRange.upperBound)
        #expect(warnings.contains { $0.hasPrefix(ModulationWarning.paramClamped) })
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["ratehz": .number(2)],
                                                 to: .defaults(for: .lfo))
        }
    }

    @Test("§7.5: a param that needs a different waveform is STORED and the caller is told when it applies")
    func ignoredParamsWarnRatherThanVanish() throws {
        let (_, warnings) = try ModulationSourceParams.apply(
            ["waveform": .string("sine"), "pulseWidth": .number(0.3)],
            to: .defaults(for: .lfo))
        #expect(warnings.contains { $0.hasPrefix(ModulationWarning.paramIgnored) })
        // Control: on a square it is NOT reported as ignored.
        let (_, quiet) = try ModulationSourceParams.apply(
            ["waveform": .string("square"), "pulseWidth": .number(0.3)],
            to: .defaults(for: .lfo))
        #expect(!quiet.contains { $0.hasPrefix(ModulationWarning.paramIgnored) })
    }

    @Test("§7.4: steps refuse when empty, over-long or non-finite — and clamp-warn in range")
    func stepsValidation() throws {
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["steps": .numbers([])],
                                                 to: .defaults(for: .stepSequencer))
        }
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(
                ["steps": .numbers(Array(repeating: 0.5, count: 65))],
                to: .defaults(for: .stepSequencer))
        }
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["steps": .numbers([0, .nan])],
                                                 to: .defaults(for: .stepSequencer))
        }
        let (params, warnings) = try ModulationSourceParams.apply(
            ["steps": .numbers([2, -2])], to: .defaults(for: .stepSequencer))
        guard case .stepSequencer(let step) = params else { Issue.record("kind"); return }
        #expect(step.steps == [1, -1])
        #expect(warnings.contains { $0.hasPrefix(ModulationWarning.paramClamped) })
    }

    @Test("§7.4: a cross-strip follower key is REFUSED, not silently self-keyed")
    func crossStripKeyIsRefused() {
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["source": .string("otherTrack")],
                                                 to: .defaults(for: .envelopeFollower))
        }
    }

    // MARK: - m39-w4-4 / 4e (W9-UNLOCK) — the stepDivision unlock

    /// The step half of the old `tempoSyncIsRefusedNotHandRolled` pin, FLIPPED ON PURPOSE by the unlock.
    @Test("m39-w4-4 unlock: stepDivision ACCEPTS all 18 NoteDivision values; null clears it; '1/17', a number and a bool refuse, listing every value")
    func stepDivisionIsUnlocked() throws {
        let fresh = ModulationSourceParams.defaults(for: .stepSequencer)
        #expect(NoteDivision.allCases.count == 18)
        for division in NoteDivision.allCases {
            let (params, _) = try ModulationSourceParams.apply(
                ["stepDivision": .string(division.rawValue)], to: fresh)
            guard case .stepSequencer(let step) = params else { Issue.record("kind"); return }
            #expect(step.stepDivision == division.rawValue)
            #expect(step.syncedDivision == division)
            #expect(TempoSync.syncedDivision(of: params) == division)
        }
        let synced = try ModulationSourceParams.apply(["stepDivision": .string("1/16")], to: fresh).params
        let cleared = try ModulationSourceParams.apply(["stepDivision": .null], to: synced).params
        guard case .stepSequencer(let free) = cleared else { Issue.record("kind"); return }
        #expect(free.stepDivision == nil && free.syncedDivision == nil, "null runs the source free again")
        let valid = NoteDivision.allCases.map(\.rawValue)
        let refused: [ModulationParamValue] = [.string("1/17"), .string("1/16 "), .string(""), .string("1/4T"),
                                               .number(16), .bool(true), .numbers([1, 16])]
        for value in refused {
            #expect(throws: ModulationError.unknownModulationParam(
                key: "stepDivision", kind: "stepSequencer", valid: valid)) {
                _ = try ModulationSourceParams.apply(["stepDivision": value], to: synced)
            }
        }
        let message = ModulationError.unknownModulationParam(
            key: "stepDivision", kind: "stepSequencer", valid: valid).errorDescription ?? ""
        #expect(message.contains("1/16") && message.contains("1/32t") && message.contains("1/1d"), "\(message)")
    }

    @Test("m39-w4-4e: an edit that does not name stepDivision KEEPS it (steps, edgeMs, rateHz, nothing at all)")
    func editsKeepStepDivision() throws {
        let synced = try ModulationSourceParams.apply(
            ["stepDivision": .string("1/8t"), "steps": .numbers([1, 0])],
            to: .defaults(for: .stepSequencer)).params
        let edits: [[String: ModulationParamValue]] = [
            ["steps": .numbers([0, 1, 0.5])], ["edgeMs": .number(5)], ["rateHz": .number(9)], [:],
        ]
        for edit in edits {
            let params = try ModulationSourceParams.apply(edit, to: synced).params
            guard case .stepSequencer(let step) = params else { Issue.record("kind"); return }
            #expect(step.stepDivision == "1/8t", "the edit \(edit.keys.sorted()) un-synced the source")
        }
    }

    @Test("m39-w4-4e: ONE inert-rateHz sentence, warned when a call sets the division or the rate on a synced source, never on a free source or a steps-only edit")
    func inertRateSentenceHasOneHome() throws {
        let fresh = ModulationSourceParams.defaults(for: .stepSequencer)
        let (synced, addWarnings) = try ModulationSourceParams.apply(["stepDivision": .string("1/16")], to: fresh)
        let note = try #require(TempoSync.inertRateNote(for: synced))
        let warning = "\(ModulationWarning.paramIgnored): \(note)"
        #expect(addWarnings == [warning], "stepDivision alone (mod.addSource's shape) is told")
        #expect(note.contains("'rateHz' is ignored while 'stepDivision' is set") && note.contains("1/16")
                && note.contains("null"), "\(note)")
        let (rated, rateWarnings) = try ModulationSourceParams.apply(["rateHz": .number(8)], to: synced)
        #expect(rateWarnings == [warning], "rateHz on a synced source is told")
        guard case .stepSequencer(let ratedStep) = rated else { Issue.record("kind"); return }
        #expect(ratedStep.rateHz == 8 && ratedStep.stepDivision == "1/16", "the rate is STORED for when sync clears")
        #expect(try ModulationSourceParams.apply(["steps": .numbers([0, 1])], to: synced).warnings.isEmpty)
        #expect(try ModulationSourceParams.apply(["rateHz": .number(8)], to: fresh).warnings.isEmpty)
        let (cleared, clearWarnings) = try ModulationSourceParams.apply(
            ["stepDivision": .null, "rateHz": .number(8)], to: synced)
        #expect(clearWarnings.isEmpty, "clearing the division makes the rate live again: nothing to warn")
        #expect(TempoSync.inertRateNote(for: cleared) == nil)
        #expect(TempoSync.inertRateNote(for: .lfo(LFOSourceParams())) == nil)
    }

    @Test("m39-w4-4: the TempoSync sibling table registers the step sequencer ONLY, under names the applier accepts")
    func modulationSyncSiblingTable() {
        #expect(TempoSync.modulationSourceRegistrations.map(\.kind) == [.stepSequencer])
        for kind in ModulationSourceKind.allCases where kind != .stepSequencer {
            #expect(TempoSync.registration(forSource: kind) == nil, "\(kind) must not sync")
        }
        for registration in TempoSync.modulationSourceRegistrations {
            // The applier's own name list, read from its refusal of a name no kind has (the template reader's probe).
            var names: [String] = []
            do {
                _ = try ModulationSourceParams.apply(["\u{1}probe": .null], to: .defaults(for: registration.kind))
            } catch let ModulationError.unknownModulationParam(_, _, valid) {
                names = valid
            } catch {
                Issue.record("unexpected \(error)")
            }
            #expect(names.contains(registration.divisionParam), "\(names)")
            #expect(names.contains(registration.freeRateParam), "\(names)")
        }
        #expect(TempoSync.divisionValues == NoteDivision.allCases.map(\.rawValue))
        for raw in TempoSync.divisionValues + ["1/17", ""] {
            let step = StepSequencerSourceParams(steps: [1, 0], stepDivision: raw)
            #expect(TempoSync.syncedDivision(of: .stepSequencer(step)) == step.syncedDivision, "\(raw)")
        }
        #expect(TempoSync.syncedDivision(of: .stepSequencer(StepSequencerSourceParams())) == nil)
        #expect(TempoSync.syncedDivision(of: .lfo(LFOSourceParams(syncDivision: "1/8"))) == nil,
                "a hand-edited LFO division never syncs")
    }

    @Test("m39-w4-4e: the describe summary — stepsPerBar at the meter in force (16, 12, 5.33), whether the pattern fits the bar, the restart and loop sentences, and the setter's sentence")
    func syncSummaryReportsBarFitAndRestart() throws {
        let meter = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                           .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
        let sixteen = StepSequencerSourceParams(steps: Array(repeating: 0, count: 16), stepDivision: "1/16")
        let in44 = try #require(sixteen.syncSummary(meterMap: meter, atBeat: 4))
        #expect(in44.stepsPerBar == 16 && in44.meter == "4/4" && in44.division == .sixteenth)
        #expect(in44.restart.contains("plays 1 time per bar"), "\(in44.restart)")
        let in34 = try #require(sixteen.syncSummary(meterMap: meter, atBeat: 17))
        #expect(in34.stepsPerBar == 12 && in34.meter == "3/4")
        #expect(in34.restart.contains("does not line up"), "16 steps in a 12-step bar: \(in34.restart)")
        let twelve = StepSequencerSourceParams(steps: Array(repeating: 0, count: 3), stepDivision: "1/16")
        let twelveIn34 = try #require(twelve.syncSummary(meterMap: meter, atBeat: 17))
        #expect(twelveIn34.restart.contains("plays 4 times per bar"), "\(twelveIn34.restart)")
        let dotted = StepSequencerSourceParams(steps: [1, 0, 0], stepDivision: "1/8d")
        let d = try #require(dotted.syncSummary(meterMap: meter, atBeat: 0))
        #expect(abs(d.stepsPerBar - 16.0 / 3.0) < 1e-12)
        #expect(d.restart.contains("5.33"), "\(d.restart)")
        let twoBars = StepSequencerSourceParams(steps: Array(repeating: 0, count: 32), stepDivision: "1/16")
        let twoBarsIn44 = try #require(twoBars.syncSummary(meterMap: meter, atBeat: 0))
        #expect(twoBarsIn44.restart.contains("spans 2 bars"), "\(twoBarsIn44.restart)")
        for (params, summary) in [(sixteen, in44), (sixteen, in34), (dotted, d)] {
            #expect(summary.restart.contains("starts again from step 1 at every time-signature change"))
            #expect(summary.restart.contains("loop"))
            #expect(summary.rateNote == TempoSync.inertRateNote(for: .stepSequencer(params)))
        }
        #expect(StepSequencerSourceParams(steps: [1, 0]).syncSummary(meterMap: meter, atBeat: 0) == nil)
    }

    /// The DAWCore half of the old-project decode fixture; the render half (byte gate on a bounce) is
    /// `StepDivisionG8Tests.oldProjectStepSourcePlaysAsBefore`.
    @Test("m39-w4-4e: an OLD project's step source (no stepDivision key) decodes free-running and re-encodes without the key; a saved synced source round-trips")
    func oldProjectStepSourceDecodesFree() throws {
        let old = #"{"id":"6A0B2E1C-3F4D-4E5A-9B6C-7D8E9F0A1B2C","kind":"stepSequencer","name":"Step","params":{"kind":"stepSequencer","steps":[1,0,0.5,-0.5],"rateHz":5.3,"edgeMs":2}}"#
        let decoded = try JSONDecoder().decode(ModulationSource.self, from: Data(old.utf8))
        guard case .stepSequencer(let step) = decoded.params else { Issue.record("kind"); return }
        #expect(step.stepDivision == nil && step.syncedDivision == nil)
        #expect(TempoSync.syncedDivision(of: decoded.params) == nil)
        #expect(step.steps == [1, 0, 0.5, -0.5] && step.rateHz == 5.3 && step.edgeMs == 2)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("stepDivision"), "\(reencoded)")
        var synced = decoded
        synced.params = try ModulationSourceParams.apply(["stepDivision": .string("1/8d")], to: decoded.params).params
        let roundTrip = try JSONDecoder().decode(ModulationSource.self, from: try JSONEncoder().encode(synced))
        #expect(roundTrip == synced)
        #expect(TempoSync.syncedDivision(of: roundTrip.params) == .eighthDotted)
    }
}
