import AIServices
import DAWAppKit
@testable import DAWCore
import Foundation
import Testing

/// p2-sing-x9-f3 (the XS half): the §4.1 interval choices are written down twice, by hand. The "Add a harmony" menu is
/// `SingSheetModel.harmonyChoices` over `SingHarmonyChoice` (DAWAppKit); the choices a range line may name are
/// `HarmonyPlanner.rangeLineChoices` (DAWCore, p2-sing-x9-f1). A choice added to one and not the other would let a range
/// line suggest a part the menu cannot add, or leave a menu part that no line ever names. This pins them to each other,
/// in the menu's order, by (interval, direction); the chord source is not compared (the menu's parts use `.auto`, the
/// line plans with the asked part's).
///
/// NOT `@MainActor` (the tree is at its suite cap): the sheet model is reached by `await` hops.
@Suite struct SingSheetHarmonyChoiceListTests {

    /// "interval direction" for a part planned from the melody by the interval rule; nil for any other kind of part.
    static func intervalChoice(_ kind: SingJobPart.Kind) -> String? {
        guard case .harmony(let spec) = kind else { return nil }
        return "\(spec.interval.rawValue) \(spec.direction.rawValue)"
    }

    @Test func theMenusIntervalChoicesAreTheRangeLinesChoicesInOrder() async throws {
        let (sheet, clipID) = try await MainActor.run { () throws -> (SingSheetModel, UUID) in
            let (store, clipID) = try SingSheetFixture.store(pitches: [60, 62, 64, 65, 67, 65, 64, 62],
                                                            lyrics: "one two three four five six sev en")
            let status = SingingSidecarStatus(state: .healthy, message: "fake engine: healthy")
            let sheet = SingSheetModel(store: store, lyrics: SingLyricsSpy(store: store), transposer: store,
                                       jobs: SingFakeJobs(), engineStatus: { status }, library: nil,
                                       styles: SingStyleSpy(store: store))
            return (sheet, clipID)
        }
        await sheet.open(clipID: clipID)
        let menu = await sheet.harmonyChoices
        let menuIntervals = menu.compactMap { Self.intervalChoice($0.kind) }
        let lineChoices = HarmonyPlanner.rangeLineChoices.map { "\($0.interval.rawValue) \($0.direction.rawValue)" }
        #expect(!menuIntervals.isEmpty, "the menu offered no interval choice at all: \(menu)")
        #expect(menuIntervals == lineChoices,
                "the menu's interval choices \(menuIntervals) and the range line's \(lineChoices) have drifted apart")
        // Every other menu entry is a part whose notes come from elsewhere in the song, which a line never names.
        #expect(menu.filter { Self.intervalChoice($0.kind) == nil }.allSatisfy { $0 == .chordNotes })
    }

    @Test func theMenusOtherEntriesAreNotIntervalParts() {
        // Why the comparison above may skip them: neither is planned from the melody by the interval rule.
        #expect(Self.intervalChoice(SingHarmonyChoice.chordNotes.kind) == nil)
        #expect(Self.intervalChoice(SingHarmonyChoice.otherMelody(clipID: UUID()).kind) == nil)
        #expect(Self.intervalChoice(SingHarmonyChoice.thirdAbove.kind) == "third above")
    }

    // MARK: - The fourth hand list: `debug.singScreens {parts}` (p2-sing-x9-f3, W8-X9F3B)

    /// `Sources/DAWApp/Sing/SingMount.swift` names the choices a THIRD time, by hand: the `parts` switch of
    /// `debug.singScreens` (`case "thirdAbove": sheet.addHarmony(.thirdAbove)` …) and its refusal's list of names. It
    /// lives in the app target, which no test target can import, so this reads the source (comment-stripped, the
    /// `AddableEffectKindsSiteTests` shape) and pins it to `HarmonyPlanner.rangeLineChoices` + "chordNotes", in order,
    /// and the refusal's list to the switch. A SOURCE-SHAPE check is the weaker instrument; it is the one available.
    static let singMount = "DAWApp/Sing/SingMount.swift"

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// The file with comment lines and trailing `//` comments removed; nil when it cannot be read.
    private static func code(_ relativePath: String) -> String? {
        guard let raw = try? String(contentsOf: sourcesDir().appendingPathComponent(relativePath), encoding: .utf8)
        else { return nil }
        return raw.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// Every `case "<name>": sheet.addHarmony(.<choice>)`, in source order.
    private static func parsedParts(_ code: String) throws -> [(name: String, choice: String)] {
        let pattern = try NSRegularExpression(pattern: #"case "([A-Za-z]+)": sheet\.addHarmony\(\.([A-Za-z]+)\)"#)
        return pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: code), let choice = Range(match.range(at: 2), in: code)
            else { return nil }
            return (String(code[name]), String(code[choice]))
        }
    }

    /// The names the refusal lists: `unknown part \"\(name)\" (a, b, …)`.
    private static func refusalNames(_ code: String) -> [String] {
        guard let line = code.split(separator: "\n").first(where: { $0.contains("debug.singScreens: unknown part") }),
              let open = line.lastIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { return [] }
        return line[line.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func theScreensVerbsPartNamesAreTheRangeLinesChoicesThenChordNotes() throws {
        // ⭐ Positive control first: the reader reaches the real file, strips comments, and the parse finds a list.
        let code = try #require(Self.code(Self.singMount), "could not read \(Self.singMount)")
        #expect(code.count > 2_000, "read \(code.count) bytes: that is not SingMount.swift")
        #expect(code.contains("debug.singScreens"))
        #expect(Self.code("DAWApp/Sing/NoSuchFile.swift") == nil, "a missing file must read as nil, not as empty")
        let parts = try Self.parsedParts(code)
        #expect(parts.count >= 4, "the parse found \(parts.count) parts: \(parts)")

        // Each name adds the choice of the same name.
        for part in parts { #expect(part.name == part.choice, "\"\(part.name)\" adds .\(part.choice)") }
        // In order: the range line's interval choices (camel case), then the chord-notes part, nothing else.
        let lineChoices = HarmonyPlanner.rangeLineChoices.map { choice -> String in
            let direction = choice.direction.rawValue
            return choice.interval.rawValue + direction.prefix(1).uppercased() + String(direction.dropFirst())
        }
        let names = parts.map { $0.name }
        #expect(names == lineChoices + [String(describing: SingHarmonyChoice.chordNotes)],
                "debug.singScreens {parts} \(names) vs the range line's \(lineChoices) + chordNotes")
        // The refusal lists exactly the names the switch accepts, in the same order.
        #expect(Self.refusalNames(code) == names, "the refusal lists \(Self.refusalNames(code))")
    }
}
