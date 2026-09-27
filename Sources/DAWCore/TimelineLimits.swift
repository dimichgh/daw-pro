import Foundation

/// **The one ceiling on the timeline** (m23-ap I5-F4, round 4): the furthest a
/// beat position may sit from beat 0, and the longest a beat length may be,
/// for everything a caller places on the timeline — notes, clips, markers, the
/// loop and punch regions, automation and controller points, tempo and meter
/// changes, comp segments — and the biggest bar number or bar count.
///
/// **2^20 = 1,048,576 beats.** At 120 BPM that is about 145 hours; at the
/// fastest tempo the app allows (400 BPM) it is still 43.7 hours. The round-4
/// census read every beat position and length the wire, the MCP server, the
/// app and the tests use: nothing comes near it.
///
/// Why there is a ceiling at all: before it, the wire accepted any finite
/// position (`clip.addMIDI` with `atBeat: 1e300`). Past about 2^53 beats a
/// Double can no longer tell two neighbouring grid lines apart, and past 2^63
/// the `Int` conversions in the grid, meter, groove and step arithmetic trap
/// and take the app down. 2^20 sits far below both cliffs, so everything
/// downstream can treat a position as an ordinary number. Those arithmetic
/// sites are also total on their own now; the ceiling is what keeps an absurd
/// number from being accepted in the first place.
///
/// A bar number or count uses the same number: a bar is at least one beat
/// long, so a bar past 2^20 can never start inside the timeline.
///
/// Refused in words that name the limit by the wire, for every command, before
/// any command reads a position (`TimelineCeiling`, DAWControl), and by the MCP
/// schemas (`maximum: 1048576`; TypeScript cannot import this constant, so the
/// server repeats the literal and a test pins both).
public enum TimelineLimits {
    /// The furthest a beat position or offset may be from beat 0, and the
    /// longest a beat length may be: 2^20 beats.
    public static let maximumBeats: Double = 1_048_576

    /// Whether `beats` is a position, length or offset the timeline can hold:
    /// finite and no further than `maximumBeats` from 0, in either direction
    /// (signs stay each command's own business: a move's offset may be
    /// negative, a note's start may not).
    public static func isWithin(_ beats: Double) -> Bool {
        beats.magnitude <= maximumBeats
    }
}
