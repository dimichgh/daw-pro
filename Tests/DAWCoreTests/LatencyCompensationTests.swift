import Foundation
import Testing
@testable import DAWCore

/// M4 (viii-a) — unit coverage for the pure PDC planner (spec §8.1):
/// stage maxima and per-strip targets, the §2 worked example verbatim,
/// bypass stability vs. removal, the no-sends direct-to-master refinement,
/// the `B > 0` skew flag, cap clamping with visible residual, and the
/// empty / all-dry degenerate cases.
@Suite("Latency compensation — PDC plan math")
struct LatencyCompensationTests {
    // Stable IDs so assertions read like the spec.
    private let idA = UUID()
    private let idB = UUID()
    private let idC = UUID()
    private let idR = UUID()

    private func track(
        _ id: UUID,
        all: Int,
        active: Int? = nil,
        toMaster: Bool = true,
        sends: Bool = false
    ) -> PDCStripInput {
        PDCStripInput(
            id: id,
            kind: .track(outputsToMaster: toMaster, hasSends: sends),
            chainLatencyAll: all,
            chainLatencyActive: active ?? all
        )
    }

    private func bus(_ id: UUID, all: Int, active: Int? = nil) -> PDCStripInput {
        PDCStripInput(id: id, kind: .bus, chainLatencyAll: all, chainLatencyActive: active ?? all)
    }

    // MARK: - Stage maxima & per-strip targets

    @Test("single latent track direct to master: T set, comp 0 (it IS the max)")
    func singleLatentTrack() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [track(idA, all: 240)]))
        #expect(plan.trackStage == 240)
        #expect(plan.busStage == 0)
        #expect(plan.maxPathLatency == 240)
        #expect(plan[idA]?.compensationSamples == 0)
        #expect(plan[idA]?.clamped == false)
        #expect(plan[idA]?.skewSamples == 0)
    }

    @Test("latent + dry track pair: dry pads to T, latent to 0")
    func latentPlusDryPair() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),
            track(idB, all: 240),
        ]))
        #expect(plan.trackStage == 240)
        #expect(plan[idA]?.compensationSamples == 240)
        #expect(plan[idB]?.compensationSamples == 0)
    }

    @Test("track routed to a bus pads to T, not T+B; the bus adds its own stage")
    func trackRoutedToBus() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 240, toMaster: false), // → bus
            track(idB, all: 0, toMaster: false),   // → bus, dry
            bus(idR, all: 100),
        ]))
        #expect(plan.trackStage == 240)
        #expect(plan.busStage == 100)
        #expect(plan.maxPathLatency == 340)
        // Routed-to-bus tracks target T (the bus-input constraint).
        #expect(plan[idA]?.compensationSamples == 0)
        #expect(plan[idB]?.compensationSamples == 240)
        // The bus is its own stage max → 0.
        #expect(plan[idR]?.compensationSamples == 0)
        // Nothing here feeds master directly with sends → no skew anywhere.
        #expect(plan.strips.allSatisfy { $0.skewSamples == 0 })
    }

    @Test("a track with sends targets T regardless of its routed output")
    func sendsForceTrackStageTarget() {
        // Direct-to-master dry track WITH a send: without the send it would
        // take the T+B refinement (340); the send pins it to T (240).
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0, toMaster: true, sends: true),
            track(idB, all: 240, toMaster: false),
            bus(idR, all: 100),
        ]))
        #expect(plan[idA]?.compensationSamples == 240)
    }

    // MARK: - §2 worked example, verbatim

    @Test("§2 worked example: dry A + limiter B, post-fader sends to reverb bus R")
    func workedExample() {
        // Track A: empty chain (0). Track B: built-in limiter (240 @ 48 kHz).
        // Both route to master, both post-fader sends into shared bus R
        // (algorithmic reverb, 0 fixed latency).
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0, toMaster: true, sends: true),
            track(idB, all: 240, toMaster: true, sends: true),
            bus(idR, all: 0),
        ]))
        #expect(plan.trackStage == 240)      // T = max(0, 240)
        #expect(plan.busStage == 0)          // B = 0
        #expect(plan.maxPathLatency == 240)  // T + B
        #expect(plan[idA]?.compensationSamples == 240) // 240 − 0
        #expect(plan[idB]?.compensationSamples == 0)   // 240 − 240
        #expect(plan[idR]?.compensationSamples == 0)   // 0 − 0
        // B = 0 → no skew despite direct-to-master tracks with sends.
        #expect(plan.strips.allSatisfy { $0.skewSamples == 0 })
        #expect(plan.strips.allSatisfy { !$0.clamped })
    }

    // MARK: - Bypass stability vs. removal

    @Test("bypass: chainLatencyAll constant → only the toggled strip's comp moves")
    func bypassIsStable() {
        let before = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),
            track(idB, all: 240, active: 240),
            bus(idR, all: 0),
        ]))
        // Bypass B's limiter: all stays 240 (stable totals), active drops to 0.
        let after = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),
            track(idB, all: 240, active: 0),
            bus(idR, all: 0),
        ]))
        // Stage maxima and every OTHER strip untouched.
        #expect(after.trackStage == before.trackStage)
        #expect(after.busStage == before.busStage)
        #expect(after.maxPathLatency == before.maxPathLatency)
        #expect(after[idA] == before[idA])
        #expect(after[idR] == before[idR])
        // Only B retargets, by exactly the bypassed effect's latency: its
        // ring absorbs the 240 the chain no longer delays.
        #expect(before[idB]?.compensationSamples == 0)
        #expect(after[idB]?.compensationSamples == 240)
    }

    @Test("removal: chainLatencyAll drops → the maxima DO move, everyone retargets")
    func removalMovesMaxima() {
        let before = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),
            track(idB, all: 240),
        ]))
        #expect(before.trackStage == 240)
        #expect(before[idA]?.compensationSamples == 240)

        // Delete B's limiter: all AND active drop to 0.
        let after = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),
            track(idB, all: 0),
        ]))
        #expect(after.trackStage == 0)
        #expect(after.maxPathLatency == 0)
        #expect(after[idA]?.compensationSamples == 0)
        #expect(after[idB]?.compensationSamples == 0)
    }

    // MARK: - Refinement & skew

    @Test("no-sends direct-to-master track aligns to T+B (free refinement)")
    func directToMasterRefinement() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0, toMaster: true, sends: false), // dry, direct
            track(idB, all: 240, toMaster: false),            // latent → bus
            bus(idR, all: 100),
        ]))
        #expect(plan.trackStage == 240)
        #expect(plan.busStage == 100)
        // A has no bus-input constraint → pads all the way to T+B = 340 and
        // lands at master together with the bus outputs.
        #expect(plan[idA]?.compensationSamples == 340)
        #expect(plan[idA]?.skewSamples == 0)
    }

    @Test("direct-to-master track WITH sends while B > 0 gets skewSamples = B")
    func skewFlagWhenBPositive() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0, toMaster: true, sends: true), // the skew case
            track(idB, all: 240, toMaster: false),
            bus(idR, all: 100),
        ]))
        // A pads to T (send constraint), so its dry feed hits master at T
        // while bus returns hit at T+B: 100 samples early, reported.
        #expect(plan[idA]?.compensationSamples == 240)
        #expect(plan[idA]?.skewSamples == 100)
        // Everyone else: zero skew.
        #expect(plan[idB]?.skewSamples == 0)
        #expect(plan[idR]?.skewSamples == 0)
    }

    // MARK: - Cap clamping

    @Test("plan above the 16 384 cap clamps, flags, and exposes the residual")
    func capClamping() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0),      // dry → planned comp = T = 20 000
            track(idB, all: 20_000), // monstrous hosted chain
        ]))
        let a = try! #require(plan[idA])
        #expect(a.plannedSamples == 20_000)
        #expect(a.compensationSamples == 16_384)
        #expect(a.clamped)
        #expect(a.residualSamples == 3_616)
        // The latent strip itself needs no comp and is not clamped.
        #expect(plan[idB]?.compensationSamples == 0)
        #expect(plan[idB]?.clamped == false)
        // Reported totals stay honest (unclamped).
        #expect(plan.trackStage == 20_000)
        #expect(plan.maxPathLatency == 20_000)
    }

    @Test("a custom cap is honored")
    func customCap() {
        let plan = PDCPlan.compute(
            input: PDCInput(strips: [track(idA, all: 0), track(idB, all: 500)]),
            cap: 100
        )
        #expect(plan[idA]?.compensationSamples == 100)
        #expect(plan[idA]?.clamped == true)
        #expect(plan[idA]?.residualSamples == 400)
    }

    // MARK: - Degenerate cases

    @Test("empty input: all-zero plan, no strips, no crash")
    func emptyInput() {
        let plan = PDCPlan.compute(input: PDCInput(strips: []))
        #expect(plan.trackStage == 0)
        #expect(plan.busStage == 0)
        #expect(plan.maxPathLatency == 0)
        #expect(plan.strips.isEmpty)
        #expect(plan[idA] == nil)
    }

    @Test("all-dry project: everything zero, nothing clamped or skewed")
    func allDryProject() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: 0, sends: true),
            track(idB, all: 0, toMaster: false),
            track(idC, all: 0),
            bus(idR, all: 0),
        ]))
        #expect(plan.trackStage == 0)
        #expect(plan.busStage == 0)
        #expect(plan.maxPathLatency == 0)
        for strip in plan.strips {
            #expect(strip.compensationSamples == 0)
            #expect(strip.plannedSamples == 0)
            #expect(!strip.clamped)
            #expect(strip.skewSamples == 0)
        }
    }

    @Test("negative inputs are clamped to 0 (documented policy, no precondition)")
    func negativeInputsClampToZero() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idA, all: -50, active: -50),
            bus(idR, all: -10, active: -10),
        ]))
        #expect(plan.trackStage == 0)
        #expect(plan.busStage == 0)
        #expect(plan[idA]?.compensationSamples == 0)
        #expect(plan[idR]?.compensationSamples == 0)
    }

    @Test("plan results preserve input order deterministically")
    func inputOrderPreserved() {
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            track(idB, all: 240),
            bus(idR, all: 0),
            track(idA, all: 0),
        ]))
        #expect(plan.strips.map(\.id) == [idB, idR, idA])
    }
}
