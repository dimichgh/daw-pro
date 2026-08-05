import Foundation
import Testing
@testable import DAWEngine

// m23-bp gates, LAYER 3(a) — the SITE PIN
// (docs/research/design-m23bp-note-chase.md §2.1, §9 layer 3(a), failure F3).
//
// The semantics are pinned frame-exact by layer 1 and audibly by layer 2. The
// remaining — and LIKELIEST — way this cycle fails is a MIS-WIRED SITE: the
// right rule applied at the wrong place. A headless suite cannot see that, so
// the wiring is pinned two ways:
//
//   1. COMPILE-ENFORCED. `AudioEngine.restart` / `AudioEngine.startPlayers`
//      take `cause: RescheduleCause` with NO DEFAULT, so a future reschedule
//      path does not compile until its author states a cause. The compiler,
//      not a comment, enumerates the sites.
//   2. SOURCE-PINNED (this file). The ORDERED SEQUENCE of causes in file order
//      must match the design's §2.1 table exactly.
//
// ⚠️ A COUNT PIN IS NOT SUFFICIENT AND MUST NOT BE SUBSTITUTED FOR THIS.
// Swapping `seek` to `.continuation` and `setTempo` to `.relocation` leaves the
// totals at 6/4: a count pin would pass, the bug would ship, and every other
// headless test would stay green. Those two are precisely the pair the original
// m23-bp filing conflated (it listed `:837` as a "seek / locate" when it is
// `setTempo`), so it is the single most likely mistake in this cycle.
//
// THE §2.1 TABLE (site → what → beat source → cause):
//
//  1. startPlayback   user pressed play              transport.positionBeats  .transportStart
//                     — m23-cd. WAS `.relocation`; the user's own pause/resume
//                       report and their 2026-08-04 ruling ("let's do what other
//                       DAWs do") moved it. ⚠️ IT IS A THIRD CASE, NOT
//                       `.continuation`: the beat was CHOSEN, so the anchor stays
//                       `.asSoonAsPractical` and StartAnchorPolicySiteTests'
//                       "a CONTINUATION cannot fix the beat" header stays TRUE.
//                       Chase and anchor policy are independent axes.
//  2. seek            transport locate               transport.positionBeats  .relocation
//                     — DELIBERATELY UNMOVED at m23-cd: the ruling was about the
//                       play button. Stop→click-ruler→play now chases (it goes
//                       through site 1); click-ruler-WHILE-ROLLING does not.
//                       That asymmetry is known and is the user's to rule on.
//  3. setTempo        tempo change WHILE ROLLING     derivedBeats()           .continuation
//  4. reconcile       structural change while        derivedBeats()           .continuation
//                     rolling — ANY piano-roll note
//                     edit, clip move/trim/fade/
//                     stretch (MIDIClipKey carries
//                     `notes`); the m23-bp trigger
//  5. routing rewire  belt-and-braces resume         captured derivedBeats()  .continuation
//  6. rebuildEngine   resume — THE DEVICE-FLIP PATH  captured derivedBeats()  .continuation
//  7. loopChanged     loop-bounds edit / disable     derivedBeats()           .continuation
//  8. record start    (with count-in)                transport.positionBeats  .relocation
//  9. loop-wrap       FALLBACK restart               loopStartBeat            .relocation
// 10. recoverEngine   resume (also watchdogRestart)  beat(forElapsedSeconds:) .continuation
//
// Site 9 is the subtle one: the loop-wrap fallback JUMPS from ≥ loopEndBeat
// back to a chosen beat, and its post-state must equal "seek to loop start and
// play" because every later gapless cycle reproduces exactly that state.
//
// Site 11 (`OfflineRenderer`) is not in the sequence above because it is not in
// this file. Until m23-bv it NAMED NO CAUSE AT ALL: it took `scheduleAll`'s
// `.relocation` default, and the only record that anyone had chosen that lived
// in this very header — prose, 95 lines from the code, invisible to every pin
// in the tree. m23-bv made it explicit and pinned it below, so the discipline
// is now machine-checked across all THREE files it spans (`AudioEngine.swift`
// for the ten live sites, `OfflineRenderer.swift` for site 11,
// `PlaybackGraph.swift` for the default and the production-caller SET).
// ⚠️ The behaviour is unchanged and deliberately so — but "it keeps the offline
// SHA gates byte-identical" argues against CHANGING it, never that it is right.
// m23-bv measured what it costs (a note held across `fromBeat` is absent from a
// bounce; an audio clip in the identical position is not) and left the product
// call to the user. See `OfflineChaseDivergenceTests`.
//
// NOT COVERED HERE (the named gap): layer 3(b), the LIVE per-site legs that
// start real playback, trigger each site and read the published schedule. Those
// need a real output device and their own mutant runs, so they are cycle B
// (design §10). Until they run, the wiring is source-pinned, not live-proven.

@Suite("Note chase — site wiring pin (m23-bp layer 3a)")
struct NoteChaseSiteTests {

    /// Locate `<repo>/Sources/DAWEngine` by walking up from this test file
    /// (`#filePath`, no bundle resources — runs headless under scripts/test.sh).
    private static func engineSourceDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWEngine", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources/DAWEngine from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func lines(of file: String) -> [(number: Int, text: String)] {
        let url = engineSourceDir().appendingPathComponent(file)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(url.path)")
            return []
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { ($0.offset + 1, String($0.element)) }
    }

    /// Non-comment lines only — the per-site trailing comments are prose
    /// (`// continuation: the tempo changed, the position did not`) and must
    /// never be counted as wiring.
    private static func codeLines(of file: String) -> [(number: Int, text: String)] {
        stripComments(lines(of: file))
    }

    /// m23-bv: the same filter, addressed by URL so a recursive scan of
    /// `Sources/DAWEngine` (subdirectories included) reuses it verbatim.
    private static func codeLines(at url: URL) -> [(number: Int, text: String)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(url.path)")
            return []
        }
        let all = content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { (number: $0.offset + 1, text: String($0.element)) }
        return stripComments(all)
    }

    private static func stripComments(_ input: [(number: Int, text: String)])
        -> [(number: Int, text: String)] {
        input.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                     || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///"))
        }
    }

    // MARK: - The ordered sequence

    @Test("the reschedule causes in AudioEngine.swift match the §2.1 table, IN ORDER")
    func causeSequenceMatchesDesignTable() {
        let expected: [String] = [
            "transportStart", // 1  startPlayback — m23-cd (was .relocation)
            "relocation",     // 2  seek
            "continuation",   // 3  setTempo
            "continuation",   // 4  reconcile structural change during playback
            "continuation",   // 5  routing-rewire resume
            "continuation",   // 6  rebuildEngine resume (the device-flip path)
            "continuation",   // 7  loopChanged — bounds edit / disable
            "relocation",     // 8  record start
            "relocation",     // 9  loop-wrap fallback
            "continuation",   // 10 recoverEngine
        ]

        var found: [(line: Int, cause: String)] = []
        for line in Self.codeLines(of: "AudioEngine.swift") {
            // ⚠️ EVERY case of RescheduleCause must appear in this token list.
            // A case missing here reads as "no site", not as a failure: the site
            // silently LEAVES the sequence and the expected array can be edited
            // to match, which is the m23-bp "prose far from the code" failure in
            // a new costume. m23-cd added `transportStart`.
            for token in ["relocation", "continuation", "transportStart"]
            where line.text.contains("cause: .\(token)") {
                found.append((line.number, token))
            }
        }
        let rendered: [String] = found.map { "\($0.line):\($0.cause)" }
        print("[measured] m23-bp site pin: \(rendered)")

        let why = "reschedule-cause SEQUENCE moved — a site was added, removed, or "
            + "MIS-CLASSIFIED. Measured: \(rendered). Re-read "
            + "design-m23bp-note-chase.md §2.1 before touching this array; the "
            + "expected sequence is the design, not a snapshot."
        #expect(found.map(\.cause) == expected, "\(why)")

        // Sites appear in strictly increasing file order (the scan is ordered).
        for i in 1..<max(found.count, 1) where i < found.count {
            #expect(found[i].line > found[i - 1].line)
        }
    }

    // MARK: - The internal forwards must forward, never re-decide

    /// `restart` → `startPlayers` → `graph.scheduleAll` pass the cause THROUGH.
    /// If either forward named a literal instead, the pin above would count it
    /// as an 11th site AND a whole class of sites would be silently overridden.
    @Test("the two internal forwards pass `cause: cause` — they never re-decide")
    func internalForwardsAreTransparent() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let forwards = code.filter { $0.text.contains("cause: cause") }
        print("[measured] forwards: \(forwards.map { "\($0.number)" })")
        #expect(forwards.count == 2)
        #expect(forwards.contains { $0.text.contains("startPlayers(") })
        #expect(forwards.contains { $0.text.contains("graph.scheduleAll(") })

        // …and both parameters are REQUIRED (no default), so the compiler
        // enumerates the sites. A default here would silently absorb any new
        // reschedule path as a relocation.
        let declarations = code.filter {
            $0.text.contains("cause: RescheduleCause")
        }
        #expect(declarations.count == 2)
        for declaration in declarations {
            let line = declaration.number
            #expect(!declaration.text.contains("RescheduleCause ="),
                    "a DEFAULT on line \(line) would defeat the compile-enforced site enumeration")
        }
    }

    // MARK: - m23-bv: the discipline spans three files, so the pin does too

    /// Every `scheduleAll` CALL in production, with the file it lives in and
    /// the `cause:` argument text it passes (nil = none passed).
    ///
    /// Scanning `Sources/DAWEngine` is COMPLETE, not a sample: `scheduleAll`
    /// carries no access modifier, so it is internal to this module and no
    /// other Sources target can reach it. If it ever gains `public`, this
    /// scan silently narrows — widen the root at the same commit.
    private static func productionScheduleAllCalls()
        -> [(file: String, line: Int, cause: String?)] {
        let fm = FileManager.default
        let root = engineSourceDir()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return []
        }
        var calls: [(file: String, line: Int, cause: String?)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // Read by URL, not `codeLines(of:)` — DAWEngine has subdirectories
            // (`Instruments/`, `Effects/`) whose files a bare filename misses.
            for line in codeLines(at: url) {
                guard line.text.contains("scheduleAll("),
                      !line.text.contains("func scheduleAll(") else { continue }
                let cause: String?
                if line.text.contains("cause: .continuation") {
                    cause = ".continuation"
                } else if line.text.contains("cause: .relocation") {
                    cause = ".relocation"
                } else if line.text.contains("cause: cause") {
                    cause = "cause"
                } else {
                    cause = nil
                }
                calls.append((url.lastPathComponent, line.number, cause))
            }
        }
        return calls.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    /// PRODUCTION CALLER SET (m23-bv). Exactly two, each STATING its cause.
    /// The default on `scheduleAll` exists for the ~30 fixture call sites that
    /// have no opinion; production never inherits a note-chase policy by
    /// omission.
    ///
    /// REDDENS IF: a third production caller lands (count moves off 2); or
    /// `OfflineRenderer`'s explicit `cause: .relocation` is deleted so it takes
    /// the default again (its cause reads nil — the exact regression this pin
    /// exists for, and one that changes NO behaviour, which is why no render
    /// test can catch it); or `AudioEngine`'s forward is changed to a literal
    /// (its cause stops reading "cause", meaning ten sites just got overridden
    /// at one line).
    @Test("m23-bv: production has exactly two scheduleAll callers, and both STATE a cause")
    func productionCallersStateTheirCause() {
        let calls = Self.productionScheduleAllCalls()
        let rendered = calls.map { "\($0.file):\($0.line):\($0.cause ?? "DEFAULTED")" }
        print("[measured] m23-bv scheduleAll production callers: \(rendered)")

        let why = "the production scheduleAll caller SET moved. Measured: \(rendered). "
            + "A new caller must state its cause explicitly and be added here WITH "
            + "its reasoning — a note-chase policy inherited by omission is exactly "
            + "the hole m23-bv closed. ⚠️ CHECK FOR A WRAPPED CALL FIRST: this scan "
            + "is line-based, so re-formatting an existing call so `cause:` lands on "
            + "the next line reads here as DEFAULTED. That is a formatting change, "
            + "not a wiring change — fix the formatting, not the policy."
        #expect(calls.count == 2, "\(why)")
        #expect(calls.allSatisfy { $0.cause != nil }, "\(why)")

        let offline = calls.first { $0.file == "OfflineRenderer.swift" }
        #expect(offline?.cause == ".relocation", "\(why)")
        let live = calls.first { $0.file == "AudioEngine.swift" }
        #expect(live?.cause == "cause", "\(why)")
    }

    /// THE DEFAULT ITSELF. `.relocation` = the v0 no-chase rule, which is what
    /// makes every fixture call and (by the pin above) the offline bounce
    /// byte-identical to the pre-m23-bp tree.
    ///
    /// REDDENS IF: the default flips to `.continuation` — a one-token edit that
    /// would silently start chasing held notes in ~30 fixtures and would be
    /// invisible to the `AudioEngine.swift`-scoped pins above it.
    @Test("m23-bv: scheduleAll's default cause is `.relocation`, declared in PlaybackGraph")
    func scheduleAllDefaultIsRelocation() {
        let declarations = Self.codeLines(of: "PlaybackGraph.swift")
            .filter { $0.text.contains("cause: RescheduleCause") }
        let rendered = declarations.map { "\($0.number):\($0.text.trimmingCharacters(in: .whitespaces))" }
        print("[measured] m23-bv PlaybackGraph cause declarations: \(rendered)")

        let why = "PlaybackGraph's `cause` declaration moved. Measured: \(rendered). "
            + "The default is the OFFLINE BYTE-IDENTITY anchor: `.relocation` is the "
            + "v0 no-chase rule. Flipping it changes what every bounce and every "
            + "fixture renders."
        #expect(declarations.count == 1, "\(why)")
        #expect(declarations.first?.text.contains("RescheduleCause = .relocation") == true,
                "\(why)")
    }

    // MARK: - The ONE home of the mapping

    /// `chasesHeldNotes` is read EXACTLY ONCE in the whole engine — in
    /// `PlaybackGraph.scheduleAll`. A second read is a second definition of the
    /// law and the registry rule forbids it.
    @Test("`chasesHeldNotes` has exactly one consumer, and it is scheduleAll")
    func chaseMappingHasOneHome() {
        let fm = FileManager.default
        let root = Self.engineSourceDir()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return
        }
        var reads: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, raw) in content.split(separator: "\n",
                                              omittingEmptySubsequences: false).enumerated() {
                let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                if trimmed.contains(".chasesHeldNotes") {
                    reads.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        print("[measured] chasesHeldNotes reads: \(reads)")
        #expect(reads.count == 1)
        #expect(reads.first?.hasPrefix("PlaybackGraph.swift:") == true)
    }

    // MARK: - The mapping itself

    @Test("the RescheduleCause mapping: continuation and transportStart chase, relocation does not")
    func mappingIsTheDesignRule() {
        #expect(RescheduleCause.continuation.chasesHeldNotes)
        #expect(!RescheduleCause.relocation.chasesHeldNotes)
        // m23-cd — THE RULING, in one line: the play button chases.
        #expect(RescheduleCause.transportStart.chasesHeldNotes)
    }

    /// The sequence scan above matches a HARD-CODED token list. A case absent
    /// from it does not fail — its sites silently vanish from `found`, and the
    /// expected array can then be "fixed" to match a sequence that is missing a
    /// real site. This makes that impossible: every case must be scannable.
    ///
    /// REDDENS IF: a fourth `RescheduleCause` case lands without joining the
    /// token list in `causeSequenceMatchesDesignTable`.
    @Test("m23-cd: the cause-sequence scan covers EVERY RescheduleCause case")
    func scanTokenListIsExhaustive() {
        let scanned: Set<String> = ["relocation", "continuation", "transportStart"]
        let all = Set(RescheduleCause.allCases.map { String(describing: $0) })
        print("[measured] RescheduleCause cases: \(all.sorted()); scanned: \(scanned.sorted())")
        let why = "a RescheduleCause case is missing from the sequence scan's token list — its "
            + "sites would DISAPPEAR from the pin rather than fail it. Cases: \(all.sorted())."
        #expect(all == scanned, "\(why)")
    }
}
