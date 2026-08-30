import Testing
import Foundation
import DAWAppKit

/// m23-cu-1 — **THE ARRANGE'S TWO FOLLOW CALL SITES MUST READ THE *SAME* ENABLE
/// FLAG, AND NOTHING ELSE IN THE REPO CAN SEE IT IF THEY DRIFT.**
///
/// The user asked that the view *"autoposition on the area where the notes are
/// placed and progress as user keeps playing"*. Follow already did that during
/// a take — measured live on staging 2026-08-30, a 6 s take moved the arrange
/// from offset 0 to 934.5 with the preference on, and zero scrolls with it off.
/// The only thing missing was that `PanelLayoutModel.defaultFollowPlayhead` is
/// `false`, so the feature never reached the person who wanted it.
///
/// The fix is an OR — `panelLayout.followPlayhead || store.transport.isRecording`
/// — read as `isEnabled` at the arrange's two `FollowPlayheadModel` call sites:
///
///   1. `followArrangeTick()`     → `arrangeFollow.target(isEnabled:…)`   (the ISSUER)
///   2. `reportArrangeHScroll(_:)` → `arrangeFollow.reportOffset(_:isEnabled:…)` (the DETECTOR)
///
/// ⛔⛔ **A DISAGREEMENT BETWEEN THEM IS A SILENT, SELF-INFLICTED SUSPENSION.**
/// `reportOffset`'s manual-scroll detector treats an offset it did not expect as
/// the user's doing. Leave the detector on the persisted preference while the
/// issuer runs on the OR, and every take-time scroll follow ISSUES arrives at a
/// detector that believes follow is off — so the detector never learns the
/// expected offset, and the first tick after the preference is switched on
/// blames the user and suspends. The view would stop following partway through
/// a take with no user action, which is the m25-r "two owners of one scroll"
/// shape wearing a different hat.
///
/// ⚠️ **THIS IS A SOURCE-SHAPE PIN, WHICH IS THE WEAKER KIND** (a spy gate beats
/// a source-shape gate). It is here because the alternative is nothing: the
/// disagreement is invisible to every headless model test — both call sites
/// compile, both models behave correctly in isolation, and only their PAIRING is
/// wrong. The behavioural half is `scripts/gates/m23cu1-follow-take.mjs`, which
/// drives a real take against a staged app; this suite is the cheap tripwire
/// that fires in `./scripts/test.sh` when someone edits one site and not the
/// other.
///
/// Assertions run against **comment-stripped** source, following
/// `ArrangeActiveTrackRailSiteTests`' rule and for its reason: the prose above
/// each call site names the flag, and prose must never be able to satisfy a
/// claim about what code READS.
@Suite("Arrange follow enable — both call sites (m23-cu-1)")
struct ArrangeFollowEnableSiteTests {

    // MARK: - Source access (the `ArrangeActiveTrackRailSiteTests` helpers)

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func text(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    private static let appPath = "DAWApp/DAWProApp.swift"

    /// The body of a `func name(` … matching-brace block, comment-stripped.
    private static func functionBody(_ code: String, named name: String) -> String? {
        body(code, after: "func \(name)(")
    }

    /// The body of a `var name: Type { … }` computed property, comment-stripped.
    ///
    /// ⚠️⚠️ **THIS EXISTS BECAUSE THE FIRST DRAFT USED `prefix(400)` AND WAS
    /// VACUOUS — CAUGHT BY MUTATION, NOT BY REVIEW.** Reverting
    /// `arrangeFollowEnabled` to the bare preference (the exact regression this
    /// suite is for) left all four tests GREEN: a 400-character window starting
    /// at the declaration runs straight past its closing brace and into
    /// `followAutoEngagedByTake` and `isFollowSuspended`, which between them
    /// contain both `||` and `store.transport.isRecording`. The window was
    /// satisfying the assertions with its NEIGHBOURS' source. A fixed-size
    /// window over source is never a scope; match the braces.
    private static func computedBody(_ code: String, named name: String) -> String? {
        body(code, after: "var \(name): Bool")
    }

    /// Shared matching-brace extractor: the block that opens at the first `{`
    /// after `marker`, up to its own closing brace.
    private static func body(_ code: String, after marker: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        guard let openBrace = code.range(of: "{", range: start.upperBound..<code.endIndex) else { return nil }
        var depth = 0
        var index = openBrace.lowerBound
        while index < code.endIndex {
            let character = code[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[openBrace.upperBound..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - The pins

    /// ⭐ **THE ONE THAT CATCHES THE DRIFT.** Both bodies must name
    /// `arrangeFollowEnabled`, and NEITHER may still be reading
    /// `panelLayout.followPlayhead` directly.
    @Test("both arrange call sites read arrangeFollowEnabled, and neither reads the raw preference")
    func bothSitesReadTheEffectiveFlag() {
        let code = Self.codeOnly(Self.text(Self.appPath))

        // NEGATIVE CONTROL FIRST — prove the needles are findable before
        // trusting anything this suite counts. A renamed function would make
        // every assertion below vacuously "fail correctly" for the wrong reason.
        let tick = Self.functionBody(code, named: "followArrangeTick")
        let report = Self.functionBody(code, named: "reportArrangeHScroll")
        #expect(tick != nil, "followArrangeTick() not found in \(Self.appPath) — renamed? Update this suite deliberately.")
        #expect(report != nil, "reportArrangeHScroll(_:) not found in \(Self.appPath) — renamed? Update this suite deliberately.")
        guard let tick, let report else { return }

        // And prove the extractor really extracts: each body must contain the
        // FollowPlayheadModel call it exists to make. Without this, an extractor
        // that silently returned "" would make the two assertions below fail and
        // the two after them pass, for reasons unrelated to the invariant.
        #expect(tick.contains("arrangeFollow.target("),
                "followArrangeTick() no longer calls arrangeFollow.target( — extractor or call site moved.")
        #expect(report.contains("arrangeFollow.reportOffset("),
                "reportArrangeHScroll() no longer calls arrangeFollow.reportOffset( — extractor or call site moved.")

        #expect(tick.contains("isEnabled: arrangeFollowEnabled"),
                """
                followArrangeTick() does not pass `isEnabled: arrangeFollowEnabled`. \
                The ISSUER and the DETECTOR must read the same flag; see this suite's header.
                """)
        #expect(report.contains("isEnabled: arrangeFollowEnabled"),
                """
                reportArrangeHScroll() does not pass `isEnabled: arrangeFollowEnabled`. \
                A detector on the raw preference blames the user for follow's own \
                take-time scrolls and suspends mid-take.
                """)

        #expect(!tick.contains("isEnabled: panelLayout.followPlayhead"),
                "followArrangeTick() is back on the raw preference — a take will not follow.")
        #expect(!report.contains("isEnabled: panelLayout.followPlayhead"),
                "reportArrangeHScroll() is back on the raw preference — mid-take self-suspension.")
    }

    /// The OR itself, at its ONE home. Pinned separately from the call sites so
    /// a failure says WHICH half broke: the definition or its use.
    @Test("arrangeFollowEnabled is the preference OR a rolling take, and writes nothing")
    func effectiveFlagIsAnOrNotAnOverride() {
        let code = Self.codeOnly(Self.text(Self.appPath))
        guard let tail = Self.computedBody(code, named: "arrangeFollowEnabled") else {
            Issue.record("`arrangeFollowEnabled` not found in \(Self.appPath) — renamed? Update this suite deliberately.")
            return
        }
        // ⛔ SCOPE CONTROL. The extractor must return THIS property's body and
        // nothing after it. `followAutoEngagedByTake` is the very next
        // declaration and it contains `store.transport.isRecording` — so if the
        // extractor over-reads, every assertion below passes on a neighbour's
        // source. That is not hypothetical: it is what the first draft did.
        #expect(!tail.contains("followAutoEngagedByTake"),
                "the extractor over-read past arrangeFollowEnabled's closing brace — assertions below would be vacuous.")
        #expect(tail.count < 200,
                "arrangeFollowEnabled's extracted body is \(tail.count) chars — far larger than a one-line OR, so the extractor is over-reading.")

        #expect(tail.contains("panelLayout.followPlayhead"),
                "arrangeFollowEnabled no longer reads the persisted preference.")
        #expect(tail.contains("||"),
                "arrangeFollowEnabled is no longer an OR — an override that must be restored is the shape this avoided.")
        #expect(tail.contains("store.transport.isRecording"),
                "arrangeFollowEnabled no longer auto-engages on a rolling take, which is the whole sub-item.")

        // ⛔ THE PREFERENCE IS NEVER WRITTEN. `setFollowPlayhead(` is the only
        // path that writes `panelLayout.setFollowPlayhead`, and it must stay
        // reachable ONLY from the chip's explicit on/off — never from anything
        // take-shaped. Two precedents forbid a take writing it:
        // `PianoRollMinimap.swift:202` and the m25-f-3 record.
        #expect(!tail.contains("setFollowPlayhead("),
                "arrangeFollowEnabled must not WRITE the preference — an OR needs no restore.")
    }

    /// `standDown()` exists and does what the chip's take-time press needs: it
    /// suspends WITHOUT touching the persisted enable, and `rearm()` clears it.
    ///
    /// ⭐ This one is behavioural, not source-shaped — `FollowPlayheadModel`
    /// lives in `DAWAppKit` and can simply be exercised.
    @MainActor
    @Test("standDown suspends this surface only, and a rearm clears it")
    func standDownIsSuspensionNotAPreference() {
        let model = FollowPlayheadModel()
        #expect(!model.isSuspended)

        // Positive control: follow issues a scroll while un-suspended, so a
        // later nil cannot be mistaken for "this fixture never worked".
        let before = model.target(isEnabled: true, isPlaying: true, playheadX: 4000,
                                  viewportWidth: 1000, contentWidth: 20000, currentOffset: 0)
        #expect(before != nil, "follow issued no scroll even un-suspended — fixture geometry is wrong.")

        model.standDown()
        #expect(model.isSuspended)
        let during = model.target(isEnabled: true, isPlaying: true, playheadX: 9000,
                                  viewportWidth: 1000, contentWidth: 20000, currentOffset: 0)
        #expect(during == nil, "standDown() did not stop follow issuing scrolls.")

        model.rearm()
        #expect(!model.isSuspended)
        let after = model.target(isEnabled: true, isPlaying: true, playheadX: 14000,
                                 viewportWidth: 1000, contentWidth: 20000, currentOffset: 0)
        #expect(after != nil, "rearm() did not clear a standDown() — the stand-down would outlive the take.")
    }

    /// The chip's press must not become a preference write while a take is the
    /// only reason it is lit. Source-shaped, because `toggleFollowPlayhead` is
    /// on the app model (`DAWApp`), which these tests cannot instantiate.
    @Test("the chip's take-time press stands down instead of writing the preference")
    func chipPressDuringTakeDoesNotWriteThePreference() {
        let code = Self.codeOnly(Self.text(Self.appPath))
        guard let body = Self.functionBody(code, named: "toggleFollowPlayhead") else {
            Issue.record("toggleFollowPlayhead() not found — renamed? Update this suite deliberately.")
            return
        }
        // Extractor control: the function's pre-existing resume branch must
        // still be in what we extracted.
        #expect(body.contains("rearmFollow()"),
                "toggleFollowPlayhead() no longer resumes from paused — extractor or call site moved.")

        #expect(body.contains("followAutoEngagedByTake"),
                """
                toggleFollowPlayhead() does not branch on `followAutoEngagedByTake`. \
                Without it, pressing the LIT chip during an auto-engaged take calls \
                setFollowPlayhead(!false) and turns following on PERMANENTLY — the \
                opposite of the press, and sticky.
                """)
        #expect(body.contains("standDown()"),
                "the take-time branch must stand the arrange down, not write the preference.")
    }
}
