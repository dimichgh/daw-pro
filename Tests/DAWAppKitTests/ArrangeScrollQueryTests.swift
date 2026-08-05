import Testing
@testable import DAWAppKit

/// Pins the `debug.arrangeScroll` bare-read classification rule (m23-ah-2)
/// and the unknown-key rejection rule layered on top of it (m23-ah-5).
///
/// This is the CLASSIFICATION half of the fix's proof — it shows `isQuery` is
/// keyed by PRESENCE, not value, and that a truly bare `{}` lands on the
/// query side. It does NOT and cannot exercise the actual mutation the old
/// code performed, nor the actual `throw` an unrecognized key now produces
/// (`AppModel` lives in the `DAWApp` executable target, which has no test
/// target — see `Package.swift`); the "fails on the old behaviour" leg for
/// both is the live round-trip against `.build/debug/DAWApp` on staging
/// 17695, recorded in the m23-ah-2 and m23-ah-5 close-outs. Since m23-ah-5,
/// the command layer (`DAWProApp.setArrangeScroll`) consults
/// `ArrangeScrollQuery.unknownKeyRejection` BEFORE `isQuery`, so `isQuery`
/// itself never actually sees an unrecognized-key request in production —
/// it stays a pure, presence-keyed classifier, unchanged since m23-ah-2.
@Suite("ArrangeScrollQuery — debug.arrangeScroll bare-read classifier (m23-ah-2)")
struct ArrangeScrollQueryTests {

    @Test("a truly bare {} classifies as a query")
    func bareIsQuery() {
        #expect(ArrangeScrollQuery.isQuery(paramKeys: []))
    }

    @Test("each of the four mutating keys alone classifies as NOT a query — by PRESENCE, never by value")
    func eachMutatingKeyAlonePreventsQuery() {
        for key in ArrangeScrollQuery.mutatingKeys {
            #expect(!ArrangeScrollQuery.isQuery(paramKeys: [key]),
                    "key \"\(key)\" alone must classify as mutating")
        }
    }

    @Test("bottom:false still counts as a mutating request — the defect this item fixes was about a MISSING key, not a false-y value")
    func falseValuedKeyStillMutates() {
        // The classifier only sees key names, never values, so this test
        // documents intent at the call site: {bottom:false} is exactly as
        // mutating as {bottom:true} to the classifier — the caller wanted to
        // scroll (with anchor=top), it just isn't a bare read.
        #expect(!ArrangeScrollQuery.isQuery(paramKeys: ["bottom"]))
    }

    @Test("isQuery itself still can't tell an unknown key from a bare read — that's WHY the command layer must ask unknownKeyRejection first (m23-ah-5)")
    func unknownKeysAloneStayQuery() {
        #expect(ArrangeScrollQuery.isQuery(paramKeys: ["foo", "bar"]))
    }

    @Test("a known key mixed with unknown keys still mutates")
    func mixedKnownAndUnknownMutates() {
        #expect(!ArrangeScrollQuery.isQuery(paramKeys: ["foo", "trackId"]))
    }

    @Test("all four mutating keys together still classify as mutating")
    func allFourKeysMutate() {
        #expect(!ArrangeScrollQuery.isQuery(paramKeys: ArrangeScrollQuery.mutatingKeys))
    }

    @Test("mutatingKeys is exactly reset/trackId/index/bottom — a regression pin so a future param rename here is deliberate, not silent")
    func mutatingKeysExactSet() {
        #expect(ArrangeScrollQuery.mutatingKeys == ["reset", "trackId", "index", "bottom"])
    }

    // MARK: - Unknown-key rejection (m23-ah-5)

    /// THE DISCRIMINATING LEG: `unknownKeyRejection` did not exist before
    /// m23-ah-5, so this whole file failed to COMPILE against the pre-fix
    /// `ArrangeScrollQuery.swift` — the same "fails on current code" evidence
    /// this test suite's own header describes for the mutation itself: what
    /// a headless unit test can prove is the classification/decision layer,
    /// and DAWApp's live round-trip proves the command actually throws (see
    /// this item's report). A capital-D `trackID` — the exact typo measured
    /// live — must be named in the message.
    @Test("a single unrecognized key (the measured trackID typo) is rejected by name")
    func unrecognizedKeyIsRejected() {
        let message = ArrangeScrollQuery.unknownKeyRejection(paramKeys: ["trackID"])
        #expect(message != nil)
        #expect(message?.contains("'trackID'") == true)
        #expect(message?.hasPrefix("debug.arrangeScroll:") == true)
    }

    @Test("a truly bare {} is never rejected — the m23-ah-2 read must keep working unconditionally")
    func bareParamsAreNeverRejected() {
        #expect(ArrangeScrollQuery.unknownKeyRejection(paramKeys: []) == nil)
    }

    @Test("each of the four mutating keys, alone or together, is never rejected")
    func knownKeysAreNeverRejected() {
        for key in ArrangeScrollQuery.mutatingKeys {
            #expect(ArrangeScrollQuery.unknownKeyRejection(paramKeys: [key]) == nil,
                    "key \"\(key)\" alone must not be rejected")
        }
        #expect(ArrangeScrollQuery.unknownKeyRejection(paramKeys: ArrangeScrollQuery.mutatingKeys) == nil)
    }

    @Test("a known key mixed with an unrecognized key is still rejected, naming only the unrecognized one")
    func mixedKnownAndUnknownIsRejectedNamingOnlyUnknown() {
        // `'trackId'` (the RECOGNIZED spelling) legitimately reappears later
        // in the message's "valid keys are …" list, so a bare substring check
        // for its absence would be a false negative — assert the exact
        // "unknown parameter" clause instead, which must name ONLY 'trackID'.
        let message = ArrangeScrollQuery.unknownKeyRejection(paramKeys: ["trackId", "trackID"])
        #expect(message == "debug.arrangeScroll: unknown parameter 'trackID' — valid keys are "
            + "'bottom', 'index', 'reset', 'trackId'")
    }

    @Test("two unrecognized keys are both named, and the message pluralizes")
    func multipleUnknownKeysAreAllNamed() {
        let message = ArrangeScrollQuery.unknownKeyRejection(paramKeys: ["foo", "bar"])
        #expect(message != nil)
        #expect(message?.contains("'bar'") == true)
        #expect(message?.contains("'foo'") == true)
        #expect(message?.contains("parameters") == true)
    }

    @Test("the rejection message names all four valid keys, sorted")
    func rejectionMessageListsValidKeys() {
        let message = ArrangeScrollQuery.unknownKeyRejection(paramKeys: ["nonsense"])
        #expect(message == "debug.arrangeScroll: unknown parameter 'nonsense' — valid keys are "
            + "'bottom', 'index', 'reset', 'trackId'")
    }
}
