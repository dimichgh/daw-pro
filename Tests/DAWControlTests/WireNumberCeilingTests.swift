import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// W7-WNM — the wire's number-magnitude ceiling (`WireNumberCeiling`): what
/// it checks, the words it answers in, and the two (command, key) exemptions
/// found by running the full `DAWControlTests` target against an
/// unconditional walk.
///
/// Nonisolated: the walker is a pure function of the params, like
/// `TimelineCeiling`'s. The end-to-end refusals through `CommandRouter` live
/// in the EXISTING `@MainActor` suites `CommandRouterTests` (ControlTests.swift)
/// and `ArrangeCommandTests` — no new `@MainActor` suite is added (the cap is
/// 394; see those files' own `WNM` sections).
@Suite("Wire number ceiling — the second wire pre-pass (W7-WNM)")
struct WireNumberCeilingTests {

    // MARK: - The walker

    @Test("the brief's own example, pinned verbatim: a number 2^53 or more, nested three deep in an array, is refused by exact path and words")
    func pinnedExampleMessage() throws {
        let params: [String: JSONValue] = ["notes": .array([
            .object(["pitch": .number(60)]),
            .object(["pitch": .number(61)]),
            .object(["pitch": .number(62)]),
            .object(["pitch": .number(1e20)]),
        ])]
        let problem = try #require(WireNumberCeiling.problem(in: params, command: "clip.setNotes"))
        #expect(problem == "params.notes[3].pitch is too large: wire numbers must be below 9007199254740992")
    }

    @Test("a top-level number past the ceiling is refused, naming 'params.<key>'")
    func refusesTopLevel() throws {
        let problem = try #require(WireNumberCeiling.problem(
            in: ["index": .number(1e20)], command: "track.reorder"))
        #expect(problem == "params.index is too large: wire numbers must be below 9007199254740992")
    }

    @Test("a nested object member is found, to any depth, by dotted path")
    func refusesNestedObjectMember() throws {
        let problem = try #require(WireNumberCeiling.problem(
            in: ["drumKit": .object(["kick": .object(["chokeGroup": .number(1e20)])])],
            command: "track.setInstrument"))
        #expect(problem == "params.drumKit.kick.chokeGroup is too large: "
            + "wire numbers must be below 9007199254740992")
    }

    @Test("a nested array element — of raw numbers, not objects — is found by index")
    func refusesNestedArrayOfNumbers() throws {
        let problem = try #require(WireNumberCeiling.problem(
            in: ["transposeSemitones": .array([.number(1), .number(1e20)])],
            command: "clip.repeatNotes"))
        #expect(problem == "params.transposeSemitones[1] is too large: "
            + "wire numbers must be below 9007199254740992")
    }

    @Test("an array of objects nests one level further: array index, then dotted member")
    func refusesArrayOfObjects() throws {
        let problem = try #require(WireNumberCeiling.problem(
            in: ["segments": .array([
                .object(["startBeat": .number(0), "beatsPerBar": .number(1e20)]),
            ])],
            command: "tempo.setMap"))
        #expect(problem == "params.segments[0].beatsPerBar is too large: "
            + "wire numbers must be below 9007199254740992")
    }

    @Test("the boundary: 2^53 itself is refused, 2^53 - 1 passes (a positive control that this is not refusing everything)")
    func boundary() {
        #expect(WireNumberCeiling.problem(
            in: ["seed": .number(9_007_199_254_740_992)], command: "ai.generateSong") != nil)
        #expect(WireNumberCeiling.problem(
            in: ["seed": .number(9_007_199_254_740_991)], command: "ai.generateSong") == nil)
    }

    @Test("a value in [2^53, 2^63) — 1e17, the value W7-WNM's plant uses — is refused the same as 1e20 and 1e300")
    func midRangeAndFarValuesBothRefused() {
        for value: Double in [1e17, 1e18, 1e19, 1e20, 1e100, 1e300, .greatestFiniteMagnitude] {
            #expect(WireNumberCeiling.problem(in: ["seed": .number(value)], command: "ai.generateSong") != nil,
                    "\(value) must be refused")
        }
    }

    @Test("negative magnitudes are refused the same as positive ones; a negative value just under the ceiling passes")
    func negativeMagnitudes() {
        #expect(WireNumberCeiling.problem(
            in: ["byTracks": .number(-1e20)], command: "clip.moveManyByTracks") != nil)
        #expect(WireNumberCeiling.problem(
            in: ["byTracks": .number(-9_007_199_254_740_991)], command: "clip.moveManyByTracks") == nil)
    }

    @Test("non-finite (NaN, +/-infinity) passes untouched: a real JSON payload cannot spell either (JSONDecoder rejects an out-of-range literal before it becomes a JSONValue, I5-F4 round 4 §5), and several commands already refuse a non-finite value for a specific param in their own, tested words")
    func nonFinitePassesThrough() {
        #expect(WireNumberCeiling.problem(in: ["gridBeats": .number(.infinity)], command: "clip.quantize") == nil)
        #expect(WireNumberCeiling.problem(in: ["gridBeats": .number(-.infinity)], command: "clip.quantize") == nil)
        #expect(WireNumberCeiling.problem(in: ["value": .number(.nan)], command: "au.setParam") == nil)
    }

    @Test("strings, bools and null pass untouched, however large-looking a string is")
    func nonNumbersPassThrough() {
        let params: [String: JSONValue] = [
            "seed": .string("100000000000000000000"), "flag": .bool(true), "note": .null,
        ]
        #expect(WireNumberCeiling.problem(in: params, command: "any.command") == nil)
    }

    @Test("the refusal is deterministic: with several values past the ceiling, the first by sorted key and array order is named, every time")
    func firstProblemIsDeterministic() {
        let params: [String: JSONValue] = [
            "zIndex": .number(1e20), "aIndex": .number(2e20), "mIndex": .number(3e20),
        ]
        for _ in 0..<20 {
            #expect(WireNumberCeiling.problem(in: params, command: "c")?.hasPrefix("params.aIndex") == true)
        }
        let arrayFirst: [String: JSONValue] = ["notes": .array([
            .object(["lengthBeats": .number(9e20), "startBeat": .number(8e20)]),
            .object(["startBeat": .number(7e20)])])]
        #expect(WireNumberCeiling.problem(in: arrayFirst, command: "c")?
            .hasPrefix("params.notes[0].lengthBeats") == true)
    }

    // MARK: - The exemption table (the two command-scoped keys that are
    // already guarded elsewhere, with their own tested words)

    @Test("clip.quantizeAudio's 'divisions' is exempt (already Double-range-checked before Int) — but the SAME key name on clip.sliceToSampler is NOT, because that parser's Int(_:) runs before any check")
    func exemptionIsCommandScopedNotKeyScoped() {
        #expect(WireNumberCeiling.problem(
            in: ["divisions": .number(1e20)], command: "clip.quantizeAudio") == nil)
        #expect(WireNumberCeiling.problem(
            in: ["divisions": .number(1e20)], command: "clip.sliceToSampler") != nil)
    }

    @Test("groove.extract's 'cycleBeats' is exempt (never reaches an Int() in this file; the store refuses it first) — the same key name elsewhere is not in the exempt table at all, and is checked normally")
    func cycleBeatsExemptionIsNarrow() {
        #expect(WireNumberCeiling.problem(
            in: ["cycleBeats": .number(1e19)], command: "groove.extract") == nil)
        #expect(WireNumberCeiling.problem(
            in: ["cycleBeats": .number(1e19)], command: "some.other.command") != nil)
    }

    @Test("an exempt key's OWN nested contents are still not walked — the exemption skips the whole subtree, not just the top number")
    func exemptionSkipsWholeSubtree() {
        // `divisions` is always a plain number on clip.quantizeAudio in
        // practice; this only proves the exemption is a subtree skip, not
        // that a nested shape is expected there.
        #expect(WireNumberCeiling.problem(
            in: ["divisions": .object(["inner": .number(1e20)])], command: "clip.quantizeAudio") == nil)
    }
}
