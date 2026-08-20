import Foundation

/// The breath pad's **circular morph space** — named effort patterns placed
/// around a circle, and a dot whose *angle* selects which gestures blend and
/// whose *radius* selects how much (breath-pad design §8, P2).
///
/// ## THE RING LAW
///
/// > Patterns sit at evenly spaced angles `θ_i = 2πi/N`. For a dot at angle φ:
/// >
/// > 1. Find the two neighbours `a`, `b` that bracket φ, and let
/// >    `t = (φ − θ_a) / (θ_b − θ_a)` ∈ 0..<1.
/// > 2. `w_b = cosineBlend(0, 1, t)`, `w_a = 1 − w_b`, **every other weight 0**.
/// > 3. Blend the patterns **in the value domain**, weights summing to 1.
/// > 4. Apply radius as the affine level map
/// >    `level' = neutral + r·(level − neutral)`.
///
/// **Nearest-two, not a global kernel.** Inverse-distance (Shepard) weighting
/// over all N patterns is singular at the pattern positions and — decisively —
/// lets *every* pattern contaminate *every* dot position, so parking the dot
/// exactly on `terraced` would not give you terraced. Being able to select one
/// pattern exactly is the whole reason for placing them on a circle. An angular
/// raised-cosine kernel degenerates to this rule at span = one spacing and only
/// reintroduces the contamination when widened. See design §8.2.
///
/// ## ⛔ THE BLEND IS EQUAL-GAIN, NEVER EQUAL-POWER — and why
///
/// The tree's crossfade idiom elsewhere is equal-power: `SamplerInstrument`'s
/// CC crossfade uses `sqrt`, **correctly**, because it crossfades *uncorrelated
/// audio*, where power adds and amplitude does not. Control curves are the
/// opposite case. They are perfectly correlated with each other, so blending
/// two identical curves must return that curve — and equal-power returns it at
/// `√0.5 + √0.5 ≈ 1.414×`. Local consistency with the sampler would be a wrong
/// answer here, so the weights sum to exactly 1 and are eased by
/// `BreathContour.cosineBlend` (which removes the slope discontinuity as the
/// dot passes a pattern without touching the sum).
///
/// ⚠️ **The trap inside the trap, for anyone testing this:**
/// `√w + √(1−w) == 1.0 exactly at w == 1`. A sqrt implementation therefore
/// passes an identity check sampled only *at the pattern angles*. The error is
/// maximal at the **midpoints between patterns**, which is where
/// `EffortRingTests` samples.
///
/// ## THE INTERPOLATION LAW — how curves of different lengths meet
///
/// > **Each pattern is evaluated in its OWN normalised domain, and the results
/// > are blended in the VALUE domain.**
/// >
/// > ```
/// > effortRaw = Σ_i w_i · pattern_i.evaluate(u_i)
/// >   where u_i = noteU    if pattern_i.scope == .note
/// >             = phraseU  if pattern_i.scope == .phrase
/// >   and   Σ_i w_i == 1
/// > ```
///
/// The alternative — warping the two time axes into correspondence and
/// interpolating knot *positions* — needs a correspondence between the knots of
/// two different curves, and a 2-knot `terraced` has none with a 4-knot
/// `sforzandoPiano`. Every rule you could pick (match by index, by order, by
/// nearest u) gives a different answer and each shows artefacts at some blend
/// positions. Value-domain blending needs no correspondence, is commutative,
/// and makes a self-blend the identity.
///
/// **Different lengths are therefore a non-issue, and this is worth stating
/// plainly because it is not obvious.** Normalisation happens per pattern, in
/// its own scope, *before* blending: a note-scoped curve over a 4-beat note and
/// a phrase-scoped curve over 16 beats are each evaluated at the musical
/// position expressed in their own unit domain, and only their outputs meet.
/// Knot counts never have to agree — `Blend.level(scope:u:)` is well defined at
/// every `u` for any mix of patterns.
///
/// ## The one place this file DEFINES rather than derives
///
/// `Blend.level(scope:u:)` is the law above, pointwise and exact. But leg D's
/// contour generator cannot be handed a curve — it is *parameterised*
/// (`onsetLevel`, `peakPosition`, `releaseLevel`, `depth`), so the store has to
/// project the blend onto that family. `Blend.curve(scope:)` is the vehicle:
///
/// > **The blended curve is the `EffortPattern` whose knots sit at the UNION of
/// > its members' knot positions, carrying the exactly-blended level at each.**
///
/// The union — not a uniform resample — is what makes this exact where it must
/// be: for a self-blend the union *is* that pattern's own knot set at its own
/// levels, so the synthesised curve is the pattern, sample for sample, and
/// §13.2's identity holds structurally rather than numerically. Between knots
/// of a genuine two-pattern blend the synthesised curve cosine-interpolates its
/// own knots while `level(scope:u:)` interpolates each parent and then sums;
/// those differ slightly, the difference is pinned by a test, and every value
/// the store actually reads off the curve (`travel`, `peakPosition`,
/// `normalisedOnsetLevel`, `normalisedReleaseLevel`, `earlyDipPosition`) is a
/// knot property and therefore exact.
///
/// ## ⭐ Radius keeps P1's boundary STRUCTURALLY, not by discipline
///
/// Radius is applied to the **levels**, before any geometry is derived:
/// `level' = neutral + r·(level − neutral)` is an increasing affine map, and
/// argmax and min/max-normalised positions are invariant under one. So
/// `peakPosition`, `normalisedOnsetLevel` and `normalisedReleaseLevel` *cannot*
/// move with radius — only `travel` scales, by exactly `r`. P1 deliberately
/// does not effort-scale `peakPosition`, because one visible outcome with two
/// independent causes is the ambiguity design §7.2 rejects; here that boundary
/// is a property of the arithmetic rather than a rule someone has to remember.
/// **Radius must therefore not be multiplied in anywhere else.**
///
/// ## ⚠️ `neutral` is 1, not the design's estimated 0.5, and that is deliberate
///
/// Design §8.2 suggests `neutral = 0.5` "so radius 0 is a neutral mid-effort
/// rather than silence" — an estimate made for a continuous field. This tree's
/// consumer is `BreathContour.scaled`, where **effort 1 means "exactly as
/// authored"** and effort 0.5 is a real level drop (≈2.8 dB at the default
/// `loudnessDepth`). A control whose name is "how far out is the dot" must not
/// quietly re-balance a mix at radius 0, so `defaultNeutral` is 1 and radius 0
/// is a true no-op. It stays a parameter because P3's field model may well want
/// 0.5, and because a number this consequential should be visible.
///
/// **Corollary, stated so nobody treats them as independent:** on the phrase
/// axis, radius gives `1 + r·(raw − 1)` and the verb's `amount` gives
/// `1 + s·(raw − 1)`. Same form — *they are one axis* and they compose as
/// `r·s`. Setting `radius 0.5, amount 1` is indistinguishable from
/// `radius 1, amount 0.5`, and a test asserts exactly that.
///
/// ## Everything here is PURE
///
/// `Sendable` value types, no store, no engine, no UI, no clock, no randomness.
public struct EffortRing: Sendable, Equatable {

    /// The level a radius of 0 collapses to — see the `neutral` note above.
    public static let defaultNeutral = 1.0

    /// The most patterns a ring may carry. Not a maths limit: a circle a user
    /// has to read has a legibility limit, and a bounded array is what keeps a
    /// wire payload from being a denial of service.
    public static let maxPatterns = 32

    /// The patterns, **in ring order** — index 0 at angle 0, then evenly spaced
    /// going round. Duplicates are allowed and are not a mistake: a ring of N
    /// copies of one pattern is exactly how design §13.2 states the self-blend
    /// identity test.
    public let patterns: [EffortPattern]

    /// Builds a ring, HEALING an empty list into the full library rather than
    /// leaving a value that cannot be evaluated — the `EffortPattern.init`
    /// discipline. Over-long lists are truncated to `maxPatterns`.
    ///
    /// A caller that wants a bad list REFUSED rather than healed (the wire does)
    /// should use `resolve(ids:)`, which names what was wrong.
    public init(patterns: [EffortPattern]) {
        if patterns.isEmpty {
            self.patterns = EffortPattern.library
        } else if patterns.count > EffortRing.maxPatterns {
            self.patterns = Array(patterns.prefix(EffortRing.maxPatterns))
        } else {
            self.patterns = patterns
        }
    }

    /// The eight-pattern ring in library order (design §7.2's recommendation:
    /// eight reads clearly at 45° apart and always gives the nearest-two rule an
    /// unambiguous pair).
    public static let standard = EffortRing(patterns: EffortPattern.library)

    /// A ring made of one pattern repeated `count` times — the fixture design
    /// §13.2 asks for, given a name so the test reads as the law it is checking.
    public static func uniform(_ pattern: EffortPattern, count: Int = 8) -> EffortRing {
        EffortRing(patterns: Array(repeating: pattern, count: max(1, count)))
    }

    /// What went wrong with a caller-supplied id list, in a sentence that names
    /// the fix. Never a silent fallback to the standard ring: a typo that
    /// quietly becomes a different gesture is this round's whole subject.
    public enum ResolveError: Error, Equatable {
        case empty
        case tooMany(count: Int, limit: Int)
        case unknown(id: String, valid: [String])

        public var message: String {
            switch self {
            case .empty:
                return "'ring' is empty — list at least one pattern id, or omit it for the "
                    + "standard eight-pattern ring: "
                    + EffortPattern.libraryIDs.joined(separator: ", ")
            case let .tooMany(count, limit):
                return "'ring' has \(count) patterns and the limit is \(limit) — a ring a "
                    + "player has to read cannot usefully carry more"
            case let .unknown(id, valid):
                return "unknown pattern '\(id)' in 'ring' — valid patterns are: "
                    + valid.joined(separator: ", ")
            }
        }
    }

    /// Resolves pattern ids (case-insensitively, as `EffortPattern.named` does)
    /// into a ring, or throws a `ResolveError` naming the problem.
    public static func resolve(ids: [String]) throws -> EffortRing {
        guard !ids.isEmpty else { throw ResolveError.empty }
        guard ids.count <= maxPatterns else {
            throw ResolveError.tooMany(count: ids.count, limit: maxPatterns)
        }
        var found: [EffortPattern] = []
        found.reserveCapacity(ids.count)
        for id in ids {
            guard let pattern = EffortPattern.named(id) else {
                throw ResolveError.unknown(id: id, valid: EffortPattern.libraryIDs)
            }
            found.append(pattern)
        }
        return EffortRing(patterns: found)
    }

    // MARK: - Geometry

    public var count: Int { patterns.count }

    /// The angle between neighbours, in radians.
    public var spacing: Double { 2 * .pi / Double(count) }

    /// Where pattern `index` sits, in radians. Out-of-range indices wrap, so a
    /// caller stepping round the ring cannot trip on the seam.
    public func angle(ofIndex index: Int) -> Double {
        let n = count
        let i = ((index % n) + n) % n
        return Double(i) * spacing
    }

    /// Folds any real angle into 0..<2π. **DAWCore wraps; the wire bounds.**
    /// P3's orbit path integrates an angle without limit and must be able to
    /// hand it straight in, whereas a `ringAngle` of 4500 on the wire is far
    /// more likely to be a typo than a request for twelve and a half turns, so
    /// `clip.applyEffortShape` refuses that with a sentence instead of taking a
    /// silent modulo.
    public static func wrap(_ angle: Double) -> Double {
        let full = 2 * Double.pi
        guard angle.isFinite else { return 0 }
        let r = angle.truncatingRemainder(dividingBy: full)
        return r < 0 ? r + full : r
    }

    /// Degrees → radians, for the wire, whose unit is DEGREES so that "halfway
    /// between messa di voce and late bloom" is 67.5 rather than 1.178.
    public static func radians(fromDegrees degrees: Double) -> Double {
        wrap(degrees * .pi / 180)
    }

    /// Radians → degrees in 0..<360, for reporting back what the dot did.
    public static func degrees(fromRadians radians: Double) -> Double {
        wrap(radians) * 180 / .pi
    }

    // MARK: - The weight law

    /// The full weight vector at angle φ (radians, wrapped): `count` entries
    /// summing to exactly 1, with at most two of them non-zero.
    ///
    /// On a ring of one, the single entry is 1 — the two "neighbours" are the
    /// same pattern and their weights are added rather than each stored, which
    /// is why the accumulation below is `+=` and not `=`. That is also what
    /// keeps partition-of-unity true at N == 1 and N == 2.
    public func weights(atAngle angle: Double) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        let phi = EffortRing.wrap(angle)
        let step = spacing
        // `floor` on a wrapped angle can only land in 0..<count, but a value a
        // hair below 2π can round to count after the division, so clamp rather
        // than trust the float.
        let a = min(count - 1, max(0, Int((phi / step).rounded(.down))))
        let t = min(1, max(0, (phi - Double(a) * step) / step))
        let b = (a + 1) % count
        let wB = BreathContour.cosineBlend(0, 1, t)
        out[a] += 1 - wB
        out[b] += wB
        return out
    }

    /// The dot resolved into a blend: the weights, the radius, and the level
    /// the radius collapses toward.
    ///
    /// `angle` is RADIANS and is wrapped. `radius` is clamped to 0...1.
    public func blend(atAngle angle: Double,
                      radius: Double = 1,
                      neutral: Double = EffortRing.defaultNeutral) -> Blend {
        let w = weights(atAngle: angle)
        var members: [Blend.Member] = []
        members.reserveCapacity(2)
        for (i, weight) in w.enumerated() where weight > 0 {
            members.append(Blend.Member(index: i, pattern: patterns[i], weight: weight))
        }
        // A weight vector of all zeros is unreachable (they sum to 1), but a
        // stated fallback beats a crash if that ever stops being true.
        if members.isEmpty {
            members = [Blend.Member(index: 0, pattern: patterns[0], weight: 1)]
        }
        return Blend(members: members,
                     angle: EffortRing.wrap(angle),
                     radius: min(1, max(0, radius)),
                     neutral: min(1, max(0, neutral)),
                     patternIDs: patterns.map(\.id),
                     weights: w)
    }

    // MARK: - Blend

    /// One dot position, resolved: which patterns are sounding, how much of
    /// each, and everything derived from that.
    public struct Blend: Sendable, Equatable {

        /// A pattern with a non-zero share of the dot.
        public struct Member: Sendable, Equatable {
            public let index: Int
            public let pattern: EffortPattern
            public let weight: Double
        }

        /// How many pieces a MISMATCHED interval is cut into when the blended
        /// curve is materialised. 8 because the cosine-interpolation error over
        /// a span falls roughly with its square, so eight pieces buys about two
        /// orders of magnitude for at most a few dozen knots on a curve that is
        /// evaluated a handful of times per note.
        static let refinementSteps = 8

        /// The non-zero contributors, in ring order — one or two, never more.
        public let members: [Member]
        /// Where the dot is, in radians, wrapped into 0..<2π.
        public let angle: Double
        /// How far out, 0...1.
        public let radius: Double
        /// What radius 0 collapses to.
        public let neutral: Double
        /// The whole ring's ids, in order — for reporting.
        public let patternIDs: [String]
        /// The whole weight vector, parallel to `patternIDs`, summing to 1.
        public let weights: [Double]

        /// The share of the dot held by `.note`-scoped patterns, and by
        /// `.phrase`-scoped ones. **These sum to exactly 1**, and they are what
        /// splits the blend across the two things a contour can express: how a
        /// single note is shaped, and where that note sits in its phrase.
        public var noteWeight: Double { weight(of: .note) }
        public var phraseWeight: Double { weight(of: .phrase) }

        public func weight(of scope: EffortPattern.Scope) -> Double {
            members.filter { $0.pattern.scope == scope }.reduce(0) { $0 + $1.weight }
        }

        /// The heaviest member — ties go to the lower ring index, so the answer
        /// is deterministic at an exact midpoint. This is what a result reports
        /// as "the" pattern when the caller used the ring: an honest label for
        /// where the dot is nearest, not a claim that only one pattern played.
        public var dominant: Member {
            var best = members[0]
            for member in members.dropFirst() where member.weight > best.weight { best = member }
            return best
        }

        /// **THE BLEND LAW, pointwise and exact.** The weighted sum of the
        /// members of `scope`, each evaluated at `u` in its own domain,
        /// renormalised so the group's weights sum to 1, then radius-mapped.
        ///
        /// Returns `neutral` when the group is empty — the honest answer for
        /// "the dot has no note-scoped content", and the value that makes the
        /// group's contribution vanish rather than distort.
        ///
        /// ⚠️ Renormalising WITHIN the group is deliberate and is not a second
        /// weight law: the group's *share* of the dot is carried separately by
        /// `noteWeight`/`phraseWeight`, so that a caller can apply it to the
        /// right axis. Folding the share into the level here would apply it
        /// twice.
        public func level(scope: EffortPattern.Scope, u: Double) -> Double {
            let group = members.filter { $0.pattern.scope == scope }
            let total = group.reduce(0) { $0 + $1.weight }
            guard total > 0 else { return neutral }
            var sum = 0.0
            for member in group {
                sum += (member.weight / total) * member.pattern.evaluate(u: u)
            }
            return radiusMapped(sum)
        }

        /// The blend as a CURVE of the same type a pattern is — knots at the
        /// union of the members' knot positions, each carrying the exact
        /// blended level there. See the file header for why the union, and for
        /// what it does and does not guarantee between knots.
        ///
        /// `nil` when no member has that scope, which the store reads as "leave
        /// this axis alone" rather than "flatten it".
        public func curve(scope: EffortPattern.Scope) -> EffortPattern? {
            let group = members.filter { $0.pattern.scope == scope }
            guard !group.isEmpty else { return nil }

            var positions: Set<Double> = [0, 1]
            for member in group {
                for knot in member.pattern.knots { positions.insert(knot.u) }
            }

            // ⭐ WHERE THE UNION IS EXACT, AND WHERE IT IS NOT — the theorem
            // this refinement rests on. `cosineBlend(a, b, t)` is AFFINE in
            // `(a, b)` for a fixed `t`. So on an interval where EVERY member has
            // a knot at both ends, each member is a single cosine segment
            // spanning exactly that interval, and
            //     Σ wᵢ · cosineBlend(Lᵢ(u₀), Lᵢ(u₁), t)
            //         == cosineBlend(Σ wᵢLᵢ(u₀), Σ wᵢLᵢ(u₁), t)
            // — the union curve is the law, exactly, with no error at all.
            // Every interval qualifies when the members share a knot set, which
            // is why a SELF-BLEND is the identity structurally.
            //
            // It fails only where a member's segment is WIDER than the interval
            // (its cosine is at a different phase there). Those intervals, and
            // only those, are subdivided — which leaves the self-blend
            // untouched and confines the refinement to exactly the spans that
            // need it. Measured: the worst library pair drops from 0.132 to a
            // figure `EffortRingTests` pins.
            let ordered = positions.sorted()
            for j in 0..<(ordered.count - 1) {
                let lo = ordered[j], hi = ordered[j + 1]
                let exact = group.allSatisfy { member in
                    member.pattern.knots.contains { $0.u == lo }
                        && member.pattern.knots.contains { $0.u == hi }
                }
                guard !exact else { continue }
                for k in 1..<Blend.refinementSteps {
                    positions.insert(lo + (hi - lo) * Double(k) / Double(Blend.refinementSteps))
                }
            }

            let knots = positions.sorted().map {
                EffortPattern.Knot(u: $0, level: level(scope: scope, u: $0))
            }
            let dom = dominant
            return EffortPattern(
                id: group.count == 1 ? group[0].pattern.id : "blend",
                displayName: group.count == 1 ? group[0].pattern.displayName
                    : "\(dom.pattern.displayName) blend",
                scope: scope,
                summary: group.count == 1 ? group[0].pattern.summary
                    : "A blend of " + group.map(\.pattern.displayName).joined(separator: " and "),
                knots: knots)
        }

        /// §8.2 step 4 — the affine level map. Increasing in `level` for any
        /// `r > 0`, which is what makes every normalised geometry the store
        /// reads invariant under radius.
        ///
        /// ⚠️ `r == 1` short-circuits, and that is not micro-optimisation: it
        /// is a CORRECTNESS fix. `1 + 1 × (0.2 − 1)` is `0.19999999999999996`
        /// in binary floating point, not `0.2`, and that one ulp propagates
        /// through `(level − min) / travel` into `normalisedReleaseLevel`,
        /// where it broke exact reproduction by ~5 ulps. At the rim the map is
        /// the identity, so it returns the identity.
        public func radiusMapped(_ level: Double) -> Double {
            if radius == 1 { return level }
            if radius == 0 { return neutral }
            return neutral + radius * (level - neutral)
        }

        /// The whole field law across both axes at once (design §7.3's
        /// `effortRaw`): each scope contributes its own curve, weighted by its
        /// share of the dot.
        ///
        /// ⚠️ **The store does NOT call this**, and the reason is worth stating.
        /// A contour has two separate destinations — the *shape within a note*
        /// and the *level of that note within its phrase* — and this function
        /// collapses both into one scalar. That is exactly right for P3's
        /// continuous field and exactly wrong for a note the generator has to
        /// draw, where the note-scoped share belongs in the shape and the
        /// phrase-scoped share belongs in the level. It is here because it is
        /// the design's stated law and because it is the cheapest thing to test
        /// the weight algebra against.
        public func effort(noteU: Double, phraseU: Double) -> Double {
            noteWeight * level(scope: .note, u: noteU)
                + phraseWeight * level(scope: .phrase, u: phraseU)
        }
    }
}
