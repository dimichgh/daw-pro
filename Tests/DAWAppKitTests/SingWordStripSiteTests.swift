import Foundation
import Testing

/// vf-2 (design 2026-10-12 §5, Lane D) — a SITE pin, by exception. Why a pin and not a behaviour test: the strip's
/// placement, floor and click rules are behaviour-tested in `SingWordStripLayoutTests`, but the VIEW that draws them
/// (`SingWordStrip`, DAWApp) can only be reached by rendering it, and no headless test does that. If the view went
/// back to placing words itself (the old `chip.startBeat / length` squeeze), or took clicks per chip, every behaviour
/// test would stay green while the screen disagreed with them. That is the tree's characteristic failure (a record
/// that looks valid while the source says otherwise). So this pin reads the view's source for exactly three facts and
/// nothing about its look:
/// 1. the strip lays out through ONE `SingWordStripLayout(` and places nothing from the chips' beats itself;
/// 2. a click is resolved by `layout.target(at:`, with no per-chip `.onTapGesture` beside it;
/// 3. the host mounts the strip `.equatable()`, so a transport tick that does not move the glow costs one comparison
///    (the strip redraws only when what it draws changes).
/// If you change the strip on purpose, change the behaviour tests first, then this pin, and say why here.
@Suite("Sing sheet strip — the view draws the lane layout (vf-2 site pin)")
struct SingWordStripSiteTests {

    private static func sourcesDir() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The view file, comments stripped line by line (a pin must not be satisfied, or broken, by prose).
    private static func code() throws -> String {
        let dir = try #require(sourcesDir(), "could not find Sources/ from \(#filePath)")
        let url = dir.appendingPathComponent("DAWApp/Sing/SingSheetView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[line.startIndex..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// The source of one top-level type: from `struct <name>` to the next line that starts a top-level declaration.
    private static func body(of name: String, in code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("struct \(name)") }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { line in
            ["struct ", "private struct ", "enum ", "private enum ", "@MainActor", "extension ", "final class "]
                .contains { line.hasPrefix($0) }
        } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// Placement the strip must not do itself: reading the chips' or notes' BEATS (that is the layout's job).
    static let placementTokens = [".startBeat", ".endBeat", ".lengthBeats", "max(18"]

    static func placementHits(in source: String) -> [String] {
        placementTokens.filter { source.contains($0) }
    }

    @Test("the strip lays out through ONE SingWordStripLayout and reads no beats itself")
    func stripDrawsTheLayout() throws {
        let strip = try #require(Self.body(of: "SingWordStrip", in: try Self.code()))
        #expect(strip.contains("ScrollView(.horizontal"), "positive control: this is the strip's body")
        #expect(strip.components(separatedBy: "SingWordStripLayout(").count - 1 == 1)
        #expect(strip.contains("layout.items"))
        #expect(Self.placementHits(in: strip).isEmpty,
                "the strip placed something from beats itself: \(Self.placementHits(in: strip))")
        // Positive control for the negative scan: it finds the old strip's placement.
        #expect(Self.placementHits(in: "let x = width * CGFloat(chip.startBeat / length)") == [".startBeat"])
    }

    @Test("a click goes through the layout's target, never a per-chip tap")
    func oneTapThroughTheLayout() throws {
        let strip = try #require(Self.body(of: "SingWordStrip", in: try Self.code()))
        #expect(strip.contains("layout.target(at:"))
        #expect(strip.components(separatedBy: "SpatialTapGesture(").count - 1 == 1)
        #expect(!strip.contains(".onTapGesture"), "a per-chip tap would bypass the tested target")
    }

    @Test("the host mounts the strip .equatable(), so a tick that moves nothing costs one comparison")
    func hostMountsTheStripEquatable() throws {
        let host = try #require(Self.body(of: "SingStripHost", in: try Self.code()))
        let mount = try #require(host.range(of: "SingWordStrip("), "positive control: the host mounts the strip")
        let after = host[mount.upperBound...]
        let equatable = try #require(after.range(of: ".equatable()"), "the strip is not mounted .equatable()")
        let frame = try #require(after.range(of: ".frame(height: SingWordStripLayout.height)"))
        #expect(equatable.lowerBound < frame.lowerBound, ".equatable() applies to the strip itself, before its frame")
        #expect(try Self.code().contains("struct SingWordStrip: View, Equatable"))
    }
}
