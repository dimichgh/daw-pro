import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-n2g/m23-n2h: the zero-param teaching
/// message (`rejectUnknownKeys([], verb:)`'s empty-`allowed` branch, added
/// m23-n2e — see `VoiceListCommandTests.rejectsUnknownParamsWithZeroParamTeachingMessage`
/// / `.zeroParamTeachingMessagePluralizes` for the original single-verb pin)
/// walks EVERY zero-parameter verb, not just `vc.listVoices`. Measured
/// (re-checked against source, not assumed) before this suite existed: 5 of
/// the ORIGINAL 18 had NO unknown-key test at all (transport.stop,
/// transport.record, ai.sidecarStart, ai.copilotReset, edit.redo —
/// `WireHardeningM16ETests`'s "F5 survey completion" `MARK` names all seven
/// of these `transport.*`/`edit.*`/`ai.copilotReset`/`ai.sidecarStart`/`Stop`
/// verbs as covered, but only 3 unknown-key tests exist under it —
/// transport.play, edit.undo, ai.sidecarStop; the 4th `@Test` there is
/// transport.play's no-params happy path); 12 more asserted only
/// `contains("bogus")`/`!response.ok` against the HEAD of the message
/// (transport.play, reference.remove/status/analyze/compare, ai.sidecarStop,
/// ai.copilotChats, ai.copilotGetModel, edit.undo, vc.sidecarStart/Stop,
/// ai.speechModelInstallStatus); only `vc.listVoices` pinned the full
/// literal. None of those 17 checked the TAIL — exactly why m23-n2e's
/// message-string change reddened nothing outside `vc.listVoices`.
///
/// m23-n2h GREW this from 18 to 38: 26 commands (`tempo.map`,
/// `marker.list`, `fx.listAudioUnits`, `instrument.listAudioUnits`,
/// `instrument.listSoundBanks`, `mixer.masterAnalysis`,
/// `engine.watchdogStatus`, `groove.list`, `ai.sidecarStatus`,
/// `ai.providerStatus`, `project.snapshot`, `project.overview`,
/// `input.listDevices`, `midi.listInputs`, `project.recoveryStatus`,
/// `project.recoveryBundles`, `edit.history`, `app.connectionInfo`,
/// `plugin.listOpenUIs`, `vc.sidecarStatus` — 20 zero-param — plus 6 with
/// REAL params, handled by their own per-command suites, not this table)
/// never called `rejectUnknownKeys` AT ALL, so an agent's typo'd param was a
/// SILENT SUCCESS, not even the dangling-tail bug m23-n2e fixed. Every one
/// of the 20 zero-param verbs above landed in this table; re-deriving the
/// count from source (not computing it as 18+20) confirmed 38 with NO
/// overlap between the two groups.
///
/// One table, one maintenance site: adding a 39th zero-param verb is a
/// one-line addition to `zeroParamVerbs` below, not a new hand-written test —
/// and `zeroParamVerbsTableMatchesSource` below scrapes Commands.swift itself
/// for every `rejectUnknownKeys([], verb: "...")` call site, so forgetting
/// that one-line addition (or removing a verb from Commands.swift without
/// updating this table) reddens THAT test rather than leaving a silent gap.
///
/// SAFETY (sidecar processes): four of these verbs (`ai.sidecarStart`,
/// `ai.sidecarStop`, `vc.sidecarStart`, `vc.sidecarStop`) would spawn or
/// SIGTERM a REAL sidecar process if they executed. `rejectUnknownKeys([],
/// verb:)` is the statement IMMEDIATELY before the
/// `sidecarManager`/`voiceConversionManager` `.start()`/`.stop()` call at
/// every one of those four sites, so an unknown key throws before any
/// manager is touched. This suite must therefore ONLY ever send unknown keys
/// to these verbs — never valid/empty params.
///
/// SAFETY (AU enumeration flake, m23-n2h): `fx.listAudioUnits` and
/// `instrument.listAudioUnits` are zero-param and DO have a
/// `rejectUnknownKeys([], verb:)` call site (so they belong in
/// `zeroParamVerbs`, and `zeroParamVerbsTableMatchesSource` covers them),
/// but this suite must NOT actually DRIVE either through
/// `CommandRouter.handle` — per the roadmap item's own standing instruction,
/// because AudioComponent enumeration is this machine's top flake source.
/// This is a POLICY exclusion, not a claim that today's source is unsafe to
/// call with an unknown key: `rejectUnknownKeys` IS the first statement in
/// both case bodies (confirmed by reading Commands.swift, not assumed), so
/// an unknown-key request never reaches `store.availableAudioUnits()` /
/// `availableAudioUnitEffects()` as things stand today. The exclusion exists
/// so a FUTURE reordering of the guard (or a refactor that moves enumeration
/// earlier) can't silently reintroduce the flake into this suite's own
/// parameterized run — which also means the ordering property for these two
/// verbs is proven by INSPECTION only here, not by a behavioural witness
/// (contrast the `resetFlags`/`reads`/`statusCalls` witnesses used for the
/// other guarded verbs below and in `EnginePerformanceCommandTests` /
/// `EngineWatchdogCommandTests` / `SidecarCommandTests` /
/// `VoiceConversionCommandTests`). They're carved into
/// `notDrivenForFlakeReasons` below; the parameterized tests iterate
/// `drivenVerbs` (36 of the 38), and `drivenVerbsPlusNotDrivenEqualsSource`
/// asserts the split covers every SOURCE-SCRAPED zero-param verb exactly
/// once (compared against the scrape, not the hand-written `zeroParamVerbs`
/// table `drivenVerbs` itself is filtered from — that comparison would be
/// tautological) — so a verb can't quietly fall through neither bucket, and
/// neither can it accidentally land in both.
@MainActor
@Suite("Zero-parameter verbs — unknown-key rejection (m23-n2g / m23-n2h)")
struct ZeroParamVerbRejectionTests {
    /// Every verb (Commands.swift) that calls `rejectUnknownKeys([], verb:)`.
    /// Exactly 38 as of m23-n2h. `nonisolated` because `@Test(arguments:)`
    /// evaluates this array outside the main actor, even though the suite
    /// itself is `@MainActor` (for `CommandRouter`/`ProjectStore` access) —
    /// a plain `[String]` is `Sendable`, so isolation buys nothing here.
    nonisolated static let zeroParamVerbs: [String] = [
        // The original 18 (m23-n2g).
        "transport.play",
        "transport.stop",
        "transport.record",
        // m23-af. `transport.panic` is zero-param like the three above, and
        // `zeroParamVerbsTableMatchesSource` scrapes Commands.swift for every
        // `rejectUnknownKeys([], verb:)` site — so omitting it here reddens
        // that test rather than leaving a silent gap. It did.
        "transport.panic",
        "reference.remove",
        "reference.status",
        "reference.analyze",
        "reference.compare",
        "ai.sidecarStart",
        "ai.sidecarStop",
        "ai.copilotReset",
        "ai.copilotGetModel",
        "ai.copilotChats",
        "edit.undo",
        "edit.redo",
        "vc.sidecarStart",
        "vc.sidecarStop",
        "vc.listVoices",
        "ai.speechModelInstallStatus",
        // The 20 added m23-n2h (were previously silent — no rejection at all).
        "tempo.map",
        "marker.list",
        "fx.listAudioUnits",
        "instrument.listAudioUnits",
        "instrument.listSoundBanks",
        "mixer.masterAnalysis",
        "engine.watchdogStatus",
        "groove.list",
        "ai.sidecarStatus",
        "ai.providerStatus",
        "project.snapshot",
        "project.overview",
        "input.listDevices",
        "midi.listInputs",
        "project.recoveryStatus",
        "project.recoveryBundles",
        "edit.history",
        "app.connectionInfo",
        "plugin.listOpenUIs",
        "vc.sidecarStatus",
    ]

    /// AudioComponent enumeration verbs, present in `zeroParamVerbs` (they
    /// DO have a `rejectUnknownKeys([], verb:)` call site — see
    /// `zeroParamVerbsTableMatchesSource`) but never DRIVEN through
    /// `CommandRouter.handle` by this suite's parameterized tests. See the
    /// SAFETY block in the suite doc comment above.
    nonisolated static let notDrivenForFlakeReasons: Set<String> = [
        "fx.listAudioUnits",
        "instrument.listAudioUnits",
    ]

    /// The subset of `zeroParamVerbs` actually exercised by
    /// `singularUnknownKey`/`pluralUnknownKeysAreSorted` below.
    nonisolated static let drivenVerbs: [String] =
        zeroParamVerbs.filter { !notDrivenForFlakeReasons.contains($0) }

    /// Locates `<repo>/Sources/DAWControl/Commands.swift` by walking up from
    /// this test file (the `CanvasContractPinTests` recipe) — no bundle
    /// resources, so it runs headless under `./scripts/test.sh`.
    private static func commandsSourceFile() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWControl/Commands.swift")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every verb Commands.swift itself calls `rejectUnknownKeys([], verb:
    /// "...")` with, scraped straight from source. This is what makes
    /// `zeroParamVerbsTableMatchesSource` load-bearing: a 39th zero-param
    /// verb landing in Commands.swift — or one of these 38 being removed —
    /// changes this set and reddens the comparison below, instead of just
    /// silently sitting outside a hand-typed table nobody re-derives.
    private static func zeroParamVerbsInSource() throws -> Set<String> {
        guard let file = commandsSourceFile() else {
            Issue.record("Could not locate Sources/DAWControl/Commands.swift from \(#filePath)")
            return []
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        // No trailing `\)`: a future `rejectUnknownKeys([], verb: "x", hint:
        // "...")` site (an extra trailing argument) must still be caught,
        // not silently invisible to this sweep.
        let pattern = #"rejectUnknownKeys\(\[\],\s*verb:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { return }
            found.insert(String(text[r]))
        }
        return found
    }

    /// Every verb Commands.swift calls `rejectUnknownKeys(...)` with, where
    /// the allowed set is written as an ARRAY LITERAL (`["a", "b"]` or `[]`)
    /// — not just the empty-`[]` branch `zeroParamVerbsInSource` scrapes.
    /// This is m23-n2h's durable win: it proves every command in
    /// `CommandRouter.allCommands` reaches a `rejectUnknownKeys` call site
    /// SOMEWHERE in its case body, so a 27th "silently accepts unknown
    /// params" command can never land unnoticed again — a source-scrape
    /// anti-regression net for future GROWTH, not proof that the call
    /// precedes any particular side effect (that's what the per-command
    /// ordering-witness tests in `EnginePerformanceCommandTests` /
    /// `EngineWatchdogCommandTests` / the sidecar-status tests are for).
    /// CAVEAT: the regex only matches an inline array literal for `allowed`;
    /// a future call site passing a named `Set`/array constant instead would
    /// not match here. That failure mode is SAFE, not silent: it would show
    /// up as a verb missing from this scrape, reddening the set-equality
    /// assertion below against `CommandRouter.allCommands` — the sweep fails
    /// loud, it doesn't pass vacuously.
    private static func verbsWithAnyRejectUnknownKeysCallSite() throws -> Set<String> {
        guard let file = commandsSourceFile() else {
            Issue.record("Could not locate Sources/DAWControl/Commands.swift from \(#filePath)")
            return []
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        let pattern = #"rejectUnknownKeys\(\s*\[[^\]]*\]\s*,\s*verb:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { return }
            found.insert(String(text[r]))
        }
        return found
    }

    @Test("the hand-maintained table above is exactly the set of rejectUnknownKeys([], verb:) sites in Commands.swift — a 39th verb (or a removal) reddens this, not just sits outside an untested table")
    func zeroParamVerbsTableMatchesSource() throws {
        let sourceVerbs = try Self.zeroParamVerbsInSource()
        #expect(!sourceVerbs.isEmpty, "the source scan itself must find something, or this test is vacuously green")
        #expect(Set(Self.zeroParamVerbs) == sourceVerbs)
        #expect(Self.zeroParamVerbs.count == 39)   // 39 at m23-af (transport.panic)
    }

    /// NOTE: this compares against the SOURCE SCRAPE, not `Self.zeroParamVerbs`
    /// — `drivenVerbs` is filtered FROM `zeroParamVerbs`, so a comparison
    /// against that same table would be tautological (true by construction,
    /// never able to redden). Comparing against `zeroParamVerbsInSource()`
    /// makes this load-bearing: it independently confirms the driven+excluded
    /// split still covers exactly what Commands.swift declares, even if
    /// `zeroParamVerbs` itself drifted from source (a drift
    /// `zeroParamVerbsTableMatchesSource` would ALSO catch, but this test
    /// doesn't rely on that one having run first).
    @Test("drivenVerbs + notDrivenForFlakeReasons exactly partitions the SOURCE-SCRAPED zero-param set — nothing falls through either bucket, nothing lands in both, and the exclusion set can't typo itself into irrelevance")
    func drivenVerbsPlusNotDrivenEqualsSource() throws {
        let sourceVerbs = try Self.zeroParamVerbsInSource()
        #expect(!sourceVerbs.isEmpty, "the source scan itself must find something, or this test is vacuously green")
        #expect(Self.notDrivenForFlakeReasons.isSubset(of: sourceVerbs),
                "a typo'd verb name in the exclusion set would silently shrink drivenVerbs without anyone noticing")
        #expect(Set(Self.drivenVerbs).isDisjoint(with: Self.notDrivenForFlakeReasons))
        #expect(Set(Self.drivenVerbs).union(Self.notDrivenForFlakeReasons) == sourceVerbs)
        #expect(Self.drivenVerbs.count == 37)   // 37 at m23-af (transport.panic)
    }

    /// m23-n2h durable-win sweep: every one of the 162 `allCommands` reaches
    /// SOME `rejectUnknownKeys` call site (any allowed set, not just `[]`).
    /// `CommandRouter.allCommands` IS the array literal Commands.swift
    /// declares (not a hand-recount of `case` labels — the roadmap item's
    /// own warning against exactly that mistake), so comparing it against
    /// the scraped call-site set is a comparison of two independent
    /// derivations of the same 162, not a self-fulfilling count. m23-r4's
    /// `fx.spectrum` is included automatically — its own call site
    /// (`rejectUnknownKeys(["trackId", "effectId", "arm"], verb:
    /// "fx.spectrum")`) matches this scrape's array-literal pattern, so no
    /// separate allowlist entry was needed for L8's missing-guard direction.
    @Test("every command in CommandRouter.allCommands reaches a rejectUnknownKeys call site somewhere in Commands.swift — the anti-regression net for a 27th silently-permissive command")
    func everyCommandReachesARejectUnknownKeysCallSite() throws {
        let sourceCallSites = try Self.verbsWithAnyRejectUnknownKeysCallSite()
        #expect(!sourceCallSites.isEmpty, "the source scan itself must find something, or this test is vacuously green")

        // Assert the two DIFFERENCES, not raw set equality. A bare
        // `#expect(a == b)` on 161-element sets prints both sets in full on
        // failure (~300 lines) and leaves the reader to diff by eye — measured,
        // by deleting `project.overview`'s guard and reading the output. These
        // two expectations name the offending verb directly, which is the whole
        // point of a net meant to be read by whoever trips it months from now.
        let unguarded = Set(CommandRouter.allCommands).subtracting(sourceCallSites)
        #expect(unguarded.isEmpty,
                "these commands never reach a rejectUnknownKeys call site and silently accept unknown params: \(unguarded.sorted())")
        // The reverse direction catches a verb renamed/removed from allCommands
        // while its guard lingers. NOTE the one legitimate way to trip this
        // WITHOUT a bug: the off-surface developer tier (`debug.*`, deliberately
        // excluded from allCommands / MCP parity — Commands.swift:153 and the
        // dispatch at :4592) is entitled to call `rejectUnknownKeys` too. If
        // someone hardens a debug verb, that is GOOD hygiene and this
        // expectation is what needs updating — add the off-surface verb to an
        // allowlist here rather than removing its guard.
        let orphaned = sourceCallSites.subtracting(Set(CommandRouter.allCommands))
        #expect(orphaned.isEmpty,
                "these verbs have a rejectUnknownKeys call site but are not in allCommands — either renamed/removed (a bug), or an off-surface debug.* verb that was hardened (good; allowlist it above): \(orphaned.sorted())")
        #expect(CommandRouter.allCommands.count == 166)   // 161 -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af
    }

    private func makeRouter() -> CommandRouter {
        CommandRouter(store: ProjectStore())
    }

    @Test(
        "singular: one unknown key is named verbatim, and the verb is told it takes no parameters",
        arguments: drivenVerbs)
    func singularUnknownKey(verb: String) async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: verb, params: ["bogus": .bool(true)]))
        #expect(!response.ok, "\(verb) should reject an unknown key, never execute")
        #expect(response.error == "\(verb): unknown parameter 'bogus' — \(verb) takes no parameters")
    }

    /// Plural + sort. NOTE on what this actually proves: the "parameters"
    /// pluralization is a hard pin (proven load-bearing by mutation below).
    /// The 'alpha' < 'zebra' ordering also asserts `.sorted()`'s output, but
    /// that half is only PROBABILISTICALLY guarded here — Swift's Dictionary
    /// iteration order is randomized per process, so removing `.sorted()`
    /// from the empty-`allowed` branch would turn this red on roughly half
    /// of runs, not deterministically. Still worth asserting: it is the
    /// literal the server actually emits today, and a real regression has
    /// good odds of being caught, just not a guarantee on any single run.
    @Test(
        "plural + sort: two unknown keys read 'parameters' and sort 'alpha' before 'zebra' regardless of dict order",
        arguments: drivenVerbs)
    func pluralUnknownKeysAreSorted(verb: String) async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: verb,
            params: ["zebra": .bool(true), "alpha": .bool(true)]))
        #expect(!response.ok, "\(verb) should reject unknown keys, never execute")
        #expect(response.error
            == "\(verb): unknown parameters 'alpha', 'zebra' — \(verb) takes no parameters")
    }
}
