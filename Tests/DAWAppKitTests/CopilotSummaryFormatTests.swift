import Foundation
import Testing
@testable import DAWAppKit

/// Pins the copilot rail's chip-summary contract (M6 rail-d): the engine hands
/// the UI capped-but-raw JSON/text, the chip shows one tidy line.
@Suite("Copilot summary formatting")
struct CopilotSummaryFormatTests {
    @Test("collapses newlines and multi-space runs to a single space")
    func collapsesWhitespace() {
        let raw = "{\n  \"bpm\": 120,\n  \"name\":   \"Bass\"\n}"
        #expect(CopilotSummaryFormat.compact(raw) == "{ \"bpm\": 120, \"name\": \"Bass\" }")
    }

    @Test("trims leading and trailing whitespace")
    func trimsEnds() {
        #expect(CopilotSummaryFormat.compact("   hello world  \n") == "hello world")
    }

    @Test("collapses tabs and carriage returns too")
    func collapsesTabsAndReturns() {
        #expect(CopilotSummaryFormat.compact("a\t\tb\r\nc") == "a b c")
    }

    @Test("empty in, empty out")
    func empty() {
        #expect(CopilotSummaryFormat.compact("") == "")
        #expect(CopilotSummaryFormat.compact("   \n\t ") == "")
    }

    @Test("an already-tidy single line is unchanged")
    func idempotentOnTidyLine() {
        let tidy = "unknown kind \"instrument\" — expected \"audio\" or \"midi\""
        #expect(CopilotSummaryFormat.compact(tidy) == tidy)
    }
}
