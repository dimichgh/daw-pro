import Foundation
import Testing
@testable import DAWAppKit

/// Unit tests for the `debug.markerRename` staging seam's decision half
/// (m23-ba-1). The seam in `DAWApp` is plumbing — read params, resolve here,
/// stage, wait, echo — so every refusal sentence and every mode selection is
/// pinned in this file. `DAWApp` has no test target; a rule written there is
/// invisible to the suite (the `DeleteMenuPolicy` / `ArrangeScrollQuery`
/// standing remedy).
///
/// The MEASUREMENT the modes exist for lives in `MarkerRenameStaging`'s own doc
/// comment: `{clear:true}` unmounts the field and DISCARDS the draft, verified
/// live on staging with a draft the model could not have produced. These tests
/// pin the seam's contract; the end-to-end proof that `commit` really renames a
/// marker is `scripts/gates/m23ba1-marker-rename-modes.mjs`.
@Suite("MarkerRenameStaging")
struct MarkerRenameStagingTests {

    /// A request with a marker present and no field open — the common shape.
    private func request(_ keys: Set<String>, markerCount: Int = 1) -> MarkerRenameStaging.Request {
        MarkerRenameStaging.Request(keys: keys, markerCount: markerCount)
    }

    /// The refusal sentence, or nil when the request resolved. Written as a
    /// helper rather than leaning on `#expect(throws:)`'s return value so the
    /// assertions can read the MESSAGE — a refusal whose text does not name the
    /// offending key is the m23-ah defect wearing an error's clothes.
    private func refusal(_ body: () throws -> MarkerRenameStaging.Action) -> String? {
        do {
            _ = try body()
            return nil
        } catch let refusal as MarkerRenameStaging.Refusal {
            return refusal.message
        } catch {
            return "UNEXPECTED ERROR TYPE: \(error)"
        }
    }

    // MARK: - The four modes

    // 1. A bare `{}` opens the first marker. The seam has answered that way
    //    since m11-c and four gates depend on it.
    @Test("a bare request opens the first marker")
    func bareRequestOpensFirst() throws {
        #expect(try MarkerRenameStaging.resolve(request([])) == .open(markerID: nil))
    }

    // 2. `{markerId}` opens that marker.
    @Test("markerId opens that marker")
    func markerIDOpens() throws {
        let ask = MarkerRenameStaging.Request(
            keys: ["markerId"], markerID: "M-1", markerIDIsKnown: true, markerCount: 3)
        #expect(try MarkerRenameStaging.resolve(ask) == .open(markerID: "M-1"))
    }

    // 3. `{clear:true}` is the teardown, and it is legal with NOTHING open — it
    //    is a reset ("make sure no field is standing"), which is exactly how
    //    m17-d / m23-g1 / m23-x / m23-aj use it.
    @Test("clear resolves to clear, and is idempotent with no field open")
    func clearIsIdempotent() throws {
        var bare = request(["clear"])
        bare.clear = true
        #expect(bare.fieldOpenMarkerID == nil)
        #expect(try MarkerRenameStaging.resolve(bare) == .clear)

        var withField = bare
        withField.fieldOpenMarkerID = "M-1"
        #expect(try MarkerRenameStaging.resolve(withField) == .clear)
    }

    // 4. commit / cancel resolve to their modes when a field is open.
    @Test("commit and cancel resolve when the view reports an open field")
    func resolutionModes() throws {
        var commit = request(["commit"])
        commit.commit = true
        commit.fieldOpenMarkerID = "M-1"
        #expect(try MarkerRenameStaging.resolve(commit) == .commit)

        var cancel = request(["cancel"])
        cancel.cancel = true
        cancel.fieldOpenMarkerID = "M-1"
        #expect(try MarkerRenameStaging.resolve(cancel) == .cancel)
    }

    // 5. The wire spelling + the "does this run a real handler" split, which is
    //    the whole distinction the item was filed about: `clear` is NOT a
    //    resolution, `commit`/`cancel` are.
    @Test("only commit and cancel claim to resolve a rename")
    func onlyResolutionsResolve() {
        #expect(MarkerRenameStaging.Action.commit.resolvesRename)
        #expect(MarkerRenameStaging.Action.cancel.resolvesRename)
        #expect(!MarkerRenameStaging.Action.clear.resolvesRename)
        #expect(!MarkerRenameStaging.Action.open(markerID: nil).resolvesRename)
        #expect(MarkerRenameStaging.Action.open(markerID: "x").wireName == "open")
        #expect(MarkerRenameStaging.Action.clear.wireName == "clear")
        #expect(MarkerRenameStaging.Action.commit.wireName == "commit")
        #expect(MarkerRenameStaging.Action.cancel.wireName == "cancel")
    }

    // MARK: - Refusals: shape

    // 6. An unknown key is refused BY NAME with the valid set — the m23-ah
    //    class: a misspelled request must never get a success-shaped response.
    @Test("an unknown key is refused by name, with the valid set")
    func unknownKeyRefused() {
        // Wrong case is a real, easy typo and is genuinely unknown.
        #expect(refusal { try MarkerRenameStaging.resolve(request(["markerID"])) } != nil)

        let text = refusal { try MarkerRenameStaging.resolve(request(["commmit", "zzz"])) }
        #expect(text?.contains("'commmit'") == true)
        #expect(text?.contains("'zzz'") == true)
        #expect(text?.contains("unknown parameters") == true)
        for key in MarkerRenameStaging.allowedKeys {
            #expect(text?.contains("'\(key)'") == true)
        }
        // Singular for one key — a message that says "parameters" for one key is
        // the kind of thing nobody notices until an agent quotes it back.
        let one = refusal { try MarkerRenameStaging.resolve(request(["zzz"])) }
        #expect(one?.contains("unknown parameter '") == true)
    }

    // 7. ⭐ A RECOGNIZED key carrying the WRONG TYPE is refused too, and that is
    //    a genuinely different defect from a misspelling: `{clear: "true"}` has
    //    a perfectly valid key name, a `boolValue` read returns nil, and the old
    //    seam read that as "clear not requested" and cheerfully opened the first
    //    marker instead. A type-and-length guard validates shape, not usability
    //    (the m23-ah finding).
    @Test("a recognized key with the wrong type is refused, not read as absent")
    func malformedValueRefused() {
        var flag = request(["clear"])
        flag.malformedKeys = ["clear"]
        #expect(refusal { try MarkerRenameStaging.resolve(flag) }?
            .contains("'clear' must be true or false") == true)

        var badID = request(["markerId"])
        badID.malformedKeys = ["markerId"]
        #expect(refusal { try MarkerRenameStaging.resolve(badID) }?
            .contains("'markerId' must be a marker-id string") == true)
    }

    // 8. An explicitly FALSE flag is not a request — `{clear:false}` still opens
    //    the first marker, which is what `params["clear"]?.boolValue == true`
    //    has always meant. False is not a typo, so it is not refused.
    @Test("an explicit false flag is not a request")
    func falseFlagIsNotARequest() throws {
        var ask = request(["clear", "commit", "cancel"])
        ask.clear = false
        ask.commit = false
        ask.cancel = false
        #expect(try MarkerRenameStaging.resolve(ask) == .open(markerID: nil))
    }

    // MARK: - Refusals: intent

    // 9. Two modes at once name different outcomes and must be refused — never
    //    silently arbitrated by declaration order.
    @Test("conflicting modes are refused by name")
    func conflictingModesRefused() {
        var both = request(["commit", "cancel"])
        both.commit = true
        both.cancel = true
        both.fieldOpenMarkerID = "M-1"
        let text = refusal { try MarkerRenameStaging.resolve(both) }
        #expect(text?.contains("'commit'") == true)
        #expect(text?.contains("'cancel'") == true)

        var withClear = request(["clear", "commit"])
        withClear.clear = true
        withClear.commit = true
        withClear.fieldOpenMarkerID = "M-1"
        #expect(refusal { try MarkerRenameStaging.resolve(withClear) } != nil)
    }

    // 10. `markerId` OPENS and the modes RESOLVE; combining them is ambiguous
    //     about ordering, so it is refused rather than guessed at.
    @Test("markerId combined with a resolution mode is refused")
    func openAndResolveRefused() {
        for mode in ["clear", "commit", "cancel"] {
            var ask = MarkerRenameStaging.Request(
                keys: ["markerId", mode], markerID: "M-1",
                markerIDIsKnown: true, markerCount: 1, fieldOpenMarkerID: "M-1")
            if mode == "clear" { ask.clear = true }
            if mode == "commit" { ask.commit = true }
            if mode == "cancel" { ask.cancel = true }
            let text = refusal { try MarkerRenameStaging.resolve(ask) }
            #expect(text?.contains("'\(mode)'") == true, "mode \(mode)")
            #expect(text?.contains("'markerId'") == true, "mode \(mode)")
        }
    }

    // MARK: - Refusals: feasibility

    // 11. ⭐ commit / cancel with NO field open is refused. Without this the seam
    //     would answer `ok` for a request that ran no handler at all — precisely
    //     the false confidence m23-ba-1 was filed to prevent ("a future gate
    //     using it to VERIFY rename commit behaviour and concluding the app
    //     commits when the seam simply never ran the commit path").
    @Test("commit or cancel with no rename field open is refused")
    func resolutionWithoutFieldRefused() {
        for mode in ["commit", "cancel"] {
            var ask = request([mode])
            if mode == "commit" { ask.commit = true } else { ask.cancel = true }
            #expect(ask.fieldOpenMarkerID == nil)
            let text = refusal { try MarkerRenameStaging.resolve(ask) }
            #expect(text?.contains("'\(mode)'") == true, "mode \(mode)")
            #expect(text?.contains("debug.markerRename {markerId}") == true, "mode \(mode)")
        }
    }

    // 12. An unknown markerId is refused rather than opening nothing.
    @Test("an unknown markerId is refused")
    func unknownMarkerIDRefused() {
        let ask = MarkerRenameStaging.Request(
            keys: ["markerId"], markerID: "nope", markerIDIsKnown: false, markerCount: 2)
        #expect(refusal { try MarkerRenameStaging.resolve(ask) }?.contains("nope") == true)
    }

    // 13. A bare `{}` on a project with NO markers opened nothing, and the old
    //     seam reported `renamingMarkerId: null` and `ok` for it — a
    //     success-shaped failure. Refused.
    @Test("a bare request with no markers is refused rather than opening nothing")
    func noMarkersRefused() {
        #expect(refusal { try MarkerRenameStaging.resolve(request([], markerCount: 0)) }?
            .contains("marker.add") == true)
    }

    // 14. ⚠️ ORDER: shape is checked before feasibility, so a caller who typo'd
    //     a key learns THAT rather than being told their project has no markers.
    //     Both are wrong with the request below; the key must win.
    @Test("shape refusals are reported before feasibility ones")
    func shapeBeforeFeasibility() {
        let text = refusal { try MarkerRenameStaging.resolve(request(["nope"], markerCount: 0)) }
        #expect(text?.contains("'nope'") == true)
        #expect(text?.contains("marker.add") == false)
    }

    // 15. And malformed values are reported before intent conflicts, so
    //     `{commit:"yes", cancel:true}` teaches the type error rather than a
    //     conflict the caller did not actually create.
    @Test("malformed values are reported before intent conflicts")
    func malformedBeforeConflict() {
        var ask = request(["commit", "cancel"])
        ask.malformedKeys = ["commit"]
        ask.cancel = true
        ask.fieldOpenMarkerID = "M-1"
        let text = refusal { try MarkerRenameStaging.resolve(ask) }
        #expect(text?.contains("must be true or false") == true)
        #expect(text?.contains("different outcomes") == false)
    }
}
