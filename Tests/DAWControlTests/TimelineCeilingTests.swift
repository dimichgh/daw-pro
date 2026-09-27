import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m23-ap I5-F4 round 4 — the wire's timeline ceiling (`TimelineCeiling`):
/// what it checks, the words it answers in, and a pin that keeps its key list
/// complete as commands are added.
///
/// Nonisolated: the walker is a pure function of the params, and the census
/// reads source text. The end-to-end refusals through `CommandRouter` live in
/// `ClipQuantizeCommandTests` (a MainActor suite, so no new one is added).
@Suite("Timeline ceiling — the wire (m23-ap I5-F4 round 4)")
struct TimelineCeilingTests {

    // MARK: - The walker

    @Test("a beat key past 2^20 is refused wherever it sits — the top of the params, an array of notes or points, an object inside them — in words naming the path, the value and the limit")
    func refusesPastTheCeilingAnywhere() throws {
        let top = try #require(TimelineCeiling.problem(
            in: ["trackId": .string("t"), "atBeat": .number(1_048_577)], command: "clip.addMIDI"))
        #expect(top == "'atBeat' is 1048577.0, past the timeline limit: a position, length or offset "
            + "in beats must be a finite number within 1048576 beats of beat 0 (2^20 beats, about "
            + "145 hours at 120 BPM)")
        let nested = TimelineCeiling.problem(in: ["notes": .array([
            .object(["pitch": .number(60), "startBeat": .number(0), "lengthBeats": .number(1)]),
            .object(["pitch": .number(62), "startBeat": .number(1), "lengthBeats": .number(3e6)]),
        ])], command: "clip.setNotes")
        #expect(nested?.hasPrefix("'notes[1].lengthBeats' is 3000000.0, past the timeline limit") == true,
                "\(nested ?? "nil")")
        // A comp segment and an automation point are decoded by their model's
        // own Codable; the walker still sees them by name.
        let comp = TimelineCeiling.problem(in: ["segments": .array([
            .object(["laneId": .string("x"), "startBeat": .number(0), "endBeat": .number(1e300)]),
        ])], command: "take.setComp")
        #expect(comp?.hasPrefix("'segments[0].endBeat' is 1e+300,") == true, "\(comp ?? "nil")")
        let point = TimelineCeiling.problem(in: ["points": .array([
            .object(["beat": .number(-2e6), "value": .number(0.5)]),
        ])], command: "automation.setPoints")
        #expect(point?.hasPrefix("'points[0].beat' is -2000000.0,") == true, "\(point ?? "nil")")
        let deep = TimelineCeiling.problem(
            in: ["outer": .object(["inner": .array([.object(["beat": .number(.infinity)])])])],
            command: "any.command")
        #expect(deep?.hasPrefix("'outer.inner[0].beat' is inf,") == true, "\(deep ?? "nil")")
    }

    @Test("bars and bar counts use the same 2^20, in their own words; a command-scoped name is checked only on its own command")
    func barsAndScopedNames() {
        let bar = TimelineCeiling.problem(in: ["atBar": .number(1e20), "count": .number(1)],
                                          command: "arrange.insertBars")
        #expect(bar == "'atBar' is 1e+20, past the timeline limit: a bar number or a number of bars "
            + "must be a finite number no bigger than 1048576 (2^20)")
        let count = TimelineCeiling.problem(in: ["fromBar": .number(1), "count": .number(2e6)],
                                            command: "arrange.deleteBars")
        #expect(count?.hasPrefix("'count' is 2000000.0, past the timeline limit: a bar number") == true,
                "\(count ?? "nil")")
        let cycles = TimelineCeiling.problem(in: ["bars": .number(4), "horizonCycles": .number(1e7)],
                                             command: "looper.begin")
        #expect(cycles?.contains("a number of loop cycles") == true, "\(cycles ?? "nil")")
        let section = TimelineCeiling.problem(in: ["sections": .array([
            .object(["name": .string("Verse"), "bars": .number(1e9)])])], command: "macro.songSkeleton")
        #expect(section?.hasPrefix("'sections[0].bars' is 1000000000.0,") == true, "\(section ?? "nil")")
        // `count` is a number of COPIES on clip.repeatNotes, and horizonCycles
        // means nothing elsewhere: not this check's business there.
        #expect(TimelineCeiling.problem(in: ["count": .number(2e6)], command: "clip.repeatNotes") == nil)
        #expect(TimelineCeiling.problem(in: ["horizonCycles": .number(2e6)], command: "playbox.generate") == nil)
    }

    @Test("the ceiling itself, anything inside it in either direction, other names, and values that are not numbers all pass untouched")
    func withinTheCeilingPasses() {
        let inside: [String: JSONValue] = [
            "atBeat": .number(1_048_576), "byBeats": .number(-1_048_576), "lengthBeats": .number(0.25),
            "startBeat": .number(-3), "atBar": .number(1_048_576),
            "seed": .number(1e30), "gridBeats": .number(1e300), "cycleBeats": .number(.infinity),
            "fromBeat": .string("far"), "toBeat": .null, "beat": .bool(true),
            "notes": .array([.object(["startBeat": .number(1_048_575.9)])]),
            "points": .array([.number(1e9)]),
        ]
        #expect(TimelineCeiling.problem(in: inside, command: "any.command") == nil)
        #expect(TimelineCeiling.problem(in: [:], command: "transport.play") == nil)
    }

    @Test("the refusal is deterministic: with several values past the ceiling, the first by sorted key and array order is named, every time")
    func firstProblemIsDeterministic() {
        let params: [String: JSONValue] = [
            "toBeat": .number(3e6), "fromBeat": .number(2e6), "atBeat": .number(4e6),
            "notes": .array([.object(["startBeat": .number(1)]), .object(["startBeat": .number(5e6)])]),
        ]
        for _ in 0..<20 {
            #expect(TimelineCeiling.problem(in: params, command: "c")?.hasPrefix("'atBeat'") == true)
        }
        let arrayOnly: [String: JSONValue] = ["notes": .array([
            .object(["lengthBeats": .number(9e6), "startBeat": .number(8e6)]),
            .object(["startBeat": .number(7e6)])])]
        #expect(TimelineCeiling.problem(in: arrayOnly, command: "c")?.hasPrefix("'notes[0].lengthBeats'") == true)
    }

    // MARK: - The census pin

    /// Keys whose name says beat or bar but which have their own bound, one
    /// home each, and so are deliberately not in the walker's lists.
    private static let exempt: [String: String] = [
        "gridBeats": "gridFloorProblem (clip.quantize, clip.quantizeAudio, groove.extract, clip.sliceToSampler): floor 1/1024, ceiling 2^20",
        "cycleBeats": "groove.extract: the store refuses more than 65536 grid slots per cycle",
    ]

    private static func commandsSource() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWControl/Commands.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                // `//` comments stripped line by line, as ZeroParamVerbRejectionTests
                // and doc-count-drift.mjs do: a doc comment may spell out a call.
                return try String(contentsOf: candidate, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> Substring in
                        if let slash = line.range(of: "//") { return line[line.startIndex..<slash.lowerBound] }
                        return line
                    }
                    .joined(separator: "\n")
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        var out: [[String]] = []
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            out.append((0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            })
        }
        return out
    }

    private static func isBeatOrBarName(_ key: String) -> Bool {
        key.range(of: "beat", options: .caseInsensitive) != nil
            || key.range(of: "bar", options: .caseInsensitive) != nil
    }

    @Test("CENSUS PIN: every beat- or bar-named key any command accepts (its rejectUnknownKeys list), and every one a parser reads inside an array, is checked by the walker or exempt with a reason; a new atBeat-style key fails here until it is listed")
    func everyBeatAndBarKeyIsChecked() throws {
        let source = try Self.commandsSource()
        let lists = try Self.matches(#"rejectUnknownKeys\(\s*(\[[^\]]*\])\s*,\s*verb:\s*"([^"]+)""#, in: source)
        var accepted: [String: Set<String>] = [:]
        for list in lists {
            for key in try Self.matches(#""([^"]+)""#, in: list[1]).map({ $0[1] }) {
                accepted[key, default: []].insert(list[2])
            }
        }
        // POSITIVE CONTROLS: the scrape sees the whole wire, and the lists it
        // must see (an empty scrape would pass every check below).
        #expect(Set(lists.map { $0[2] }).count >= 250)
        #expect(accepted["atBeat"]?.contains("clip.addMIDI") == true)
        #expect(accepted["count"]?.contains("arrange.insertBars") == true)
        #expect(accepted["gridBeats"]?.contains("clip.sliceToSampler") == true)

        let checked = TimelineCeiling.beatKeys.union(TimelineCeiling.barKeys)
        let named = accepted.keys.filter(Self.isBeatOrBarName)
        #expect(named.count >= 25)
        for key in named.sorted() where !checked.contains(key) {
            #expect(Self.exempt[key] != nil,
                    "'\(key)' (accepted by \(accepted[key]!.sorted())) names a beat or a bar but the timeline ceiling does not check it: add it to TimelineCeiling or exempt it with a reason")
        }
        // Every listed name is really accepted somewhere (no dead entries).
        for key in checked.sorted() {
            #expect(accepted[key] != nil, "'\(key)' is listed in TimelineCeiling but no command accepts it")
        }
        // Command-scoped names: each command really takes the name.
        for (command, keys) in TimelineCeiling.commandScopedKeys {
            for key in keys.keys {
                #expect(accepted[key]?.contains(command) == true, "\(command) does not accept '\(key)'")
            }
        }

        // Inside arrays: every `element["…"]`-style read of a beat or bar name.
        let reads = try Self.matches(#"\b(?:element|object|point|segment|entry|item)\["([A-Za-z]+)"\]"#, in: source)
        let nested = Set(reads.map { $0[1] }).filter(Self.isBeatOrBarName)
        #expect(nested.contains("startBeat") && nested.contains("bars"))   // POSITIVE CONTROL
        for key in nested.sorted() where !checked.contains(key) {
            #expect(Self.exempt[key] != nil || ["beatsPerBar", "beatUnit"].contains(key),
                    "a parser reads '\(key)' inside an array, and the walker does not check it")
        }

        // Decoded through the model's own Codable (no hand-written read):
        // their beat-named keys must be checked too.
        let point = try JSONValue(encoding: AutomationPoint(beat: 1, value: 0.5))
        let segment = try JSONValue(encoding: CompSegment(laneID: UUID(), startBeat: 0, endBeat: 1))
        for value in [point, segment] {
            let keys = value.objectValue?.keys.filter(Self.isBeatOrBarName) ?? []
            #expect(!keys.isEmpty)
            for key in keys { #expect(checked.contains(key), "Codable key '\(key)' is not checked") }
        }
    }
}
