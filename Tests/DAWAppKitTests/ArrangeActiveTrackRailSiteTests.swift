import Testing
import Foundation

/// m25-l-1 defect ① — THE ACTIVE-TRACK RAIL IS ACTUALLY MOUNTED.
///
/// ⚠️⚠️ **THIS SUITE EXISTS BECAUSE THE BUG IT GUARDS ALREADY HAPPENED, AND
/// EVERY OTHER TEST IN THE REPO STAYED GREEN THROUGH IT.** When m25-l-1 shipped,
/// `activeTrackRail` was **declared and never mounted** — measured 2026-08-13 as
/// exactly two occurrences repo-wide, both prose (a doc comment and the
/// declaration itself), zero uses. The resolution logic was correct and unit
/// tested, the view compiled, the suite was green, and the user reported the
/// active track as invisible because it *was*.
///
/// ⭐ **THE CLASS OF BUG: a `@ViewBuilder` property that nothing references is
/// dead code that LOOKS like a feature.** Swift will not warn — a private
/// computed property is legitimately allowed to be unused — so the compiler
/// cannot catch this, and neither can a headless model test, because the model
/// was right. Only the pixels were wrong, and m23-g1 established that no gate in
/// this tree sees a pixel of an unbundled binary.
///
/// ⚠️ Assertions run against a **comment-stripped** declaration body, following
/// `PianoRollScrubRulerSiteTests`' rule and for its reason: **prose must not be
/// able to satisfy a claim about what code CALLS.** The doc comment at the
/// declaration site describes the mount in detail and would satisfy a naive
/// grep — that is precisely how this defect hid.
@Suite("Active track rail wiring (m25-l-1)")
struct ArrangeActiveTrackRailSiteTests {

    // MARK: - Source access (the `PianoRollScrubRulerSiteTests` helpers)

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

    private static let listPath = "DAWApp/TrackListView.swift"

    // MARK: - The pin

    /// **THE ONE THAT WOULD HAVE CAUGHT IT.** The rail must be REFERENCED
    /// somewhere other than its own declaration, in code rather than in prose.
    @Test("the rail is mounted, not merely declared")
    func railIsMounted() {
        let code = Self.codeOnly(Self.text(Self.listPath))

        // The declaration itself is one occurrence; a mount is a SECOND.
        let occurrences = code.components(separatedBy: "activeTrackRail").count - 1
        #expect(occurrences >= 2,
                """
                `activeTrackRail` appears \(occurrences)× in COMMENT-STRIPPED source. \
                1 means it is declared and never mounted — the exact m25-l-1 defect \
                the user reported as "cyan rail is not visible".
                """)

        // ⚠️ NEGATIVE CONTROL FOR THE PATTERN ITSELF. If the property were
        // renamed, the assertion above would read 0 and "fail correctly" for the
        // WRONG reason — a rename is not the defect this pins. Prove the needle
        // is findable before trusting a count of it.
        #expect(code.contains("private var activeTrackRail"),
                "`activeTrackRail` declaration not found — renamed? Update this suite deliberately.")
    }

    /// The mount must sit BEFORE `.clipShape` so the card's rounded corners cut
    /// the rail. Mounted after, a 3 pt full-height bar overhangs the radius at
    /// top and bottom — visible, but wrong, and no model test can see it.
    @Test("the rail is cut by the card's corners, not drawn over them")
    func railIsClippedByTheCard() {
        let code = Self.codeOnly(Self.text(Self.listPath))

        guard let mount = code.range(of: ".overlay(alignment: .leading) { activeTrackRail }") else {
            Issue.record("leading-edge mount not found — if the alignment changed, change this too")
            return
        }
        guard let clip = code.range(of: ".clipShape(RoundedRectangle(cornerRadius: 7))",
                                    range: mount.upperBound..<code.endIndex) else {
            Issue.record("no `.clipShape` AFTER the rail mount — the rail will overhang the corners")
            return
        }
        #expect(mount.upperBound <= clip.lowerBound)
    }

    /// The rail must not be able to eat a click meant for the row. This is the
    /// property its own doc block claims; pin it so the claim stays true.
    @Test("the rail never intercepts a click")
    func railIsNotHitTestable() {
        let code = Self.codeOnly(Self.text(Self.listPath))
        guard let decl = code.range(of: "private var activeTrackRail") else {
            Issue.record("declaration not found")
            return
        }
        // Scope to the declaration body rather than the file: `.allowsHitTesting`
        // appears elsewhere, so a file-wide search would pass vacuously.
        let tail = String(code[decl.lowerBound...].prefix(600))
        #expect(tail.contains(".allowsHitTesting(false)"),
                "the rail must stay non-interactive — it spans the whole card")

        // Positive control: the needle IS findable in this window when present.
        #expect(tail.contains("Rectangle()"), "declaration body window did not capture the rail's view")
    }
}
