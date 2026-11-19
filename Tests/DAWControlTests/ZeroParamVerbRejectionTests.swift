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
    /// MEASURED at 51 as of m34-h-1 (the count in this line has been stale
    /// before — `doc-count-drift.mjs` derives the same total from source,
    /// independently). `nonisolated` because `@Test(arguments:)`
    /// evaluates this array outside the main actor, even though the suite
    /// itself is `@MainActor` (for `CommandRouter`/`ProjectStore` access) —
    /// a plain `[String]` is `Sendable`, so isolation buys nothing here.
    nonisolated static let zeroParamVerbs: [String] = [
        // The original 18 (m23-n2g).
        "transport.play",
        "transport.stop",
        "transport.record",
        // m34-h LIVE LOOPING. DRIVEN, not excluded: `rejectUnknownKeys([], verb:)`
        // runs BEFORE `store.recordLayer()` / `store.finishLayer()` in both
        // handlers, so a bogus-key probe is refused at the parameter layer and
        // never reaches the transport at all — no take starts, nothing to flake.
        "transport.recordLayer",
        "transport.finishLayer",
        // m34-h-1 LIVE LOOPING, the loop deck's three zero-param verbs. All
        // DRIVEN, for the same reason as the two above and one more: with no
        // session open they each refuse (or, for `looper.status`, answer null)
        // without touching the transport, a device or a sidecar, so the probe
        // is inert whichever order the routing loop reaches them in.
        // `looper.begin`/`armLayer`/`finishLayer`/`setLayerMuted` are NOT here
        // — every one of them takes at least one parameter.
        "looper.undoLayer",
        "looper.status",
        "looper.end",
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
        // m39-e — the modulation layer's discovery entry point. Zero params by
        // design: it is a STATIC catalogue (every source kind, every parameter
        // with range/unit/default/curve, the depth law's worked examples and
        // the polarity convention), so there is nothing to parameterize.
        "mod.describeKinds",
        // The 20 added m23-n2h (were previously silent — no rejection at all).
        "tempo.map",
        "marker.list",
        "fx.listAudioUnits",
        "instrument.listAudioUnits",
        "instrument.listSoundBanks",
        "mixer.masterAnalysis",
        "engine.watchdogStatus",
        "engine.auPrepareStats",   // m23-br-1
        "groove.list",
        "ai.sidecarStatus",
        "ai.providerStatus",
        "project.snapshot",
        "project.overview",
        "input.listDevices",
        "output.listDevices",   // m20-j
        "midi.listInputs",
        // m28-knob. DRIVEN, not excluded: reading the mapping table is PASSIVE
        // by design — unlike its sibling above it never brings the CoreMIDI
        // client up, so it opens no device and cannot flake on one.
        "midi.getControlMap",
        "project.recoveryStatus",
        "project.recoveryBundles",
        "edit.history",
        "app.connectionInfo",
        "plugin.listOpenUIs",
        "vc.sidecarStatus",
        // m24-n. DRIVEN, not excluded: it reads the live model plus a handful
        // of `fileExists` calls — no device, no sidecar, no model load — so it
        // cannot flake the way the AudioComponent enumerations can.
        "project.embeddedVoices",
        // m34-c. All three DRIVEN, not excluded: the catalogue read is a
        // compile-time list plus one directory scan, the status read touches
        // an in-memory actor, and cancel refuses when nothing is running —
        // none of them opens a device, spawns a sidecar or reaches the
        // network, and `rejectUnknownKeys` fires before any of them executes
        // anyway. The DOWNLOAD verb itself is absent from this table on
        // purpose: it REQUIRES `id`.
        "instrument.listDownloadableSoundBanks",
        "instrument.soundBankDownloadStatus",
        "instrument.cancelSoundBankDownload",
        // m39-dm. DRIVEN, not excluded: the preset list is a compile-time
        // constant in DAWCore — no store state, no device, no sidecar, no
        // filesystem — so it is the least flake-prone verb in this table. The
        // drum machine's other three verbs are absent on purpose: all three
        // REQUIRE `trackId`.
        "instrument.listDrumPresets",
        // m39-tpl-6. DRIVEN, not excluded: listing templates reads files
        // under the library root (built-ins plus saved) and reports
        // per-file problems under `unreadable` rather than throwing — no
        // store mutation, no device, no sidecar.
        "template.list",
        // m39-w4-10. DRIVEN, not excluded: the ready-made drum beats are a
        // compile-time list in DAWCore (DrumPatternLibrary) — no store state,
        // no device, no sidecar, no filesystem. Its sibling
        // clip.addDrumPattern is absent on purpose: it REQUIRES trackId and pattern.
        "pattern.list",
        // p2-sing-e. All five DRIVEN, not excluded: `rejectUnknownKeys` runs
        // first in each case, so an unknown key is refused before anything
        // else happens. This suite's bare router has no singing engine wired
        // in (no `singServices`) and no voice-recorder window, so even a
        // well-formed call would only refuse; nothing here can start an
        // engine, download anything, or open a window.
        "sing.sidecarStart", "sing.installEngine", "sing.cancelInstall",
        "sing.listVoices", "sing.openVoiceRecorder",
        // p2-sing-x7 part A. DRIVEN, not excluded: sing.capabilities reads the
        // language list and, with an engine wired in, the install marker; this
        // suite's bare router has none, so it answers from LyricLanguage alone.
        // It never starts, installs or downloads anything.
        "sing.capabilities",
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

    /// Mirrors `stripLineComments` in `scripts/gates/doc-count-drift.mjs`
    /// literally: for each line, cut everything from the FIRST `//` onward.
    /// NOT a block-comment parser, and (like the gate) not string-literal
    /// aware either — a `//` inside a same-line quoted string is stripped
    /// too. GAP 2 (ZP-2, 2026-09-25): that specific same-line blind spot is
    /// NOT what the gate's own comment calls out (that comment warns against
    /// a naive WHOLE-FILE regex eating a URL's `//`, a related but distinct
    /// risk from the one line-by-line stripping still carries) — so this is
    /// recorded here, precisely, as a shared, deliberately-unfixed limitation
    /// of BOTH implementations, not as something the gate's prose already
    /// documents. The goal here is AGREEMENT with the gate, not a better
    /// comment parser, so this is a port, not a fix. See ZP (2026-09-25): the
    /// two scrapes below
    /// used to skip this step entirely, so a doc comment that spelled out a
    /// call-shaped `rejectUnknownKeys([…], verb: "…")` example (Commands.swift
    /// carries several today, deliberately worded to avoid the exact call
    /// shape after this was diagnosed — see the comment above
    /// `clip.setNoteVibrato`'s own call site) made this suite see a phantom
    /// verb the gate's own comment-stripped scrape never saw. The two
    /// instruments disagreeing was the bug, not either count alone.
    private static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let slashRange = line.range(of: "//") {
                    return line[line.startIndex..<slashRange.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    /// Pure scrape (no file I/O) for every `rejectUnknownKeys([], verb:
    /// "...")` site in `text`, AFTER stripping `//` comments via
    /// `stripLineComments` above — the same order `doc-count-drift.mjs`'s
    /// `measureWire` applies (strip, then match). Split from
    /// `zeroParamVerbsInSource` so a test can hand it a small snippet
    /// directly instead of only ever exercising it against the real file
    /// (`commentedZeroParamCallSiteIsNotCounted` below).
    static func scrapeZeroParamVerbs(from text: String) throws -> Set<String> {
        let stripped = stripLineComments(text)
        // ZP-2 (2026-09-25): mirrors doc-count-drift.mjs's `zeroParam` pattern
        // EXACTLY (`\(\s*\[\s*\]\s*,` — whitespace tolerated after `(`, inside
        // `[ ]`, and before the comma), not the tighter `\(\[\],` this suite
        // used before. The tight version was itself an instance of the same
        // "two instruments disagree" shape ZP exists for: a future
        // `rejectUnknownKeys( [], verb: "x")` or `rejectUnknownKeys([ ],
        // verb: "x")` would have counted as zero-param in the gate but not
        // here. No trailing `\)`: a future `rejectUnknownKeys([], verb: "x",
        // hint: "...")` site (an extra trailing argument) must still be
        // caught, not silently invisible to this sweep.
        let pattern = #"rejectUnknownKeys\(\s*\[\s*\]\s*,\s*verb:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(stripped.startIndex..., in: stripped)
        var found: Set<String> = []
        regex.enumerateMatches(in: stripped, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: stripped) else { return }
            found.insert(String(stripped[r]))
        }
        return found
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
        return try Self.scrapeZeroParamVerbs(from: text)
    }

    /// Pure scrape (no file I/O) for every `rejectUnknownKeys(...)` call site
    /// in `text` where `allowed` is an array literal, AFTER stripping `//`
    /// comments via `stripLineComments` above. Split from
    /// `verbsWithAnyRejectUnknownKeysCallSite` for the same reason as
    /// `scrapeZeroParamVerbs` — see `commentedAnyCallSiteIsNotCounted` below.
    static func scrapeAnyRejectUnknownKeysCallSites(from text: String) throws -> Set<String> {
        let stripped = stripLineComments(text)
        let pattern = #"rejectUnknownKeys\(\s*\[[^\]]*\]\s*,\s*verb:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(stripped.startIndex..., in: stripped)
        var found: Set<String> = []
        regex.enumerateMatches(in: stripped, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: stripped) else { return }
            found.insert(String(stripped[r]))
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
        return try Self.scrapeAnyRejectUnknownKeysCallSites(from: text)
    }

    @Test("the hand-maintained table above is exactly the set of rejectUnknownKeys([], verb:) sites in Commands.swift — a 39th verb (or a removal) reddens this, not just sits outside an untested table")
    func zeroParamVerbsTableMatchesSource() throws {
        let sourceVerbs = try Self.zeroParamVerbsInSource()
        #expect(!sourceVerbs.isEmpty, "the source scan itself must find something, or this test is vacuously green")
        #expect(Set(Self.zeroParamVerbs) == sourceVerbs)
        #expect(Self.zeroParamVerbs.count == 61)   // 61 at m39-w4-10 (pattern.list, DRIVEN — a compile-time list of drum beats, no store, device or sidecar) <- 60 at p2-sing-x7 part A (sing.capabilities, DRIVEN — no engine is touched) <- 59 at p2-sing-e (sing.sidecarStart, sing.installEngine, sing.cancelInstall, sing.listVoices, sing.openVoiceRecorder, all DRIVEN — the unknown key is refused before the engine, the consent request or the window is reached) <- 54 at m39-tpl-6 (template.list, DRIVEN — reads the template library's files, writes nothing) <- 53 at m39-dm (instrument.listDrumPresets, DRIVEN — a compile-time preset list with no store, device or sidecar behind it) <- 52 at m39-e (mod.describeKinds, DRIVEN — a static catalogue read that touches no store state, no device and no sidecar) <- 51 at m34-h-1 (looper.undoLayer + looper.status + looper.end, all DRIVEN; the deck's other four verbs all take params) <- 48 at m34-c (instrument.listDownloadableSoundBanks + instrument.soundBankDownloadStatus + instrument.cancelSoundBankDownload, all DRIVEN; instrument.downloadSoundBank is NOT here — it requires `id`) <- 45 at m34-h <- 39 at m23-af (transport.panic) -> 40 at m20-j (output.listDevices) -> 41 at m23-br-1 (engine.auPrepareStats) -> 42 at m28-knob (midi.getControlMap) -> 43 at m24-n (project.embeddedVoices) -> 45 at m34-h (transport.recordLayer + transport.finishLayer, both DRIVEN)
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
        #expect(Self.drivenVerbs.count == 59)   // 59 at m39-w4-10 (pattern.list) <- 58 at p2-sing-x7 part A (sing.capabilities) <- 57 at p2-sing-e (the five no-param singing verbs) <- 52 at m39-tpl-6 (template.list) <- 51 at m39-dm (instrument.listDrumPresets) <- 50 at m39-e (mod.describeKinds) <- 49 at m34-h-1 (looper.undoLayer + looper.status + looper.end — DRIVEN: with no deck session open each one refuses or answers null without reaching the transport, a device or a sidecar) <- 46 at m34-c (the three no-param sound-bank download verbs, all DRIVEN — catalogue read, status read and a cancel that refuses when nothing runs) <- 43 at m34-h <- 37 at m23-af (transport.panic) -> 38 at m20-j (output.listDevices) -> 39 at m23-br-1 (engine.auPrepareStats) -> 40 at m28-knob (midi.getControlMap — DRIVEN: reading the map is passive and opens no device) -> 41 at m24-n (project.embeddedVoices — DRIVEN: a model read plus a few fileExists calls, no device and no sidecar) -> 43 at m34-h (transport.recordLayer + transport.finishLayer — DRIVEN: rejectUnknownKeys runs before the store call, so no take can start)
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
        // ZP (2026-09-26): this used to be a hand-bumped literal (see the
        // trail below, kept for history — it stops here, at 247: the wire
        // moved to 253 while this literal stayed put, which IS the "record
        // says X, source says Y, nothing compares them" drift this repo's
        // other gates exist to catch). Derived instead. Not fully redundant
        // with the unguarded/orphaned checks above: those compare SET
        // membership, so a duplicate name inside the `allCommands` array
        // body itself would leave both sets equal while the array's own
        // `.count` silently drifted from the scrape's — this catches that
        // shape too, and still fails outright if the scrape finds fewer (or
        // more) names than the router has.
        #expect(sourceCallSites.count == CommandRouter.allCommands.count,
                "the source scrape found \(sourceCallSites.count) verb(s) but CommandRouter.allCommands has \(CommandRouter.allCommands.count) — the scrape and the wire have drifted")
        // Historical trail while this was the literal: 161 -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction) -> 234 at m23-q (clip.autoCorrectPitch/clip.clearPitchEdits/clip.getPitchEdits, appended at the tail) -> 237 at p2-c (view.openPitchEditor next to view.openEditor; clip.setNotePitch/clip.splitNote next to clip.sliceToSampler, NOT at the tail) -> 239 at m39-levels-2 wire (instrument.spreadSlice/instrument.setSpreadDirection, placed next to instrument.describeSampler, NOT at the tail) -> 241 at I7a (clip.setNoteCleared, placed next to clip.getPlayedPitch in the per-note door cluster, NOT at the tail) -> 243 at the I4 wire leg (clip.setNotePitches, placed next to clip.setNoteGain in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; two added since I7a — U-D's clip.setNoteGain landed 242 without a matching entry appended here, so this suffix continues from 241, not 242) -> 244 at the I1 wire leg (clip.auditionNote, placed immediately after clip.setNotePitches — a deliberate departure from the tail-of-cluster rule, since this verb is not a per-note WRITER like its neighbours and no dropLast(N)/suffix-window pin anywhere depends on it landing at the tail — still beside clip.sliceToSampler) -> 245 at UB-2 (clip.findUnpitchedSounds, placed immediately after clip.auditionNote, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail) -> 247 at C5a-3/NT-L3 (clip.setNoteVibrato/clip.setNoteVibratos, placed immediately after clip.findUnpitchedSounds, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; two verbs land together)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
    }

    /// ZP (2026-09-25): a call-shaped example living in a `//` comment must
    /// NOT be counted as a real `rejectUnknownKeys([], verb:)` site — a
    /// doc-count-drift.mjs would strip that comment before scoring, and this
    /// scrape must agree, or the two instruments disagree on the same file
    /// (that disagreement, not either count alone, was the bug: a phantom
    /// "orphaned verb" here while the gate stayed clean).
    @Test("a call-shaped example inside a `//` comment is not counted as a real rejectUnknownKeys([], verb:) site; the real guard right after it is")
    func commentedZeroParamCallSiteIsNotCounted() throws {
        let snippet = #"""
        // Example: rejectUnknownKeys([], verb: "zz.fakeCommentedZeroParamVerb")
        case "zz.realZeroParamVerb":
            try params.rejectUnknownKeys([], verb: "zz.realZeroParamVerb")
        """#
        let found = try Self.scrapeZeroParamVerbs(from: snippet)
        #expect(found == ["zz.realZeroParamVerb"])
    }

    /// Same law, for the any-allowed-set scrape `everyCommandReachesARejectUnknownKeysCallSite`
    /// uses — a commented example with a non-empty `allowed` array must not
    /// count either.
    @Test("a call-shaped example inside a `//` comment is not counted as a real rejectUnknownKeys(...) call site with a non-empty allowed array; the real guard right after it is")
    func commentedAnyCallSiteIsNotCounted() throws {
        let snippet = #"""
        // Example: rejectUnknownKeys(["a", "b"], verb: "zz.fakeCommentedVerb")
        case "zz.realVerb":
            try params.rejectUnknownKeys(["a", "b"], verb: "zz.realVerb")
        """#
        let found = try Self.scrapeAnyRejectUnknownKeysCallSites(from: snippet)
        #expect(found == ["zz.realVerb"])
    }

    /// ZP-2 (2026-09-25): the gate's zero-param pattern tolerates whitespace
    /// after `(`, inside `[ ]`, and before the comma
    /// (`\(\s*\[\s*\]\s*,\s*verb:`); this scrape must tolerate the SAME
    /// whitespace, not a tighter rule of its own — a `rejectUnknownKeys( [ ],
    /// verb: "…")` site would otherwise count as zero-param in the gate but
    /// not here, the identical "two instruments disagree" shape ZP exists
    /// for, just on whitespace instead of comments. Cross-checked against the
    /// gate's own regex on this exact snippet via a one-off `node -e` run
    /// (see the report) — this Swift test only needs to prove the Swift side
    /// agrees with the mirrored pattern, not re-run the gate.
    @Test("a rejectUnknownKeys([], verb:) call site written with extra whitespace inside the brackets still counts as zero-param — the scrape mirrors the gate's whitespace tolerance exactly")
    func whitespaceInsideEmptyBracketsStillCountsAsZeroParam() throws {
        let snippet = #"""
        case "zz.spaced":
            try params.rejectUnknownKeys( [ ], verb: "zz.spaced")
        """#
        let found = try Self.scrapeZeroParamVerbs(from: snippet)
        #expect(found == ["zz.spaced"])
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
