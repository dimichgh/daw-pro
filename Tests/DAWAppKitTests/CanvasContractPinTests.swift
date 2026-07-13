import Foundation
import Testing

/// C6 source pin for the m16-a "Canvas-closure crash class" fix
/// (docs/research/design-m16a-canvas-crash.md §4 Leg 2 / §6-C6).
///
/// Every `Canvas` renderer closure in `Sources/DAWApp` MUST open `@Sendable`.
/// `@Sendable` is the load-bearing part of the fix: it makes the renderer closure
/// nonisolated, which removes the SE-0423 dynamic actor-isolation check — the exact
/// instruction that faulted inside the poisoned-MainActor window — and then the
/// compiler *enforces* value-only capture forever (a reference or MainActor-state
/// capture becomes a compile error). This test is the greppable convention pin: a
/// future `Canvas { context, size in … }` written without `@Sendable` fails here so
/// the contract cannot silently erode. Compile itself is the capture-discipline test
/// from then on; this guards the annotation that turns it on.
///
/// The scan is anchored to the repository via `#filePath` (no bundle resources), so
/// it runs headless under `./scripts/test.sh`.
@Suite("Canvas @Sendable contract pin (m16-a C6)")
struct CanvasContractPinTests {

    /// Locate `<repo>/Sources/DAWApp` by walking up from this test file.
    private static func dawAppSourceDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWApp", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources/DAWApp from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// Every `.swift` file under `Sources/DAWApp`.
    private static func swiftFiles() -> [URL] {
        let root = dawAppSourceDir()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            out.append(url)
        }
        return out
    }

    /// A detected `Canvas` renderer opening: its file, 1-based line, the line text,
    /// and whether `@Sendable` immediately follows the closure brace.
    private struct Site {
        var file: String
        var line: Int
        var text: String
        var sendable: Bool
    }

    /// Detects `Canvas {` / `Canvas(…) {` renderer openings (skipping comment lines)
    /// and reports whether `@Sendable` follows the brace on the same line — the shape
    /// every site in the tree uses.
    private static func scan() -> [Site] {
        // `Canvas`, optional `(…)`, then the trailing-closure `{`, then whatever comes
        // next up to the closure parameters. Capture group 1 is the post-brace text.
        let opening = try! NSRegularExpression(pattern: #"Canvas\s*(?:\([^{)]*\))?\s*\{\s*(@Sendable\b)?"#)
        var sites: [Site] = []
        for url in swiftFiles() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.lastPathComponent
            for (index, raw) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comment-only lines (doc/line comments mention "Canvas" prose).
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in opening.matches(in: line, range: range) {
                    // Guard: only count a real renderer opening (has the `{`).
                    guard line.contains("Canvas") else { continue }
                    let sendable = match.range(at: 1).location != NSNotFound
                    sites.append(Site(file: name, line: index + 1, text: trimmed, sendable: sendable))
                }
            }
        }
        return sites
    }

    @Test("every Canvas renderer in Sources/DAWApp opens @Sendable")
    func allCanvasClosuresAreSendable() {
        let sites = Self.scan()
        // Guard the scan itself: the sweep landed 17 sites; if the count collapses the
        // regex or the path walk broke and the pin would pass vacuously.
        #expect(sites.count >= 17,
                "expected at least 17 Canvas renderer sites, found \(sites.count) — scan likely broke")
        let offenders = sites.filter { !$0.sendable }
        let detail = offenders.map { "  \($0.file):\($0.line)  \($0.text)" }.joined(separator: "\n")
        #expect(offenders.isEmpty,
                "Canvas renderer(s) missing @Sendable (m16-a CANVAS CONTRACT):\n\(detail)")
    }
}
