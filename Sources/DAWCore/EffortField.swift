import Foundation

// MARK: - THE PAD LAW

/// The breath pad's **continuous effort field** — the thing that makes the dot
/// move (breath pad P3, `docs/research/design-breath-pad.md` §5.1, §8.3, §8.4).
///
/// P2 gave the dot a *place* on the ring. This gives it a *path*: a fixed dot,
/// a steady orbit, or a seeded wander that flows from one gesture into the next
/// and back. That last one is the user's own words — "flow from one pattern to
/// the other, or even more patterns."
///
/// ---
///
/// # ⭐⭐⭐ THE PAD LAW — this file owns it
///
/// > **`effort` is a PURE FUNCTION of (musical position, seed, path). NEVER of
/// > wall-clock time, and NEVER of evaluation history.**
///
/// Concretely: `effort(atBeat: 33)` computed **cold**, in a freshly built
/// process, having evaluated nothing else, returns the bit-identical `Double`
/// you get by walking beats 0…33 in order. There is no `Date`, no
/// `mach_absolute_time`, no `Hasher`/`hashValue` (per-process seeded — it looks
/// deterministic inside one test process and is not), no un-seeded RNG, and no
/// `var` carried between calls anywhere in this file.
///
/// ## ⛔⛔ The trap this file exists to avoid: an integrating random walk
///
/// The obvious "random walk with momentum" is `v ← momentum·v + ε; p ← p + v`,
/// stepped once per unit of time. **It must not be used, and it is not used
/// here.** It is deterministic given a seed, it replays exactly from the start,
/// and it passes every naive reproducibility test — and it is still wrong,
/// because it is not *position-pure*: `p(b)` depends on having evaluated every
/// step from 0 to `b`. What that costs, all of it silent:
///
/// - `extendLoopMIDI` rebuilds each loop cycle's events from `loop.startBeat`
///   (`PlaybackGraph.swift:2923-2930`), so cycle 5 would take a different path
///   than cycle 1 over the *same* bars.
/// - A bounce starting at bar 33 would differ from playing through to bar 33.
/// - Seeking backward and playing again would give a different result.
///
/// The walk here is **position-pure fBm over a hashed integer lattice**
/// (§8.4). "Momentum" is the *spectral tilt of the noise*, not state carried
/// between calls — see `DotPath.drift` and `fbm(seed:at:octaves:persistence:)`. That is not a
/// discipline the tests police; it is what the arithmetic can express.
/// `Tests/DAWCoreTests/BreathPadDeterminismTests.swift` runs the discriminating
/// test against a deliberately-wrong accumulator kept in that file as a
/// **negative control**, and asserts the accumulator *fails*.
///
/// ---
///
/// # Which beat: CLIP-RELATIVE, and that is a decision with consequences
///
/// Every `beat` in this file is **clip-relative** — the same coordinate
/// `MIDINote.startBeat` and `PhraseDetection.Phrase.startBeat` use.
///
/// It is deliberate and it is not free. The pad's output is *committed into the
/// clip's controller lanes* (§5.2: the lane is the record), and the loop
/// unroller **copies** that lane per cycle. So a timeline-relative field would
/// promise per-cycle variation that the write path structurally cannot deliver:
/// you would compute a different dot for cycle 5 and then render cycle 1's
/// bytes anyway. Clip-relative makes loop-cycle invariance *structural* rather
/// than aspirational — the same bar of the clip is the same beat, always.
///
/// ---
///
/// # ⚠️ What this field CANNOT deliver, measured rather than hoped
///
/// 1. **The dot is sampled once per note, at the note's start.** That is P3's
///    real resolution limit and it is much lower than any render-block rate:
///    a path whose top octave moves faster than the notes arrive is aliased by
///    the note grid, and the store warns when it does
///    (`EffortField.Excursion.outrunsNotes`). A dot cannot shape *within* a
///    note — that is what the note-scoped patterns are for.
/// 2. **On the hosted-AU path (every `.soundBank` track, so the user's GM sax)
///    nothing above ~5.86 Hz survives a bounce.** MEASURED 2026-08-19
///    (`docs/research/measure-gm-sax-cc.md`): 4096-frame blocks ⇒ an 11.719 Hz
///    effective sampler ⇒ 5.86 Hz Nyquist. P1 already suppresses bend vibrato
///    there for exactly this reason and keeps doing so. **This constrains P5,
///    not P3**: P3's dot moves at the note rate (fractions of a Hz), so it is
///    two orders of magnitude clear of that ceiling — but §10.1's 4–8 Hz
///    micro-tremor is *not*. Stated here rather than discovered later by
///    generating something that silently aliases.
///    ⭐ **P5 MEASURED THE CC HALF, which this comment used to record as merely
///    derived, and the answer is worse than "the top of the band".** The 11.719
///    Hz figure came from a *bend* measurement; the obvious escape was to
///    deliver modulation amplitude-side on CC 11 instead, so P5 measured that
///    path directly (`SoundBankHostingTests` T5): an 8 Hz CC 11 modulation on
///    the stock GM alto sax returns **2.14× more energy at 3.719 Hz than at
///    8 Hz**, against 0.043 on the built-in sampler. CC is re-sampled exactly
///    as bend is. The ratio obeys `f / (f_s − f)` at four measured rates, so at
///    the band's *bottom* (4 Hz) the image is already 52 % of the tremor —
///    **the whole 4–8 Hz band is compromised there, not just its top.** See
///    `modulationImageRatio(rateHz:samplingHz:)`.
/// 3. **A drift is reproducible but not editable.** It is a fixed function of
///    its seed; a user who likes one bar of it and wants to keep it must commit
///    it and edit the lane. §8.4 states this and it is still true.
public enum EffortField {

    // MARK: - The pinned hash

    /// **splitmix64, written out and pinned** — the whole field's only source
    /// of randomness (§8.4).
    ///
    /// ⛔ **Never `Hasher`/`hashValue` here.** Swift's `Hasher` is seeded per
    /// process, so it produces different values in different runs. Inside one
    /// test process it looks perfectly deterministic; across a save/reopen it
    /// silently re-voices the project. That is this tree's characteristic
    /// failure wearing a hash function.
    ///
    /// `BreathPadDeterminismTests` pins `splitmix64(seed: 1, 0…7)` to eight
    /// literal `UInt64`s, so a future "optimisation" of this function reddens a
    /// test instead of changing every project's sound.
    ///
    /// This is the stateless form: the caller's `index` is folded in with the
    /// golden-ratio increment instead of advancing a stored state, which is
    /// what makes it a *hash of a position* rather than a generator.
    public static func splitmix64(seed: UInt64, _ index: UInt64) -> UInt64 {
        var z = seed &+ (index &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A seed for one *domain* of the field (angle, radius, and later tremor),
    /// derived by hashing rather than by arithmetic on the user's seed.
    ///
    /// ⚠️ **This deviates from §8.4, which writes `seed ⊕ j`, and the deviation
    /// is a correctness fix rather than taste.** With XOR of a small integer,
    /// seed 4's octave 1 uses `4 ⊕ 1 == 5`, which is *seed 5's octave 0* — so
    /// two neighbouring seeds share a whole octave of noise at a 2:1 frequency
    /// ratio. "Change the seed and you get a different performance" would then
    /// be only three-quarters true, in a way that a "the samples differ" test
    /// cannot see. Hashing the domain index decorrelates them, and
    /// `BreathPadDeterminismTests` measures the residual correlation between
    /// adjacent seeds at every lag, with a positive control proving the
    /// correlator can report 1.
    public static func derivedSeed(_ seed: UInt64, domain: UInt64) -> UInt64 {
        splitmix64(seed: seed &+ 0x243F_6A88_85A3_08D3, domain)
    }

    // MARK: - Value noise

    /// One lattice sample, in −1…1. Stateless: it reads `index` and nothing
    /// else, so any lattice point can be evaluated cold.
    ///
    /// Uses the top 53 bits, which is exactly the mantissa width of a `Double`,
    /// so the mapping to −1…1 loses nothing and is the same on every platform
    /// with IEEE 754 doubles.
    public static func noise1D(seed: UInt64, at index: Int64) -> Double {
        let bits = splitmix64(seed: seed, UInt64(bitPattern: index))
        let unit = Double(bits >> 11) * (1.0 / 9_007_199_254_740_992.0)  // 2⁻⁵³
        return unit * 2 - 1
    }

    /// The largest lattice index the field will address. Beyond it the position
    /// is clamped rather than allowed to overflow `Int64`: a project cannot
    /// reach beat 2⁵⁰ (that is ~10¹⁰ years at 120 BPM), so clamping there costs
    /// nothing real and removes an undefined-behaviour edge from a pure
    /// function that must never trap.
    private static let latticeLimit = Double(Int64(1) << 50)

    /// Value noise with cosine interpolation between lattice points (§8.4).
    /// C¹-continuous at the lattice, which is what stops the dot's motion
    /// having audible corners.
    ///
    /// Non-finite input returns 0 rather than propagating NaN — the field is a
    /// control signal that lands in a CC lane, and a NaN there would become a
    /// clamp to 0 or 127 somewhere far away with nothing naming the cause.
    public static func smoothNoise(seed: UInt64, at x: Double) -> Double {
        guard x.isFinite else { return 0 }
        let clamped = min(latticeLimit, max(-latticeLimit, x))
        let base = clamped.rounded(.down)
        let frac = clamped - base
        let index = Int64(base)
        return BreathContour.cosineBlend(noise1D(seed: seed, at: index),
                                         noise1D(seed: seed, at: index &+ 1),
                                         frac)
    }

    /// The default number of fBm octaves. Four is enough for the motion to stop
    /// looking like a single sine without the top octave outrunning the note
    /// grid at ordinary settings (§8.4).
    public static let defaultOctaves = 4
    /// Upper bound on octaves. Above 8 the top octave is 128× the base rate,
    /// which the note grid cannot sample at any musical tempo — so the extra
    /// octaves are not detail, they are aliasing.
    public static let maxOctaves = 8

    /// **Fractional Brownian motion over the hashed lattice — the whole random
    /// walk** (§8.4). Position-pure by construction: it reads `x`, and nothing
    /// else.
    ///
    /// Output is bounded in −1…1 (the octave weights are normalised to sum to
    /// 1 and every octave is bounded by 1), which is what lets the callers
    /// treat `angleSwing`/`radiusSwing` as honest maxima rather than as
    /// "roughly this much".
    ///
    /// ## `persistence`, spelled as §8.4 spells it
    ///
    /// ```
    /// fbm = Σ_j persistence^j · smoothNoise(derivedSeed(seed, j), x · 2^j) / Σ_j persistence^j
    /// ```
    ///
    /// - `persistence → 0`: only the base octave survives ⇒ long, lazy travel.
    /// - `persistence → 1`: every octave at equal weight ⇒ twitchy.
    /// - `persistence == 0.5`: amplitude halving per frequency doubling ⇒ a
    ///   spectrum near **1/f** — §10.2's figure.
    ///
    /// ⚠️ This parameter is **not** the user-facing `momentum` knob, and the
    /// two run in opposite directions. §8.4 uses one word for both and
    /// contradicts itself doing it; the inversion is done once, visibly, at
    /// `DotPath.drift`, which is the only place a user's number arrives. See
    /// that case for the argument.
    public static func fbm(seed: UInt64, at x: Double,
                           octaves: Int = defaultOctaves,
                           persistence rawPersistence: Double = 0.5) -> Double {
        guard x.isFinite else { return 0 }
        let count = min(maxOctaves, max(1, octaves))
        let persistence = rawPersistence.isFinite ? min(1, max(0, rawPersistence)) : 0.5
        var sum = 0.0
        var norm = 0.0
        var amplitude = 1.0
        var frequency = 1.0
        for j in 0..<count {
            sum += amplitude * smoothNoise(seed: derivedSeed(seed, domain: UInt64(j)),
                                           at: x * frequency)
            norm += amplitude
            amplitude *= persistence
            frequency *= 2
            // persistence 0 ⇒ every later octave contributes exactly nothing;
            // stopping is not an optimisation, it is what keeps `norm` from
            // being the only thing distinguishing 1 octave from 8.
            if amplitude == 0 { break }
        }
        guard norm > 0 else { return 0 }
        let out = sum / norm
        return out.isFinite ? min(1, max(-1, out)) : 0
    }
}

// MARK: - Where the dot is

/// A dot position on the ring: **angle in radians, unwrapped**, and radius.
///
/// ⚠️ The angle is deliberately *not* wrapped into 0..<2π. An orbit integrates
/// an angle without limit, and the excursion report needs to say "the dot went
/// round twice" rather than "it ended up at 12°". `EffortRing.blend(atAngle:)`
/// wraps, so nothing downstream cares.
public struct DotPosition: Sendable, Equatable, Codable {
    /// Radians, unwrapped, measured the same way `EffortRing.angle(ofIndex:)` is.
    public var angle: Double
    /// 0…1. Clamped on construction, because every consumer clamps anyway and
    /// an unclamped radius reaching a report would read as a real value.
    public var radius: Double

    public init(angle: Double, radius: Double) {
        self.angle = angle.isFinite ? angle : 0
        self.radius = radius.isFinite ? min(1, max(0, radius)) : 1
    }

    /// The dot parked on the first pattern at full radius — P1's implicit
    /// position, so `DotPath.fixed` from this origin is P1's behaviour exactly.
    public static let origin = DotPosition(angle: 0, radius: 1)
}

/// How the dot moves as the music plays (§8.3).
///
/// **Every variant is a pure function of beat.** The path produces an *offset
/// from an origin*, and the origin is what the hand sets — the Wavestation
/// lesson (§3.2): grabbing the dot during an orbit relocates the orbit instead
/// of cancelling it.
///
/// ## What is NOT here, and why
///
/// §8.3 also lists `.drawn(points:)` and `.musical(...)`. Neither is built:
///
/// - **`.drawn`** is the commit-time target of "record my dot drag", and the
///   drag does not exist until P7. Building the knot format now would fix a
///   wire shape for a producer that has not been written, and P2 already
///   declined `clip.getEffortField` on the same reasoning. It is a *storage*
///   feature, not a maths one, and it costs the same in P7 as it does today.
/// - **`.musical`** derives angle and radius from the notes themselves. It is
///   the one variant whose *musical* rule is unspecified in the design (which
///   direction does density push the radius, and how far?), and inventing that
///   rule here would ship an estimate as a mechanism. It is also the only path
///   that is not reproducible under editing: changing one note would move the
///   dot everywhere, which the user has no way to predict.
public enum DotPath: Sendable, Equatable {

    /// Which way round the ring an orbit travels. `clockwise` is the direction
    /// of increasing pattern index, so an orbit visits the ring in the order the
    /// caller listed it.
    public enum Direction: String, Sendable, Equatable, CaseIterable, Codable {
        case clockwise
        case counterclockwise

        var sign: Double { self == .clockwise ? 1 : -1 }
    }

    /// The dot does not move. P1 and P2's behaviour, exactly.
    case fixed

    /// A steady revolution: `φ(b) = φ₀ + 2π · (b / revolutionBeats) · dir`.
    /// Radius is the origin's, untouched — an orbit changes *which* gesture,
    /// never *how much*.
    ///
    /// ⚠️ There is no `phase` parameter although §8.3 lists one: the origin
    /// angle **is** the phase. Two controls for one quantity is the ambiguity
    /// §7.2 rejects, and the wire already has `ringAngle`.
    case orbit(revolutionBeats: Double, direction: Direction)

    /// The seeded wander (§8.4). fBm on the angle, optionally on the radius.
    ///
    /// - `scaleBeats`: how many beats one unit of noise spans. Bigger is
    ///   slower. Default 8 (§10.2's figure, an **estimate**).
    /// - `octaves` / `momentum`: the spectral shape.
    ///
    ///   ## ⚠️ `momentum` is LAZINESS — the reciprocal of §8.4's persistence,
    ///   and the inversion happens HERE, once
    ///
    ///   §8.4 writes the sum as `Σ m^j · noise(x·2^j)` **and** says "high
    ///   momentum ⟹ low frequencies dominate ⟹ long, lazy travel". Those are
    ///   opposites: in that sum `m` is the amplitude of the *faster* octaves,
    ///   so raising it makes the path **twitchier**, not lazier.
    ///
    ///   This honours the **prose**, because the prose is what the user asked
    ///   for ("flow from one pattern to the other") and a knob named momentum
    ///   whose high end is jitter would be indefensible in a UI:
    ///   `persistence = 1 − momentum`, applied in `offset(atBeat:seed:)` and
    ///   nowhere else.
    ///
    ///   - `momentum → 1` ⇒ persistence 0 ⇒ one octave ⇒ long, lazy travel.
    ///   - `momentum → 0` ⇒ persistence 1 ⇒ equal octaves ⇒ twitchy.
    ///   - `momentum == 0.5` ⇒ persistence 0.5 ⇒ ≈1/f. ⭐ The mapping is a
    ///     reflection about 0.5, so §10.2's one numeric claim ("momentum 0.5
    ///     with octave-doubling gives ≈1/f", which P5 reuses) comes out at the
    ///     **same number** under either reading. That is what makes the
    ///     correction safe: it moves the ends and fixes the midpoint in place.
    ///
    ///   `BreathPadDeterminismTests` pins the direction by measuring
    ///   high-frequency energy, so it cannot silently flip back.
    /// - `angleSwingRadians`: the maximum excursion either side of the origin
    ///   angle. `fbm` is bounded by 1, so this is an honest maximum.
    /// - `radiusSwing`: the same, on radius, clamped into 0…1 afterwards.
    ///   **Defaults to 0** so the default drift moves the dot *around* the ring
    ///   without also changing how strongly the gesture is applied — one visible
    ///   outcome, one cause.
    case drift(scaleBeats: Double, octaves: Int, momentum: Double,
               angleSwingRadians: Double, radiusSwing: Double)

    /// §10.2's estimate, reused: the beat scale at which a wander reads as
    /// phrasing rather than as wobble.
    public static let defaultScaleBeats = 8.0
    /// One pattern spacing on the default 8-pattern ring. The dot reaches its
    /// neighbour and no further, which is what "flow from one pattern to the
    /// other" asks for at its smallest honest setting.
    public static let defaultAngleSwingRadians = Double.pi / 4
    /// See `drift`: radius is left alone by default.
    public static let defaultRadiusSwing = 0.0
    /// §10.2's 1/f point, and the midpoint of the momentum knob.
    public static let defaultMomentum = 0.5

    /// A drift with every default filled in — the "just make it wander" form.
    public static var drifting: DotPath {
        .drift(scaleBeats: defaultScaleBeats,
               octaves: EffortField.defaultOctaves,
               momentum: defaultMomentum,
               angleSwingRadians: defaultAngleSwingRadians,
               radiusSwing: defaultRadiusSwing)
    }

    /// A short, stable id for reports and the wire.
    public var id: String {
        switch self {
        case .fixed: return "fixed"
        case .orbit: return "orbit"
        case .drift: return "drift"
        }
    }

    /// An octave carrying less than this share of the base octave's amplitude
    /// is not what the path sounds like. **(estimate)** — but a load-bearing
    /// one, so it is a named constant rather than a literal in a comparison.
    ///
    /// The alternative, judging a path by its literal top octave, was tried and
    /// MEASURED to be useless: at the recommended defaults (persistence 0.5,
    /// 4 octaves) the top octave carries **6.7 %** of the total amplitude, so
    /// the aliasing warning fired on ordinary, correct settings. A warning that
    /// fires on the defaults is a warning nobody reads.
    public static let audibleOctaveShare = 0.2

    /// Cycles per beat of this path's fastest component **that carries real
    /// energy** — what the note grid actually has to sample. `nil` for
    /// `.fixed`, which has no rate at all.
    ///
    /// An orbit's only component is its revolution. A drift's is its highest
    /// octave whose relative amplitude is still at least `audibleOctaveShare`;
    /// octaves quieter than that are texture, and treating them as the signal
    /// makes every setting look like an aliasing bug.
    public var effectiveRateCyclesPerBeat: Double? {
        switch self {
        case .fixed:
            return nil
        case let .orbit(revolutionBeats, _):
            guard revolutionBeats > 0 else { return nil }
            return 1 / revolutionBeats
        case let .drift(scaleBeats, octaves, momentum, angleSwing, radiusSwing):
            guard scaleBeats > 0, angleSwing != 0 || radiusSwing != 0 else { return nil }
            let count = min(EffortField.maxOctaves, max(1, octaves))
            let persistence = 1 - (momentum.isFinite ? min(1, max(0, momentum)) : 0.5)
            var top = 0
            var amplitude = 1.0
            for j in 1..<count {
                amplitude *= persistence
                if amplitude >= Self.audibleOctaveShare { top = j } else { break }
            }
            return Double(1 << top) / scaleBeats
        }
    }

    /// The path's offset from the origin at a beat. **Pure**: it reads `beat`
    /// and `seed`, and touches nothing else.
    ///
    /// `beat` is CLIP-RELATIVE — see `EffortField`'s header for why that is the
    /// coordinate and what it costs.
    public func offset(atBeat beat: Double, seed: UInt64) -> (angle: Double, radius: Double) {
        guard beat.isFinite else { return (0, 0) }
        switch self {
        case .fixed:
            return (0, 0)
        case let .orbit(revolutionBeats, direction):
            guard revolutionBeats > 0 else { return (0, 0) }
            return (2 * .pi * (beat / revolutionBeats) * direction.sign, 0)
        case let .drift(scaleBeats, octaves, momentum, angleSwing, radiusSwing):
            guard scaleBeats > 0 else { return (0, 0) }
            let x = beat / scaleBeats
            // ⭐ THE ONE PLACE momentum becomes persistence. See the doc comment
            // on this case: the design's word and the design's formula disagree,
            // and this line is where that is resolved, visibly, once.
            let persistence = 1 - (momentum.isFinite ? min(1, max(0, momentum)) : 0.5)
            // Two INDEPENDENT domains of the same seed, not one field read
            // twice: sharing it would lock radius to angle, so every time the
            // dot leaned toward one gesture it would also lean out — a
            // correlation nobody asked for and nobody could switch off.
            let a = EffortField.fbm(seed: EffortField.derivedSeed(seed, domain: 0x1000),
                                    at: x, octaves: octaves, persistence: persistence)
            let r = EffortField.fbm(seed: EffortField.derivedSeed(seed, domain: 0x2000),
                                    at: x, octaves: octaves, persistence: persistence)
            return (angleSwing * a, radiusSwing * r)
        }
    }
}

// MARK: - The field

extension EffortField {

    /// Everything the field needs to answer `effort(atBeat:)`: the ring of
    /// gestures, where the hand put the dot, how it moves, and the seed that
    /// makes a wander this wander rather than another.
    ///
    /// §8.5's `BreathPadSettings` is a superset of this — it also carries the
    /// per-destination depths, P4's air budget and P5's tremor. Those are not
    /// here because they do not exist yet; adding them later is additive.
    ///
    /// ⚠️ **The seed lives here, not in `DotPath.drift`** although §8.3 puts it
    /// in the case. One seed for the whole field is what lets P5's tremor be
    /// *decorrelated from* the drift by domain rather than *identical to* it by
    /// accident, and it keeps "reseed this pad" a single number the user can
    /// change without re-stating the path.
    public struct Settings: Sendable, Equatable {
        public var ring: EffortRing
        /// What the hand set (§8.3). The path is an offset from here.
        public var origin: DotPosition
        public var path: DotPath
        public var seed: UInt64
        /// What radius 0 collapses to. **1, not §8.2's estimated 0.5** — see
        /// `EffortRing.defaultNeutral`: effort 1 means "as authored", so 0.5 at
        /// radius 0 would drop the part ≈2.8 dB from a control that only says
        /// how far out the dot is.
        public var neutral: Double

        public init(ring: EffortRing = .standard,
                    origin: DotPosition = .origin,
                    path: DotPath = .fixed,
                    seed: UInt64 = 0,
                    neutral: Double = EffortRing.defaultNeutral) {
            self.ring = ring
            self.origin = origin
            self.path = path
            self.seed = seed
            self.neutral = neutral
        }
    }

    /// Where the dot is at a (clip-relative) beat. Pure; see THE PAD LAW.
    public static func dot(atBeat beat: Double, settings: Settings) -> DotPosition {
        let offset = settings.path.offset(atBeat: beat, seed: settings.seed)
        return DotPosition(angle: settings.origin.angle + offset.angle,
                           radius: settings.origin.radius + offset.radius)
    }

    /// The blend at the **origin** — where the hand put the dot, with the path's
    /// offset left out entirely.
    ///
    /// ⚠️ This is NOT `blend(atBeat: 0)`, and the difference is a bug I shipped
    /// for an hour and a test caught: at beat 0 a drift already has an offset
    /// (fBm is not 0 at x = 0), so a result that called that "the origin" would
    /// report an angle the hand never set — 168.7° for a dot placed at 157.5°.
    /// A report has to answer the question the caller asked, and the caller
    /// asked for `ringAngle`.
    public static func originBlend(settings: Settings) -> EffortRing.Blend {
        settings.ring.blend(atAngle: settings.origin.angle,
                            radius: settings.origin.radius,
                            neutral: settings.neutral)
    }

    /// The dot resolved into a blend of ring gestures at that beat.
    ///
    /// This is the entry point the store uses: it asks once per note, at the
    /// note's start beat, and shapes that note with the answer.
    public static func blend(atBeat beat: Double, settings: Settings) -> EffortRing.Blend {
        let position = dot(atBeat: beat, settings: settings)
        return settings.ring.blend(atAngle: position.angle,
                                   radius: position.radius,
                                   neutral: settings.neutral)
    }

    /// **The top-level field law.** How hard the player is blowing at a
    /// clip-relative beat, given where that beat sits inside its note and
    /// inside its phrase.
    ///
    /// Returns 0…1-ish (bounded by the ring's own levels), where 1 is "as
    /// authored" — the `BreathContour.scaled` convention, not a 0.5-centred one.
    ///
    /// ## What `phrase` and `note` are for
    ///
    /// The ring holds two *kinds* of gesture and they read different
    /// coordinates: a `.note`-scoped pattern is a shape *within* one note, a
    /// `.phrase`-scoped one is an arc *across* a phrase. So the field needs both
    /// positions, and `EffortRing.Blend.effort(noteU:phraseU:)` weighs each
    /// kind by its share of the dot.
    ///
    /// ⚠️ **Both are optional and the fallback is 0.5**, stated rather than
    /// hidden: with no note (or no phrase) the corresponding scope has no
    /// domain, and mid-gesture is the least-wrong constant. It is the same
    /// fallback `ProjectStore.applyEffortShape` already makes for a note whose
    /// phrase cannot be located, so the two cannot disagree.
    ///
    /// ⚠️ **This is NOT what the store writes into a lane**, and that is
    /// deliberate — `EffortRing.Blend.effort` collapses both axes into one
    /// scalar, which is right for a continuous field (this function, P4's air
    /// sweep, and a future readout) and wrong for a note the generator has to
    /// draw, where the note-scoped share belongs in the note's *shape* and the
    /// phrase-scoped share in its *level*. See `ProjectStore+BreathPad.swift`.
    public static func effort(atBeat beat: Double,
                              settings: Settings,
                              phrase: PhraseDetection.Phrase? = nil,
                              note: MIDINote? = nil) -> Double {
        let blended = blend(atBeat: beat, settings: settings)
        let noteU: Double
        if let note, note.lengthBeats > 0 {
            noteU = min(1, max(0, (beat - note.startBeat) / note.lengthBeats))
        } else {
            noteU = 0.5
        }
        let phraseU = phrase?.position(ofBeat: beat) ?? 0.5
        return blended.effort(noteU: noteU, phraseU: phraseU)
    }

    // MARK: - What the dot actually did

    /// A legible, falsifiable account of the dot's travel over a set of sampled
    /// beats — the answer to "did it actually move?", which is the question this
    /// tree's characteristic defect (a plausible-looking inert result) turns on.
    public struct Excursion: Sendable, Equatable {
        /// The path that produced it.
        public var pathID: String
        /// Unwrapped angular travel, in degrees: `max − min` over the samples.
        /// 0 means the dot never moved, whatever the path claimed to be.
        public var angleSweepDegrees: Double
        /// Wrapped, for reading: where the dot was at the first and last sample.
        public var startAngleDegrees: Double
        public var endAngleDegrees: Double
        public var minRadius: Double
        public var maxRadius: Double
        /// Every pattern that held a non-zero weight at any sample, in ring
        /// order. On a fixed dot this is the one or two the dot sits between; a
        /// wander that never leaves them is a wander that did nothing musical,
        /// and this is how a caller can see that.
        public var patternIDs: [String]
        /// The dot's fastest energy-carrying component, in cycles per beat, and
        /// the rate at which the notes sample it. `outrunsNotes` is the honest
        /// comparison of the two.
        public var effectiveRateCyclesPerBeat: Double?
        public var noteRatePerBeat: Double
        /// How far apart the ring's gestures are, in degrees — what a travel
        /// figure has to be compared against to mean anything.
        public var ringSpacingDegrees: Double

        /// True when the dot completes **more cycles per beat than notes
        /// arrive** — it is literally outrunning the grid that samples it, and
        /// what you hear is an alias of the motion rather than the motion.
        ///
        /// ⚠️ **Deliberately NOT `> noteRate / 2`, the Nyquist limit.** Above
        /// Nyquist you begin to lose detail; above the note rate itself you are
        /// guaranteed to be hearing something that is not what was asked for.
        /// The stricter test was tried and fires on correct, ordinary settings
        /// (a `scaleBeats: 8` drift over half notes), which would make this
        /// sentence noise. The doc comment on `EffortField` states the Nyquist
        /// limit as the theory; this fires at the point where it is unarguable.
        public var outrunsNotes: Bool {
            guard let rate = effectiveRateCyclesPerBeat, noteRatePerBeat > 0 else { return false }
            return rate > noteRatePerBeat
        }

        /// True when the dot moved but its whole travel is smaller than a
        /// quarter of the gap between gestures — it wandered inside one
        /// gesture, so nothing blended and the wander is musically inert.
        ///
        /// ⚠️ **Not "it only touched one pattern".** That was tried and is
        /// wrong: a 2° wander around a dot parked exactly ON a pattern straddles
        /// the boundary and touches *two*, at weights of a few thousandths.
        /// Counting touched patterns therefore reports a blend that is not
        /// audible and misses the case this is for. Travel against spacing is
        /// the same question asked in the unit the ring is actually built in.
        public var travelIsInsideOneGesture: Bool {
            guard moved, ringSpacingDegrees > 0 else { return false }
            return angleSweepDegrees < ringSpacingDegrees / 4
        }

        /// Did the dot move at all, to a resolution anyone could hear? A tenth
        /// of a degree is far below the blend's audible resolution, so anything
        /// under it is arithmetic noise, not motion.
        public var moved: Bool { angleSweepDegrees > 0.1 || maxRadius - minRadius > 0.001 }
    }

    /// Samples the path at the given (clip-relative) beats and reports what it
    /// did. The beats are the note starts, because that is exactly where the
    /// store asks — a report built from a different sampling would describe a
    /// dot the music never saw.
    ///
    /// (P5's humanisation is deliberately **not** in this report: drift moves
    /// the effort a note is written at, not where the dot is, and folding it in
    /// here would make `angleSweepDegrees` describe travel the path never had.)
    public static func excursion(atBeats beats: [Double], settings: Settings) -> Excursion {
        guard !beats.isEmpty else {
            return Excursion(pathID: settings.path.id, angleSweepDegrees: 0,
                             startAngleDegrees: EffortRing.degrees(fromRadians: settings.origin.angle),
                             endAngleDegrees: EffortRing.degrees(fromRadians: settings.origin.angle),
                             minRadius: settings.origin.radius, maxRadius: settings.origin.radius,
                             patternIDs: [],
                             effectiveRateCyclesPerBeat: settings.path.effectiveRateCyclesPerBeat,
                             noteRatePerBeat: 0,
                             ringSpacingDegrees: 360 / Double(max(1, settings.ring.count)))
        }
        var minAngle = Double.greatestFiniteMagnitude
        var maxAngle = -Double.greatestFiniteMagnitude
        var minRadius = Double.greatestFiniteMagnitude
        var maxRadius = -Double.greatestFiniteMagnitude
        var touched = Set<Int>()
        var first = DotPosition.origin
        var last = DotPosition.origin
        for (i, beat) in beats.enumerated() {
            let position = dot(atBeat: beat, settings: settings)
            if i == 0 { first = position }
            last = position
            minAngle = min(minAngle, position.angle)
            maxAngle = max(maxAngle, position.angle)
            minRadius = min(minRadius, position.radius)
            maxRadius = max(maxRadius, position.radius)
            for (index, weight) in settings.ring.weights(atAngle: position.angle).enumerated()
            where weight > 0 {
                touched.insert(index)
            }
        }
        // The note rate the path is judged against is measured from the SPAN,
        // not from an average gap: a phrase of quavers followed by a long note
        // samples the path at the quaver rate over that stretch, and the span
        // form is the conservative reading of the two.
        let span = (beats.max() ?? 0) - (beats.min() ?? 0)
        let noteRate = span > 0 ? Double(beats.count - 1) / span : 0
        return Excursion(
            pathID: settings.path.id,
            // ⚠️ NOT `EffortRing.degrees(fromRadians:)` — that wraps, and a
            // wrapped sweep would report an orbit that went round three times
            // as having travelled 0°. The sweep is the one angle in this file
            // that must stay unwrapped.
            angleSweepDegrees: (maxAngle - minAngle) * 180 / .pi,
            startAngleDegrees: EffortRing.degrees(fromRadians: first.angle),
            endAngleDegrees: EffortRing.degrees(fromRadians: last.angle),
            minRadius: minRadius, maxRadius: maxRadius,
            patternIDs: touched.sorted().map { settings.ring.patterns[$0].id },
            effectiveRateCyclesPerBeat: settings.path.effectiveRateCyclesPerBeat,
            noteRatePerBeat: noteRate,
            // ⚠️ NOT `EffortRing.degrees(fromRadians: ring.spacing)` — that
            // WRAPS, and a ring of one has spacing 2π, which wraps to 0. Divided
            // out directly it reports 360°, so on a ring of one no travel is
            // ever "inside one gesture" — which is the right answer twice over:
            // there is nothing to blend into, so the sentence would name a fix
            // that does not exist.
            ringSpacingDegrees: 360 / Double(max(1, settings.ring.count)))
    }
}

// MARK: - Physiological humanisation (breath-pad P5, §10)

extension EffortField {

    /// §10's two involuntary layers: a slow **1/f drift** in the baseline and a
    /// **micro-tremor** inside each note. Both are estimates, both are
    /// parameterised, and — the point of this type — **both default to OFF, so
    /// `.none` reproduces the pre-P5 tree bit-for-bit.**
    ///
    /// ⚠️ **The defaults deviate from §10 and §10 contradicts itself here.**
    /// §10.1 gives `tremorDepth` a default of 0.03 and §10.2 gives `driftDepth`
    /// a default of 0.05, while §13.5 requires that "**at the default value**
    /// the rendered bytes are identical to the pre-feature tree". Those cannot
    /// both hold. §13.5 wins: it is the property that makes each knob
    /// individually declinable after the fact, and §10's numbers survive as the
    /// *suggested* values, quoted in each doc comment with the dB they were
    /// measured to be worth.
    ///
    /// ## What is estimated and what is measured
    ///
    /// The *shapes* here are estimates — no measurement of involuntary tremor
    /// or of 1/f structure in wind-instrument breath pressure was found, and
    /// §10 says so. What is **measured** is what the delivery path does to
    /// them, and that is the part that determines the defaults: see
    /// `modulationImageRatio(rateHz:samplingHz:)`.
    public struct Humanisation: Sendable, Equatable {

        // MARK: 1/f drift (§10.2)

        /// How far the effort baseline is allowed to sag, as a fraction of the
        /// requested effort. **Default 0 (off).** §10.2 suggests 0.05.
        ///
        /// ⭐ **The drift is DOWNWARD ONLY, and that is a correctness fix, not
        /// a simplification.** `BreathContour.scaled` clamps effort to 0…1 and
        /// derives everything from the *shortfall* `1 − effort`, and on a
        /// note-scoped pattern every note sits at effort exactly **1** (P1's
        /// finding 5). A symmetric ±d drift there is therefore **half
        /// rectified**: the positive half is the identity because it clamps,
        /// the negative half attenuates, and what ships is a one-sided downward
        /// flicker with a lowered mean — wearing the name "drift" while being
        /// something else. Making it explicitly one-sided also matches the
        /// model's own units: effort 1 means "as authored", i.e. the ceiling,
        /// and there is no "louder than authored" for a player to drift into.
        ///
        /// So the written effort wanders in `[e·(1 − driftDepth), e]` and the
        /// mean cost is about half of `driftDepth`.
        public var driftDepth: Double

        /// The drift's period, in beats — one lattice step of the fBm. **Default
        /// 8** (§10.2's estimate): two bars of 4/4, far slower than any note
        /// rate, which is what keeps the note grid from aliasing it (§8.4's
        /// limit, and P3's `Excursion.outrunsNotes`).
        public var driftScaleBeats: Double

        /// fBm octaves for the drift. **Default `defaultOctaves` (4)** with
        /// persistence fixed at 0.5, which is the 1/f spectrum §10.2 asks for.
        ///
        /// ⚠️ **"Human breath pressure is 1/f" is a MODELLING CHOICE this
        /// design made, not a finding** — §10.2 says so in as many words.
        /// Flicker noise is well established as a general phenomenon and is a
        /// conventional pick for slow human control drift; no measurement of
        /// 1/f structure in wind breath pressure was found.
        public var driftOctaves: Int

        // MARK: Micro-tremor (§10.1)

        /// Peak-to-trough depth of the intra-note tremor, as a fraction of the
        /// contour level it rides on. **Default 0 (off).** §10.1 suggests 0.03.
        ///
        /// ⛔ **This is a fraction of the CONTOUR LEVEL, not of §10.1's "effort
        /// travel", and the difference is the whole feature.** At leg D's
        /// defaults `travel = peakValue × depth = 127 × 0.25 = 31.75 CC`, so
        /// §10.1's plain reading makes 0.03 mean **±0.95 CC — one integer
        /// step**, measured at **0.16 dB peak-to-trough** on the built-in
        /// sampler (`SoundBankHostingTests` T6). The feature would have shipped
        /// inaudible at its own suggested default. Against the contour level,
        /// 0.03 is 3.81 CC peak-to-trough at level 127 ⇒ **≈ 0.29 dB**, on a
        /// measured line of **0.0755 dB per CC of peak-to-trough travel**
        /// (measured at ±1, ±2, ±4 and ±8 CC; linear across all four).
        ///
        /// ⛔ **And it rides the CONTOUR, not `effort`.** §10.1 adds tremor to
        /// effort, but effort only reaches the lane through
        /// `BreathContour.EffortResponse.loudnessDepth`, whose default is the
        /// identity — so a tremor added to effort is **inert at the default
        /// response**, which is P1's finding 5 arriving a second time.
        ///
        /// Riding the level also gives §10.1's "deepens with effort" for free
        /// in CC terms: the same fraction of a quieter contour is fewer CC.
        public var tremorDepth: Double

        /// Tremor rate in Hz. **Default 4.565** — leg D's `vibratoRateHz` (5.5)
        /// times §10.1's suggested 0.83 detune, so tremor and vibrato are not
        /// one oscillator at one rate summing into a single deeper vibrato.
        ///
        /// ⛔ **Deliberately at the BOTTOM of §10.1's 4–8 Hz band, because the
        /// top of that band is not reachable on the path this exists for.** See
        /// `modulationImageRatio(rateHz:samplingHz:)` for the measurement.
        ///
        /// ⚠️ §10.1's preferred construction — drive the tremor from the fBm
        /// field at a higher octave, for a naturally irregular tremor rather
        /// than a sine — was **evaluated and rejected**: fBm puts energy at 2×
        /// and 4× the base rate, which is exactly where the ceiling below bites
        /// hardest (an octave at 2 × 4.565 = 9.13 Hz comes back at 2.59 Hz,
        /// *louder* than it went in), and it leaves the tremor with no single
        /// rate to check a ceiling against. A sine has one rate, so the ceiling
        /// is exactly statable.
        public var tremorRateHz: Double

        /// How the tremor deepens with effort: depth is scaled by
        /// `effort^tremorEffortExponent`. **Default 1** (§10.1's estimate —
        /// linear growth with effort). 0 makes the tremor effort-independent.
        public var tremorEffortExponent: Double

        /// ⛔⛔ **THE TREMOR RATE IS CLAMPED IN TWO PLACES AND THEY MUST AGREE.**
        /// `ProjectStore.applyEffortShape` derives each note's tremor PHASE from
        /// *this* struct's rate and hands `BreathContour.Options` the same
        /// number to OSCILLATE at — but `Options` sanitizes independently. If
        /// the two bands differ, a rate in the gap advances the phase at one
        /// rate and the waveform at another, so every note onset gets a growing
        /// phase discontinuity while both surfaces report a value that is "in
        /// range" on its own terms. That is a silently plausible wrong result
        /// reaching the one parameter whose entire job is to be checkable
        /// against a ceiling. Hence: **one band, declared once, referenced by
        /// both sanitizers**, and gated by `bothTremorRateClampsAgree`.
        ///
        /// The band is leg D's vibrato band, and its reasoning transfers: below
        /// 0.2 Hz a "tremor" is a drift, which is a different knob on this same
        /// struct; above 20 Hz it is a buzz, not a physiological gesture. Both
        /// ends sit far outside §10.1's 4–8 Hz band, and the 2.34 Hz hosted-AU
        /// ceiling this phase measured falls comfortably inside.
        public static let minTremorRateHz = 0.2
        public static let maxTremorRateHz = 20.0

        /// **The null.** Every knob off; the field behaves exactly as it did
        /// before P5, and `ProjectStore.applyEffortShape` writes byte-identical
        /// lanes. This is the value §13.5's null test is about.
        public static let none = Humanisation()

        /// True when this instance can change nothing. Both depths are the
        /// gates: a rate or a scale with no depth behind it is inert by
        /// construction, so a caller that set only those has still asked for
        /// nothing — and saying so is cheaper than letting them wonder.
        public var isIdentity: Bool { driftDepth <= 0 && tremorDepth <= 0 }

        public init(driftDepth: Double = 0,
                    driftScaleBeats: Double = 8,
                    driftOctaves: Int = EffortField.defaultOctaves,
                    tremorDepth: Double = 0,
                    tremorRateHz: Double = 4.565,
                    tremorEffortExponent: Double = 1) {
            self.driftDepth = driftDepth
            self.driftScaleBeats = driftScaleBeats
            self.driftOctaves = driftOctaves
            self.tremorDepth = tremorDepth
            self.tremorRateHz = tremorRateHz
            self.tremorEffortExponent = tremorEffortExponent
        }

        /// Domain-clamped copy. Called once at the store boundary so nothing
        /// downstream has to re-check, and so a hand-authored wire payload
        /// cannot reach the generator with a negative depth or a 0 Hz rate.
        public func sanitized() -> Humanisation {
            Humanisation(
                driftDepth: clampFinite(driftDepth, 0, 1, fallback: 0),
                driftScaleBeats: clampFinite(driftScaleBeats, 0.01, 4096, fallback: 8),
                driftOctaves: min(EffortField.maxOctaves, max(1, driftOctaves)),
                tremorDepth: clampFinite(tremorDepth, 0, 1, fallback: 0),
                tremorRateHz: clampFinite(tremorRateHz,
                                          Humanisation.minTremorRateHz,
                                          Humanisation.maxTremorRateHz,
                                          fallback: 4.565),
                tremorEffortExponent: clampFinite(tremorEffortExponent, 0, 8, fallback: 1))
        }

        private func clampFinite(_ value: Double, _ low: Double, _ high: Double,
                                 fallback: Double) -> Double {
            value.isFinite ? min(high, max(low, value)) : fallback
        }
    }

    // MARK: - The drift

    /// Domain index for the drift's noise, so it can never share a lattice with
    /// the dot path's angle (`0x1000`) or radius (`0x2000`) octaves — the whole
    /// reason `Settings.seed` is one seed for the field rather than a seed per
    /// case. A drift that moved in lockstep with the radius would read as one
    /// louder wander, not as two independent involuntary layers.
    static let driftDomain: UInt64 = 0x3000

    /// How much effort this beat gives up to the 1/f drift: **0 … driftDepth**,
    /// as a fraction, and never negative (see `Humanisation.driftDepth`).
    ///
    /// Pure and clip-relative, exactly like `dot(atBeat:settings:)` — so a
    /// looped clip drifts the same way on every cycle, which is P3's structural
    /// determinism law and not a coincidence to be re-derived here.
    ///
    /// The fBm is bounded in −1…1; mapping it through `(1 − n) / 2` gives a
    /// 0…1 shortfall whose *shape* is unchanged and whose mean is ½.
    public static func driftShortfall(atBeat beat: Double,
                                      seed: UInt64,
                                      humanisation: Humanisation) -> Double {
        let h = humanisation.sanitized()
        guard h.driftDepth > 0, beat.isFinite else { return 0 }
        let noise = fbm(seed: derivedSeed(seed, domain: driftDomain),
                        at: beat / h.driftScaleBeats,
                        octaves: h.driftOctaves,
                        persistence: 0.5)
        return h.driftDepth * (1 - noise) / 2
    }

    /// The requested effort for a note, after the drift has taken its cut.
    /// Clamped at 0 — a drift can flatten a note, never invert it.
    public static func drifted(effort: Double, atBeat beat: Double,
                               seed: UInt64, humanisation: Humanisation) -> Double {
        let shortfall = driftShortfall(atBeat: beat, seed: seed, humanisation: humanisation)
        return max(0, effort * (1 - shortfall))
    }

    // MARK: - The tremor

    /// Domain index for the tremor's phase offset — §10.1's requirement that
    /// tremor and vibrato "must not be the same oscillator at the same rate
    /// with the same phase".
    static let tremorPhaseDomain: UInt64 = 0x4000

    /// The tremor's phase at a clip-relative time, in radians: one continuous
    /// oscillator across the whole clip, seeded so two projects with different
    /// seeds do not start on the same crest.
    ///
    /// ⚠️ **Continuous across the clip, not restarted per note**, deliberately.
    /// A per-note phase reset puts a step in the pressure at every legato
    /// join — m27-o ⓑ deliberately overlaps those — and the involuntary layer
    /// is precisely the one that should not know where the notes are.
    public static func tremorPhase(atSeconds seconds: Double,
                                   seed: UInt64,
                                   humanisation: Humanisation) -> Double {
        let h = humanisation.sanitized()
        guard seconds.isFinite else { return 0 }
        let offset = Double(splitmix64(seed: derivedSeed(seed, domain: tremorPhaseDomain), 0)
            >> 11) * (1.0 / 9_007_199_254_740_992.0) * 2 * .pi
        return 2 * .pi * h.tremorRateHz * seconds + offset
    }

    /// The multiplier the tremor applies to the contour at `seconds` after the
    /// note's onset, given that note's `phase` at its onset: a value in
    /// `[1 − depth, 1]`.
    ///
    /// ⭐ **Downward-only, for the same reason the drift is** — and here there
    /// is a second, sharper reason. The contour's own peak is `peakValue`,
    /// which defaults to **127**, the top of the lane; a symmetric ripple would
    /// clamp there, so the tremor's upper half would vanish exactly on the
    /// loudest instant of every note while its lower half survived. That is a
    /// half-wave rectifier disguised as a tremor, and it would be invisible in
    /// any test that only asked "did the samples change?".
    /// ⭐ **THE ONE IMPLEMENTATION**, and it took a planted regression to make
    /// that true. This function first took a `Humanisation` and read the rate
    /// off it, which meant `BreathContour.generate` — whose rate lives in
    /// `Options` — could not call it and carried its own copy of the formula.
    /// A plant that made the GENERATOR's copy symmetric left this one's tests
    /// green: the pure test passed while the shipping arithmetic was wrong,
    /// which is a worse failure than duplication because it looks like
    /// coverage. `rateHz` is a plain parameter so there is one copy again.
    public static func tremorRipple(atSeconds seconds: Double,
                                    phaseAtOnset phase: Double,
                                    depth: Double,
                                    rateHz: Double) -> Double {
        // ⚠️ The literal 1.0, not a computed one: this is what makes the
        // generator's multiply bit-identical at depth 0 rather than merely
        // close, and §13.5's null test rests on it.
        guard depth > 0, seconds.isFinite, phase.isFinite, rateHz.isFinite else { return 1 }
        let d = min(1, max(0, depth))
        let angle = 2 * .pi * rateHz * seconds + phase
        return 1 - d * (1 + sin(angle)) / 2
    }

    /// This note's tremor depth: the requested depth deepened by effort, per
    /// §10.1's `tremorDepth · effort^tremorEffortExponent`.
    public static func tremorDepth(forEffort effort: Double,
                                   humanisation: Humanisation) -> Double {
        let h = humanisation.sanitized()
        guard h.tremorDepth > 0 else { return 0 }
        let e = min(1, max(0, effort))
        return h.tremorDepth * pow(e, h.tremorEffortExponent)
    }

    // MARK: - ⛔ The measured ceiling

    /// The **offline** rate, in Hz, at which a hosted Audio Unit re-samples the
    /// MIDI controller and pitch-bend lanes we write: `OfflineRenderer`'s
    /// default block of 4096 frames at 48 kHz = **11.71875 Hz**.
    ///
    /// ⛔ **MEASURED for CC 11 by breath-pad P5**
    /// (`SoundBankHostingTests` T5, 2026-08-19), not merely inherited from the
    /// bend measurement. `measure-gm-sax-cc.md` §2.3a measured the hold for
    /// *pitch bend*; §2.4 stated the mechanism as "AUSampler computes pitch per
    /// sample and merely reads its MIDI *inputs* per block", from which CC was
    /// only ever **derived**. P5 needed the CC answer — the obvious escape from
    /// the bend ceiling is to deliver modulation amplitude-side instead — so it
    /// measured it. There is no escape: an 8 Hz CC 11 modulation on the stock
    /// GM alto sax comes back with **2.14× more energy at 3.719 Hz than at
    /// 8 Hz**, against **0.043** on the built-in sampler and a no-lane floor
    /// 400× below.
    ///
    /// ⚠️ **This is a BOUNCE limit, and the cause is ours.** Live playback
    /// pulls at the hardware buffer size — at a typical 512 frames the sampling
    /// rate is 93.75 Hz and none of this applies. `measure-gm-sax-cc.md` §2.4
    /// calls the 4096-frame default a bounce-fidelity bug rather than a tuning
    /// problem, and P5 agrees: the right long-term fix is a smaller offline
    /// block, not a smaller tremor.
    public static let hostedAUOfflineModulationSamplingHz = 48_000.0 / 4_096.0

    /// How loud the sample-and-hold's first image is, relative to the
    /// modulation that was asked for, when a modulation at `rateHz` is
    /// re-sampled at `samplingHz`. The image sits at `|samplingHz − rateHz|`.
    ///
    /// ⭐ **Closed form, and MEASURED at four rates within 3 %.** A zero-order
    /// hold weights the fundamental by `sinc(f/f_s)` and the first image by
    /// `sinc((f_s − f)/f_s)`; the two sine terms are supplementary and cancel,
    /// leaving
    ///
    /// ```
    /// image / fundamental = f / (f_s − f)
    /// ```
    ///
    /// | f (Hz) | image at | measured | this formula |
    /// |---|---|---|---|
    /// | 2.0 | 9.719 Hz | 0.222 | 0.206 |
    /// | 4.0 | 7.719 Hz | 0.520 | 0.518 |
    /// | 5.5 | 6.219 Hz | 0.911 | 0.884 |
    /// | 8.0 | 3.719 Hz | **2.139** | 2.151 |
    ///
    /// (`SoundBankHostingTests` T5, stock GM alto sax through AUSampler,
    /// CC 11, RMS-envelope Goertzel.)
    ///
    /// ⛔ **What this says about §10.1's 4–8 Hz band is worse than "the top is
    /// unreachable".** At the band's *bottom* the image is already at 52 % of
    /// the tremor; at 5.5 Hz it is at 91 %, i.e. two tremors of nearly equal
    /// depth beating at 0.72 Hz; at 8 Hz the image is the louder of the two and
    /// the tremor simply arrives at the wrong rate (3.72 Hz). **The whole band
    /// is compromised on the hosted-AU path in a bounce, not just its top.**
    public static func modulationImageRatio(rateHz: Double, samplingHz: Double) -> Double {
        guard rateHz > 0, samplingHz > 0, rateHz.isFinite, samplingHz.isFinite else { return 0 }
        guard rateHz < samplingHz else { return .infinity }
        return rateHz / (samplingHz - rateHz)
    }

    /// The highest modulation rate whose image stays at or below `maxImageRatio`
    /// of it, for a lane re-sampled at `samplingHz`. Inverse of
    /// `modulationImageRatio`: `f = f_s · r / (1 + r)`.
    ///
    /// At the hosted-AU offline rate, holding the image 12 dB down (ratio 0.25)
    /// caps the rate at **2.34 Hz** — below the whole physiological band, which
    /// is why P5 suppresses the tremor on that path rather than retuning it
    /// into a band it is not named for.
    public static func modulationRateCeilingHz(samplingHz: Double,
                                               maxImageRatio: Double) -> Double {
        guard samplingHz > 0, maxImageRatio > 0,
              samplingHz.isFinite, maxImageRatio.isFinite else { return 0 }
        return samplingHz * maxImageRatio / (1 + maxImageRatio)
    }

    /// The image ratio P5 is willing to write. **0.25 — the image 12 dB below
    /// the tremor**, which is the point at which the beating between the two
    /// stops being the dominant thing you hear. An estimate, and named rather
    /// than buried at a call site so it can be argued with.
    public static let maxAcceptableImageRatio = 0.25
}
