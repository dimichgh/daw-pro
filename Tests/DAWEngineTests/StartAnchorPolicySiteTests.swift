import Foundation
import Testing
@testable import DAWEngine

// m23-bs-2 LEG L5 — THE START-ANCHOR POLICY SITE PIN.
//
// `AudioEngine.startPlayers(anchorPolicy:)` decides WHICH INSTANT a start
// anchors on. The rule is one question:
//
//     DID THE CALLER CHOOSE THE BEAT, OR DID WALL TIME CHOOSE IT?
//
// `startBeats` is the beat that occurs at `anchorHostTime` — for the clip
// schedule, the automation origin, the metronome, the reference track and the
// playhead SIMULTANEOUSLY. A RELOCATION fixes the beat (the user seeked, or
// picked a record point), so any instant will do and `.asSoonAsPractical` takes
// the earliest practical one. A CONTINUATION cannot: wall time kept running
// through the engine bounce, so the beat is a FUNCTION of the instant, and the
// caller must pick the instant FIRST, derive the beat for it off the outgoing
// anchor's line, and pass both — `.atHostTime`.
//
// FOUR PINS, because each alone has a hole:
//
//   1. COMPILE-ENFORCED. `anchorPolicy` has NO DEFAULT, exactly as m23-bp did
//      for `cause` and m23-bq for `renderClockTrusted`. Silence is how
//      `recoverEngine` inherited the wrong answer BOTH previous times; a
//      required parameter makes the compiler ask every future start path.
//
//   2. SOURCE-PINNED SEQUENCE (this file). The ordered (enclosing method,
//      policy) table must match. ⚠️ A COUNT PIN IS NOT SUFFICIENT — moving the
//      `.atHostTime` from `recoverEngine` to `startPlayback` keeps the totals at
//      5/1 while inverting the meaning of both sites (the m23-bp lesson).
//
//   3. THE CLICK ANCHOR. §13.6 — the blind spot NO property witness covers. In
//      both anchor branches the metronome anchors on `clickAnchorHost`, not on
//      the transport anchor. An implementation that sets the transport anchor to
//      the chosen instant and leaves the click anchor built from the LEAD
//      desyncs the click from the transport by exactly the continuation's
//      over-prediction — and every anchor-pair assertion in
//      `RecoveryAnchorContinuityGateTests` stays GREEN, because they all read
//      the transport pair. There is no live metronome-timing leg in this tree;
//      this source assertion is the whole guard.
//
//   4. THE TWO ANCHOR-SAMPLE FORMS. §11's risk register assigns "source-pinned
//      at bs-2" to the trusted branch's `anchorSample`, and §13.7's L5 row then
//      omitted it — so §13.6's "do not rewrite the `.asSoonAsPractical` path to
//      use the host-delta form for symmetry" had only a code comment behind it.
//      Added here after review. The two forms are algebraically equal and NOT
//      byte-identical; collapsing them perturbs `anchorSampleTime` on every
//      normal play, and no property witness can see it.
//
// THE TABLE (site → who chose the beat? → policy):
//
//  1. startPlayback        the user seeked/played           .asSoonAsPractical
//  2. tracksDidChangeBody  WALL TIME (rewire resume)        .atHostTime
//                          — m23-bs-3a. ⚠️ SOURCE-PINNED HERE AND NOWHERE ELSE:
//                            this site is UNREACHABLE in this tree (an announce
//                            always aborts into the rebuild branch, which
//                            consumes the resume state), so it has NO live leg
//                            and this table is its whole coverage. It is flipped
//                            anyway — a reachable future path must inherit a
//                            STATED answer, not a known-wrong one.
//  3. rebuildEngine        WALL TIME (rebuild resume)       .atHostTime
//                          — m23-bs-3a, THE device-flip path (m20-e). Live leg:
//                            EngineRebuildTests.midPlayStripBirthRebuildsAndResumes
//  4. startTakeBody        the user chose the record beat   .asSoonAsPractical
//                          — and the ONE site passing a non-zero countInBars
//  5. restart              THE reschedule primitive; every  .asSoonAsPractical
//                          path through it relocated       — m23-bs-3b splits
//                          this row in two (a RestartOrigin, one branch each)
//  6. recoverEngine        WALL TIME — THE m23-bs-2 FIX     .atHostTime
//
// ⚠️ THE COUNT READ AND THE DERIVATION MOVE TOGETHER WITH THE POLICY, and this
// table cannot see either. Rows 2 and 3 read `graph.startablePlayerCount` at
// QUIESCE — not at the resume site, where it returns 0 BY CONSTRUCTION — and
// derive their beat at the CALL SITE, above `startPlayers`. Those two are pinned
// by `ContinuationResumeStateSiteTests` (A-L7, A-L8) and by the live L3 half in
// `EngineRebuildTests`. A green table with a wrong read site is a real state.
//
// ⚠️ `RenderClockTrustSiteTests` DID NOT MOVE FOR bs-3a, and that is not an
// oversight either: flipping the anchor POLICY does not change the TRUST answer.
// Both resume sites still bounced the engine, so both stay `renderClockTrusted:
// false` and the `untrusted` set is identical. Only this file moved.
//
// Headless: source-text only, no engine, no device.

@Suite("Start-anchor policy — site wiring pin (m23-bs-2)")
struct StartAnchorPolicySiteTests {

    // MARK: - Source access (the RenderClockTrustSiteTests idiom, verbatim)

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

    /// Non-comment lines only — this file's prose and the engine's own doc
    /// comments name both policies many times over. Comments are never wiring.
    private static func codeLines(of file: String) -> [(number: Int, text: String)] {
        lines(of: file).filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                     || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///"))
        }
    }

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

    /// ⚠️ PAREN-BALANCED JOIN, NOT A PER-LINE MATCH. `anchorPolicy:` sits on the
    /// CONTINUATION line at five of the six sites (adding it is what forced
    /// those calls to wrap), so a per-line matcher — the
    /// `NoteChaseSiteTests.internalForwardsAreTransparent` idiom — would find
    /// nothing and this whole file would read green while asserting on an empty
    /// array. Mirror `RenderClockTrustSiteTests.callText` instead.
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

    @Test("every startPlayers call site states its anchor policy, and the sequence matches the table")
    func policySequenceMatchesTheTable() {
        let expected: [(method: String, policy: String)] = [
            ("startPlayback", "asSoonAsPractical"),        // 1
            ("tracksDidChangeBody", "atHostTime"),         // 2  bs-3a, no live leg
            ("rebuildEngine", "atHostTime"),               // 3  bs-3a, THE m20-e path
            ("startTakeBody", "asSoonAsPractical"),        // 4
            ("restart", "asSoonAsPractical"),              // 5  bs-3b splits this row
            ("recoverEngine", "atHostTime"),               // 6  THE m23-bs-2 FIX
        ]

        let code = Self.codeLines(of: "AudioEngine.swift")
        var found: [(line: Int, method: String, policy: String)] = []
        for line in code where line.text.contains("startPlayers(")
            && !line.text.contains("func startPlayers(") {
            let call = Self.callText(from: line.number, in: code)
            let policy: String
            if call.contains("anchorPolicy: .asSoonAsPractical") {
                policy = "asSoonAsPractical"
            } else if call.contains("anchorPolicy: .atHostTime") {
                policy = "atHostTime"
            } else {
                let silent: String = "startPlayers call at AudioEngine.swift:\(line.number) "
                    + "states no anchorPolicy — the parameter must have regained a default. "
                    + "Silence is how recoverEngine inherited the wrong answer for BOTH "
                    + "`cause` (m23-bp) and `renderClockTrusted` (m23-bq). Re-read this "
                    + "file's header."
                Issue.record("\(silent)")
                continue
            }
            found.append((line.number, Self.enclosingMethod(ofLine: line.number, in: code),
                          policy))
        }

        let rendered = found.map { "\($0.line):\($0.method):\($0.policy)" }
        print("[measured] m23-bs-2 anchor-policy sites: \(rendered)")

        let why = "the start-anchor policy SEQUENCE moved — a start path was added, removed, or "
            + "MIS-CLASSIFIED. Measured: \(rendered). The question every entry answers is 'did "
            + "the CALLER choose the beat, or did WALL TIME choose it?'; re-read this file's "
            + "header table before touching the expected array, and note that a COUNT pin "
            + "would not have caught a swap."
        #expect(found.map(\.method) == expected.map(\.method), "\(why)")
        #expect(found.map(\.policy) == expected.map(\.policy), "\(why)")

        // THE CONTINUATION SET — the three sites where wall time chose the beat.
        // Grown DELIBERATELY at m23-bs-3a (the two resume sites joined
        // `recoverEngine`); bs-3b adds `restart` and the header table grows with
        // it. A set, not a count: moving `.atHostTime` from one site to another
        // keeps every total identical while inverting the meaning of both (the
        // m23-bp lesson).
        let continuations = Set(found.filter { $0.policy == "atHostTime" }.map(\.method))
        #expect(continuations == ["tracksDidChangeBody", "rebuildEngine", "recoverEngine"],
                "\(why)")

        for i in 1..<max(found.count, 1) where i < found.count {
            #expect(found[i].line > found[i - 1].line)
        }
    }

    // MARK: - The compile-enforced half

    @Test("`anchorPolicy` has NO default — the compiler enumerates the sites")
    func parameterHasNoDefault() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let declarations = code.filter { $0.text.contains("anchorPolicy: StartAnchorPolicy") }
        print("[measured] anchorPolicy declarations: \(declarations.map { "\($0.number)" })")
        #expect(declarations.count == 1)
        for declaration in declarations {
            let why: String = "a DEFAULT on AudioEngine.swift:\(declaration.number) would let a "
                + "future start path inherit an anchor policy by saying nothing — the exact "
                + "shape of the m23-bp and m23-bq defects, twice over on this same routine"
            #expect(!declaration.text.contains("StartAnchorPolicy ="), "\(why)")
        }
    }

    // MARK: - §13.6: the click anchor derives from the CHOSEN instant

    /// The blind spot no property witness covers — see this file's header pin 3.
    @Test("both anchor branches derive clickAnchorHost from the CHOSEN anchor, not from the lead")
    func clickAnchorFollowsTheChosenInstant() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        let assignments = code.filter { $0.text.contains("let clickAnchorHost =") }
        print("[measured] clickAnchorHost assignments: "
              + "\(assignments.map { "\($0.number):\($0.text.trimmingCharacters(in: .whitespaces))" })")

        let why: String = "the metronome anchors on `clickAnchorHost`, NOT on the transport "
            + "anchor. Rebuilding it from `renderTime.hostTime + leadHostTicks` or "
            + "`anchorSampledHost + leadHostTicks` desyncs the CLICK from the transport by "
            + "exactly the continuation's over-prediction (~30 ms typical) — and every "
            + "assertion in RecoveryAnchorContinuityGateTests stays GREEN, because they all "
            + "read the transport pair. It must be derived FROM the chosen anchor: "
            + "`anchorHost - countInHostTicks` (design §13.6)."
        // One per anchor branch (trusted / host-clock), and no third.
        #expect(assignments.count == 2, "\(why)")
        for assignment in assignments {
            #expect(assignment.text.contains("anchorHost - countInHostTicks"), "\(why)")
            #expect(!assignment.text.contains("leadHostTicks"), "\(why)")
        }

        // …and each branch routes its earliest-practical instant through the
        // ONE clamp. Two branches, two calls, no third computation of the
        // anchor instant anywhere.
        let resolves = code.filter {
            $0.text.contains("resolveAnchorHost(policy:")
                && !$0.text.contains("func resolveAnchorHost(")
        }
        print("[measured] resolveAnchorHost call sites: \(resolves.map { "\($0.number)" })")
        let twoBranches: String = "each anchor branch must route its `earliest` through the ONE "
            + "clamp. A branch that computes its own anchor instant is a second home for the "
            + "clamp-forward rule, and clamping BACKWARD is the m19-f shifted-origin hazard."
        #expect(resolves.count == 2, "\(twoBranches)")
    }

    // MARK: - §13.6: the two anchor-SAMPLE expressions stay two

    /// ⚠️ THE MITIGATION §11's risk register ASSIGNS TO bs-2 AND §13.7's L5 row
    /// FORGOT TO LIST. §13.6 warns in prose: *"Do not rewrite the
    /// `.asSoonAsPractical` path to use the host-delta form for symmetry."*
    /// Until this test existed, that warning had only a code comment behind it —
    /// and "collapse two algebraically-equal branches into one" is precisely the
    /// edit a tidy-minded author makes with confidence.
    ///
    /// The two forms are equal in exact arithmetic and NOT byte-identical in
    /// floating point: the `.atHostTime` form round-trips the delta through
    /// `AVAudioTime.seconds(forHostTime:)`, so collapsing the relocation path
    /// onto it perturbs `anchorSampleTime` by up to a sample on EVERY normal
    /// play — silently, and in a place the m23-bq render-clock work chose to
    /// leave alone. The null-case claim ("relocation behaves exactly as today")
    /// is only reviewable while the original expression is still literally
    /// present in the file.
    ///
    /// No property witness can catch this. Both forms produce a correct-looking
    /// anchor; the difference is a rounding step, not a semantic one.
    @Test("the trusted branch keeps TWO anchor-sample expressions, one per policy")
    func trustedBranchKeepsBothAnchorSampleForms() {
        let code = Self.codeLines(of: "AudioEngine.swift")

        let leadDerived = code.filter {
            $0.text.contains("(startLead + countIn.delaySeconds) * hardwareRate")
        }
        let hostDerived = code.filter { $0.text.contains("anchorHost >= renderTime.hostTime") }
        print("[measured] anchorSample forms — lead-derived: "
              + "\(leadDerived.map { "\($0.number)" }), host-delta-derived: "
              + "\(hostDerived.map { "\($0.number)" })")

        let why: String = "the trusted anchor branch must keep TWO anchor-sample expressions, "
            + "one per policy. `.asSoonAsPractical` derives the sample offset from "
            + "`(startLead + countIn.delaySeconds) * hardwareRate` — the pre-bs-2 line, "
            + "unchanged — and `.atHostTime` derives it from the ACTUAL host delta to the "
            + "chosen instant. They are algebraically equal and NOT byte-identical (the "
            + "second round-trips through hostTime/seconds conversion), so collapsing them "
            + "'for symmetry' perturbs anchorSampleTime on every normal play and destroys "
            + "the null-case claim. §13.6 forbids exactly this edit; measured "
            + "lead-derived=\(leadDerived.count), host-derived=\(hostDerived.count)."
        #expect(leadDerived.count == 1, "\(why)")
        #expect(hostDerived.count == 1, "\(why)")

        // …and they must sit in DIFFERENT cases of the same switch, not one
        // above it feeding both. A hoisted single expression would keep both
        // counts at 1 while making the policy irrelevant to the sample anchor.
        let cases = code.filter {
            let trimmed = $0.text.trimmingCharacters(in: .whitespaces)
            return trimmed == "case .asSoonAsPractical:" || trimmed.hasPrefix("case .atHostTime")
        }
        print("[measured] anchor-policy switch cases: \(cases.map { "\($0.number)" })")
        let ordering: String = "the two anchor-sample forms must be SEPARATED by a policy switch "
            + "— lead-derived inside `.asSoonAsPractical`, host-delta inside `.atHostTime`. "
            + "Hoisting either above the switch keeps both counts at 1 while making the policy "
            + "stop reaching the sample anchor at all."
        #expect(cases.count >= 2, "\(ordering)")
        if let lead = leadDerived.first, let host = hostDerived.first,
           let asSoon = cases.first(where: {
               $0.text.trimmingCharacters(in: .whitespaces) == "case .asSoonAsPractical:"
           }),
           let atHost = cases.first(where: {
               $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("case .atHostTime")
           }) {
            #expect(lead.number > asSoon.number && lead.number < atHost.number, "\(ordering)")
            #expect(host.number > atHost.number, "\(ordering)")
        }
    }

    // MARK: - §7: `.atHostTime` requires countInBars == 0

    /// `anchorHost = clickAnchorHost + countInHostTicks`, so a count-in would
    /// push the anchor PAST the instant the resume beat was derived for. Every
    /// continuation site passes 0 today (they pass nothing, and the parameter
    /// defaults to 0); the ONE site that passes a non-zero `countInBars` is
    /// `startTakeBody`, which is a relocation.
    @Test("no `.atHostTime` site passes a count-in")
    func continuationSitesCarryNoCountIn() {
        let code = Self.codeLines(of: "AudioEngine.swift")
        var checked = 0
        for line in code where line.text.contains("startPlayers(")
            && !line.text.contains("func startPlayers(") {
            let call = Self.callText(from: line.number, in: code)
            guard call.contains("anchorPolicy: .atHostTime") else { continue }
            checked += 1
            let why: String = "the `.atHostTime` site at AudioEngine.swift:\(line.number) passes "
                + "a countInBars. The anchor is built as `clickAnchorHost + countInHostTicks`, "
                + "so a count-in pushes it PAST the instant the resume beat was derived for — "
                + "the transport would resume ahead of the music by the whole count-in (§7)."
            #expect(!call.contains("countInBars:"), "\(why)")
        }
        #expect(checked >= 1,
                "no `.atHostTime` call site was found at all — this leg proved nothing")
    }
}
