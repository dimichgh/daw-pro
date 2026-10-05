import Foundation
import DAWCore

/// **The wire's timeline ceiling** (m23-ap I5-F4, round 4), checked ONCE for
/// every command, before the command reads anything (`CommandRouter.route`).
///
/// Every beat position, beat length or beat offset, and every bar number or
/// bar count, wherever it sits in a command's params — at the top, or inside
/// the `notes`, `update`, `points`, `segments`, `meterChanges` and `sections`
/// arrays — must be a finite number no further than
/// `TimelineLimits.maximumBeats` (2^20 = 1048576) from 0. Past it the command
/// is refused, in words that name the param, its value and the limit.
///
/// WHY one check by key name, and not one per command: the round-4 census found
/// the same few names (`atBeat`, `startBeat`, `lengthBeats`, `beat`, …) on
/// 51 commands (43 at the top of their params, 8 more only inside an array),
/// and two of those arrays are decoded through a model's own `Codable`
/// (`automation.setPoints`' `points`, `take.setComp`'s `segments`), so there is
/// no hand-written read to put a check next to. A command added later with an
/// `atBeat` is covered the day it lands, and `TimelineCeilingTests` fails if
/// any command accepts a beat- or bar-named key this file does not list.
///
/// What it does NOT decide: signs, whole numbers, and each command's own
/// tighter ranges (a note's `startBeat >= 0`, `looper.begin`'s `bars` 1...64)
/// stay where they were, in each command's own words. Only magnitude and
/// finiteness are checked here, so every value within the ceiling reaches its
/// command exactly as before.
///
/// Before this, a bar number of 1e20 trapped inside the wire itself
/// (`arrange.insertBars` converted it with `Int(_:)` before any check), and a
/// note or clip at 1e18 or more beats trapped later, in the meter, groove and
/// step arithmetic, the first time a view or a quantize read it.
enum TimelineCeiling {
    /// Beat positions, lengths and offsets (a move's `byBeats` is signed, so
    /// the test is on magnitude). `gridBeats` and `cycleBeats` are NOT here:
    /// each has its own bound and words (`gridFloorProblem` and the
    /// `clip.sliceToSampler` parser for the grid, the store's 65536-slot rule
    /// for the groove cycle), and one param gets one refusal.
    static let beatKeys: Set<String> = [
        "atBeat", "lengthBeats", "startBeat", "endBeat", "toStartBeat",
        "fromBeat", "toBeat", "newStartBeat", "newLengthBeats", "beat", "beats",
        "inBeat", "outBeat", "byBeats", "firstCopyAtBeat", "periodBeats",
        "fadeInBeats", "fadeOutBeats", "timingBeats", "legatoOverlapBeats",
        "maxGapBeats", "scaleBeats", "revolutionBeats", "driftScaleBeats",
    ]

    /// Bar numbers and bar counts. A bar is at least one beat long, so no bar
    /// past the ceiling can start inside the timeline.
    static let barKeys: Set<String> = ["atBar", "fromBar", "bars", "countInBars"]

    /// Names that are a length on ONE command only, checked at the top level of
    /// that command's params: `count` is a number of bars on the two arrange
    /// commands (and a number of copies on `clip.repeatNotes`, which this does
    /// not check), and `horizonCycles` is a number of loop cycles.
    static let commandScopedKeys: [String: [String: Unit]] = [
        "arrange.insertBars": ["count": .bars],
        "arrange.deleteBars": ["count": .bars],
        "looper.begin": ["horizonCycles": .cycles],
    ]

    /// What a checked number counts, for the refusal's words.
    enum Unit: Sendable {
        case beats, bars, cycles
    }

    /// The refusal for the first number past the ceiling in `params`, or nil
    /// when every checked number is within it. Keys are visited in sorted
    /// order and arrays front to back, so the same params always name the
    /// same param.
    static func problem(in params: [String: JSONValue], command: String) -> String? {
        let scoped = commandScopedKeys[command] ?? [:]
        for key in params.keys.sorted() {
            guard let value = params[key] else { continue }
            if let unit = scoped[key], let refusal = check(value, path: key, unit: unit) {
                return refusal
            }
            if let refusal = walk(value, key: key, path: key) { return refusal }
        }
        return nil
    }

    /// Checks `value` if `key` is a beat or bar name, then looks inside it.
    private static func walk(_ value: JSONValue, key: String, path: String) -> String? {
        if let unit = unit(forKey: key), let refusal = check(value, path: path, unit: unit) {
            return refusal
        }
        switch value {
        case .object(let object):
            for inner in object.keys.sorted() {
                guard let innerValue = object[inner] else { continue }
                if let refusal = walk(innerValue, key: inner, path: "\(path).\(inner)") {
                    return refusal
                }
            }
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                if let refusal = walk(element, key: "", path: "\(path)[\(index)]") {
                    return refusal
                }
            }
        case .null, .bool, .number, .string:
            break
        }
        return nil
    }

    private static func unit(forKey key: String) -> Unit? {
        if beatKeys.contains(key) { return .beats }
        if barKeys.contains(key) { return .bars }
        return nil
    }

    /// A number past the ceiling (or not finite) is refused; an array of
    /// numbers under a checked name has each element checked. Anything else is
    /// left to the command, which reports a wrong type in its own words.
    private static func check(_ value: JSONValue, path: String, unit: Unit) -> String? {
        switch value {
        case .number(let number):
            return TimelineLimits.isWithin(number) ? nil : refusal(path: path, value: number, unit: unit)
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                if case .number(let number) = element, !TimelineLimits.isWithin(number) {
                    return refusal(path: "\(path)[\(index)]", value: number, unit: unit)
                }
            }
            return nil
        case .null, .bool, .string, .object:
            return nil
        }
    }

    /// The words: the param, the value it had, and the limit it passed.
    static func refusal(path: String, value: Double, unit: Unit) -> String {
        let limit = Int(TimelineLimits.maximumBeats)
        let rule: String
        switch unit {
        case .beats:
            rule = "a position, length or offset in beats must be a finite number within \(limit) beats "
                + "of beat 0 (2^20 beats, about 145 hours at 120 BPM)"
        case .bars:
            rule = "a bar number or a number of bars must be a finite number no bigger than \(limit) (2^20)"
        case .cycles:
            rule = "a number of loop cycles must be a finite number no bigger than \(limit) (2^20)"
        }
        return "'\(path)' is \(value), past the timeline limit: \(rule)"
    }
}
