import Foundation

/// A named **effort shape** — "how hard is the player blowing, over what span"
/// — and the eight-entry library the breath pad's ring is built from
/// (breath-pad design §7, P1).
///
/// ## What a pattern IS, and what it is not
///
/// A pattern is `(scope, knots)`: an ordered set of (position, level) knots in
/// a normalised 0...1 × 0...1 box, interpolated with
/// `BreathContour.cosineBlend` — the SAME interpolation law the contour
/// generator uses, deliberately, so there is one curve law in the tree rather
/// than two that round differently.
///
/// A pattern is **not** a controller lane and never becomes one directly. It is
/// consumed in one of two ways, and which one depends only on its `scope`:
///
/// - **`.note`** — the shape spans one note, so the pattern configures that
///   note's contour: `onsetLevel`, `releaseLevel`, `peakPosition` and `depth`
///   are read off the curve and handed to `BreathContour.generate`, which draws
///   the actual points. The pattern shapes the note; it does not draw it.
/// - **`.phrase`** — the shape spans a whole phrase, so the pattern is sampled
///   ONCE PER NOTE at that note's position within its phrase
///   (`PhraseDetection.Phrase.position(ofBeat:)`), giving a per-note *effort*
///   scalar that `BreathContour.scaled(_:effort:response:)` turns into that
///   note's options. The phrase's arc is carried by the notes' relative levels.
///
/// ⭐ **This split is the whole reason the library needs a `scope` field**, and
/// it is also why "hairpin crescendo" and "hairpin diminuendo" are two entries
/// rather than one signed entry (design §7.2): they are two positions on the
/// ring, and the dot travelling between them is the gesture.
///
/// ## Everything here is PURE
///
/// No store, no engine, no UI, no randomness, no clock — a `Sendable` value
/// type and a `static let` library. The pad's panel model, the wire, and any
/// test all read the same eight patterns.
///
/// ⛔ **What P1 patterns deliberately cannot do.** Leg D's generator draws ONE
/// shape family per note — onset → settling dip → single peak → release — so a
/// pattern with two peaks, or a peak whose *value* exceeds the note's loudest
/// instant, cannot be reproduced. Every library entry below is inside the
/// family; a caller cannot author one that is not, because knots are not on the
/// P1 wire. Should they ever be, this is the constraint that has to be checked
/// rather than assumed.
public struct EffortPattern: Sendable, Equatable, Identifiable {

    /// Which span the curve is normalised against.
    public enum Scope: String, Sendable, Equatable, CaseIterable, Codable {
        /// One note's sounding length: `u` runs 0...1 from its onset to its end.
        case note
        /// One phrase — first onset to last end, split at breaths by
        /// `PhraseDetection.phrases(in:maxGapBeats:)`.
        case phrase
    }

    /// One (position, level) knot. `u` and `level` both live in 0...1; the
    /// initialiser clamps, so a hand-built pattern cannot leave the box.
    public struct Knot: Sendable, Equatable {
        public var u: Double
        public var level: Double

        public init(u: Double, level: Double) {
            self.u = min(1, max(0, u))
            self.level = min(1, max(0, level))
        }
    }

    /// Stable identifier — this is what crosses the wire, so it is `camelCase`
    /// ASCII and is never renamed once shipped (the `MixerPresetCatalog` /
    /// `SongSkeletonCatalog` convention).
    public let id: String
    /// Human name for a panel or a warning sentence.
    public let displayName: String
    public let scope: Scope
    /// One beginner-readable sentence: what the gesture IS, in the words a
    /// musician would use. Surfaced by the MCP tool description and (later) the
    /// pad's ring labels.
    public let summary: String
    /// Ascending in `u`, at least two knots, first at `u == 0` and last at
    /// `u == 1`. `init` enforces all of that rather than trusting the caller.
    public let knots: [Knot]

    /// Builds a pattern, HEALING the knot list rather than trusting it: knots
    /// are sorted by `u`, ties are dropped (the first wins), and the endpoints
    /// are synthesised from the nearest knot if the list does not reach them.
    /// An empty list becomes a flat 0.5. This is the `MIDINote` self-healing
    /// discipline — a value that cannot be evaluated must not be constructible.
    public init(id: String, displayName: String, scope: Scope,
                summary: String, knots: [Knot]) {
        self.id = id
        self.displayName = displayName
        self.scope = scope
        self.summary = summary

        var healed: [Knot] = []
        for knot in knots.sorted(by: { $0.u < $1.u }) where healed.last?.u != knot.u {
            healed.append(knot)
        }
        if healed.isEmpty { healed = [Knot(u: 0, level: 0.5)] }
        if healed[0].u > 0 { healed.insert(Knot(u: 0, level: healed[0].level), at: 0) }
        if let last = healed.last, last.u < 1 { healed.append(Knot(u: 1, level: last.level)) }
        self.knots = healed
    }

    // MARK: - Evaluation

    /// The curve's level at `u` ∈ 0...1, raised-cosine between the bracketing
    /// knots and held flat outside the ends.
    ///
    /// Uses `BreathContour.cosineBlend` — not a private copy — so the pattern
    /// library and the contour generator can never round differently. Linear
    /// search over the knots: eight patterns of at most five knots each, called
    /// once per note; a binary search here would be cost with no benefit.
    public func evaluate(u: Double) -> Double {
        let x = min(1, max(0, u))
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first.u { return first.level }
        if x >= last.u { return last.level }
        for i in 0..<(knots.count - 1) {
            let a = knots[i], b = knots[i + 1]
            if x >= a.u, x <= b.u {
                let span = b.u - a.u
                guard span > 0 else { return b.level }
                return BreathContour.cosineBlend(a.level, b.level, (x - a.u) / span)
            }
        }
        return last.level
    }

    /// The `u` of the highest knot — where the gesture peaks. Ties resolve to
    /// the EARLIEST such knot, so a pattern that is flat at its maximum (a
    /// terraced level) peaks where it first arrives rather than where it
    /// happens to stop.
    public var peakPosition: Double {
        var best = knots[0]
        for knot in knots.dropFirst() where knot.level > best.level { best = knot }
        return best.u
    }

    /// Highest and lowest knot levels, and the travel between them. `travel` is
    /// what maps onto `BreathContour.Options.depth` for a note-scoped pattern:
    /// a flat pattern travels 0 and asks for a flat lane.
    public var maxLevel: Double { knots.map(\.level).max() ?? 0 }
    public var minLevel: Double { knots.map(\.level).min() ?? 0 }
    public var travel: Double { maxLevel - minLevel }

    /// The level the note SPEAKS at, rescaled so that the pattern's own minimum
    /// is 0 and its maximum is 1 — which is the scale
    /// `BreathContour.Options.onsetLevel` is expressed on. A flat pattern has no
    /// travel to normalise against and returns 1 (it speaks at its only level,
    /// which is also its peak).
    public var normalisedOnsetLevel: Double { normalised(knots[0].level) }
    /// The same rescaling for the final knot → `Options.releaseLevel`.
    public var normalisedReleaseLevel: Double { normalised(knots[knots.count - 1].level) }

    /// The `u` of the pattern's LOWEST knot when that low point sits early in
    /// the span — strictly after the start and before the midpoint — or nil.
    ///
    /// This is the one thing `BreathContour`'s shape family calls the *settling
    /// dip*, and it is what an `sfp` is: accent, immediate drop, then grow.
    /// Mapping it lets `applyEffortShape` ask for an `attackSettleSeconds` that
    /// puts leg D's dip exactly where the pattern's is.
    ///
    /// ⚠️ **Nil is the common case and is correct.** A pattern whose minimum is
    /// at `u == 0` (sub-tone entry, terraced, late bloom) has no dip: its low
    /// point IS the onset, which `onsetLevel` already carries. A pattern whose
    /// minimum is at the end (messa di voce) has no dip either — that is its
    /// release. Only a pattern that goes DOWN before it goes up needs this, and
    /// in the shipped library exactly one does.
    public var earlyDipPosition: Double? {
        guard travel > 1e-12 else { return nil }
        var best = knots[0]
        for knot in knots.dropFirst() where knot.level < best.level { best = knot }
        guard best.u > 0, best.u < 0.5 else { return nil }
        return best.u
    }

    /// How the breath pad turns a phrase-scoped effort scalar into contour
    /// options, when a caller does not say.
    ///
    /// **(estimate.)** `loudnessDepth` 0.55 makes a full hairpin span about
    /// **9.3 dB**: the pattern's soft end is effort 0.25, which scales the peak
    /// CC by `1 − 0.55 × 0.75 = 0.5875`, and CC 11 is a square law, so
    /// `20·log₁₀(0.5875²) ≈ −9.3 dB` against the loud end. That is a clearly
    /// audible written crescendo without being a fade-out. `swellDepth` 0.5
    /// halves the per-note swell at zero effort, on the reasoning in
    /// `BreathContour.EffortResponse.swellDepth`.
    ///
    /// ⚠️ Both numbers are taste, not measurement, and are exposed on the wire
    /// precisely because of that.
    public static let defaultEffortResponse = BreathContour.EffortResponse(
        loudnessDepth: 0.55, swellDepth: 0.5)

    private func normalised(_ level: Double) -> Double {
        let span = travel
        guard span > 1e-12 else { return 1 }
        return min(1, max(0, (level - minLevel) / span))
    }

    // MARK: - The library

    /// The eight-pattern ring (design §7.2, adopted as recommended).
    ///
    /// **Order is the ring order** — index 0 at the top and going clockwise — so
    /// neighbouring entries are gestures a musician would hear as neighbouring.
    /// P2 puts these on a circle; P1 just needs them named and stable.
    ///
    /// ⛔ **"Air runs out" is deliberately ABSENT**, and its absence is a design
    /// decision worth finding here rather than in a doc: a decaying phrase is
    /// the *air budget's output* (P4), not a shape a player chooses. Offering
    /// both would let a user select "sounds like he ran out of air" while the
    /// budget separately decided he had not — two mechanisms, one symptom, and
    /// no way to tell which produced it.
    public static let library: [EffortPattern] = [
        EffortPattern(
            id: "flat",
            displayName: "Flat",
            scope: .note,
            summary: "No shaping at all — a steady level for the whole note. The identity: "
                + "pick this to hear the part with breath expression effectively off.",
            knots: [Knot(u: 0, level: 0.8), Knot(u: 1, level: 0.8)]),

        EffortPattern(
            id: "messaDiVoce",
            displayName: "Messa di voce",
            scope: .note,
            summary: "Grow from a soft start to a peak in the MIDDLE of the note, then fade "
                + "back — the classical exercise for breath control, and the anchor gesture "
                + "for a held wind or vocal note.",
            // Peak at exactly 0.5 — deliberately NOT leg D's default 0.65, which
            // is its cousin (design §7.2: "the library's version should peak at
            // 0.5 and be recognisably different").
            knots: [Knot(u: 0, level: 0.25), Knot(u: 0.5, level: 1), Knot(u: 1, level: 0.2)]),

        EffortPattern(
            id: "lateBloom",
            displayName: "Late bloom",
            scope: .note,
            summary: "Hold steady, then swell in the last third — the difference between "
                + "singing a note and leaning into it. The natural opposite of messa di voce "
                + "on the ring.",
            knots: [Knot(u: 0, level: 0.45), Knot(u: 0.55, level: 0.5),
                    Knot(u: 0.85, level: 1), Knot(u: 1, level: 0.8)]),

        EffortPattern(
            id: "hairpinCrescendo",
            displayName: "Hairpin crescendo",
            scope: .phrase,
            summary: "The whole PHRASE grows from soft to loud, note by note — a written "
                + "crescendo, not a per-note swell. Splits at breaths, so each phrase gets "
                + "its own arc.",
            knots: [Knot(u: 0, level: 0.25), Knot(u: 1, level: 1)]),

        EffortPattern(
            id: "hairpinDiminuendo",
            displayName: "Hairpin diminuendo",
            scope: .phrase,
            summary: "The whole PHRASE falls away from loud to soft. The crescendo's mirror, "
                + "and its neighbour on the ring — moving the dot between the two is the "
                + "gesture, which is why they are two patterns and not one with a sign.",
            knots: [Knot(u: 0, level: 1), Knot(u: 1, level: 0.25)]),

        EffortPattern(
            id: "terraced",
            displayName: "Terraced",
            scope: .phrase,
            summary: "Step to a level and HOLD it for the phrase — the baroque/organ contrast "
                + "to the hairpins. Use it when a section should sit at one dynamic instead "
                + "of breathing through it.",
            knots: [Knot(u: 0, level: 0.7), Knot(u: 0.06, level: 0.75), Knot(u: 1, level: 0.75)]),

        EffortPattern(
            id: "sforzandoPiano",
            displayName: "Sforzando-piano",
            scope: .note,
            summary: "Hit the note hard, drop immediately to soft, then grow back — the sfp "
                + "marking. The only gesture here whose ATTACK is the point.",
            // The accent normalises to 0.95 (BreathContour.maxOnsetLevel) rather
            // than 1: see that constant for why 1 would flatten the bend lane.
            knots: [Knot(u: 0, level: 0.95), Knot(u: 0.12, level: 0.1),
                    Knot(u: 0.9, level: 1), Knot(u: 1, level: 0.75)]),

        EffortPattern(
            id: "subToneEntry",
            displayName: "Sub-tone entry",
            scope: .note,
            summary: "Start almost breath-only and low-pressure, then rise into full tone — "
                + "the gesture that says tenor-ballad. ⚠️ On a sound-bank instrument this is "
                + "a LOUDNESS shape only; the breathy TIMBRE half needs the built-in sampler "
                + "with its expression filter turned up.",
            knots: [Knot(u: 0, level: 0.05), Knot(u: 0.6, level: 0.9),
                    Knot(u: 0.85, level: 1), Knot(u: 1, level: 0.85)]),
    ]

    /// Looks a pattern up by `id`, case-INSENSITIVELY (an agent that sends
    /// `"messadivoce"` meant the same thing), returning nil for an unknown one
    /// so the caller can raise a teaching error naming the valid ids.
    public static func named(_ id: String) -> EffortPattern? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return library.first { $0.id.lowercased() == wanted }
    }

    /// Every id, in ring order — for error messages and tool descriptions.
    public static var libraryIDs: [String] { library.map(\.id) }
}
