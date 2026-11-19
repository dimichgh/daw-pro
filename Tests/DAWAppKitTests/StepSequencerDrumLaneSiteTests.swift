import Foundation
import Testing

/// m39-w4-2 — the view half of "the step grid reads the drum lane map".
///
/// ⚠️ SOURCE-SHAPE GATES, and honest about it. `DAWApp` is an executable target
/// with no test target, so what the roll feeds its editor mode and what the
/// staging seam echoes can only be read from the source here. The behaviour
/// each line feeds is pinned headless in `StepSequencerDrumLaneTests` and
/// `DrumLaneMapTests`; these tests pin that the view is WIRED to it. A spy gate
/// would beat this; there is no spy seam in the view.
///
/// Deliberately NOT `@MainActor`: it reads files. No `@MainActor` slot spent.
@Suite("m39-w4-2 — the roll and the staging seam read the drum lane map")
struct StepSequencerDrumLaneSiteTests {

    // MARK: - Helpers (the house pattern — each site suite carries its own)

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

    /// The source with comments removed, so a comment can neither satisfy nor
    /// break a gate.
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

    /// The text BETWEEN the braces of `func <name>` or `var <name>`, by brace
    /// matching. nil means "not found", which every caller treats as a FAILURE:
    /// "renamed" and "clean" must never look the same.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard let decl = code.range(of: "func \(name)")
                ?? code.range(of: "var \(name)") else { return nil }
        guard let open = code.range(of: "{", range: decl.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open.lowerBound)..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollView = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let contentView = "DAWApp/ContentView.swift"
    private static let staging = "DAWApp/PianoRoll/StepSequencerStaging.swift"

    // MARK: - The roll

    @Test("the roll's editor mode is fed by the drum lane map, never by the export predicate")
    func editorModeReadsTheLaneMap() throws {
        let body = try #require(Self.body(of: "editorMode", in: Self.text(Self.rollView)),
                                "`var editorMode` not found — renamed is a failure, not a pass")
        #expect(body.contains("drumLanes != nil"))
        #expect(!body.contains("isDrumKit: isDrumKit"),
                "the editor mode is fed from isDrumKit again: a pads drum machine opens in the piano roll")
    }

    @Test("the roll builds its step rows from the drum lane map")
    func stepGeometryReadsTheLaneMap() throws {
        let body = try #require(Self.body(of: "stepGeometry", in: Self.text(Self.rollView)),
                                "`var stepGeometry` not found")
        #expect(body.contains("drumLanes: drumLanes"))
        #expect(!body.contains("isDrumKit:"))
    }

    @Test("ContentView hands the roll the lane map of the clip's own track")
    func contentViewResolvesTheLaneMap() throws {
        let source = Self.text(Self.contentView)
        #expect(Self.codeOnly(source).contains("drumLanes: drumLaneMap(ofClip: clip.id)"))
        let resolver = try #require(Self.body(of: "drumLaneMap(ofClip", in: source),
                                    "`func drumLaneMap(ofClip:)` not found")
        #expect(resolver.contains("DrumLaneMap.lanes(for: track.instrument)"))
        #expect(!resolver.contains("isDrumKit"))
    }

    // MARK: - The staging seam (I3)

    @Test("I3: staging still reports isDrumKit from the export predicate, and adds drumLanes from the lane map")
    func stagingKeepsIsDrumKitAndAddsDrumLanes() {
        let code = Self.codeOnly(Self.text(Self.staging))
        #expect(code.contains("object[\"isDrumKit\"] = .bool(drumKit)"))
        #expect(code.contains(".map { SMFProjectExporter.isDrumKit($0) } ?? false"))
        #expect(code.contains("object[\"drumLanes\"] = .number(Double(drumLaneCount))"))
        #expect(code.contains("DrumLaneMap.lanes(for: $0.instrument)?.count"))
    }

    // MARK: - W9-PATF: debug.stepSequencer act:"startFromBeat"

    @Test("W9-PATF: the startFromBeat act stages through the bridge, and the menu and the seam share ONE pick")
    func startFromBeatActSharesThePickWithTheMenu() throws {
        let staging = Self.codeOnly(Self.text(Self.staging))
        #expect(staging.contains("act == \"startFromBeat\""))
        #expect(staging.contains("stepSequencer.stageStartFromBeat(pattern)"))
        #expect(staging.contains("guard stepSequencer.reportedBeatOffered"), "refuses what the mouse cannot reach")
        #expect(!staging.contains("fillDrumPattern"), "no second writer in the seam")
        #expect(staging.contains("object[\"beatStrip\"]"))
        #expect(staging.contains("stepSequencer.reportedBeatLines"), "the echo reads what the grid drew")

        let grid = Self.codeOnly(Self.text("DAWApp/PianoRoll/StepSequencerGrid.swift"))
        #expect(grid.contains("pickBeat(choice.id)"), "the menu item runs the shared pick")
        #expect(grid.contains("pickBeat(id)"), "the staged pick runs the shared pick")
        #expect(grid.components(separatedBy: "onStartFromBeat(").count - 1 == 1,
                "exactly one call site of the writer closure")
        #expect(grid.contains("bridge.reportBeatStrip("))
    }
}

