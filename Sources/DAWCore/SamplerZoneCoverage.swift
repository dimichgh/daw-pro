import Foundation

/// The union coverage of a set of INCLUSIVE integer spans: the outer envelope
/// plus every INTERIOR gap.
///
/// This exists because a naive min-of-lower / max-of-upper LIES. A keymap whose
/// zones cover MIDI 24–47 and 60–96 has a naive envelope of "24–96, fully
/// covered" while everything from 48 to 59 is silent. The envelope's own
/// min/max cannot see that hole; `gaps` is the fix.
///
/// ONE HOME (m26-i): both callers share this computation — `DAWControl`'s
/// `instrument.describeSampler` (which shapes it into JSON) and `DAWAppKit`'s
/// `SamplerEditorModel` (which shapes it into the editor header). DAWAppKit
/// cannot see DAWControl, so the alternative was a second copy, and a forked
/// coverage rule is exactly the drift this codebase's "ONE home" discipline
/// prevents. The JSON shaping stays in DAWControl; only the pure arithmetic
/// lives here.
public struct SamplerZoneCoverage: Equatable, Sendable {
    /// One INTERIOR hole, inclusive on both ends: nothing in
    /// `lowerBound...upperBound` is covered by any span, and there IS covered
    /// material on both sides of it. A hole at the envelope's own edge is not a
    /// gap — it is simply outside the envelope, and already visible in
    /// `lowerBound`/`upperBound`.
    public struct Gap: Equatable, Sendable {
        public var lowerBound: Int
        public var upperBound: Int

        public init(lowerBound: Int, upperBound: Int) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }
    }

    /// The lowest covered value.
    public var lowerBound: Int
    /// The highest covered value.
    public var upperBound: Int
    /// Every interior hole, ascending. Empty = the envelope is solid.
    public var gaps: [Gap]

    public init(lowerBound: Int, upperBound: Int, gaps: [Gap]) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.gaps = gaps
    }

    /// Merges a list of INCLUSIVE `(lowerBound, upperBound)` spans into their
    /// union, then reports the outer envelope plus every interior gap.
    ///
    /// nil for an empty input — no spans means no envelope, which is a legal,
    /// describable state (a sampler with `zones: []` is a silent sampler, not
    /// an error), NOT a zero-width envelope at 0.
    ///
    /// Adjacency counts as contiguous: `(0, 59)` and `(60, 127)` merge into
    /// `0...127` with no gap, because inclusive integer spans that touch leave
    /// nothing uncovered between them (hence the `+ 1` in the merge test).
    ///
    /// Written against the m26-i field report's own two examples — a bass
    /// silent below MIDI 35, a library silent above 45. BOTH of those sit at
    /// the envelope's OWN edges and so are already visible in a naive min/max;
    /// an interior hole between two zone islands is the case a naive envelope
    /// hides, and the case this function exists for.
    public static func coverage(of ranges: [(Int, Int)]) -> SamplerZoneCoverage? {
        guard !ranges.isEmpty else { return nil }
        let sorted = ranges.sorted { $0.0 < $1.0 }
        var merged: [(lowerBound: Int, upperBound: Int)] = []
        for range in sorted {
            if let last = merged.last, range.0 <= last.upperBound + 1 {
                merged[merged.count - 1].upperBound = max(last.upperBound, range.1)
            } else {
                merged.append((lowerBound: range.0, upperBound: range.1))
            }
        }
        var gaps: [Gap] = []
        for i in 1..<merged.count {
            let gapStart = merged[i - 1].upperBound + 1
            let gapEnd = merged[i].lowerBound - 1
            if gapStart <= gapEnd { gaps.append(Gap(lowerBound: gapStart, upperBound: gapEnd)) }
        }
        return SamplerZoneCoverage(
            lowerBound: merged.first!.lowerBound, upperBound: merged.last!.upperBound, gaps: gaps)
    }

    /// PITCH coverage for a zone list — nil for no zones.
    public static func pitchCoverage(of zones: [SamplerZone]) -> SamplerZoneCoverage? {
        coverage(of: zones.map { ($0.minPitch, $0.maxPitch) })
    }

    /// VELOCITY coverage for a zone list — nil for no zones.
    ///
    /// ⚠️ `minVelocity`/`maxVelocity` nil means the FULL velocity span (the
    /// model's own documented default — see `SamplerZone.minVelocity`), never
    /// 0. Folding nil to 0 here would silently report a velocity hole that does
    /// not exist. The bounds come from `SamplerZone.velocityRange` rather than
    /// from `0`/`127` literals so this fold cannot drift from the domain.
    public static func velocityCoverage(of zones: [SamplerZone]) -> SamplerZoneCoverage? {
        coverage(of: zones.map { zone in
            (zone.minVelocity ?? SamplerZone.velocityRange.lowerBound,
             zone.maxVelocity ?? SamplerZone.velocityRange.upperBound)
        })
    }
}
