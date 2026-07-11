import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for the "Explain this" catalog + mode state (M8 ex-a
/// mechanism, ex-b app-wide coverage). The curated copy lives in DAWAppKit so
/// these style rules — the beginner-readable contract from docs/DESIGN-LANGUAGE.md
/// "Explain this" — are enforced without a running app: every registered control
/// has an entry, titles read as titles, bodies are the right length and shape, and
/// no raw unit jargon slips past a newcomer. A count floor fails a silent shrink.
/// The `debug.explainMode` staging handler lives in the un-testable DAWApp
/// executable target, so its `ExplainID(rawValue:)` parsing is covered here.
@Suite("Explain catalog + mode (M8 ex-a/ex-b)")
struct ExplainCatalogTests {

    // MARK: - Completeness

    @Test("every registered ExplainID has a catalog entry")
    func everyIDHasAnEntry() {
        for id in ExplainID.allCases {
            #expect(ExplainCatalog.entry(for: id) != nil, "no explain copy for \(id.rawValue)")
        }
        // No stray entries either — the map is exactly the registered ids.
        #expect(ExplainCatalog.entries.count == ExplainID.allCases.count)
    }

    @Test("the catalog covers every surface — a count floor so a silent shrink fails")
    func catalogHasGrownAppWide() {
        // ex-b takes coverage app-wide: transport, the whole mixer console (strips +
        // master), the piano roll, the arrange surface (track rows + clip body), the
        // AI panels, and Settings. The floor is the landed count; adding is fine,
        // dropping a registered control below it fails here (docs/DESIGN-LANGUAGE.md
        // "every NEW control ships with a catalog entry").
        #expect(ExplainID.allCases.count >= 43,
                "explain coverage shrank below the ex-b floor: \(ExplainID.allCases.count)")
    }

    @Test("ExplainID round-trips its raw value; unknown raw is nil (debug.explainMode focus)")
    func rawValueParsing() {
        #expect(ExplainID(rawValue: "transportPlay") == .transportPlay)
        #expect(ExplainID(rawValue: "mixerFader") == .mixerFader)
        #expect(ExplainID(rawValue: "panelDensity") == .panelDensity)   // the shared density id
        #expect(ExplainID(rawValue: "clipBlock") == .clipBlock)
        #expect(ExplainID(rawValue: "SIMPLE") == nil)          // case-sensitive wire value
        #expect(ExplainID(rawValue: "bogus") == nil)
        #expect(ExplainID.transportPlay.rawValue == "transportPlay")
    }

    // MARK: - Style rules (the copy contract)

    @Test("every title is a short, non-empty label (≤ 24 chars)")
    func titleLength() {
        for (id, entry) in ExplainCatalog.entries {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!title.isEmpty, "\(id.rawValue) has an empty title")
            #expect(entry.title.count <= 24, "\(id.rawValue) title is too long: \"\(entry.title)\" (\(entry.title.count))")
        }
    }

    @Test("every body is 40–280 chars (2–3 short sentences, not a wall of text)")
    func bodyLength() {
        for (id, entry) in ExplainCatalog.entries {
            #expect(entry.body.count >= 40, "\(id.rawValue) body is too short: \(entry.body.count)")
            #expect(entry.body.count <= 280, "\(id.rawValue) body is too long: \(entry.body.count)")
        }
    }

    @Test("no body ends mid-sentence (ends with . ! or ?)")
    func bodyEndsCleanly() {
        for (id, entry) in ExplainCatalog.entries {
            let last = entry.body.trimmingCharacters(in: .whitespacesAndNewlines).last
            #expect(last == "." || last == "!" || last == "?",
                    "\(id.rawValue) body doesn't end on a full stop: …\(String(entry.body.suffix(12)))")
        }
    }

    @Test("no body carries raw unit jargon a newcomer wouldn't know (dB / Hz / …)")
    func bodyAvoidsRawUnitJargon() {
        // A banned-lone-token spot-check: these units are meaningless to a beginner
        // in bare form. The copy spells concepts out instead ("beats per minute",
        // "louder / quieter"), so a card never leans on unglossed jargon
        // (docs/DESIGN-LANGUAGE.md "Explain this" / Rule 6 beginner test). Longer
        // tokens lead the alternation so `dBFS` isn't half-matched as `dB`; the
        // letter look-arounds keep real words safe ("terms" ≠ a bare `ms`).
        let bannedUnits = ["dBFS", "LUFS", "kHz", "RMS", "dB", "Hz", "ms"]
        let pattern = "(?<![A-Za-z])(" + bannedUnits.joined(separator: "|") + ")(?![A-Za-z])"
        let regex = try! NSRegularExpression(pattern: pattern)   // case-sensitive on purpose
        for (id, entry) in ExplainCatalog.entries {
            let range = NSRange(entry.body.startIndex..., in: entry.body)
            let match = regex.firstMatch(in: entry.body, range: range)
            #expect(match == nil,
                    "\(id.rawValue) body uses raw jargon: \((match.flatMap { Range($0.range, in: entry.body) }).map { String(entry.body[$0]) } ?? "?")")
        }
        // Guard the guard: the matcher must still catch bare units, and must NOT
        // trip on real words that merely contain the letters.
        #expect(regex.firstMatch(in: "set it to -6 dB", range: NSRange("set it to -6 dB".startIndex..., in: "set it to -6 dB")) != nil)
        #expect(regex.firstMatch(in: "delay of 200ms", range: NSRange("delay of 200ms".startIndex..., in: "delay of 200ms")) != nil)
        #expect(regex.firstMatch(in: "instruments and terms", range: NSRange("instruments and terms".startIndex..., in: "instruments and terms")) == nil)
    }

    @Test("titles are distinct enough to read as different controls")
    func titlesAreDistinct() {
        let titles = ExplainCatalog.entries.values.map(\.title)
        #expect(Set(titles).count == titles.count, "two controls share an explain title")
    }

    // MARK: - Sample copy pins (a change here should be deliberate)

    @Test("reference copy reads for a beginner — verbatim pins across surfaces")
    func sampleCopy() {
        // Transport + mixer (ex-a references, unchanged).
        #expect(ExplainCatalog.entry(for: .transportPlay)?.title == "Play / Pause")
        #expect(ExplainCatalog.entry(for: .mixerSolo)?.body.hasPrefix("Isolates this track") == true)
        // ex-b: the shared density id, and a Settings key row that must never
        // surface a key value.
        #expect(ExplainCatalog.entry(for: .panelDensity)?.title == "Simple / Pro")
        #expect(ExplainCatalog.entry(for: .settingsApiKey)?.body.contains("Keychain") == true)
        #expect(ExplainCatalog.entry(for: .clipBlock)?.title == "Clip")
    }

    // MARK: - ExplainModel state

    @MainActor
    @Test("explain mode defaults off and toggles")
    func modeDefaultAndToggle() {
        let model = ExplainModel()
        #expect(model.isActive == false)          // opt-in, never on by default
        #expect(model.focusedForCapture == nil)
        model.toggle()
        #expect(model.isActive == true)
        model.toggle()
        #expect(model.isActive == false)
    }

    @MainActor
    @Test("turning explain mode off clears any capture focus")
    func turningOffClearsFocus() {
        let model = ExplainModel()
        model.setActive(true)
        model.focusedForCapture = .transportRecord
        #expect(model.focusedForCapture == .transportRecord)
        model.setActive(false)
        #expect(model.focusedForCapture == nil)   // no stale card can linger
        // toggle() off path clears it too.
        model.setActive(true)
        model.focusedForCapture = .mixerFader
        model.toggle()
        #expect(model.isActive == false)
        #expect(model.focusedForCapture == nil)
    }
}
