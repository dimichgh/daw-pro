import Foundation

/// Pure, headless policy for the in-app AI Copilot's per-turn budget (beta m10-m).
/// The Copilot runs a turn as a bounded loop of tool ROUNDS (think → batch of
/// edits → repeat); before m10-m that bound was a hardcoded 8. This centralizes the
/// default and the valid range so BOTH the Settings field (DAWAppKit) and the engine
/// + wire (DAWControl) read ONE source of truth — no duplicated range constant lives
/// anywhere else (the `ControlPortConfig` precedent). Everything here is a pure
/// function, so the clamp/validate edges are unit-tested without a running app.
///
/// Placed in DAWCore (UI-free, engine-free) because it is depended on by both
/// DAWAppKit (the Settings store/field) and DAWControl (the engine resolver + the
/// `ai.copilotSend` override + the `ai.copilotState` limits echo).
public enum CopilotLimits {
    /// The built-in default max tool-rounds per turn. Was 8 (the pre-m10-m
    /// hardcoded value) through 2026-07-19; raised to 30 at the user's request —
    /// real composition turns routinely batch tools across many rounds, and 8
    /// cut legitimate work short. Still inside `validRange`'s runaway bound.
    public static let defaultMaxRounds = 30

    /// The valid range for a user-configured / caller-supplied round budget. A
    /// floor of 1 guarantees at least one provider round (a turn that can never
    /// think is useless); a ceiling of 32 gives power users real headroom for
    /// complex asks while still bounding runaway loops and token spend.
    public static let validRange: ClosedRange<Int> = 1...32

    /// The UserDefaults key the in-app setting persists under — the
    /// `controlServer.port` / `panelDensity.*` app-preference naming family.
    public static let userDefaultsKey = "copilot.maxRounds"

    /// Clamps `value` into `validRange`. Used where an out-of-range number should be
    /// coerced rather than rejected: a caller-supplied `ai.copilotSend` override
    /// (0 → 1, 99 → 32) and a stale persisted setting on load. A caller bounding its
    /// OWN turn budget only harms itself, so clamping (not erroring) is the kind
    /// behavior on the wire.
    public static func clamp(_ value: Int) -> Int {
        min(max(value, validRange.lowerBound), validRange.upperBound)
    }

    /// Validates a user-entered string for the Settings field: the trimmed input must
    /// parse as an integer inside `validRange` (1–32). Returns the parsed value on
    /// success, or nil for a parse failure / out-of-range / empty / whitespace input
    /// — the caller then persists nothing and shows an inline error (the
    /// `ControlPortConfig.validate` idiom). The field REJECTS out-of-range (so a user
    /// sees their typo), while the wire override CLAMPS it (see `clamp`); the two
    /// audiences want different edge behavior over the one shared range.
    public static func validate(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), validRange.contains(value) else { return nil }
        return value
    }
}
