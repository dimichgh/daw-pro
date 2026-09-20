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
    /// 113 over 18. A new param without a verdict must fail this loudly.
    @Test("§6.2 frozen verdict split: 74 yes + 20 warned + 19 refused = 113 across all 18 param-bearing kinds")
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
        #expect(total == 113)
        #expect(yes == 74)
        #expect(warned == 20)
        #expect(refused == 19)
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
        #expect(checked == 113)
        #expect(refusedByAutomation >= 2, "delay.sync and delay.division at minimum")
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

    @Test("⛔ §7.2.1: syncDivision / stepDivision REFUSE in v1, naming m39-c as the prerequisite")
    func tempoSyncIsRefusedNotHandRolled() {
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["syncDivision": .string("1/8")],
                                                 to: .defaults(for: .lfo))
        }
        #expect(throws: ModulationError.self) {
            _ = try ModulationSourceParams.apply(["stepDivision": .string("1/16")],
                                                 to: .defaults(for: .stepSequencer))
        }
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
}
