import Foundation
import Testing
@testable import DAWCore

/// m39-y L10 (B7 half) — **THE HAND-WRITTEN REBUILD SITE NO GATE IN THIS TREE
/// CAN SEE.** The B8 half (`ProjectStore`'s display-name `default:` arm) lives
/// in `EffectChainStoreTests`, because `ProjectStore` is `@MainActor` and
/// `MainActorOccupancySiteTests` Leg C pins the main-actor SUITE count at its
/// cap with ZERO SLACK — so this suite deliberately stays nonisolated.
///
/// `EffectDescriptor` has **EIGHT** compiler-silent per-kind rebuild sites, not
/// the six that are folklore here. Six of them live in `ProjectDocument.swift`
/// and are pinned by `EffectDocumentMirrorTests`' census. The other two are:
///
///  · **B7 — `MixerPresets.withFreshID()`.** It rebuilds the descriptor FIELD BY
///    FIELD. Omit a kind and a mixer preset containing it stamps onto a strip
///    with the right kind and **every parameter silently reset to default**.
///    `scripts/gates/effect-kind-surface.mjs` does not list `MixerPresets.swift`
///    as a surface, so a green gate run says nothing about it.
///  · **B8 — `ProjectStore.effectDisplayName`.** It has a `default:` arm, and
///    its own comment says *"The compiler cannot catch that — this switch is not
///    exhaustive."* Omit a kind and it ships as "TransientShaper" in every undo
///    label. The surface gate is whole-file PRESENCE and cannot see it either.
///
/// **Why the compiler is silent on B7:** `EffectDescriptor.init`'s parameters
/// are ALL `= nil`-defaulted, so a field-by-field rebuild call site that omits
/// the new argument compiles cleanly and drops it.
///
/// ⭐ Both legs are CENSUSES driven by `Kind.allCases`, so the NEXT kind is
/// covered without anyone remembering this file exists.
@Suite("m39-y — the compiler-silent preset-stamp rebuild site (B7)")
struct TransientShaperSiteTests {

    /// Shared with `EffectDocumentMirrorTests` — one home for the non-default
    /// fixtures, whose non-defaultness that suite pins mechanically.
    private static var fixtures: [EffectDescriptor.Kind: EffectDescriptor] {
        EffectDocumentMirrorTests.fixtures
    }

    // MARK: - B7: the preset stamp

    /// ⛔ The exact failure this catches: a preset containing the kind stamps
    /// onto a strip and the user sees the right effect with default values.
    /// Nothing else in the tree looks at this file.
    @Test("L10a — every kind's parameters survive a mixer-preset stamp (withFreshID)")
    func everyKindSurvivesThePresetStamp() throws {
        let all = EffectDescriptor.Kind.allCases
        // Non-vacuity: if `allCases` stopped enumerating, the loop would pass
        // by doing nothing at all.
        #expect(all.count >= 21, "the kind roster went vacuous: \(all.map(\.rawValue))")
        let uncovered = all.filter { Self.fixtures[$0] == nil }
        #expect(uncovered.isEmpty,
                "kinds with no fixture: \(uncovered.map(\.rawValue)) — add one to EffectDocumentMirrorTests.fixtures rather than filtering it out")

        for kind in all {
            guard let fixture = Self.fixtures[kind] else { continue }
            let preset = MixerPreset(name: "probe", displayName: "Probe",
                                     summary: "one kind", chain: [fixture])
            let stamped = try #require(preset.freshChain().first)

            // A FRESH id — that is what the method is for.
            #expect(stamped.id != fixture.id, "\(kind.rawValue) kept its template id")
            #expect(stamped.kind == fixture.kind)
            // …and EVERYTHING ELSE identical. Compared by rebuilding the
            // fixture with the stamped id, so the comparison covers every field
            // at once rather than the handful somebody thought to name.
            var expected = fixture
            expected = EffectDescriptor(
                id: stamped.id, kind: fixture.kind, isBypassed: fixture.isBypassed,
                gain: fixture.gain, eq: fixture.eq, compressor: fixture.compressor,
                limiter: fixture.limiter, reverb: fixture.reverb, delay: fixture.delay,
                saturator: fixture.saturator, gate: fixture.gate, chorus: fixture.chorus,
                bassEnhancer: fixture.bassEnhancer, bitCrusher: fixture.bitCrusher,
                djFilter: fixture.djFilter, ringMod: fixture.ringMod,
                flanger: fixture.flanger, hallReverb: fixture.hallReverb,
                tapeDelay: fixture.tapeDelay, stereoWidth: fixture.stereoWidth,
                phaser: fixture.phaser, transientShaper: fixture.transientShaper,
                freqShifter: fixture.freqShifter, clipper: fixture.clipper,
                dynamicEQ: fixture.dynamicEQ,
                audioUnit: fixture.audioUnit)
            #expect(stamped == expected,
                    "\(kind.rawValue) LOST PARAMETERS through withFreshID() — MixerPresets.swift is missing its line")
        }
    }

    /// The named leg for this item's own kind, spelled out field by field so a
    /// regression reads as the bug it is rather than as an anonymous census
    /// failure.
    @Test("L10a-named — a .transientShaper preset keeps all SIX parameters through the stamp")
    func transientShaperSurvivesThePresetStampByField() throws {
        let params = TransientShaperParams(attackDb: 7.25, sustainDb: -11.5,
                                           attackMs: 0.8, sustainMs: 675,
                                           outputDb: -4.25, mix: 0.62)
        let preset = MixerPreset(
            name: "punch", displayName: "Punch", summary: "front of the sound",
            chain: [EffectDescriptor(kind: .transientShaper, transientShaper: params)])
        let stamped = try #require(preset.freshChain().first)
        let back = try #require(stamped.transientShaper)
        #expect(back.attackDb == 7.25)
        #expect(back.sustainDb == -11.5)
        #expect(back.attackMs == 0.8)
        #expect(back.sustainMs == 675)
        #expect(back.outputDb == -4.25)
        #expect(back.mix == 0.62)
        // ⭐ POSITIVE CONTROL on the instrument: a KNOWN-GOOD kind must survive
        // the same check. If `phaser` also came back nil, the probe is broken
        // and the assertion above would be evidence of nothing.
        let control = MixerPreset(
            name: "control", displayName: "Control", summary: "known good",
            chain: [EffectDescriptor(kind: .phaser,
                                     phaser: PhaserParams(centerHz: 640, stages: 12))])
        let controlStamped = try #require(control.freshChain().first)
        #expect(controlStamped.phaser?.centerHz == 640,
                "the known-good control ALSO lost its params — this probe measures nothing")
    }

    /// And the falsifiability proof for the census above: a descriptor whose
    /// params were dropped must COMPARE UNEQUAL. Without this, a `freshChain()`
    /// that returned its input unchanged would pass everything.
    @Test("L10a-control — the preset comparison DOES redden when params are dropped")
    func theStampComparisonCanRedden() throws {
        for kind in [EffectDescriptor.Kind.transientShaper, .phaser, .stereoWidth] {
            let fixture = try #require(Self.fixtures[kind])
            // The exact shape of a missing line in `withFreshID()`: same kind,
            // same id, NO params.
            let dropped = EffectDescriptor(id: fixture.id, kind: kind)
            #expect(dropped != fixture,
                    "a \(kind.rawValue) descriptor with its params DROPPED compares equal to one with them — the census is not measuring anything")
        }
    }
}
