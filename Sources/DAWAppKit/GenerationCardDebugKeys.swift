/// Validates the key sets `debug.generationCard` accepts (m23-ah-6) — a pure
/// classifier over `Set<String>`, unit-testable without SwiftUI or
/// `JSONValue`, following the shape `ArrangeScrollQuery.unknownKeyRejection`
/// shipped for `debug.arrangeScroll` at m23-ah-5: `DAWApp` is an executable
/// target with no test target of its own (see `Package.swift`), so the
/// decision logic — and the exact message wording — lives here instead of
/// inline in `DAWProApp.swift`.
///
/// THE BUG THIS EXISTS TO PIN: `generationCardDebug`'s nested `seed` object
/// read every OPTIONAL key with `?? default` and validated only the VALUE
/// that came back — `seed["origin"]?.stringValue ??
/// GenerationJobOrigin.wire.rawValue` correctly throws on a bad origin VALUE
/// ("wier") but a misspelled origin KEY ("orgin") reads as absent, silently
/// takes the `.wire` default, and returns `ok: true`. `phase` was
/// accidentally safe only because it is REQUIRED — its
/// `guard let phaseRaw = seed["phase"]?.stringValue else { throw }`
/// validates the key for free. Every OTHER key in the object has the same
/// silent-drop shape: `label`, `jobId`, `progress`, `stage`, `detail`,
/// `reason`, `elapsedSeconds`, `stale`. `jobId` is the worst of these:
/// omitting it is MEANINGFUL (it keeps the live poll off the staged row —
/// the `debug.sketchpadDemo` empty-jobID rule), so a typo is
/// indistinguishable from a deliberate choice. Value validation can never
/// catch a key-NAME error, so the fix is a key-set check, not a change to
/// any default.
///
/// Two independent key sets are in scope, because `debug.generationCard`
/// nests one object inside the other: the TOP-LEVEL params (`seed`, `clear`)
/// and the `seed` object's own keys. Both must be validated BEFORE any
/// value inside them is read — a truly bare `{}` (no top-level keys at all)
/// must keep returning the m11-a read-only echo unconditionally, and a
/// `seed` object must have its own key set checked before `phase` or any
/// optional key is read out of it.
public enum GenerationCardDebugKeys {
    /// The top-level parameter set `debug.generationCard` reads.
    public static let topLevelKeys: Set<String> = ["seed", "clear"]

    /// The nested `seed` object's key set (`phase` required, the rest
    /// optional — see the doc comment above for why "optional" is exactly
    /// where the pre-fix silent-drop lived).
    public static let seedKeys: Set<String> = [
        "phase", "origin", "label", "jobId", "progress", "stage", "detail",
        "reason", "elapsedSeconds", "stale",
    ]

    /// The teaching error for an unrecognized TOP-LEVEL key, or `nil` when
    /// every key is recognized — including a truly bare `{}`, whose empty
    /// `paramKeys` makes `subtracting` empty unconditionally, so the m11-a
    /// bare-read case is never rejected.
    public static func unknownTopLevelKeyRejection(paramKeys: Set<String>) -> String? {
        rejection(for: paramKeys, against: topLevelKeys, scope: "debug.generationCard")
    }

    /// The teaching error for an unrecognized key inside `seed`, or `nil`.
    /// Must be consulted BEFORE `phase`/`origin`/any other key in `seed` is
    /// read — that ordering is the entire fix, since reading first and
    /// validating the resulting value second is exactly the shape that let
    /// a misspelled key fall through to its default silently.
    public static func unknownSeedKeyRejection(paramKeys: Set<String>) -> String? {
        rejection(for: paramKeys, against: seedKeys, scope: "debug.generationCard seed")
    }

    private static func rejection(
        for paramKeys: Set<String>, against known: Set<String>, scope: String
    ) -> String? {
        let unknown = paramKeys.subtracting(known)
        guard !unknown.isEmpty else { return nil }
        let named = unknown.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        let valid = known.sorted().joined(separator: ", ")
        return "\(scope): unknown key\(unknown.count > 1 ? "s" : "") \(named)"
            + " — valid keys: \(valid)"
    }
}
