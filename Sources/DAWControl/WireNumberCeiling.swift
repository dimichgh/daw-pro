import Foundation
import DAWCore

/// **The wire's number-magnitude ceiling** (W7-WNM, 2026-10-05), checked for
/// every command, immediately after `TimelineCeiling`, before any command
/// reads a param.
///
/// The round-4 census (`TimelineCeiling`) closed the beat/bar axis, and found
/// ~40 OTHER places in `Commands.swift` where a wire `Double` is converted
/// with a bare `Int(_:)` — a track-reorder index, a note pitch, a generation
/// seed, a tempo-map `beatsPerBar`, a sound-bank program number, a drum
/// choke group, and more — with no range check first. `Int(_:)` (and
/// `UInt64(_:)`) TRAP THE WHOLE PROCESS on a finite `Double` of magnitude
/// 2^63 or more: a single JSON number such as `1e20` (valid JSON) sent for
/// ANY of those params took the app down.
///
/// Rather than add a range check at each of the ~40 sites (and every one
/// written after today), this is ONE walk over `params` — nested objects and
/// arrays included — refusing any number whose magnitude is 2^53
/// (`maximumMagnitude`) or more, in words naming the exact path. 2^53 is the
/// point past which a `Double` can no longer represent every whole number
/// exactly, so it is both comfortably below the 2^63 trap line and a bound
/// no LEGITIMATE wire value needs: the round-5 census (this file) found two
/// existing call sites in this same file that already draw the line at
/// EXACTLY 2^53 for the same reason —
/// `requireAUAddress` (`number <= 9_007_199_254_740_992`) and
/// `clip.humanize`'s `seed` (`seedDouble < 9_007_199_254_740_992`, with the
/// comment "a seed above 2^53 does not survive the trip through JavaScript
/// and back") — and no other numeric param's real domain (seeds, indices,
/// pitches, bar/beat counts, byte-ish fields) ever approaches it; see the
/// W7-WNM STATUS census for the full method and list.
///
/// WHAT THIS DOES NOT CHECK:
/// - **Non-finite (`NaN`/`±Infinity`).** A real JSON payload cannot spell
///   either — `JSONDecoder` rejects an out-of-range literal like `1e400`
///   before it ever becomes a `JSONValue` (measured, I5-F4 round 4 §5) — so
///   a non-finite number only reaches a `JSONValue` through in-process
///   construction (a test, or a re-encoding elsewhere). Several commands
///   already refuse a non-finite value for a specific param IN THEIR OWN
///   WORDS before this file existed (`clip.quantize`'s `gridBeats`,
///   `groove.extract`'s `gridBeats`/`cycleBeats`, an AU param's `value`, a
///   drum param's `value`, `clip.detectPitch`'s `silenceFloorDbfs`, and
///   others) — tests pin those exact sentences. Stepping in here with a
///   generic refusal would only replace a more specific, already-correct,
///   already-tested message with a less useful one, for a shape that cannot
///   reach the wire regardless. So the check is scoped to FINITE numbers:
///   `number.isFinite && number.magnitude >= maximumMagnitude`.
/// - **Two (command, key) pairs already guarded, with their own tested
///   words, before this file existed** — `exempt` below, found empirically
///   (installing an unconditional walk broke their tests) rather than
///   guessed in advance. Neither ever reaches an unguarded `Int(_:)`, so
///   exempting them costs no safety.
enum WireNumberCeiling {
    /// The largest magnitude a wire number may have: 2^53
    /// (9,007,199,254,740,992), the point past which a `Double` can no
    /// longer represent every whole number exactly. See the file doc for why
    /// no legitimate param needs more.
    static let maximumMagnitude: Double = 9_007_199_254_740_992

    /// (command, key) pairs where the command ALREADY range-checks the
    /// number in `Double` space, with its own tested words, before any
    /// `Int(_:)` — so this file would only steal a better message, not add
    /// safety. One line each, with the proof.
    ///
    /// - `clip.quantizeAudio`'s `divisions`: `Commands.swift` (B4, I5-F4
    ///   round 4) compares `raw` against `AudioQuantizeSettings.divisionsRange`
    ///   in `Double` before `Int(raw)`. `ClipQuantizeCommandTests
    ///   .gridCeilingAndSliceFloor` sends `1e20` and asserts
    ///   "'divisions' must be a whole number between ...".
    /// - `groove.extract`'s `cycleBeats`: never reaches an `Int(_:)` in this
    ///   file at all — it is passed straight to `ProjectStore.extractGroove`,
    ///   which refuses a non-finite or more-than-65536-slot cycle in ITS OWN
    ///   words before `GrooveTemplate.extract`'s `Int(cycle/grid)` runs.
    ///   `GrooveCommandTests.extractRefusesAbsurdGridsInWords` sends `1e19`
    ///   and asserts "at most 65536 slots".
    ///
    /// NOTE: `clip.sliceToSampler` also takes a `divisions` key, parsed by a
    /// DIFFERENT, UNGUARDED call (`SliceToSamplerSettings.divisionsRange
    /// .contains(Int(raw))` — the `Int(_:)` runs BEFORE the range check), so
    /// the exemption is scoped to `clip.quantizeAudio` only: exempting by key
    /// name alone would reopen that trap.
    static let exempt: [String: Set<String>] = [
        "clip.quantizeAudio": ["divisions"],
        "groove.extract": ["cycleBeats"],
    ]

    /// The refusal for the first number at or past `maximumMagnitude` in
    /// magnitude anywhere in `params` — top level, inside an object, inside
    /// an array, to any depth — or nil when every finite number is within
    /// it. Keys are visited in sorted order and arrays front to back, so the
    /// same params always name the same path. Every path starts with
    /// `"params."` (or `"params["` for a top-level array — params itself is
    /// never an array, so this never fires, but `walk` is shaped the same
    /// way at every level on purpose: one recursive function, not a
    /// top-level special case plus a recursive one that could drift apart).
    static func problem(in params: [String: JSONValue], command: String) -> String? {
        let skip = exempt[command] ?? []
        for key in params.keys.sorted() {
            guard let value = params[key] else { continue }
            if skip.contains(key) { continue }
            if let refusal = walk(value, path: "params.\(key)") { return refusal }
        }
        return nil
    }

    private static func walk(_ value: JSONValue, path: String) -> String? {
        switch value {
        case .number(let number):
            return isWithinMagnitude(number) ? nil : refusal(path: path)
        case .object(let object):
            for inner in object.keys.sorted() {
                guard let innerValue = object[inner] else { continue }
                if let refusal = walk(innerValue, path: "\(path).\(inner)") { return refusal }
            }
            return nil
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                if let refusal = walk(element, path: "\(path)[\(index)]") { return refusal }
            }
            return nil
        case .null, .bool, .string:
            return nil
        }
    }

    /// True (pass, do not refuse) for a non-finite number — left to
    /// whichever command reads it, file doc "WHAT THIS DOES NOT CHECK" —
    /// and for a finite number under the ceiling in magnitude. Only a
    /// FINITE number at or past the ceiling returns false.
    private static func isWithinMagnitude(_ number: Double) -> Bool {
        !number.isFinite || number.magnitude < maximumMagnitude
    }

    /// The words: the path and the limit it passed. No value is echoed back
    /// (unlike `TimelineCeiling`'s refusal) — at this magnitude the caller
    /// already knows what it sent, and `String(describing:)` on a number
    /// near 2^63 is not always round-trippable scientific notation a human
    /// finds familiar.
    static func refusal(path: String) -> String {
        "\(path) is too large: wire numbers must be below \(Int(maximumMagnitude))"
    }
}
