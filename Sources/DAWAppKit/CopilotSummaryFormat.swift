import Foundation

/// Pure formatting for the tool-call / tool-result summaries the copilot rail
/// (M6 rail-d) shows on a chip. `CopilotEngine` hands the UI capped-but-raw
/// JSON/text (newlines, indentation, brace runs); a chip wants one tidy line.
/// Headless + unit-tested (the `ClipStretch`/`TakeLaneGeometry` precedent) so the
/// rail view stays thin and the rendering contract is pinned.
public enum CopilotSummaryFormat {
    /// Collapses every run of whitespace (spaces, tabs, newlines, returns) to a
    /// single space and trims the ends — turning a multi-line JSON summary into a
    /// compact single line for a chip. Idempotent; empty in → empty out.
    public static func compact(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
