import Testing
import Foundation

/// m23-ap I5-F4 — **THE STEP GRID'S SONG-GRID WIRING, PINNED AT THE SOURCE.**
///
/// ⚠️ **WHY A SOURCE-SITE PIN.** `StepSequencerTests` proves the geometry puts
/// every column edge on a song line. What it cannot see is whether the VIEW
/// hands the geometry the song's context at all: `DAWApp` is an executable
/// target with no test target, and the step grid's old call —
/// `make(…, beatsPerBar: beatsPerBar)` — still compiles (it is kept, meaning "a
/// clip at song beat 0"). A silent revert to it would draw the clip-counted
/// columns again, with every headless test green. So would a playhead that
/// went back to the raw `PianoRollPlayhead.lineX`, which ignores the partial
/// column 0. This reddens instead.
///
/// Runs against COMMENT-STRIPPED, brace/paren-matched source (the
/// `PianoRollSnapPolicySiteTests` rule): the files under test carry doc
/// comments that name the very symbols asserted on, so an unstripped
/// `contains` would pass on prose alone. Nonisolated file reads: a plain suite,
/// no `@MainActor` slot spent.
@Suite("m23-ap I5-F4 — the step grid is WIRED to the song's grid")
struct PianoRollStepGridSiteTests {

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

    /// The text BETWEEN the braces of `func <name>` — or `var <name>` — by brace
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
    private static let stepGrid = "DAWApp/PianoRoll/StepSequencerGrid.swift"
    private static let staging = "DAWApp/PianoRoll/StepSequencerStaging.swift"

    // MARK: - The roll view hands the geometry the song's grid

    @Test("I5-F4 — PianoRollView builds the step geometry from `songGridContext` (the note grid's own context), never the clip-at-0 `beatsPerBar:` signature")
    func stepGeometryReadsTheSongGrid() throws {
        let body = try #require(Self.body(of: "stepGeometry", in: Self.text(Self.rollView)),
                                "`var stepGeometry` not found — renamed is a failure, not a pass")
        #expect(body.contains("StepSequencerGeometry.make("))
        #expect(body.contains("songGrid: songGridContext"))
        #expect(!body.contains("beatsPerBar:"))
    }

    @Test("I5-F4 — the step band's playhead goes through the geometry (which adds the partial column 0), never the raw `PianoRollPlayhead.lineX`")
    func stepPlayheadGoesThroughTheGeometry() throws {
        let body = try #require(Self.body(of: "stepSequencerBand", in: Self.text(Self.rollView)),
                                "`var stepSequencerBand` not found")
        #expect(body.contains("stepGeometry.playheadX("))
        #expect(!body.contains("PianoRollPlayhead.lineX("))
    }

    // MARK: - The grid draws and reports what the geometry says

    @Test("I5-F4 — the step ruler labels the geometry's SONG bar marks, and the out-of-clip shade covers the partial column 0 (`clipStartX`) as well as the tail")
    func rulerAndShadeReadTheSongPlacement() throws {
        let source = Self.text(Self.stepGrid)
        let ruler = try #require(Self.body(of: "stepRuler", in: source), "`var stepRuler` not found")
        #expect(ruler.contains("geometry.barMarks"))
        #expect(!ruler.contains("stepsPerBar"))
        let shade = try #require(Self.body(of: "drawOutOfClipShade", in: source),
                                 "`func drawOutOfClipShade` not found")
        #expect(shade.contains("clipStartX"))
        #expect(shade.contains("clipEndX"))
    }

    @Test("I5-F4 — the step Canvas is compared BY VALUE (`Equatable` + `.equatable()`, the I5-F2 `PianoRollGrid` fix): its geometry now carries the song's MeterMap, rebuilt on every transport read, so without it a playback tick could redraw the grid")
    func stepCanvasIsComparedByValue() {
        let grid = Self.codeOnly(Self.text(Self.stepGrid))
        #expect(grid.contains("struct StepGridCanvas: View, Equatable"))
        #expect(grid.range(of: #"StepGridCanvas\([^)]*\)\s*\.equatable\(\)"#,
                           options: .regularExpression) != nil,
                "the Canvas must be MOUNTED `.equatable()` — conforming alone changes nothing")
        #expect(grid.contains("lhs.geometry == rhs.geometry"))
    }

    @Test("I5-F4 — the grid reports its song placement up from the drawing layer, and `debug.stepSequencer` echoes it")
    func placementIsReportedAndEchoed() {
        let grid = Self.codeOnly(Self.text(Self.stepGrid))
        #expect(grid.contains("phaseBeats: drawn.phaseBeats"))
        #expect(grid.contains("firstStepSongBeat: drawn.firstStepSongBeat"))
        #expect(grid.contains("barMarks: drawn.barMarks"))
        let echo = Self.codeOnly(Self.text(Self.staging))
        #expect(echo.contains("object[\"phaseBeats\"]"))
        #expect(echo.contains("object[\"firstStepSongBeat\"]"))
        #expect(echo.contains("object[\"barStarts\"]"))
    }
}
