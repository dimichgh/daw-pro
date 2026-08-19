import Foundation

/// Generates the correlated controller contour a wind/bowed player puts on a
/// sustained note (m27 leg D): **louder, brighter and very slightly sharper as
/// they lean in, with vibrato arriving LATE and widening**.
///
/// ## Why this exists, and why it is not a volume-lane swell
///
/// Before m27 legs A and C, "expression" on a held note could only be drawn on
/// the track's VOLUME automation lane, which reads as a fader move: loudness
/// changes and timbre does not, so the note still sounds like a synthesizer
/// holding a key down. Leg A routed **CC11 (expression)** to a smoothed
/// per-voice amplitude, and leg C routed a controller (`SamplerParams
/// .expressionFilterCC`, default 11) to a per-voice low-pass cutoff. So on the
/// built-in sampler ONE CC11 contour now moves **loudness and brightness
/// together** — which is what breath pressure actually does. That is what this
/// type generates.
///
/// ⚠️ **The brightness half only moves if `SamplerParams.expressionFilterDepth`
/// is above 0 on the track's instrument.** With it at 0 (the default) the
/// contour is still correct and still audible, but it is a loudness swell only.
/// `ProjectStore.applyBreathContour` warns about exactly this.
///
/// ## Everything here is PURE
///
/// No store access, no engine, no UI, no randomness, no clock — `generate` is a
/// function of its arguments, so the same note and options always produce
/// byte-identical points (the `applyLegatoPass` precedent, m27-o ⓑ). It is a
/// free `enum` namespace rather than a `ProjectStore` extension because the
/// wire, the store and any future panel model all call it, and a
/// MainActor-isolated helper would make the first nonisolated caller a compile
/// error for no reason.
///
/// ## Points are STEPWISE, so the contour is DENSE — this is load-bearing
///
/// `MIDIControllerPoint` has no curve field by design: "a value holds until the
/// next point steps it; a ramp is a DENSE run of points" (`Model.swift`). A
/// handful of points therefore does not draw a swell — it draws a STAIRCASE.
/// `SamplerInstrument` one-poles both the amplitude multiplier and the filter
/// coefficient with a ~12 ms time constant
/// (`SamplerInstrument.expressionSmoothingSeconds = 0.012`), which de-zippers a
/// step but cannot manufacture a curve between two distant ones. The defaults
/// below therefore emit at 20 ms (expression) and 8 ms (pitch bend), and both
/// are caller-tunable. Redundant points are dropped: a point whose rounded
/// value equals the previous kept point's is omitted, which is exactly
/// equivalent under stepwise semantics and collapses the flat top of the swell
/// to a single point.
public enum BreathContour {

    // MARK: - Shape constants

    /// Contour level at the note's ONSET, as a fraction of the swell's travel
    /// (0 = the contour's lowest point, 1 = its peak). The tone speaks at a
    /// moderate pressure, not at the note's loudest instant.
    ///
    /// **(estimate)** — `docs/research/spike-wind-instrument-realism.md` §6
    /// gives a usable CC11 BAND ("100-127, never resting below ~90 for a
    /// still-audible passage") but no onset/peak split; nothing found is
    /// willing to put a number on where inside that band a note starts. 0.35
    /// places the onset a third of the way up the travel, so the swell is the
    /// dominant gesture and the attack is not itself the peak.
    static let onsetLevel = 0.35

    /// Contour level at the settling dip — the LOWEST point of the whole
    /// contour, by construction, which is what makes `Options.depth` mean "the
    /// peak-to-trough travel" rather than an abstract scale factor.
    ///
    /// The dip is the air column and embouchure settling after the attack
    /// transient: pressure momentarily sags below where the note spoke. Fixed
    /// at 0 rather than exposed, because a dip that is not the minimum would
    /// make `depth` unreadable.
    static let dipLevel = 0.0

    /// Contour level at the note's END. Above the settling dip and below the
    /// onset: the taper eases off, it does not fade to nothing — the note's own
    /// amplitude release does that.
    ///
    /// **(estimate)**, same gap in the sources as `onsetLevel`.
    static let releaseLevel = 0.25

    /// The settling dip may never occupy more than this fraction of the note.
    /// THE SHORT-NOTE RULE for the expression half: an absolute-time feature
    /// (~50 ms) on a 60 ms note would be the entire note. Clamping keeps a
    /// staccato note's contour a scaled-down version of the same shape instead
    /// of nonsense. See `Options.attackSettleSeconds`.
    static let maxSettleFraction = 0.25

    /// The coarsest bend spacing that still represents the vibrato oscillation:
    /// at least this many points per vibrato cycle. Nyquist alone would allow
    /// 2, but a stepwise lane sampled at 2-3 points per cycle is a square wave,
    /// not a vibrato. Only reachable when the point budget forces a widening —
    /// see `Generated.vibratoTruncatedAtBeat`.
    static let minPointsPerVibratoCycle = 8.0

    // MARK: - Options

    /// The caller-tunable shape of the contour. Every default is justified in
    /// its own doc comment; figures taken from
    /// `docs/research/spike-wind-instrument-realism.md` cite their section, and
    /// figures with no source behind them say **(estimate)** rather than
    /// arriving as bare magic numbers.
    public struct Options: Sendable, Equatable {

        /// How far the expression contour travels from its peak down to its
        /// lowest point, as a fraction of `peakValue`. 0 = a flat lane at
        /// `peakValue` (a valid no-op on this axis); 1 = the dip reaches CC 0
        /// (silence at the settle).
        ///
        /// **Default 0.25.** At the default `peakValue` of 127 that puts the
        /// settling dip at CC 95 and the taper at CC ≈ 103 — inside the
        /// spike's §6 recommendation of "CC11 100-127, never resting below ~90
        /// for a still-audible passage", with the transient dip the one
        /// excursion below 100. In loudness that is about −2.5 dB peak to
        /// trough; with `expressionFilterDepth` at 1 it is also about 1.2
        /// octaves of low-pass cutoff. This is the INVOLUNTARY contour of a
        /// note held steady, not a written crescendo — a hairpin wants a much
        /// larger value, or an automation lane.
        public var depth: Double

        /// The raw CC value at the top of the swell (0...127).
        ///
        /// **Default 127**, deliberately the lane's own neutral value
        /// (`MIDIControllerType.neutralDefault` for CC11). CC11 on this sampler
        /// ATTENUATES — 127 is unity — so peaking at 127 makes the loudest
        /// instant of the note exactly as loud as the same note with no lane at
        /// all: the contour only ever carves, and applying it cannot quietly
        /// drop the level of a part an agent already balanced. Lower it to
        /// leave headroom for a later hand edit above the peak.
        public var peakValue: Int

        /// Where the peak of the swell sits, as a fraction of the note's
        /// sounding length. **Default 0.65** — past the middle, so the note
        /// spends longer arriving than leaving, which is the asymmetry that
        /// reads as a player leaning in rather than a tremolo. Clamped to
        /// 0.05...0.95; `attackSettleSeconds` is further clamped to half of it
        /// so the dip always precedes the peak.
        public var peakPosition: Double

        /// How long after the attack the settling dip bottoms out, in SECONDS.
        /// **Default 0.05** — the pressure settling, on the order of one
        /// attack transient. Clamped to `maxSettleFraction` (0.25) of the note,
        /// so short notes scale instead of becoming all dip.
        public var attackSettleSeconds: Double

        /// Which CC carries the contour. **Default 11 (expression)** — the one
        /// controller the built-in sampler routes to amplitude with no opt-in
        /// (leg A), and the default `SamplerParams.expressionFilterCC` (leg C),
        /// so one lane moves loudness and brightness together.
        ///
        /// Set this to a different CC only if the track's instrument has
        /// `expressionFilterCC` pointed somewhere else — e.g. point the filter
        /// at CC 1 and run this twice (once on CC 11, once on CC 1 with a
        /// smaller `peakPosition`) to get brightness that fades BEFORE
        /// loudness, which is what a release into a dull tone really is. With a
        /// single lane the two fall together, which is the honest limit of the
        /// one-contour design.
        public var expressionCC: Int

        /// Seconds between emitted expression points. **Default 0.02.** The
        /// sampler one-poles the expression multiplier with a ~12 ms time
        /// constant, so a 20 ms step is ≈81 % settled (1 − e^(−20/12)) before
        /// the next arrives: the run reads as a curve, not a staircase, and
        /// nothing is wasted resolving faster than the smoother can follow.
        ///
        /// ⚠️ This is the finest STEP TIMING, not the point count. Redundant
        /// points are thinned (see `BreathContour.thin`), and the expression
        /// curve is monotone between its knots, so the emitted count is bounded
        /// by the number of DISTINCT CC values the contour passes through —
        /// about `depth × peakValue` (32 at the defaults), whatever the
        /// spacing. Measured: a 4 s note emits 32 points on its rise at 20 ms
        /// and 30 at 60 ms. Halving this buys resolution in TIME, not in level.
        public var expressionSpacingSeconds: Double

        /// How long the note is played STRAIGHT before vibrato starts, in
        /// seconds. **Default 0.5.** The spike's §6 table recommends holding
        /// vibrato depth at 0 for "the first ~300-600 ms of a note (or the
        /// whole note, for notes shorter than that)"; 0.5 is the middle of that
        /// band. Constant vibrato from the attack is the classic MIDI
        /// giveaway.
        ///
        /// ⭐ The parenthesis is implemented literally: a note that cannot fit
        /// this delay plus one whole vibrato cycle gets **no pitch-bend lane at
        /// all** (see `Generated.pitchBend`).
        public var vibratoOnsetSeconds: Double

        /// Vibrato rate in Hz. **Default 5.5 (estimate)** — the middle of the
        /// 5-7 Hz band conventionally quoted for instrumental vibrato. The
        /// spike doc names no rate, so this is not sourced; it is exposed
        /// precisely because it is a taste parameter.
        public var vibratoRateHz: Double

        /// Peak vibrato width in CENTS (a ±figure: ±12 spans 24 cents).
        /// **Default 12.**
        ///
        /// Deliberately conservative. Real saxophone vibrato runs wider, and
        /// the spike's §6 table quotes the SoundFont-2 default vibrato ceiling
        /// as "~50 cents at CC1=127" (§2.3, itself flagged unverified against
        /// the actual macOS GM bank). Two reasons to stay well under that:
        /// pitch bend is **channel-wide**, so this bends every voice sounding
        /// on the track — including the overlapping tail m27-o ⓑ's legato pass
        /// deliberately leaves under the next attack — and 12 cents sits just
        /// above the ~5-10 cent pitch JND for a sustained tone, so it is
        /// clearly present without reading as out of tune.
        public var vibratoDepthCents: Double

        /// How long the vibrato takes to widen from nothing to
        /// `vibratoDepthCents`, in seconds. **Default 0.7 (estimate)** ≈ 4
        /// cycles at the default rate. The spike says only "then ramp in over
        /// the remainder"; a fixed bloom is preferred to a proportional one so
        /// that a 2 s and a 6 s note bloom at the same rate rather than the
        /// long note blooming in slow motion. Clamped to the available span.
        public var vibratoBloomSeconds: Double

        /// How long before the note's end the vibrato relaxes back to centre,
        /// in seconds. **Default 0.08 (estimate).** Two jobs: players do ease
        /// off at the end of a note, and it guarantees the lane arrives at
        /// exactly centre with no pitch step on the decaying tail. Clamped to a
        /// quarter of the vibrato span.
        public var vibratoReleaseSeconds: Double

        /// Peak micro-sharpening in CENTS at the top of the swell, resolving to
        /// 0 as the contour falls. **Default 4.0 (estimate).** Blowing harder
        /// pushes a wind instrument sharp; 4 cents is below the ~5-10 cent JND
        /// for a sustained tone in isolation, so it never reads as out of tune
        /// on its own, but it is correlated with the loudness swell and that
        /// correlation is what the ear hears as effort. No source found puts a
        /// number on it — the spike's §6 pitch-bend rows are about scoops and
        /// falls (100-200 cents), a different gesture entirely.
        public var sharpenCents: Double

        /// Seconds between emitted pitch-bend points. **Default 0.008.** Bend
        /// is stepwise like every other lane and is NOT smoothed by the
        /// instrument (`SamplerInstrument` applies each bend event straight to
        /// the playback increment), so the emitted run IS the waveform: 8 ms
        /// gives ≈23 points per cycle at 5.5 Hz. The steps are pitch, not
        /// amplitude, and the phase stays continuous, so a coarse run detunes
        /// rather than clicks — but it stops sounding like vibrato.
        public var bendSpacingSeconds: Double

        /// The instrument's pitch-bend range in semitones for the full ±8192
        /// deflection. **Default 2** — `SamplerInstrument.bendRangeSemitones`
        /// is exactly 2.0, so cents map exactly on the built-in sampler.
        ///
        /// ⚠️ **UNVERIFIED for hosted AUs.** `AUHostRegistry` never sets
        /// `kAUSamplerProperty`'s bend range, so a hosted AUSampler uses its own
        /// factory default (conventionally ±2, unmeasured here — the spike's
        /// §2.4 flags exactly this as needing a render test). If a hosted
        /// instrument's range is wider, the generated vibrato comes out
        /// proportionally wider; pass the real figure to correct it.
        public var bendRangeSemitones: Double

        /// The most points either generated lane may carry. **Default 16384**,
        /// which is `ProjectStore.maxControllerPointsPerLane` restated
        /// (DAWCore's model layer cannot see the store's constant without
        /// making this file depend on it, and the store re-checks anyway).
        ///
        /// Exposed mainly so the budget-exhaustion branches are REACHABLE in a
        /// test without a 12-minute note: at the default they need a note of
        /// roughly 130 s (widening) or 745 s (truncation).
        public var maxPointsPerLane: Int

        public init(depth: Double = 0.25,
                    peakValue: Int = 127,
                    peakPosition: Double = 0.65,
                    attackSettleSeconds: Double = 0.05,
                    expressionCC: Int = 11,
                    expressionSpacingSeconds: Double = 0.02,
                    vibratoOnsetSeconds: Double = 0.5,
                    vibratoRateHz: Double = 5.5,
                    vibratoDepthCents: Double = 12,
                    vibratoBloomSeconds: Double = 0.7,
                    vibratoReleaseSeconds: Double = 0.08,
                    sharpenCents: Double = 4,
                    bendSpacingSeconds: Double = 0.008,
                    bendRangeSemitones: Double = 2,
                    maxPointsPerLane: Int = 16384) {
            self.depth = depth
            self.peakValue = peakValue
            self.peakPosition = peakPosition
            self.attackSettleSeconds = attackSettleSeconds
            self.expressionCC = expressionCC
            self.expressionSpacingSeconds = expressionSpacingSeconds
            self.vibratoOnsetSeconds = vibratoOnsetSeconds
            self.vibratoRateHz = vibratoRateHz
            self.vibratoDepthCents = vibratoDepthCents
            self.vibratoBloomSeconds = vibratoBloomSeconds
            self.vibratoReleaseSeconds = vibratoReleaseSeconds
            self.sharpenCents = sharpenCents
            self.bendSpacingSeconds = bendSpacingSeconds
            self.bendRangeSemitones = bendRangeSemitones
            self.maxPointsPerLane = maxPointsPerLane
        }

        /// Every field forced into the domain the generator can honour, so a
        /// hand-authored wire payload cannot produce nonsense (the `MIDINote`
        /// self-healing discipline). Applied once at the top of `generate`.
        func sanitized() -> Options {
            var o = self
            o.depth = clampD(depth, 0, 1)
            o.peakValue = min(127, max(0, peakValue))
            o.peakPosition = clampD(peakPosition, 0.05, 0.95)
            o.attackSettleSeconds = max(0, attackSettleSeconds)
            o.expressionCC = min(127, max(0, expressionCC))
            // A spacing of 0 would be an infinite loop; 1 ms is finer than any
            // smoother in the engine can follow, and 1 s is coarser than any
            // gesture this generates.
            o.expressionSpacingSeconds = clampD(expressionSpacingSeconds, 0.001, 1)
            o.vibratoOnsetSeconds = max(0, vibratoOnsetSeconds)
            // Below 0.2 Hz "vibrato" is a slow pitch drift and one cycle would
            // not fit any real note; 20 Hz is past the top of every instrument
            // vibrato ever measured and into audible FM.
            o.vibratoRateHz = clampD(vibratoRateHz, 0.2, 20)
            o.vibratoDepthCents = clampD(vibratoDepthCents, 0, 200)
            o.vibratoBloomSeconds = max(0, vibratoBloomSeconds)
            o.vibratoReleaseSeconds = max(0, vibratoReleaseSeconds)
            o.sharpenCents = clampD(sharpenCents, -200, 200)
            o.bendSpacingSeconds = clampD(bendSpacingSeconds, 0.001, 1)
            // 0 semitones would divide by zero; the ±48 ceiling is the widest
            // range any MIDI instrument advertises via RPN 0.
            o.bendRangeSemitones = clampD(bendRangeSemitones, 0.01, 48)
            // Floor 8, not 2: the expression grid reserves 4 slots for its
            // knots and endpoints and the bend grid 2, so a smaller budget
            // would leave the generator dividing the note by zero or less.
            o.maxPointsPerLane = min(16384, max(8, maxPointsPerLane))
            return o
        }
    }

    // MARK: - Result

    /// One note's generated contour, in CLIP-RELATIVE beats — ready to hand to
    /// `MIDIControllerLane`, which sorts, clamps and dedupes on its own.
    ///
    /// Carries its diagnostics rather than logging them: every figure the
    /// generator DERIVED (rather than was handed) is readable here, because a
    /// caller that cannot tell "vibrato was skipped" from "vibrato was applied
    /// and did nothing" is exactly the silent-failure shape this round exists
    /// to end.
    public struct Generated: Sendable, Equatable {
        /// The expression (CC) run. Always non-empty for a note of non-zero
        /// length.
        public var expression: [MIDIControllerPoint]

        /// The pitch-bend run: micro-sharpening plus delayed vibrato, ending on
        /// an exact 8192 (centre) point at the note's end so the following note
        /// can never start detuned by this one's last vibrato phase.
        ///
        /// **EMPTY when the note is too short for vibrato** — see
        /// `vibratoStartBeat`. Empty rather than a flat centre run: an
        /// all-neutral lane is data that cannot sound, and it would burn the
        /// clip's point budget for nothing.
        public var pitchBend: [MIDIControllerPoint]

        /// Clip-relative beat at which vibrato begins, or nil if this note got
        /// none (its sounding length did not exceed
        /// `vibratoOnsetSeconds` + one vibrato cycle).
        public var vibratoStartBeat: Double?

        /// Clip-relative beat at which vibrato was CUT SHORT because the point
        /// budget ran out even at the coarsest representable spacing, or nil
        /// (the overwhelmingly normal case) if it ran to the note's end. When
        /// non-nil the bend lane holds centre from here on: the contour is
        /// shortened, never aliased into a buzz.
        public var vibratoTruncatedAtBeat: Double?

        /// The bend spacing actually used, in seconds. Equal to
        /// `Options.bendSpacingSeconds` unless the budget forced a widening.
        public var bendSpacingSecondsUsed: Double

        /// The expression spacing actually used, in seconds. Equal to
        /// `Options.expressionSpacingSeconds` unless the budget forced a
        /// widening.
        public var expressionSpacingSecondsUsed: Double

        /// The note's sounding length in seconds, as resolved through the tempo
        /// map (so a tempo ramp under the note is accounted for). 0 for a
        /// zero-length note, which produces no points at all.
        public var noteDurationSeconds: Double
    }

    // MARK: - Generation

    /// Builds the correlated expression + pitch-bend contour for ONE note.
    ///
    /// - Parameters:
    ///   - noteStartBeat: the note's CLIP-RELATIVE start (`MIDINote.startBeat`).
    ///   - noteLengthBeats: the note's length in beats.
    ///   - clipStartBeat: the clip's TIMELINE start, needed only to look the
    ///     note up in the tempo map. Emitted points are clip-relative, so this
    ///     never appears in the output.
    ///   - tempoMap: the project's map. A `TempoMap` rather than a scalar
    ///     seconds-per-beat because every shape figure above is in SECONDS
    ///     while lanes are in BEATS, and under a tempo ramp those two do not
    ///     scale together — `seconds(from:to:)` / `beat(from:elapsedSeconds:)`
    ///     integrate the ramp exactly.
    ///
    /// **The note's PITCH is deliberately not a parameter.** No source found
    /// supports pitch-dependent breath shaping — register affects timbre, not
    /// the shape of the pressure envelope — and taking an argument that is
    /// never read is worse than explaining its absence.
    ///
    /// ⚠️ **Pitch bend is CHANNEL-WIDE on every instrument in this engine.**
    /// The generated vibrato bends every voice sounding on the track, including
    /// the previous note's tail where m27-o ⓑ's legato pass deliberately
    /// overlaps it. On a monophonic wind line — the part this exists for — that
    /// is correct and is what a real player does. On a polyphonic part it is
    /// not: the whole chord will wobble. That is a property of MIDI 1.0 channel
    /// bend, not something this generator can fix.
    public static func generate(noteStartBeat: Double,
                                noteLengthBeats: Double,
                                clipStartBeat: Double,
                                tempoMap: TempoMap,
                                options rawOptions: Options = Options()) -> Generated {
        let options = rawOptions.sanitized()
        let startTimeline = clipStartBeat + noteStartBeat
        let endTimeline = startTimeline + max(0, noteLengthBeats)
        let duration = max(0, tempoMap.seconds(from: startTimeline, to: endTimeline))

        guard duration > 0, noteLengthBeats > 0 else {
            return Generated(expression: [], pitchBend: [],
                             vibratoStartBeat: nil, vibratoTruncatedAtBeat: nil,
                             bendSpacingSecondsUsed: options.bendSpacingSeconds,
                             expressionSpacingSecondsUsed: options.expressionSpacingSeconds,
                             noteDurationSeconds: 0)
        }

        // Seconds-since-note-onset → clip-relative beat, integrating any tempo
        // ramp under the note.
        func beat(at seconds: Double) -> Double {
            tempoMap.beat(from: startTimeline,
                          elapsedSeconds: min(seconds, duration)) - clipStartBeat
        }

        // --- The shape's knots, in seconds from the note's onset -------------
        var peakTime = duration * options.peakPosition
        // The dip is an ABSOLUTE-time feature and the peak a PROPORTIONAL one;
        // on a short note the two collide. Clamp the dip to a quarter of the
        // note AND to half the time available before the peak, so both rising
        // segments always exist and a staccato note gets a scaled-down version
        // of the same curve rather than a degenerate one.
        var settleTime = min(options.attackSettleSeconds,
                             duration * maxSettleFraction,
                             peakTime * 0.5)
        settleTime = max(0, settleTime)
        peakTime = min(max(peakTime, settleTime), duration)

        func shape(_ t: Double) -> Double {
            if t <= 0 { return onsetLevel }
            if t >= duration { return releaseLevel }
            if t <= settleTime {
                return settleTime > 0
                    ? cosineBlend(onsetLevel, dipLevel, t / settleTime)
                    : dipLevel
            }
            if t <= peakTime {
                let span = peakTime - settleTime
                return span > 0 ? cosineBlend(dipLevel, 1, (t - settleTime) / span) : 1
            }
            let span = duration - peakTime
            return span > 0 ? cosineBlend(1, releaseLevel, (t - peakTime) / span) : releaseLevel
        }

        // --- Expression lane -------------------------------------------------
        let travel = Double(options.peakValue) * options.depth
        func expressionValue(_ t: Double) -> Int {
            let raw = Double(options.peakValue) - travel * (1 - shape(t))
            return Int(min(127, max(0, raw.rounded())))
        }

        // Sample on a uniform grid PLUS the three knots, so the dip and the
        // peak land on exact extrema instead of wherever the grid happens to
        // fall. Widen the grid if the note is long enough to blow the budget.
        var expressionSpacing = options.expressionSpacingSeconds
        let expressionNeeded = Int((duration / expressionSpacing).rounded(.up)) + 4
        if expressionNeeded > options.maxPointsPerLane {
            // `max(1, …)` because the 4 reserved slots (three knots plus the
            // end) can exceed a tiny budget; the sanitizer's floor of 8 makes
            // this unreachable, and it is kept so a future floor change cannot
            // silently produce a negative spacing (measured: it did, and the
            // note came out with ONE point).
            expressionSpacing = duration / Double(max(1, options.maxPointsPerLane - 4))
        }
        let expressionTimes = sampleTimes(from: 0, to: duration, spacing: expressionSpacing,
                                          extras: [settleTime, peakTime])
        let expression = thin(expressionTimes.map {
            MIDIControllerPoint(beat: beat(at: $0), value: expressionValue($0))
        })

        // --- Pitch-bend lane -------------------------------------------------
        // THE SHORT-NOTE RULE. The spike's §6 recommendation is to hold vibrato
        // at 0 "for the first ~300-600 ms of a note (or the whole note, for
        // notes shorter than that)". Implemented literally: a note that cannot
        // fit the straight opening plus one WHOLE vibrato cycle gets no bend
        // lane at all. Emitting a flat centre lane instead would be data that
        // cannot sound, and micro-sharpening without the vibrato it accompanies
        // is inaudible on a note this short — so the lane is simply absent,
        // which also leaves the clip's point budget for the notes that use it.
        let cyclePeriod = 1 / options.vibratoRateHz
        let vibratoOnset = options.vibratoOnsetSeconds
        guard duration > vibratoOnset + cyclePeriod else {
            return Generated(expression: expression, pitchBend: [],
                             vibratoStartBeat: nil, vibratoTruncatedAtBeat: nil,
                             bendSpacingSecondsUsed: options.bendSpacingSeconds,
                             expressionSpacingSecondsUsed: expressionSpacing,
                             noteDurationSeconds: duration)
        }

        let vibratoSpan = duration - vibratoOnset
        let bloom = min(max(options.vibratoBloomSeconds, 0), vibratoSpan)
        let vibratoRelease = min(options.vibratoReleaseSeconds, vibratoSpan * 0.25)

        // THE POINT BUDGET. `sparse` covers [0, vibratoOnset] at the expression
        // spacing — the micro-sharpening there is a slow curve and needs no
        // more. Everything left goes to the vibrato at `bendSpacing`; if that
        // overruns, widen it, and if the widened spacing could no longer
        // represent the oscillation (fewer than `minPointsPerVibratoCycle`
        // points per cycle) hold it at the coarsest representable value and
        // CUT the vibrato short instead of aliasing it into a buzz.
        let sparseCount = Int((vibratoOnset / expressionSpacing).rounded(.up)) + 1
        // −2 leaves room for the exact vibrato-onset point and the exact
        // centre point at the note's end.
        let denseBudget = max(1, options.maxPointsPerLane - sparseCount - 2)
        var bendSpacing = options.bendSpacingSeconds
        var vibratoEnd = duration
        var truncatedAt: Double?
        if Int((vibratoSpan / bendSpacing).rounded(.up)) > denseBudget {
            let coarsest = cyclePeriod / minPointsPerVibratoCycle
            bendSpacing = vibratoSpan / Double(denseBudget)
            if bendSpacing > coarsest {
                bendSpacing = coarsest
                vibratoEnd = vibratoOnset + bendSpacing * Double(denseBudget)
                truncatedAt = beat(at: vibratoEnd)
            }
        }

        func sharpenCents(_ t: Double) -> Double {
            let above = (shape(t) - onsetLevel) / max(1e-9, 1 - onsetLevel)
            return options.sharpenCents * clampD(above, 0, 1)
        }

        func vibratoCents(_ t: Double) -> Double {
            guard t >= vibratoOnset, t <= vibratoEnd else { return 0 }
            let sinceOnset = t - vibratoOnset
            // Widening in, relaxing out. Both raised-cosine so the depth
            // envelope has no corner at either end.
            let growth = bloom > 0
                ? cosineBlend(0, 1, clampD(sinceOnset / bloom, 0, 1))
                : 1
            let relax = vibratoRelease > 0
                ? cosineBlend(0, 1, clampD((vibratoEnd - t) / vibratoRelease, 0, 1))
                : 1
            // Phase 0 at the onset, so the lane leaves centre continuously.
            return options.vibratoDepthCents * growth * relax
                * sin(2 * Double.pi * options.vibratoRateHz * sinceOnset)
        }

        let centsPerUnit = options.bendRangeSemitones * 100 / 8192
        func bendValue(_ t: Double) -> Int {
            let cents = sharpenCents(t) + vibratoCents(t)
            let raw = 8192 + (cents / centsPerUnit).rounded()
            return Int(min(16383, max(0, raw)))
        }

        var bendTimes = sampleTimes(from: 0, to: vibratoOnset,
                                    spacing: expressionSpacing, extras: [])
        bendTimes += sampleTimes(from: vibratoOnset, to: vibratoEnd,
                                 spacing: bendSpacing, extras: [])
        var bend = thin(bendTimes.map {
            MIDIControllerPoint(beat: beat(at: $0), value: bendValue($0))
        })
        // When the budget cut the vibrato short, state the centre explicitly at
        // the cut rather than relying on the relax ramp having landed there:
        // "the lane holds centre from here on" is the contract, and after the
        // cut nothing else re-states it until the note's end.
        if truncatedAt != nil {
            bend.append(MIDIControllerPoint(beat: beat(at: vibratoEnd), value: 8192))
        }
        // The lane ALWAYS ends at exact centre at the note's end. The relax
        // ramp already brings it there, but "already there" is an argument, and
        // a following note starting detuned by this note's last vibrato phase
        // is a real defect — so it is stated, not inferred. (When vibrato was
        // truncated this is also the point that holds centre for the rest of
        // the note.)
        let endBeat = beat(at: duration)
        if bend.last.map({ $0.beat < endBeat || $0.value != 8192 }) ?? true {
            bend.removeAll { $0.beat >= endBeat }
            bend.append(MIDIControllerPoint(beat: endBeat, value: 8192))
        }

        return Generated(expression: expression, pitchBend: bend,
                         vibratoStartBeat: beat(at: vibratoOnset),
                         vibratoTruncatedAtBeat: truncatedAt,
                         bendSpacingSecondsUsed: bendSpacing,
                         expressionSpacingSecondsUsed: expressionSpacing,
                         noteDurationSeconds: duration)
    }

    // MARK: - Helpers

    /// Raised-cosine blend from `a` to `b` over `u` ∈ 0...1. Chosen over a
    /// linear ramp because the shape is sampled at KNOTS (dip, peak) where a
    /// linear blend leaves a visible corner in the emitted values, and over a
    /// cubic because it needs no tangent bookkeeping and is exactly flat at
    /// both ends — which is what makes the peak read as a peak rather than a
    /// direction change.
    static func cosineBlend(_ a: Double, _ b: Double, _ u: Double) -> Double {
        let t = clampD(u, 0, 1)
        return a + (b - a) * (1 - cos(.pi * t)) / 2
    }

    /// A uniform grid over `from...to` INCLUSIVE of both ends, with `extras`
    /// merged in and near-duplicates (closer than a quarter of the spacing)
    /// dropped. Deterministic and allocation-bounded: the caller has already
    /// sized `spacing` against the point budget.
    static func sampleTimes(from: Double, to: Double, spacing: Double,
                            extras: [Double]) -> [Double] {
        guard to > from, spacing > 0 else { return to >= from ? [from] : [] }
        var times: [Double] = []
        let steps = Int(((to - from) / spacing).rounded(.up))
        times.reserveCapacity(steps + extras.count + 2)
        for i in 0...steps { times.append(min(to, from + Double(i) * spacing)) }
        times += extras.filter { $0 > from && $0 < to }
        times.sort()
        var out: [Double] = []
        let tolerance = spacing / 4
        for t in times where out.last.map({ t - $0 > tolerance }) ?? true { out.append(t) }
        // The near-duplicate filter can drop the endpoint when an extra lands
        // just inside it; the endpoint is a knot and must survive.
        if let last = out.last, last < to { out.append(to) }
        return out
    }

    /// Drops points whose value repeats the previous KEPT point's — exactly
    /// equivalent under stepwise semantics (a value holds until the next point
    /// steps it), and it collapses the flat top of the swell and the straight
    /// opening of the bend lane to a single point each. The FIRST and LAST
    /// points always survive: the first because after merging into an existing
    /// lane the preceding value belongs to someone else, the last because it is
    /// the note's contractual end state.
    static func thin(_ points: [MIDIControllerPoint]) -> [MIDIControllerPoint] {
        guard points.count > 2 else { return points }
        var out: [MIDIControllerPoint] = [points[0]]
        for point in points[1..<(points.count - 1)] where point.value != out[out.count - 1].value {
            out.append(point)
        }
        out.append(points[points.count - 1])
        return out
    }
}

/// Local double clamp — `Comparable.clamped(to:)` in this module is defined for
/// the integer/range shapes the model uses, and a second overload there would
/// touch a file this feature has no other reason to open.
private func clampD(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(high, max(low, value))
}
