/// Classifies a `debug.arrangeScroll` request by which of its keys are
/// PRESENT, never by their values (m23-ah-2). Pure over the param-key set so
/// it is unit-testable without SwiftUI or `JSONValue` — `DAWApp` is an
/// executable target with no test target of its own (see `Package.swift`),
/// so the seam's decision logic lives here, mirroring `ArrangeZoom`'s split.
///
/// THE BUG THIS EXISTS TO PIN: before m23-ah-2, a bare `debug.arrangeScroll
/// {}` fell through every "was a target named?" check straight to
/// `tracks[count - 1]` — the same code path a caller who explicitly asked to
/// jump to the bottom took — and silently scrolled the arrange view there.
/// A gate author reading it as a state query moved the very viewport they
/// were trying to verify, then measured the move they caused. The m11-a law
/// (already house style for `debug.arrangeZoom`/`debug.undoHistory`/
/// `debug.generationCard`) is: a bare call is a pure, side-effect-free READ.
public enum ArrangeScrollQuery {
    /// The keys `debug.arrangeScroll` reads as a request to MOVE the
    /// viewport. Any other key present (or nothing at all) leaves the
    /// request classified as a query — UNLESS `unknownKeyRejection` below
    /// has already thrown for it; the command layer consults that FIRST.
    public static let mutatingKeys: Set<String> = ["reset", "trackId", "index", "bottom"]

    /// True when the request carries NONE of `mutatingKeys` — including a
    /// truly bare `{}`. Still presence-keyed and value-blind, exactly as
    /// m23-ah-2 shipped it. As of m23-ah-5 the command layer never actually
    /// reaches this with an unrecognized key in play (see
    /// `unknownKeyRejection`), but the function itself stays byte-identical:
    /// what changed is what calls it, not what it computes.
    public static func isQuery(paramKeys: Set<String>) -> Bool {
        paramKeys.isDisjoint(with: mutatingKeys)
    }

    /// The teaching error `debug.arrangeScroll` should throw for `paramKeys`,
    /// or `nil` when every key is recognized (m23-ah-5).
    ///
    /// THE BUG THIS EXISTS TO PIN: `isQuery` classifies by presence of the
    /// four `mutatingKeys` ONLY, so a key it has never heard of — a `trackId`
    /// typo'd as `trackID`, a stray `foo` — is "none of the mutating keys"
    /// exactly like a truly bare `{}`, and falls into the query branch.
    /// Before m23-ah-2 that typo scrolled to the bottom (wrong, but
    /// visible); after m23-ah-2 it silently reads (safer, but invisible) — a
    /// gate author gets `ok: true` and an unchanged `nonce` and believes they
    /// scrolled. This closes it the way `Commands.swift`'s `rejectUnknownKeys`
    /// closes the same class of hole on every regular verb: name the bad
    /// key(s) and fail loudly, at the call site, in the same round trip.
    /// Reimplemented here rather than calling `rejectUnknownKeys` directly —
    /// that helper (and `ControlError`) are `internal` to `DAWControl` and
    /// `debug.*` is served from the `DAWApp` executable target, across the
    /// module boundary, so the helper is not visible there; `debug.*` is
    /// also deliberately excluded from `allCommands`/MCP parity by design
    /// (`Commands.swift:161`), so this is a parallel policy, not a call
    /// through a shared one. Owning the exact wording here (not inline in
    /// `DAWApp`) keeps it testable — `DAWApp` has no test target.
    ///
    /// A bare `{}` (no keys at all) is always `nil` — that is the legitimate
    /// read m23-ah-2 shipped and must keep working unconditionally.
    public static func unknownKeyRejection(paramKeys: Set<String>) -> String? {
        let unknown = paramKeys.subtracting(mutatingKeys)
        guard !unknown.isEmpty else { return nil }
        let named = unknown.sorted().map { "'\($0)'" }.joined(separator: ", ")
        let valid = mutatingKeys.sorted().map { "'\($0)'" }.joined(separator: ", ")
        return "debug.arrangeScroll: unknown parameter\(unknown.count > 1 ? "s" : "") \(named)"
            + " — valid keys are \(valid)"
    }
}
