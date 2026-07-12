import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for `CopilotLimits` (beta m10-m): the pure clamp/validate policy
/// the Copilot's per-turn round budget flows through. One source of truth, imported by
/// both the Settings field (DAWAppKit) and the engine + wire (DAWControl), so the edge
/// behavior is pinned here without a running app (the `ControlPortConfig` precedent).
@Suite("CopilotLimits — round-budget policy (beta m10-m)")
struct CopilotLimitsTests {

    @Test("the default and valid range are the documented policy (8; 1…32)")
    func policyConstants() {
        #expect(CopilotLimits.defaultMaxRounds == 8)
        #expect(CopilotLimits.validRange == 1...32)
        #expect(CopilotLimits.validRange.contains(CopilotLimits.defaultMaxRounds))
    }

    // MARK: - clamp (the wire override / on-load coercion)

    @Test("clamp coerces below/above the range and passes an in-range value through")
    func clampEdges() {
        #expect(CopilotLimits.clamp(0) == 1)      // below the floor → floor
        #expect(CopilotLimits.clamp(-5) == 1)     // well below → floor
        #expect(CopilotLimits.clamp(1) == 1)      // floor
        #expect(CopilotLimits.clamp(8) == 8)      // the default, untouched
        #expect(CopilotLimits.clamp(32) == 32)    // ceiling
        #expect(CopilotLimits.clamp(33) == 32)    // just above → ceiling
        #expect(CopilotLimits.clamp(99) == 32)    // well above → ceiling
    }

    // MARK: - validate (the Settings field)

    @Test("validate accepts the in-range boundaries and rejects the neighbors")
    func validateBoundaries() {
        #expect(CopilotLimits.validate("0") == nil)      // just below floor
        #expect(CopilotLimits.validate("1") == 1)        // floor
        #expect(CopilotLimits.validate("8") == 8)        // the default
        #expect(CopilotLimits.validate("32") == 32)      // ceiling
        #expect(CopilotLimits.validate("33") == nil)     // just above ceiling
    }

    @Test("validate rejects garbage, empty, and whitespace-only input")
    func validateJunk() {
        #expect(CopilotLimits.validate("") == nil)
        #expect(CopilotLimits.validate("   ") == nil)
        #expect(CopilotLimits.validate("abc") == nil)
        #expect(CopilotLimits.validate("8.5") == nil)
        #expect(CopilotLimits.validate("-1") == nil)
        #expect(CopilotLimits.validate("16x") == nil)
    }

    @Test("validate trims surrounding whitespace before parsing")
    func validateTrims() {
        #expect(CopilotLimits.validate("  16  ") == 16)
        #expect(CopilotLimits.validate("\t4\n") == 4)
    }

    @Test("validate REJECTS out of range while clamp COERCES it — the two audiences differ")
    func validateAndClampDiverge() {
        // The Settings field shows a typo (nil → inline error); the wire override is
        // kind to a caller bounding its own budget (clamp into range).
        #expect(CopilotLimits.validate("99") == nil)
        #expect(CopilotLimits.clamp(99) == 32)
    }
}
