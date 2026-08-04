import Foundation
import Testing
@testable import DAWEngine

// m23-bs-3a LEGS A-L7, A-L8, A-L9 — THE STRUCTURAL HALF OF THE CONTINUATION FIX.
//
// bs-3a gave the two resume sites (the routing-rewire resume in
// `tracksDidChangeBody`, and the cold-rebuild resume in `rebuildEngine`) the
// mechanism bs-2 built for `recoverEngine`: predict the instant the anchor will
// land on, derive the beat FOR that instant off the outgoing anchor's line, and
// pass both. Three of the ways to get that wrong are INVISIBLE to any property
// witness this tree can afford, and each has its own leg here.
//
//   A-L7  THE COUNT'S READ SITE. `graph.startablePlayerCount` must be read
//         BEFORE the enclosing method's `stopAllPlayers()`. That call runs
//         `noteStopped()` on every node and the enqueue ledger goes to ZERO, so
//         the same read one line lower returns 0 whatever the project holds —
//         the horizon collapses to the floor and a large project under-predicts
//         its anchor by up to 0.44 s. SILENT, PROJECT-SIZE-DEPENDENT, and
//         invisible to a one-clip fixture. Two of the four reads this covers
//         have NO live leg at all.
//
//   A-L8  THE RESUME STATE CARRIES NO BEAT. Until bs-3a,
//         `resumeAfterRoutingRewire` was `(beats:, tempoMap:)` — a beat frozen
//         at quiesce, anchored at a NEW instant an arbitrary amount of work
//         later. ⚠️ THIS LEG IS NOT "JUST A SOURCE PIN" AND MUST NOT BE DELETED
//         AS ONE. The rejected §14.2 alternative — carry `(beats, quiesceHost)`
//         and derive FORWARD by elapsed wall time — is algebraically close
//         enough to pass the live property leg on a LINEAR fixture; its real
//         defect is a modular-ORIGIN error (`beat(forElapsedSeconds:)` measures
//         the modular branch's `headSeconds` from the ANCHOR, not from quiesce)
//         and bs-3a has no loop leg. That is a NAMED COVERAGE GAP, closed
//         STRUCTURALLY here rather than behaviourally.
//
//   A-L9  `loopContext` HAS EXACTLY THREE WRITING FUNCTIONS. The carried line
//         describes the OUTGOING roll, but `resumeBeat`'s modular branch reads
//         the ENGINE's surviving `loopContext`. That pairing is valid only
//         because nothing writes `loopContext` between quiesce and resume. A
//         fourth writer would break it SILENTLY — the wrong wrap, on the right
//         line, with every anchor-pair assertion green.
//
// ⚠️ A-L9 IS A SET PIN, NOT A COUNT PIN, AND THE DIFFERENCE IS NOT PEDANTRY.
// There are FOUR textual assignments in three functions: `startPlayers` writes
// `loopContext` TWICE (nil on the way in, then the rebuilt `LoopContext` when
// the window is eligible — that pair IS §5.1's hazard and the reason the
// derivation must stay at the call site). A count pin would red on arrival and
// the obvious "fix" would be to weaken it to 4, which then admits a genuine
// fourth writer anywhere.
//
// SCOPING, CONFIRMED BY READING RATHER THAN INFERRED (§14.8's warning). The
// enclosing declaration of the quiesce hook is `wireGraphHooks` — the hook is a
// CLOSURE assigned to `graph.willMutateRoutingTopology` inside that method, so a
// slicer that guessed brace depth would silently cover three sites while
// reporting four. Confirmed ranges at the time of writing (2026-08-02):
//
//     wireGraphHooks   :611  read :708  stop :722   PASS
//     rebuildEngine    :1163 read :1175 stop :1185  PASS
//     startPlayers     :3342 read :3402 (no stopAllPlayers in body)  PASS
//     recoverEngine    :3864 read :3890 stop :3899  PASS
//
// ⚠️ "NO `stopAllPlayers()` AT ALL" IS A PASS, AND THAT CLAUSE IS NOT A
// LOOPHOLE. `startPlayers`' own read has no stop in its body and is correct; a
// pin that failed it would be deleted within a cycle.
//
// Headless: source-text only, no engine, no device, no live session. bs-3a adds
// ZERO live playback sessions and this file is why that is affordable.
//
// MUTANTS RUN AND MEASURED (filtered, 2026-08-02 — full numbers in
// `docs/ROADMAP.md`'s m23-bs-3a close record):
//
//   (b) move either resume site's count read below its `stopAllPlayers()`
//                                          → A-L7 RED (named site), and the
//                                            live L3 half RED (engine 0 vs
//                                            snapshot 1)
//   (d) carry `(beats:, line:, count:)` and derive forward from the frozen beat
//                                          → A-L8 RED; NOTHING ELSE reddens
//
// Suite is `.serialized` for no concurrency reason — these are pure file reads —
// but the printed `[measured]` lines are the record, and interleaved prints from
// a parallel suite make them unreadable.

@Suite("Continuation resume state — site wiring pins (m23-bs-3a)", .serialized)
struct ContinuationResumeStateSiteTests {

    // MARK: - Source access (the StartAnchorPolicySiteTests idiom, verbatim)

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

    /// Non-comment lines only. This file's subject is named dozens of times in
    /// the engine's own doc comments — including in the very comments that
    /// explain WHY the read site matters — so a matcher that saw comments would
    /// report reads and writes that do not exist.
    private static func codeLines(of file: String) -> [(number: Int, text: String)] {
        lines(of: file).filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                     || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///"))
        }
    }

    /// Every 4-space-indented `func` declaration, as (name, first line). The
    /// enclosing declaration of any line is the LAST of these above it, and its
    /// range runs to the next one — §14.8's rule, chosen over brace depth
    /// precisely so a closure assigned inside a method (the quiesce hook) is
    /// attributed to the method that installs it.
    ///
    /// ⚠️ Members that are not `func`s (stored/computed properties, nested
    /// types) do not open a range, so lines between two funcs are attributed to
    /// the earlier func. That is deliberate for the closure case and harmless
    /// for the four reads this file cares about — all four are inside real
    /// function bodies. It would matter if someone read
    /// `graph.startablePlayerCount` from a computed property; the printed
    /// attribution below is what would show it.
    private static func declarations(in code: [(number: Int, text: String)])
        -> [(name: String, line: Int)] {
        var found: [(name: String, line: Int)] = []
        for candidate in code {
            let text = candidate.text
            guard text.hasPrefix("    ") && !text.hasPrefix("     ") else { continue }
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            for modifier in ["public ", "private ", "internal ", "fileprivate ", "static ",
                             "override ", "final "] {
                while trimmed.hasPrefix(modifier) { trimmed.removeFirst(modifier.count) }
            }
            guard trimmed.hasPrefix("func ") else { continue }
            trimmed.removeFirst("func ".count)
            found.append((String(trimmed.prefix { $0 != "(" && $0 != "<" }), candidate.number))
        }
        return found
    }

    /// The half-open line range of the declaration lexically containing `line`.
    private static func enclosingRange(ofLine line: Int,
                                       declarations: [(name: String, line: Int)],
                                       lastLine: Int) -> (name: String, from: Int, to: Int) {
        var result = (name: "<file scope>", from: 0, to: lastLine + 1)
        for (index, declaration) in declarations.enumerated() where declaration.line < line {
            let end = index + 1 < declarations.count ? declarations[index + 1].line : lastLine + 1
            result = (declaration.name, declaration.line, end)
        }
        return result
    }

    // MARK: - A-L7: the count is read BEFORE the stop that zeroes it

    @Test("every startablePlayerCount read precedes its method's stopAllPlayers (m23-bs-3a A-L7)")
    func countIsReadAboveTheStopThatZeroesIt() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let declarations = Self.declarations(in: code)
        let lastLine = code.last?.number ?? 0

        let reads = code.filter { $0.text.contains("graph.startablePlayerCount") }
        let stops = code.filter { $0.text.contains("stopAllPlayers()") }
        print("[measured] m23-bs-3a A-L7 startablePlayerCount reads: "
              + "\(reads.map { "\($0.number)" }); stopAllPlayers(): "
              + "\(stops.map { "\($0.number)" })")

        let hollow: String = "no `graph.startablePlayerCount` read was found in AudioEngine.swift "
            + "at all — this leg proved nothing. Either the forecast source moved out of the "
            + "engine or the matcher broke."
        #expect(reads.count >= 4, "\(hollow)")

        var attribution: [String] = []
        for read in reads {
            let scope = Self.enclosingRange(ofLine: read.number, declarations: declarations,
                                            lastLine: lastLine)
            let stopsInScope = stops.filter { $0.number > scope.from && $0.number < scope.to }
            let verdict: String
            if stopsInScope.isEmpty {
                // The §14.8 clause: no stop in the declaration at all is a PASS.
                // `startPlayers`' own read lives here and is correct.
                verdict = "no-stop"
            } else if let after = stopsInScope.first(where: { $0.number > read.number }) {
                verdict = "stop@\(after.number)"
            } else {
                verdict = "STOP-ABOVE"
            }
            attribution.append("\(scope.name):read@\(read.number):\(verdict)")

            guard !stopsInScope.isEmpty else { continue }
            let why: String = "m23-bs-3a LANDMINE (§13.3/§14.3): `graph.startablePlayerCount` is "
                + "read at AudioEngine.swift:\(read.number), inside `\(scope.name)` "
                + "(\(scope.from)..<\(scope.to)), with NO `stopAllPlayers()` after it — so the "
                + "read sits BELOW the stop. `stopAllPlayers()` calls `noteStopped()` on every "
                + "node, which zeroes the enqueue ledger, so that read returns 0 whatever the "
                + "project holds. The continuation horizon then collapses to the floor and a "
                + "large project under-predicts its anchor by up to 0.44 s — SILENTLY, in "
                + "proportion to project size, and invisibly to a one-clip fixture. Move the "
                + "read above the stop. Sites: \(attribution)"
            #expect(stopsInScope.contains { $0.number > read.number }, "\(why)")
        }
        print("[measured] m23-bs-3a A-L7 attribution: \(attribution)")

        // ANTI-VACUITY. The rule's whole value is that it covers the two resume
        // sites, which have NO live leg. If the slicer ever stops finding them —
        // a renamed method, a hoisted closure — this leg would keep passing while
        // covering less, which is the failure mode §14.8 warns about by name.
        let covered = Set(reads.map {
            Self.enclosingRange(ofLine: $0.number, declarations: declarations,
                                lastLine: lastLine).name
        })
        let missing: String = "A-L7 no longer covers the sites it exists for. Expected reads "
            + "inside `wireGraphHooks` (the routing-rewire quiesce hook — a CLOSURE, so its "
            + "enclosing declaration is the method that installs it), `rebuildEngine` (the "
            + "cold-rebuild quiesce) and `recoverEngine`. Measured: \(covered.sorted())"
        #expect(covered.isSuperset(of: ["wireGraphHooks", "rebuildEngine", "recoverEngine"]),
                "\(missing)")
    }

    // MARK: - A-L8: the resume state carries a LINE, never a beat

    @Test("the resume state carries no frozen beat, and one derivation takes it (m23-bs-3a A-L8)")
    func resumeStateCarriesALineAndNotABeat() {
        let code = Self.codeLines(of: "AudioEngine.swift")

        let declarations = code.filter { $0.text.contains("var resumeAfterRoutingRewire") }
        print("[measured] m23-bs-3a A-L8 resume-state declaration: "
              + "\(declarations.map { "\($0.number):\($0.text.trimmingCharacters(in: .whitespaces))" })")
        #expect(declarations.count == 1,
                "there must be exactly ONE resume-state declaration; found \(declarations.count)")

        for declaration in declarations {
            let text = declaration.text
            let why: String = "m23-bs-3a §14.2 REGRESSION at AudioEngine.swift:"
                + "\(declaration.number): the resume state must carry the outgoing anchor's "
                + "LINE and the quiesce player count, and NOTHING ELSE — `(line: AnchorLine, "
                + "startablePlayerCount: Int)?`. Measured: "
                + text.trimmingCharacters(in: .whitespaces) + ". A `beats:` field is the "
                + "PRE-bs-3a frozen beat, which anchors a stale beat at a new instant (the "
                + "m19-f shifted-origin hazard). A carried quiesce HOST time is the rejected "
                + "'derive forward' option, which fails on three counts: it mixes clock bases "
                + "(the quiesce beat prefers the SAMPLE branch while the host stamp does not, "
                + "re-importing the render-clock lead as a silent additive error), it needs a "
                + "SECOND home for the loop-wrap arithmetic (the modular branch measures "
                + "headSeconds from the ANCHOR, not from quiesce), and it double-applies the "
                + "`max(startBeats, …)` clamp, which is not idempotent across the modular "
                + "branch. ⚠️ A LINEAR live fixture CANNOT SEE that mutant — this assertion is "
                + "the only thing covering it."
            #expect(text.contains("line: AnchorLine"), "\(why)")
            #expect(text.contains("startablePlayerCount: Int"), "\(why)")
            #expect(!text.contains("beats:"), "\(why)")
            #expect(!text.contains("tempoMap:"), "\(why)")
            #expect(!text.contains("Host"), "\(why)")
        }

        // The derivation is narrowed to the LINE, and there is exactly one of it.
        let resumeBeat = code.filter { $0.text.contains("func resumeBeat(") }
        print("[measured] m23-bs-3a A-L8 resumeBeat declarations: "
              + "\(resumeBeat.map { "\($0.number):\($0.text.trimmingCharacters(in: .whitespaces))" })")
        let oneHome: String = "there must be exactly ONE `resumeBeat` declaration and it must "
            + "take `(at:line:)`. FOUR sites now come to it (recoverEngine, the rewire resume, "
            + "the rebuild resume, and bs-3b's restart) and two of them no longer hold a "
            + "PlaybackAnchor at all — the engine they anchored against was discarded. An "
            + "overload taking a PlaybackAnchor is a second entrance to the one derivation. "
            + "Measured: \(resumeBeat.map { $0.text.trimmingCharacters(in: .whitespaces) })"
        #expect(resumeBeat.count == 1, "\(oneHome)")
        for declaration in resumeBeat {
            #expect(declaration.text.contains("at host: UInt64"), "\(oneHome)")
            #expect(declaration.text.contains("line: AnchorLine"), "\(oneHome)")
        }

        // …and the type it narrows TO carries no sample-domain field. This is the
        // representability claim itself: `anchorSampleTime` / `outputSampleRate` /
        // `hasSampleAnchor` stop meaning anything across an engine REPLACEMENT,
        // and carrying them re-opens the m23-bq failure class (a stale sample
        // clock, structurally valid-looking, read against a NEW render session).
        guard let start = code.first(where: { $0.text.contains("struct AnchorLine {") })
        else {
            let absent: String = "no `struct AnchorLine` declaration found in "
                + "AudioEngine.swift — A-L8's representability half proved nothing"
            Issue.record("\(absent)")
            return
        }
        var body: [String] = []
        for line in code where line.number > start.number {
            if line.text.trimmingCharacters(in: .whitespaces) == "}" { break }
            body.append(line.text.trimmingCharacters(in: .whitespaces))
        }
        print("[measured] m23-bs-3a A-L8 AnchorLine fields: \(body)")
        let narrow: String = "`AudioEngine.AnchorLine` must carry the HOST-domain projection "
            + "ONLY — startBeats, tempoMap, anchorHostTime. The sample-domain fields stop "
            + "meaning anything when the engine object is replaced, and carrying them across a "
            + "rebuild makes representable exactly the state the m23-bq defect was made of. "
            + "Measured: \(body)"
        #expect(body.contains { $0.contains("let startBeats: Double") }, "\(narrow)")
        #expect(body.contains { $0.contains("let tempoMap: TempoMap") }, "\(narrow)")
        #expect(body.contains { $0.contains("let anchorHostTime: UInt64") }, "\(narrow)")
        for forbidden in ["anchorSampleTime", "outputSampleRate", "hasSampleAnchor"] {
            #expect(!body.contains { $0.contains(forbidden) }, "\(narrow)")
        }
    }

    // MARK: - A-L9: exactly three functions write loopContext

    @Test("`loopContext` is written by exactly three functions (m23-bs-3a A-L9)")
    func loopContextHasThreeWritingFunctions() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let declarations = Self.declarations(in: code)
        let lastLine = code.last?.number ?? 0

        // Assignment lines only: `loopContext = …` / `self.loopContext = …`,
        // never `if let loop = loopContext` or `loopContext != nil`.
        let writes = code.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("loopContext =") || trimmed.hasPrefix("self.loopContext =")
        }
        let writers = writes.map {
            (line: $0.number,
             name: Self.enclosingRange(ofLine: $0.number, declarations: declarations,
                                       lastLine: lastLine).name)
        }
        print("[measured] m23-bs-3a A-L9 loopContext writes: "
              + "\(writers.map { "\($0.line):\($0.name)" })")

        // ⚠️ A SET, NOT A COUNT — `startPlayers` writes it TWICE (nil in, then
        // the rebuilt window). See this file's header.
        let expected: Set<String> = ["windDownAfterException", "stopPlayback", "startPlayers"]
        let measured = Set(writers.map(\.name))
        let why: String = "m23-bs-3a §14.2 PAIRING ASSUMPTION BROKEN: `loopContext` is written "
            + "by \(measured.sorted()), expected \(expected.sorted()). The two resume sites "
            + "carry an `AnchorLine` from the OUTGOING roll, but `resumeBeat`'s modular branch "
            + "reads the ENGINE's `loopContext` — correct ONLY because the carried line and the "
            + "surviving loop context come from the same outgoing `startPlayers`. A fourth "
            + "writer between quiesce and resume would wrap the resume against a window the "
            + "carried line never played, and every anchor-pair assertion would stay GREEN. If "
            + "the new writer is legitimate, the resume sites need to carry the loop context "
            + "too — do NOT simply widen this set. Writes: "
            + "\(writers.map { "\($0.line):\($0.name)" })"
        #expect(measured == expected, "\(why)")

        let hollow: String = "no `loopContext` assignment was found at all — the matcher broke, "
            + "and a broken matcher here reads exactly like a clean tree"
        #expect(writes.count >= 3, "\(hollow)")
    }
}
