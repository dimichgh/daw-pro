import Testing
@testable import DAWAppKit

/// Pins `debug.generationCard`'s unknown-key rejection (m23-ah-6) — the
/// same shape m23-ah-5 shipped for `debug.arrangeScroll`'s
/// `ArrangeScrollQuery.unknownKeyRejection`.
///
/// This is the CLASSIFICATION half of the fix's proof. It shows the two key
/// sets `GenerationCardDebugKeys` validates — the top-level params
/// (`seed`/`clear`) and `seed`'s own nested keys — and that a truly bare
/// `{}` (empty `paramKeys`) is never rejected at either level. It does NOT
/// and cannot exercise the actual `throw` `generationCardDebug` now
/// produces, nor the pre-fix silent `?? .wire` default it used to fall
/// through to (`AppModel` lives in the `DAWApp` executable target, which
/// has no test target — see `Package.swift`); that "fails on the old
/// behaviour" leg is the live round-trip against `.build/debug/DAWApp` on
/// staging 17695, recorded in this item's close-out.
///
/// THE DISCRIMINATING LEG: `GenerationCardDebugKeys` did not exist before
/// m23-ah-6, so this whole file fails to compile against the pre-fix tree —
/// the same "fails on current code" evidence m23-ah-5's test file
/// describes for its own classifier.
@Suite("GenerationCardDebugKeys — debug.generationCard key-set validation (m23-ah-6)")
struct GenerationCardDebugKeysTests {

    // MARK: - Top-level key set

    @Test("topLevelKeys is exactly seed/clear — a regression pin so a future param rename here is deliberate, not silent")
    func topLevelKeysExactSet() {
        #expect(GenerationCardDebugKeys.topLevelKeys == ["seed", "clear"])
    }

    @Test("a truly bare {} is never rejected at the top level — the m11-a read-only echo must keep working unconditionally")
    func bareTopLevelParamsAreNeverRejected() {
        #expect(GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: []) == nil)
    }

    @Test("each of the two known top-level keys, alone or together, is never rejected")
    func knownTopLevelKeysAreNeverRejected() {
        for key in GenerationCardDebugKeys.topLevelKeys {
            #expect(GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: [key]) == nil,
                    "key \"\(key)\" alone must not be rejected")
        }
        #expect(GenerationCardDebugKeys.unknownTopLevelKeyRejection(
            paramKeys: GenerationCardDebugKeys.topLevelKeys) == nil)
    }

    @Test("an unrecognized top-level key is rejected by name, scoped to debug.generationCard")
    func unrecognizedTopLevelKeyIsRejected() {
        let message = GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: ["seeed"])
        #expect(message != nil)
        #expect(message?.contains("\"seeed\"") == true)
        #expect(message?.hasPrefix("debug.generationCard:") == true)
    }

    @Test("a known top-level key mixed with an unrecognized one is still rejected, naming only the unrecognized one")
    func mixedKnownAndUnknownTopLevelNamesOnlyUnknown() {
        let message = GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: ["seed", "seeed"])
        #expect(message == "debug.generationCard: unknown key \"seeed\" — valid keys: clear, seed")
    }

    @Test("two unrecognized top-level keys are both named, and the message pluralizes")
    func multipleUnknownTopLevelKeysAreAllNamed() {
        let message = GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: ["foo", "bar"])
        #expect(message != nil)
        #expect(message?.contains("\"bar\"") == true)
        #expect(message?.contains("\"foo\"") == true)
        #expect(message?.contains("unknown keys") == true)
    }

    // MARK: - Nested `seed` key set — the item's actual defect

    @Test("seedKeys is exactly the ten documented keys — a regression pin")
    func seedKeysExactSet() {
        #expect(GenerationCardDebugKeys.seedKeys == [
            "phase", "origin", "label", "jobId", "progress", "stage", "detail",
            "reason", "elapsedSeconds", "stale",
        ])
    }

    @Test("a truly bare seed key set ({} for the nested object) is never rejected")
    func bareSeedParamsAreNeverRejected() {
        #expect(GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: []) == nil)
    }

    @Test("each of the ten known seed keys, alone or together, is never rejected")
    func knownSeedKeysAreNeverRejected() {
        for key in GenerationCardDebugKeys.seedKeys {
            #expect(GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: [key]) == nil,
                    "key \"\(key)\" alone must not be rejected")
        }
        #expect(GenerationCardDebugKeys.unknownSeedKeyRejection(
            paramKeys: GenerationCardDebugKeys.seedKeys) == nil)
    }

    /// THE MEASURED DEFECT ITSELF: `orgin` (missing the `i`/`g` swap) is the
    /// exact typo the item's own filing walks through — under the pre-fix
    /// code it silently took the `.wire` default and returned `ok: true`.
    @Test("the measured 'orgin' typo (missing origin) is rejected by name, scoped to the nested seed object")
    func measuredOrginTypoIsRejected() {
        let message = GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: ["phase", "orgin"])
        #expect(message != nil)
        #expect(message?.contains("\"orgin\"") == true)
        #expect(message?.hasPrefix("debug.generationCard seed:") == true)
        // The RECOGNIZED spelling 'origin' legitimately reappears in the
        // "valid keys" list, so assert the full exact message rather than a
        // bare substring check for the typo's absence.
        #expect(message == "debug.generationCard seed: unknown key \"orgin\" — valid keys: "
            + "detail, elapsedSeconds, jobId, label, origin, phase, progress, reason, stage, stale")
    }

    /// `jobId` is called out by the item as the worst instance: omitting it
    /// is a deliberate, meaningful choice (keeps the live poll off the
    /// staged row), so a typo'd `jobid`/`jobID` must not be silently
    /// indistinguishable from that choice.
    @Test("a jobId case typo is rejected by name — omitting it on purpose must stay distinguishable from a typo")
    func jobIdCaseTypoIsRejected() {
        let message = GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: ["phase", "jobID"])
        #expect(message != nil)
        #expect(message?.contains("\"jobID\"") == true)
    }

    @Test("two unrecognized seed keys are both named, and the message pluralizes")
    func multipleUnknownSeedKeysAreAllNamed() {
        let message = GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: ["foo", "bar"])
        #expect(message != nil)
        #expect(message?.contains("\"bar\"") == true)
        #expect(message?.contains("\"foo\"") == true)
        #expect(message?.contains("unknown keys") == true)
    }

    @Test("the seed rejection message lists all ten valid keys, sorted, scoped separately from the top-level message")
    func seedRejectionMessageListsValidKeysSorted() {
        let message = GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: ["nonsense"])
        #expect(message == "debug.generationCard seed: unknown key \"nonsense\" — valid keys: "
            + "detail, elapsedSeconds, jobId, label, origin, phase, progress, reason, stage, stale")
    }

    @Test("the two key sets are validated independently — a name valid in one scope is unknown in the other")
    func theTwoScopesAreIndependent() {
        // 'phase' is a valid SEED key but not a valid TOP-LEVEL key.
        #expect(GenerationCardDebugKeys.unknownTopLevelKeyRejection(paramKeys: ["phase"]) != nil)
        // 'clear' is a valid TOP-LEVEL key but not a valid SEED key.
        #expect(GenerationCardDebugKeys.unknownSeedKeyRejection(paramKeys: ["clear"]) != nil)
    }
}
