import Foundation
import Testing
@testable import DAWCore

/// ⭐⭐ **m39-o LANDS THE EXHAUSTIVE PIN FOUR `ProjectDocument` COMMENTS HAD
/// BEEN DEFERRING TO IT** (`hallReverb`, `tapeDelay`, `stereoWidth` and
/// `flanger` each say "covered by hand until m39-o lands the exhaustive pin").
///
/// **The hazard.** `EffectDocument` mirrors `EffectDescriptor` BY HAND at SIX
/// sites: the stored property, `CodingKeys`, `init(from effect:)`,
/// `decodeIfPresent`, `encodeIfPresent`, and `effectDescriptor()`. The compiler
/// forces only three of them. Miss `encodeIfPresent` and the project **saves,
/// reports success, and reopens with that effect reset to defaults** — silent
/// data loss, on the user's work, with every existing test green.
///
/// **Why this is a census and not a list.** The loop is driven by
/// `EffectDescriptor.Kind.allCases` and a kind with no fixture entry FAILS
/// here rather than being skipped. That is the m39-n lesson applied: a
/// hand-written array READS like "every kind is covered" while silently
/// omitting whichever one nobody remembered to append, and `.tapeDelay` had
/// already been lost from exactly such an array in `FXCommandTests`.
///
/// **Why the fixtures are non-default in every field.** A round trip whose
/// fixture is all-defaults passes with every `encodeIfPresent` DELETED, because
/// the `resolved<Kind>` accessors manufacture defaults out of nil. Every value
/// below differs from the default, and `everyFixtureIsActuallyNonDefault` pins
/// that property mechanically rather than trusting the author.
///
/// The per-kind hand-written legs in `PersistenceTests` stay: they name the
/// individual fields and go through the real `ProjectStore` save/open path,
/// which this suite deliberately does not (it isolates the MIRROR).
@Suite("EffectDocument mirror — every kind, every site (m39-o)")
struct EffectDocumentMirrorTests {

    /// `.eq` and `.delay` carry v2 additive optionals whose defaults are
    /// expressed as nil, so they are built then mutated rather than squeezed
    /// through one initialiser. Every field below is non-default;
    /// `everyFixtureIsActuallyNonDefault` is what proves it stayed that way.
    private static func nonDefaultEQ() -> EQParams {
        var eq = EQParams(lowShelfFreq: 137, lowShelfGainDb: -4.5,
                          peak1Freq: 1_234, peak1GainDb: 6.25, peak1Q: 2.4,
                          peak2Freq: 4_100, peak2GainDb: -3.75, peak2Q: 0.55,
                          highShelfFreq: 7_800, highShelfGainDb: 3.5)
        eq.highPassFreq = 62
        eq.highPassSlopeDbPerOct = 24
        // ⚠️ `true`, not `false`: the SPEC default for these two is 0 (the
        // filter is off until you give it a frequency), while the nil-decoding
        // default is `true`. The control compares against the SPEC.
        eq.highPassEnabled = true
        eq.lowPassFreq = 15_500
        eq.lowPassSlopeDbPerOct = 24
        eq.lowPassEnabled = true
        eq.lowShelfQ = 1.9
        eq.highShelfQ = 1.3
        eq.lowShelfEnabled = false
        eq.peak1Enabled = false
        eq.peak2Enabled = false
        eq.highShelfEnabled = false
        return eq
    }

    private static func nonDefaultDelay() -> DelayParams {
        var delay = DelayParams(timeMs: 333, feedback: 0.62, mix: 0.44,
                                pingPong: 0.8, highCutHz: 4_500)
        delay.sync = true
        delay.division = .eighthDotted
        return delay
    }

    /// One NON-DEFAULT descriptor per kind. ⛔ ADD A ROW WHEN YOU ADD A KIND —
    /// `everyKindRoundTripsThroughTheHandWrittenMirror` fails loudly otherwise.
    /// ⚠️ `internal`, not `private`, since m39-y: `TransientShaperSiteTests`
    /// runs the SAME non-default fixtures through `MixerPresets.withFreshID()`,
    /// which is a SEVENTH hand-written rebuild site of exactly this shape and
    /// which no gate in this tree covers. Sharing the fixtures rather than
    /// copying them is the ONE HOME rule: a second table would drift, and a
    /// drifted fixture is how `everyFixtureIsActuallyNonDefault` stops meaning
    /// anything.
    static let fixtures: [EffectDescriptor.Kind: EffectDescriptor] = [
        .gain: EffectDescriptor(kind: .gain,
                                gain: GainParams(gainLinear: 2.75, invertPolarity: true)),
        .eq: EffectDescriptor(kind: .eq, eq: nonDefaultEQ()),
        .compressor: EffectDescriptor(
            kind: .compressor,
            compressor: CompressorParams(thresholdDb: -21.5, ratio: 5.5, attackMs: 7.25,
                                         releaseMs: 155, kneeDb: 4.5, makeupDb: 3.25,
                                         mix: 0.65,
                                         // m39-ae de-esser — non-default on all
                                         // three, or their mirror sites are
                                         // untested (the census below is what
                                         // caught this).
                                         detectorMode: 1, detectorFreqHz: 7_250,
                                         detectorQ: 3.25)),
        .limiter: EffectDescriptor(kind: .limiter,
                                   limiter: LimiterParams(ceilingDb: -1.7, releaseMs: 88,
                                                          truePeak: true)),
        .reverb: EffectDescriptor(kind: .reverb,
                                  reverb: ReverbParams(roomSize: 0.73, damping: 0.41,
                                                       mix: 0.37, preDelayMs: 23,
                                                       width: 0.85)),
        .delay: EffectDescriptor(kind: .delay, delay: nonDefaultDelay()),
        // m39-ad. `oversampling` 4 (DEFAULT 1 — as a NEW clipper's has also been
        // since the 2026-09-20 ruling) so a mirror site that dropped the new
        // field reddens. ⚠️ 4 is an
        // exact supported factor, so `SaturatorParams.init`'s SNAPPING leaves
        // it unchanged — a fixture whose value the init rewrote would make the
        // round-trip compare equal for the wrong reason.
        .saturator: EffectDescriptor(kind: .saturator,
                                     saturator: SaturatorParams(driveDb: 9.5, mix: 0.72,
                                                                outputDb: -2.5,
                                                                oversampling: 4)),
        .gate: EffectDescriptor(kind: .gate,
                                gate: GateParams(thresholdDb: -37.5, attackMs: 2.25,
                                                 holdMs: 44, releaseMs: 175)),
        .chorus: EffectDescriptor(kind: .chorus,
                                  chorus: ChorusParams(rateHz: 1.35, depthMs: 4.4, mix: 0.58)),
        .bassEnhancer: EffectDescriptor(
            kind: .bassEnhancer,
            bassEnhancer: BassEnhancerParams(crossoverHz: 92, amount: 0.63, mix: 0.47)),
        .bitCrusher: EffectDescriptor(
            kind: .bitCrusher,
            bitCrusher: BitCrusherParams(bits: 7, downsampleHz: 11_025, antiAlias: true,
                                         dither: true, mix: 0.66)),
        .djFilter: EffectDescriptor(
            kind: .djFilter,
            djFilter: DJFilterParams(position: -0.62, resonance: 0.73, slopeDbPerOct: 12,
                                     deadZoneWidth: 0.16, resonanceTrack: 0.4)),
        .ringMod: EffectDescriptor(
            kind: .ringMod,
            ringMod: RingModParams(carrierHz: 437, mix: 0.81, waveform: 2,
                                   inputHighCutHz: 6_500, stereoSpreadDeg: 55)),
        .flanger: EffectDescriptor(
            kind: .flanger,
            flanger: FlangerParams(rateHz: 1.7, depthMs: 6.5, delayMs: 2.25,
                                   feedback: -0.66, mix: 0.83, stereoPhaseDeg: 145)),
        .hallReverb: EffectDescriptor(
            kind: .hallReverb,
            hallReverb: HallReverbParams(mix: 0.42, decaySeconds: 4.75, sizeMeters: 33,
                                         preDelayMs: 27, width: 0.71, diffusion: 0.83,
                                         earlyLateBalance: 0.36,
                                         lowDecayMultiplier: 1.4,
                                         highDecayMultiplier: 0.28,
                                         lowCrossoverHz: 260, highCrossoverHz: 5_600,
                                         modRateHz: 0.65, modDepthMs: 1.1, freeze: 1)),
        .tapeDelay: EffectDescriptor(
            kind: .tapeDelay,
            tapeDelay: TapeDelayParams(timeMs: 475, feedback: 0.61, mix: 0.52,
                                       wowDepthMs: 3.75, wowRateHz: 1.4,
                                       flutterDepthMs: 0.55, saturationDrive: 0.68,
                                       highCutHz: 8_200)),
        .stereoWidth: EffectDescriptor(
            kind: .stereoWidth,
            stereoWidth: StereoWidthParams(width: 1.63, spread: 0.71, bassMonoHz: 87.5,
                                           bassMonoAmount: 0.42)),
        .phaser: EffectDescriptor(
            kind: .phaser,
            phaser: PhaserParams(rateHz: 1.9, centerHz: 640, depthOctaves: 1.75,
                                 stages: 12, feedback: -0.72, mix: 0.81,
                                 stereoPhaseDeg: 137)),
        .transientShaper: EffectDescriptor(
            kind: .transientShaper,
            transientShaper: TransientShaperParams(attackDb: 7.25, sustainDb: -11.5,
                                                   attackMs: 0.8, sustainMs: 675,
                                                   outputDb: -4.25, mix: 0.62)),
        // m39-z. EVERY field non-default, including the two that are 0 by
        // default AND bipolar — `fineHz` and `stereoSpreadHz` are given
        // NEGATIVE values on purpose, so a mirror site that dropped the field
        // and a mirror site that dropped only its SIGN both redden.
        .freqShifter: EffectDescriptor(
            kind: .freqShifter,
            freqShifter: FreqShifterParams(shiftHz: -347.5, fineHz: -6.25,
                                           stereoSpreadHz: 3.75, mix: 0.83,
                                           outputDb: -5.5)),
        // m39-ac. EVERY field non-default, including BOTH discrete ones —
        // `mode` 1 (soft, default hard) and `oversampling` 2 (1 for a new
        // clipper, 4 for a pre-ruling one saved without params — 2 is neither) — so a
        // mirror site that dropped either snapped field reddens. ⚠️ The two
        // discrete values are chosen to survive `ClipperParams.init`'s SNAPPING
        // unchanged (1 and 2 are exact), because a fixture whose value the init
        // rewrites would make the round-trip compare equal for the wrong reason.
        .clipper: EffectDescriptor(
            kind: .clipper,
            clipper: ClipperParams(driveDb: 9.5, ceilingDb: -4.25, mode: 1,
                                   oversampling: 2, mix: 0.73, outputDb: -3.5)),
        // m39-af. ALL THIRTY-TWO FIELDS NON-DEFAULT, so a mirror site that
        // dropped any one of them reddens — and the bands are given DIFFERENT
        // values from each other on purpose: a mirror that wrote band 1's block
        // four times would compare equal against a fixture whose bands matched.
        // ⚠️ Every `mode` is non-zero AND distinct from the others, because 0 is
        // the default and a dropped mode field would decode back to it. The
        // values are all inside their clamps so the clamping init rewrites
        // nothing (the `ClipperParams` snapping note above, same trap).
        .dynamicEQ: EffectDescriptor(
            kind: .dynamicEQ,
            dynamicEQ: DynamicEQParams(
                band1Mode: 1, band1Freq: 91.5, band1Q: 0.75, band1ThresholdDb: -31.5,
                band1Ratio: 2.5, band1RangeDb: -9.25, band1AttackMs: 3.5,
                band1ReleaseMs: 63.5,
                band2Mode: 2, band2Freq: 413.25, band2Q: 1.25, band2ThresholdDb: -24.75,
                band2Ratio: 6.5, band2RangeDb: 4.5, band2AttackMs: 17.25,
                band2ReleaseMs: 231.5,
                band3Mode: 1, band3Freq: 2_712.5, band3Q: 5.5, band3ThresholdDb: -13.25,
                band3Ratio: 11.5, band3RangeDb: -15.75, band3AttackMs: 0.75,
                band3ReleaseMs: 41.25,
                band4Mode: 2, band4Freq: 10_450.5, band4Q: 9.25, band4ThresholdDb: -7.5,
                band4Ratio: 17.25, band4RangeDb: 11.5, band4AttackMs: 44.5,
                band4ReleaseMs: 812.75)),
        .audioUnit: EffectDescriptor(
            kind: .audioUnit,
            audioUnit: AudioUnitConfig(
                component: AudioUnitComponentID(type: "aufx", subType: "dcmp",
                                                manufacturer: "appl"),
                name: "AUDynamicsProcessor", manufacturerName: "Apple",
                stateData: Data([0x62, 0x70, 0x6C, 0x69]))),
    ]

    private func roundTrip(_ descriptor: EffectDescriptor) throws -> EffectDescriptor? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(EffectDocument(from: descriptor))
        let decoded = try JSONDecoder().decode(EffectDocument.self, from: bytes)
        return decoded.effectDescriptor()
    }

    // MARK: - ⭐ The census

    /// ⛔ A KIND WITH NO FIXTURE FAILS HERE. That is the point: adding a kind
    /// and forgetting one of the six mirror sites is SILENT DATA LOSS, and the
    /// only thing that catches it is a census that refuses to be incomplete.
    @Test("⭐ every effect kind survives the hand-written EffectDocument mirror intact")
    func everyKindRoundTripsThroughTheHandWrittenMirror() throws {
        let all = EffectDescriptor.Kind.allCases
        // Non-vacuity: if `allCases` ever stopped enumerating, the loop below
        // would pass by doing nothing.
        #expect(all.count >= 21, "the kind roster went vacuous: \(all.map(\.rawValue))")

        let uncovered = all.filter { Self.fixtures[$0] == nil }
        #expect(uncovered.isEmpty, """
            kinds with no fixture in this census: \(uncovered.map(\.rawValue)) — add a \
            NON-DEFAULT descriptor rather than widening the filter. A kind with no mirror \
            fixture is how a save silently drops a user's settings.
            """)

        for kind in all {
            guard let fixture = Self.fixtures[kind] else { continue }
            #expect(fixture.kind == kind, "fixture for \(kind.rawValue) carries the wrong kind")
            let rebuilt = try roundTrip(fixture)
            let restored = try #require(
                rebuilt,
                "\(kind.rawValue): the document mirror could not rebuild a descriptor at all")
            #expect(restored == fixture, """
                \(kind.rawValue) did NOT survive the mirror. One of the six hand-written \
                sites in ProjectDocument.swift is missing this kind — a project carrying it \
                SAVES successfully and REOPENS with the effect reset to defaults.
                """)
        }
    }

    /// ⭐ THE FIXTURE CONTROL, and it is what makes the census above evidence.
    /// A round trip of an ALL-DEFAULTS descriptor passes with every
    /// `encodeIfPresent` deleted, because `resolved<Kind>` manufactures the
    /// defaults back out of nil. So every fixture must differ from its kind's
    /// default — asserted mechanically, not trusted.
    @Test("⭐ every fixture is genuinely non-default, so the census cannot pass vacuously")
    func everyFixtureIsActuallyNonDefault() throws {
        for (kind, fixture) in Self.fixtures {
            // Built the way an untouched insert is built: kind only.
            let plain = EffectDescriptor(id: fixture.id, kind: kind)
            #expect(fixture != plain,
                    "the \(kind.rawValue) fixture is indistinguishable from a fresh insert")
            guard kind != .audioUnit else { continue }
            // And every DECLARED param differs from its declared default, so
            // the mirror cannot lose one field and keep the rest.
            for spec in EffectParamSpec.specs(for: kind) {
                let value = try #require(fixture.paramValue(spec.name),
                                         "\(kind.rawValue).\(spec.name) is unreadable")
                #expect(abs(value - spec.defaultValue) > 1e-9, """
                    \(kind.rawValue).\(spec.name) is at its default (\(spec.defaultValue)) in \
                    the fixture — that field's mirror site is untested
                    """)
            }
        }
    }

    /// ⭐ POSITIVE CONTROL ON THE INSTRUMENT ITSELF. A dropped mirror site
    /// looks like "the params object came back nil". This reproduces that
    /// failure shape directly — a document whose params key was never written
    /// — and proves the comparison above reddens on it. Without this, a
    /// `roundTrip` that silently returned its own input would pass everything.
    @Test("⭐ the comparison DOES redden when a params object goes missing")
    func aDroppedParamsObjectIsDetected() throws {
        for kind in [EffectDescriptor.Kind.phaser, .stereoWidth, .flanger, .tapeDelay] {
            let fixture = try #require(Self.fixtures[kind])
            // The exact shape of a missing `encodeIfPresent`: the key is absent
            // from the JSON, so the decode produces nil and `effectDescriptor()`
            // rebuilds a defaults-only descriptor.
            let stripped = #"{"id":"\#(fixture.id.uuidString)","kind":"\#(kind.rawValue)"}"#
            let decoded = try JSONDecoder().decode(
                EffectDocument.self, from: Data(stripped.utf8))
            let rebuilt = try #require(decoded.effectDescriptor())
            #expect(rebuilt != fixture,
                    "a \(kind.rawValue) descriptor with its params key STRIPPED compares equal to one with them — the census is not measuring anything")
            // …and it is exactly the defaults-only shape, which is what the
            // user would see on reopen.
            #expect(rebuilt == EffectDescriptor(id: fixture.id, kind: kind))
        }
    }

    /// §12 gate 7, generalised: a descriptor with NO params object must encode
    /// to bytes that carry no per-kind key at all, so a project saved before a
    /// kind existed stays byte-identical. The positive control is built in.
    @Test("a nil params object is OMITTED, not encoded as null, for every kind")
    func nilParamsAreOmittedForEveryKind() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let id = UUID(uuidString: "0BADF00D-1111-2222-3333-444444444444")!
        let bare = EffectDocument(from: EffectDescriptor(id: id, kind: .gain,
                                                         gain: GainParams(gainLinear: 1.5)))
        let bareBytes = try encoder.encode(bare)
        let text = String(decoding: bareBytes, as: UTF8.self)
        for kind in EffectDescriptor.Kind.allCases where kind != .gain {
            #expect(!text.contains("\"\(kind.rawValue)\""),
                    "a nil \(kind.rawValue) must be OMITTED, not encoded as null")
        }
        // POSITIVE CONTROL: populate one and watch the bytes change and the key
        // appear, so the absence above is a measurement and not a broken probe.
        var populated = bare
        populated.phaser = PhaserParams(centerHz: 640, stages: 12)
        let populatedBytes = try encoder.encode(populated)
        #expect(populatedBytes != bareBytes,
                "the encoder is ignoring `phaser` entirely — the omission proof is vacuous")
        #expect(String(decoding: populatedBytes, as: UTF8.self).contains("\"phaser\""))
        let decoded = try JSONDecoder().decode(EffectDocument.self, from: populatedBytes)
        #expect(decoded.phaser?.centerHz == 640)
        #expect(decoded.phaser?.stages == 12)
        #expect(decoded.effectDescriptor()?.phaser?.stages == 12)
    }
}
