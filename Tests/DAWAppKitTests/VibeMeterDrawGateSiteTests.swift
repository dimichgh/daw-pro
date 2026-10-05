import Foundation
import Testing

/// Source pin for **WF-F1: the vibe orb TICKS every frame but DRAWS only a
/// visibly new one.** The behaviour is measured by the staging probe (an
/// `RBLayer -display` spy, display awake and asleep) and the frame rule by
/// `VibeOrbFrameGateTests`; this pin is the cheap half that runs on every
/// `./scripts/test.sh`, so the wiring cannot quietly regress to an inline
/// Canvas — the shape that re-displayed a small, surface-PACKED RenderBox layer
/// 60 times a second and, with the display asleep or the screen locked, blocked
/// the main thread ~25–30 ms per display in `-[CAContext waitForCommitId:timeout:]`.
///
/// It also pins the half that must NOT change: the timeline stays an UNPAUSED
/// `.periodic` 60 Hz schedule and the witness still sees every tick (the
/// m23-r3b law — the fix is "don't redraw identical pixels", never "tick less").
///
/// Anchored via `#filePath` (the `PollDisciplinePinTests` idiom); comment-stripped
/// so the file's own prose cannot satisfy a needle.
@Suite("Vibe orb draw gate — tick every frame, draw only visibly new ones (WF-F1)")
struct VibeMeterDrawGateSiteTests {

    private static func source() -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let f = dir.appendingPathComponent("Sources/DAWApp/Components/VibeMeterView.swift")
            if let s = try? String(contentsOf: f, encoding: .utf8) { return s }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources/DAWApp/Components/VibeMeterView.swift from \(#filePath)")
        return ""
    }

    /// The source with `//` comments removed (whole-line and trailing). The file
    /// has no `//` inside string literals, which the raw-text control below checks.
    private static func code(_ src: String) -> String {
        src.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The brace-balanced body that follows the first occurrence of `header`.
    private static func block(after header: String, in text: String) -> String? {
        guard let h = text.range(of: header),
              let open = text[h.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[open...i]) } }
            i = text.index(after: i)
        }
        return nil
    }

    @Test("the orb ticks unpaused at 60 Hz, reports every tick, and draws only through the gated Equatable face")
    func tickEveryFrameDrawOnlyNewOnes() throws {
        let raw = Self.source()
        let code = Self.code(raw)
        // Controls: the file was found, stripping kept code, and the stripped text
        // really lost the prose. The prose anchor is a TRAILING comment that
        // predates WF-F1, so this control holds on the pre-fix file too and a red
        // below is always the needle, never the control.
        #expect(raw.contains("struct VibeMeterView"), "the meter source was not read")
        #expect(raw.contains("a bare call is a ViewBuilder expression")
                && !code.contains("a bare call is a ViewBuilder expression")
                && code.contains("let _ = onFrame?(state)"),
                "comment stripping did not remove the file's own prose — needles below could match it")
        #expect(!raw.contains("\"//") && !raw.contains("//\""), "a // inside a string literal would break the stripper")

        let viewBody = try #require(Self.block(after: "var body: some View", in: code),
                                    "VibeMeterView.body not found")
        // TICK: an unpaused periodic schedule at the named 60 Hz rate…
        #expect(viewBody.contains("TimelineView(.periodic(from: .now, by: Self.pollInterval))"),
                "the orb's timeline is no longer the unpaused periodic schedule (m23-r3b)")
        #expect(code.contains("private static let pollInterval = 1.0 / 60"), "the tick rate moved off 60 Hz")
        // …the witness sees every tick, BEFORE and independent of the draw gate…
        let report = try #require(viewBody.range(of: "onFrame?(state)"), "the witness no longer sees every tick")
        let draw = try #require(viewBody.range(of: "VibeOrbFace(frame: smoother.frameToDraw()).equatable()"),
                                "the orb no longer draws through the gated Equatable face")
        #expect(report.upperBound <= draw.lowerBound, "the witness call must precede the gated draw")
        // DRAW: no Canvas inline in the view's own body — it lives in the face only.
        #expect(!viewBody.contains("Canvas"),
                "an inline Canvas is back in VibeMeterView.body — it re-renders every tick")

        let face = try #require(Self.block(after: "struct VibeOrbFace: View, Equatable", in: code),
                                "VibeOrbFace is no longer an Equatable view")
        #expect(face.contains("a.frame == b.frame"), "the face's == no longer compares the drawn frame")
        #expect(face.contains("Canvas"), "positive control: the face draws the orb")
        #expect(code.contains("gate.frame(for: model, phase: phase)"),
                "frameToDraw() no longer asks VibeOrbFrameGate")
    }
}
