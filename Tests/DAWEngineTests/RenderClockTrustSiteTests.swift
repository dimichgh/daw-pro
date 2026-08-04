import Foundation
import Testing
@testable import DAWEngine

// m23-bq — THE RENDER-CLOCK TRUST SITE PIN.
//
// `AudioEngine.startPlayers(renderClockTrusted:)` decides which clock the
// transport anchor is built from. `true` reads `outputNode.lastRenderTime`;
// `false` forces the host-clock branch. The rule is one question:
//
//     DID THE ENGINE BOUNCE (stop→start) SINCE THE LAST RENDER CALLBACK?
//
// If it did, `lastRenderTime` still reports the PREVIOUS session's sample clock
// with its valid flags set while the new session's clock restarts near zero,
// so a sample anchor built from it makes `derivedBeats` read negative elapsed
// time and the `max()` clamp freezes the playhead for the whole length of the
// previous session (m23-bq, measured 1045/2060/3063 ms against 1/2/3 s rolls;
// and M4 (i) before it, 2026-07-06).
//
// TWO PINS, because either alone has a hole:
//
//   1. COMPILE-ENFORCED. m23-bq REMOVED the `= true` default from
//      `renderClockTrusted`, exactly as m23-bp did for `cause`. The defaulted
//      form is HOW THIS BUG SHIPPED: `recoverEngine` — the one routine whose
//      own doc comment says the sample timeline just broke — inherited "trust
//      the render clock" by saying nothing at all. A required parameter makes
//      the compiler ask every future start path the question above.
//
//   2. SOURCE-PINNED (this file). The ORDERED SEQUENCE of (enclosing method,
//      trusted?) must match the table below.
//
// ⚠️ A COUNT PIN IS NOT SUFFICIENT AND MUST NOT BE SUBSTITUTED FOR THIS
// (the m23-bp lesson, NoteChaseSiteTests). Moving the `false` from
// `recoverEngine` to `startPlayback` keeps the totals at 3/3: a count pin would
// pass while the shipped bug came back and every other headless test stayed
// green.
//
// THE TABLE (site → does the engine bounce first? → trusted):
//
//  1. startPlayback        no  — `stopPlayback` stops PLAYERS, not the         true
//                                engine, so the clock rolls through; a
//                                never-started engine reports nil and the
//                                trusted branch falls through by itself
//  2. tracksDidChangeBody  YES — routing-rewire resume (belt-and-braces;       false
//                                the announce normally aborts into rebuild)
//  3. rebuildEngine        YES — the whole AVAudioEngine was replaced;         false
//                                THE DEVICE-FLIP PATH (m20-e)
//  4. startTakeBody        no  — record-arm never bounces the output           true
//                                engine (capture is InputCapture's own)
//  5. restart              no  — THE reschedule primitive: stops players,      true
//                                never the engine, so every site that
//                                reaches playback through it is trusted
//                                by construction (seek, setTempo, edits,
//                                loop changes, the loop-wrap fallback)
//  6. recoverEngine        YES — engine.prepare()+start() two lines above,     false
//                                and `watchdogRestart` stops it first;
//                                ALSO the config-change route
//                                (`handleConfigurationChange` is a verbatim
//                                one-line alias). THE m23-bq FIX.
//
// Behavioral twins for sites 5 and 6 live in `RecoveryPlayheadTests`; sites 2
// and 3 have no live leg in this tree (a routing rewire under a rolling
// transport needs the m20-e style live gate), which is precisely why the
// source pin is not optional.

@Suite("Render-clock trust — site wiring pin (m23-bq)")
struct RenderClockTrustSiteTests {

    // MARK: - Source access (the NoteChaseSiteTests idiom, verbatim)

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

    /// Non-comment lines only — this file's own prose says
    /// `renderClockTrusted: false` many times over, and so does the
    /// `startPlayers` doc comment. Comments are never wiring.
    private static func codeLines(of file: String) -> [(number: Int, text: String)] {
        lines(of: file).filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                     || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///"))
        }
    }

    /// Name of the method a source line sits inside — the nearest preceding
    /// declaration at type-body indent (4 spaces).
    private static func enclosingMethod(ofLine line: Int,
                                        in code: [(number: Int, text: String)]) -> String {
        var name = "<file scope>"
        for candidate in code where candidate.number < line {
            let text = candidate.text
            guard text.hasPrefix("    ") && !text.hasPrefix("     ") else { continue }
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            for modifier in ["public ", "private ", "internal ", "fileprivate ", "static "] {
                while trimmed.hasPrefix(modifier) { trimmed.removeFirst(modifier.count) }
            }
            guard trimmed.hasPrefix("func ") else { continue }
            trimmed.removeFirst("func ".count)
            name = String(trimmed.prefix { $0 != "(" && $0 != "<" })
        }
        return name
    }

    /// Joins a call that spans lines: from `start`, accumulate until the
    /// parentheses balance (the argument list is closed).
    private static func callText(from start: Int,
                                 in code: [(number: Int, text: String)]) -> String {
        var depth = 0
        var joined = ""
        for line in code where line.number >= start {
            joined += " " + line.text
            for character in line.text {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            }
            if depth <= 0 { break }
        }
        return joined
    }

    // MARK: - The ordered sequence

    @Test("every startPlayers call site states its render-clock trust, and the sequence matches the table")
    func trustSequenceMatchesTheTable() {
        let expected: [(method: String, trusted: Bool)] = [
            ("startPlayback", true),           // 1
            ("tracksDidChangeBody", false),    // 2  routing-rewire resume
            ("rebuildEngine", false),          // 3  THE device-flip path
            ("startTakeBody", true),           // 4
            ("restart", true),                 // 5  the reschedule primitive
            ("recoverEngine", false),          // 6  THE m23-bq fix
        ]

        let code = Self.codeLines(of: "AudioEngine.swift")
        var found: [(line: Int, method: String, trusted: Bool)] = []
        for line in code where line.text.contains("startPlayers(")
            && !line.text.contains("func startPlayers(") {
            let call = Self.callText(from: line.number, in: code)
            let trusted: Bool
            if call.contains("renderClockTrusted: true") {
                trusted = true
            } else if call.contains("renderClockTrusted: false") {
                trusted = false
            } else {
                let silent: String = "startPlayers call at AudioEngine.swift:\(line.number) "
                    + "states no renderClockTrusted — the parameter must have regained a "
                    + "default. Re-read this file's header."
                Issue.record("\(silent)")
                continue
            }
            found.append((line.number, Self.enclosingMethod(ofLine: line.number, in: code),
                          trusted))
        }

        let rendered = found.map { "\($0.line):\($0.method):\($0.trusted)" }
        print("[measured] m23-bq trust sites: \(rendered)")

        let why = "the render-clock trust SEQUENCE moved — a start path was added, removed, "
            + "or MIS-CLASSIFIED. Measured: \(rendered). The question every entry answers "
            + "is 'did the engine bounce since the last render callback?'; re-read this "
            + "file's header table before touching the expected array, and note that a "
            + "COUNT pin would not have caught a swap."
        #expect(found.map(\.method) == expected.map(\.method), "\(why)")
        #expect(found.map(\.trusted) == expected.map(\.trusted), "\(why)")

        // The three host-clock sites are the three engine-bounce paths, named.
        let untrusted = Set(found.filter { !$0.trusted }.map(\.method))
        #expect(untrusted == ["tracksDidChangeBody", "rebuildEngine", "recoverEngine"],
                "\(why)")

        // Sites appear in strictly increasing file order (the scan is ordered).
        for i in 1..<max(found.count, 1) where i < found.count {
            #expect(found[i].line > found[i - 1].line)
        }
    }

    // MARK: - The compile-enforced half

    /// The hole a pure call-site pin leaves: restore `= true` on the
    /// declaration and a future site can go back to inheriting trust silently
    /// — which is exactly how m23-bq shipped. (The mirror of
    /// NoteChaseSiteTests' no-default assertion for `cause`.)
    @Test("`renderClockTrusted` has NO default — the compiler enumerates the sites")
    func parameterHasNoDefault() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let declarations = code.filter { $0.text.contains("renderClockTrusted: Bool") }
        print("[measured] renderClockTrusted declarations: \(declarations.map { "\($0.number)" })")
        #expect(declarations.count == 1)
        for declaration in declarations {
            let why = "a DEFAULT on AudioEngine.swift:\(declaration.number) would let a future "
                + "start path inherit render-clock trust by saying nothing — the exact shape "
                + "of the m23-bq defect"
            #expect(!declaration.text.contains("Bool ="), "\(why)")
        }
    }

    // MARK: - The ONE consumer of the resulting flag

    /// `hasSampleAnchor` is the only thing the choice produces, and it is read
    /// EXACTLY ONCE in the whole engine — `AudioEngine.elapsedSeconds(anchor:)`,
    /// which picks render clock vs host clock. A second reader would be a
    /// second definition of the law (the "ONE home" registry rule) and would
    /// mean the audit behind this fix — that taking the host branch changes
    /// nothing but which clock `elapsedSeconds` reads — no longer holds.
    @Test("`hasSampleAnchor` has exactly one consumer, and it is elapsedSeconds")
    func sampleAnchorFlagHasOneConsumer() {
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
                // `.hasSampleAnchor` = a READ; `hasSampleAnchor:` = construction.
                if trimmed.contains(".hasSampleAnchor") {
                    reads.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        print("[measured] hasSampleAnchor reads: \(reads)")
        #expect(reads.count == 1)
        #expect(reads.first?.hasPrefix("AudioEngine.swift:") == true)
    }
}
