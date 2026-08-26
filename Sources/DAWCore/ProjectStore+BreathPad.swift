import Foundation

/// What `ProjectStore.applyEffortShape` did — the leg D result plus the things
/// only an effort SHAPE can report: which pattern, how many phrases it found,
/// and the range of effort it actually asked for (breath-pad P1).
///
/// ⭐ `minEffort`/`maxEffort` exist because of this tree's characteristic
/// failure: a call that succeeds, writes points, and shapes nothing. A
/// phrase-scoped pattern applied to notes that all landed in one instant would
/// return `minEffort == maxEffort`, which is the one number that tells a caller
/// "this ran and did nothing" without them having to diff the lane.
public struct EffortShapeApplication: Sendable, Equatable {
    /// The updated clip, with its rebuilt controller lanes.
    public var clip: Clip
    /// The pattern's stable id, echoed back so a caller that passed a
    /// case-insensitive spelling learns the canonical one.
    public var patternID: String
    /// Its human name.
    public var patternName: String
    /// Whether the pattern shaped each NOTE or each PHRASE.
    public var scope: EffortPattern.Scope
    /// How many notes received a contour.
    public var notesTouched: Int
    /// How many phrases the selected notes fell into. **1 for a note-scoped
    /// pattern** — phrases are not consulted there, and reporting 0 would look
    /// like a failed split rather than an unasked question.
    public var phraseCount: Int
    /// How many notes actually got VIBRATO — long enough for it AND generated
    /// with a non-zero width. 0 whenever vibrato was suppressed for the
    /// instrument (see `warnings`), which is the honest answer and the reason
    /// this is not simply leg D's field forwarded.
    public var notesWithVibrato: Int
    /// Total points now on the expression lane.
    public var expressionPointCount: Int
    /// Total points now on the pitch-bend lane, or 0 if none was written.
    public var pitchBendPointCount: Int
    /// The per-note point budget actually used (leg D's clip-wide division).
    public var perNotePointBudget: Int
    /// Lowest and highest effort **asked for** across the selected notes, 0...1.
    /// Equal for a note-scoped pattern (effort is not what varies there) and
    /// for a phrase-scoped one applied to a single instant.
    ///
    /// ⛔ **ASKED FOR, NOT WRITTEN — the air budget does NOT move these** (P4),
    /// even with `enforced` on. They answer one question, "did the GESTURE vary
    /// anything?", and a budget that pulled a note down would otherwise make a
    /// note-scoped pattern report `1.0 … 1.0` as `0.0 … 1.0` and read as
    /// variation the gesture never asked for. What the budget did is in `air`,
    /// per note, with `effortRequested` beside `effortAllowed`.
    public var minEffort: Double
    public var maxEffort: Double
    /// Non-fatal, human-readable. The call SUCCEEDED and the lanes ARE stored.
    public var warnings: [String]
    /// Where the dot landed, or **nil for the single-pattern form** (P2).
    ///
    /// Without this a caller who moved the dot cannot tell what the ring
    /// actually resolved to — the same reason P1 added `minEffort`/`maxEffort`.
    /// `patternID` and `scope` above then describe the DOMINANT member, which
    /// is an honest label for "nearest gesture", not a claim that one pattern
    /// played alone; the weights here are what say otherwise.
    public var ring: EffortRingReport? = nil
    /// What the dot's PATH did, or **nil when the dot did not move** (P3).
    ///
    /// A moving dot has one obvious way to fail: it looks like it worked and
    /// went nowhere. `moved` and `patternIDs` are the two numbers that answer
    /// that without a caller diffing lanes.
    public var path: EffortPathReport? = nil
    /// What the AIR BUDGET said (P4). **Never nil**, and that is the point.
    ///
    /// ⭐ It is computed on every call, whether or not `enforced` is on, because
    /// this is the surface that answers "why did this get quiet?". Read
    /// `air.applied` first: when it is false the lane was NOT touched and the
    /// report is the prediction of what enforcement would do. When it is true,
    /// `air.constrainedNotes` names every note the budget pulled down and
    /// `warnings` says so in a sentence.
    ///
    /// ⛔ A phrase can also get quiet because the COMPOSER asked for it — a
    /// hairpin diminuendo, or a dot drifting toward one. That shows up as a low
    /// `effortRequested`; only the budget produces
    /// `effortAllowed < effortRequested`. Keeping those two distinguishable is
    /// why "air runs out" is not, and must never become, a selectable pattern.
    public var air: AirBudget.Report = .empty(settings: .standard, applied: false)
}

/// What the dot's path actually did over the notes it shaped (breath pad P3).
///
/// ⚠️ Every figure here is sampled **at the note starts** — exactly where the
/// store asked the field — not on a regular grid. A report built from a
/// different sampling would describe a dot the music never saw.
public struct EffortPathReport: Sendable, Equatable {
    /// `fixed`, `orbit` or `drift`.
    public var pathID: String
    /// The seed that produced it. Echoed so "give me that one again" is one
    /// number, and so a caller can tell a reseed from a re-run.
    public var seed: UInt64
    /// Total angular travel in DEGREES, unwrapped: an orbit that went round
    /// twice reports 720, not 0.
    public var angleSweepDegrees: Double
    /// Where the dot was at the first and last shaped note, in 0..<360.
    public var startAngleDegrees: Double
    public var endAngleDegrees: Double
    public var minRadius: Double
    public var maxRadius: Double
    /// Every pattern that held a non-zero share at any note, in ring order.
    /// **One id here means the dot never left one gesture** — the wander ran
    /// and was musically inert.
    public var patternIDs: [String]
    /// Did it move at all, past a tenth of a degree?
    public var moved: Bool
    /// True when the path's fastest component is above the Nyquist rate of the
    /// note grid sampling it — the motion is then an alias, not the shape asked
    /// for. See `EffortField`'s header: the dot is sampled once per note.
    public var outrunsNotes: Bool
}

/// What the dot was, resolved — the ring, the angle, and the share each pattern
/// took (breath pad P2).
public struct EffortRingReport: Sendable, Equatable {
    /// Where the dot sat, in DEGREES in 0..<360 — the unit the wire speaks.
    public var angleDegrees: Double
    /// How far out, 0...1. 0 is a true no-op: see `EffortRing`'s note on why
    /// `neutral` is 1 here and not the design's estimated 0.5.
    public var radius: Double
    /// The ring's pattern ids, in ring order.
    public var patternIDs: [String]
    /// Each pattern's share, parallel to `patternIDs`, summing to 1. At most
    /// two are non-zero — the nearest-two law.
    public var weights: [Double]
    /// The shares that went to the two things a contour can express: the shape
    /// WITHIN a note, and the level of that note within its PHRASE. They sum
    /// to 1.
    public var noteWeight: Double
    public var phraseWeight: Double
}

/// The breath pad's store boundary (breath-pad P1, `docs/research/design-breath-pad.md`).
///
/// New domain, its own extension file — the ProjectStore.swift-is-7k-lines rule.
@MainActor
extension ProjectStore {

    /// Applies a named **effort shape** to a MIDI clip's notes: picks one
    /// pattern from `EffortPattern.library`, turns it into per-note breath
    /// contour options, and writes them through the SAME machinery
    /// `applyBreathContour` uses.
    ///
    /// ## What this adds over `clip.applyBreathContour`
    ///
    /// Leg D writes ONE contour shape to every selected note. This chooses the
    /// shape from a named gesture, and — for a phrase-scoped pattern — varies
    /// it note by note across the phrase, which is the thing leg D structurally
    /// could not do: a written crescendo is a property of the phrase, not of
    /// any note in it.
    ///
    /// ⚠️ **There is no second lane-writing path here, deliberately.** This
    /// method computes options and calls
    /// `applyBreathContourVarying`, which IS leg D's body. The merge semantics
    /// (points outside the touched spans survive), the clip-wide point budget,
    /// the single undo step, the lane-cap refusal and the routing warnings are
    /// all the ones that already shipped and are already tested. The only thing
    /// this file owns is *which options each note gets* and *what extra it must
    /// warn about*.
    ///
    /// ## How a pattern becomes options
    ///
    /// - **`.note` scope** — the pattern IS the intra-note shape, so it sets
    ///   `onsetLevel`, `releaseLevel`, `peakPosition` and `depth`. Every note
    ///   gets the same options; effort is a constant 1.
    /// - **`.phrase` scope** — the pattern is sampled once per note at that
    ///   note's position inside its phrase (`PhraseDetection`), giving a
    ///   per-note effort that `BreathContour.scaled` turns into that note's
    ///   `peakValue` and `depth`. The intra-note shape stays leg D's default,
    ///   because the gesture being authored is the phrase's, not the note's.
    ///
    /// `amount` (0...1, default 1) is how strongly the pattern is applied: it
    /// scales the note-scoped depth, and pulls phrase-scoped effort toward full
    /// pressure. **`amount == 0` is a valid no-op on the shaping axis** — a flat
    /// lane at `peakValue` — not an error.
    ///
    /// ## What it refuses, and what it only warns about
    ///
    /// Refusals are leg D's, verbatim: an audio clip, an unknown clip id, a comp
    /// member, a clip with no notes, an unknown note id, an unsatisfiable point
    /// budget. An unknown pattern id is an `invalidClipEdit` naming every valid
    /// one — never a silent fallback to a default shape.
    ///
    /// ⚠️ **There is no `requireNotCompMember` call in THIS file, and that is
    /// not an omission — grepping here for one and concluding this sentence
    /// lies is a mistake already made once.** Both refusal paths are leg D's own
    /// code: `breathSelection` guards the read and `applyBreathContourVarying`
    /// guards the write, and this method reaches a comp member through neither.
    /// The guard living in exactly one place is the point (`requireNotCompMember`
    /// is documented as the ONE home for that question); a copy here would be
    /// free to drift from the refusal it exists to mirror.
    ///
    /// ⛔ **Vibrato is SUPPRESSED, not silently mangled, on a track hosting an
    /// Audio Unit** (including every `.soundBank` track — where the GM sax
    /// lives). MEASURED 2026-08-19: bend is sample-and-held at the offline
    /// render block rate there, so an authored 5.5 Hz vibrato bounces as two
    /// vibratos beating. The warning names the route that does work — the
    /// instrument's own CC 1 vibrato. See
    /// `MIDIControllerRouting.bendVibratoWarning(for:requestedRateHz:)`.
    ///
    /// ⛔ **No text anywhere in this feature promises BRIGHTNESS on a sound-bank
    /// track.** MEASURED the same day: CC 11 there is exactly a gain, with any
    /// non-gain difference bounded at −104 dB. Brightness is a built-in
    /// `.sampler` capability, and the warning says which switch turns it on.
    ///
    /// `performEdit("Effort Shape")` — ONE undo step.
    @discardableResult
    public func applyEffortShape(
        clipID: UUID,
        noteIDs: [UUID]? = nil,
        pattern: EffortPattern,
        amount: Double = 1,
        maxGapBeats: Double = HumanizeLegato.defaultMaxGapBeats,
        response: BreathContour.EffortResponse? = nil,
        air: AirBudget.Settings? = nil,
        humanisation: EffortField.Humanisation = .none,
        options: BreathContour.Options = .init()
    ) throws -> EffortShapeApplication {
        // ⭐ P2 DID NOT FORK THIS PATH — it made it a special case of the ring.
        // A ring of ONE pattern, dot parked on it at full radius, weighs that
        // pattern 1 and everything else 0, and `EffortRingTests` proves the
        // resulting curve is the pattern bit for bit. So "the single-pattern
        // form still behaves exactly as it did" is not a promise maintained by
        // discipline — it is the same code, and P1's tests staying green is the
        // proof. `reportRing: false` is the only difference: a caller who never
        // mentioned a ring should not be told about one.
        try applyEffortShape(
            clipID: clipID, noteIDs: noteIDs,
            field: EffortField.Settings(ring: EffortRing(patterns: [pattern]),
                                        origin: .origin, path: .fixed),
            reportRing: false, amount: amount, maxGapBeats: maxGapBeats,
            response: response, air: air, humanisation: humanisation, options: options)
    }

    /// The same gesture chosen from the **ring** instead of by name: patterns
    /// placed round a circle, and a dot whose angle picks which two blend and
    /// whose radius picks how much (breath pad P2, design §8).
    ///
    /// `angleRadians` is wrapped, so a dot path that integrates an angle
    /// without limit can hand it straight in. `radius` is clamped to 0...1.
    ///
    /// ⚠️ **`radius` and `amount` are not independent controls.** Both scale the
    /// same thing and the product `radius × amount` is all that survives — see
    /// `EffortRing`'s header for the algebra. They are both here because the
    /// pad drags the radius and the verb keeps its `amount`, not because they
    /// do different jobs.
    ///
    /// ⭐ **P3 adds `path` and `seed`, and they are the dot's MOVEMENT** — the
    /// user's "flow from one pattern to the other". `angleRadians`/`radius` stop
    /// being where the dot *is* and become where the hand *put* it: the path is
    /// an offset from that origin (§8.3, the Wavestation lesson). `.fixed`, the
    /// default, leaves every note on the origin, which is P2's behaviour by the
    /// same code rather than by a promise.
    ///
    /// ⚠️ **The dot is sampled ONCE PER NOTE, at the note's start beat**, in
    /// CLIP-RELATIVE beats. Both halves matter and both are in `EffortField`'s
    /// header: per-note sampling is what makes the note grid the path's
    /// resolution limit (and earns the `outrunsNotes` warning), and
    /// clip-relative beats are what make a looped clip play the same path on
    /// every cycle — the lane is clip data and the unroller copies it.
    @discardableResult
    public func applyEffortShape(
        clipID: UUID,
        noteIDs: [UUID]? = nil,
        ring: EffortRing,
        angleRadians: Double,
        radius: Double = 1,
        path: DotPath = .fixed,
        seed: UInt64 = 0,
        amount: Double = 1,
        maxGapBeats: Double = HumanizeLegato.defaultMaxGapBeats,
        response: BreathContour.EffortResponse? = nil,
        air: AirBudget.Settings? = nil,
        humanisation: EffortField.Humanisation = .none,
        options: BreathContour.Options = .init()
    ) throws -> EffortShapeApplication {
        try applyEffortShape(
            clipID: clipID, noteIDs: noteIDs,
            field: EffortField.Settings(
                ring: ring,
                origin: DotPosition(angle: angleRadians, radius: radius),
                path: path, seed: seed),
            reportRing: true, amount: amount, maxGapBeats: maxGapBeats,
            response: response, air: air, humanisation: humanisation, options: options)
    }

    /// The one body both forms run through.
    ///
    /// ## How a BLEND becomes options — the two axes, and why they are separate
    ///
    /// A contour has exactly two destinations, and the blend's weights split
    /// across them rather than being averaged into one number:
    ///
    /// - **the shape WITHIN a note** — driven by the `.note`-scoped share.
    ///   `EffortRing.Blend.curve(scope: .note)` is projected onto leg D's
    ///   parameterised family (`onsetLevel`, `releaseLevel`, `peakPosition`,
    ///   `depth`), interpolated away from the caller's own options by
    ///   `noteWeight`, so a dot with no note-scoped content leaves the intra-
    ///   note shape exactly as the caller set it rather than flattening it.
    /// - **the LEVEL of that note in its phrase** — driven by the
    ///   `.phrase`-scoped share, sampled once per note at its position inside
    ///   its phrase and handed to `BreathContour.scaled`.
    ///
    /// > `depth = options.depth × (noteWeight · travel · amount + phraseWeight)`
    /// > `effort(note) = 1 − amount · phraseWeight · (1 − phraseCurve(u))`
    ///
    /// Both collapse to P1's two branches literally at `noteWeight == 1` and at
    /// `phraseWeight == 1`, which is what makes the single-pattern form a
    /// special case rather than a parallel implementation.
    ///
    /// ⚠️ **`radius` is NOT multiplied in here.** It is already baked into the
    /// blend's levels as an affine map (`EffortRing.Blend.radiusMapped`), which
    /// is what keeps `peakPosition` invariant under it — the P1 boundary, held
    /// by the arithmetic. Multiplying it again would apply it twice and would
    /// quietly re-derive the geometry the ring is not allowed to touch.
    ///
    /// ⚠️ **The full field law `Blend.effort(noteU:phraseU:)` is deliberately
    /// NOT called.** It collapses both axes into one scalar, which is right for
    /// P3's continuous field and wrong for a note the generator has to draw.
    ///
    /// ## P3: the blend is now PER NOTE
    ///
    /// Everything above still holds — it is just evaluated once per note, at
    /// `EffortField.blend(atBeat: note.startBeat, settings:)`, instead of once
    /// per call. Two consequences worth stating rather than discovering:
    ///
    /// - **A `.fixed` path resolves ONE blend and hands the SAME instance to
    ///   every note.** So P1's and P2's behaviour is not preserved by care, it
    ///   is the identical object flowing through the identical arithmetic, and
    ///   their existing assertions staying green is the proof.
    /// - **The warnings became aggregate questions.** "This pattern is
    ///   note-scoped" is no longer a property of *the* dot — with a moving one
    ///   it is `max phraseWeight over the notes`. Each such test is written as
    ///   the aggregate that collapses to P2's exact question when the dot is
    ///   fixed, so the sentences are unchanged word for word on that path.
    @discardableResult
    private func applyEffortShape(
        clipID: UUID,
        noteIDs: [UUID]?,
        field: EffortField.Settings,
        reportRing: Bool,
        amount: Double,
        maxGapBeats: Double,
        response: BreathContour.EffortResponse?,
        air: AirBudget.Settings?,
        humanisation rawHumanisation: EffortField.Humanisation,
        options: BreathContour.Options
    ) throws -> EffortShapeApplication {
        // ⚠️ OPTIONAL ON PURPOSE, and it is not a style choice. The response is
        // PROVABLY INERT on a note-scoped pattern (every note gets effort 1, so
        // `BreathContour.scaled` returns its input whatever the response says),
        // and a caller who sets `loudnessDepth: 0.9` on `messaDiVoce` would
        // otherwise get success, a written lane, and no effect — this tree's
        // characteristic failure. Distinguishing "the caller asked for this"
        // from "this is the default" is what lets the warning fire only when
        // someone is actually being ignored.
        let effectiveResponse = response ?? EffortPattern.defaultEffortResponse
        // Resolve the selection through leg D's own resolver, so the effort
        // curve is computed over exactly the notes the write will touch, in
        // exactly the order it will touch them. Re-deriving it here is how the
        // two silently disagree about a tie.
        let selected = try breathSelection(clipID: clipID, noteIDs: noteIDs)
        guard let (t, c) = locateClipForPad(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        let clip = tracks[t].clips[c]
        let instrument = tracks[t].instrument
        let strength = min(1, max(0, amount))

        var warnings: [String] = []

        // --- Where the dot is, note by note ----------------------------------
        //
        // ⭐ A FIXED dot resolves ONCE and every note gets the SAME `Blend`
        // instance. That is the P2 idiom repeated: rather than keeping a static
        // code path alongside a moving one and promising they agree, the static
        // case IS the moving one with a zero offset, and the object handed to
        // each note is literally the same. Note starts are CLIP-RELATIVE beats,
        // which is what makes a looped clip take the same path every cycle.
        //
        // ⚠️ `originBlend` is the dot the HAND set, not the dot at beat 0 — a
        // drift already has an offset at beat 0, so reporting that as the origin
        // answers a question nobody asked (measured: 168.7° for a dot placed at
        // 157.5°). For a `.fixed` path the two are the same object by
        // definition, which is what keeps P2's report byte-identical.
        let originBlend = EffortField.originBlend(settings: field)
        let fixedBlend: EffortRing.Blend? = field.path == .fixed ? originBlend : nil
        var blendByNote: [UUID: EffortRing.Blend] = [:]
        for note in selected {
            blendByNote[note.id] = fixedBlend
                ?? EffortField.blend(atBeat: note.startBeat, settings: field)
        }
        let blends = selected.compactMap { blendByNote[$0.id] }
        let excursion = EffortField.excursion(atBeats: selected.map(\.startBeat), settings: field)
        let dot = PadDotSummary(blends: blends, origin: originBlend, excursion: excursion)

        // --- Effort per note ------------------------------------------------
        //
        // Phrases are computed over EVERY note in the clip, not just the
        // selected ones: a phrase is a property of the music, and shaping the
        // middle three notes of a phrase must place them where they really sit
        // in it, not renormalise them into a phrase of their own.
        let allNotes = clip.notes ?? []
        var phraseCount = 1
        var effortByNote: [UUID: Double] = [:]
        // ⭐ P4 moved this OUT of the `maxPhraseWeight > 0` branch: the air
        // budget reports per PHRASE whatever gesture the dot is sitting on, so
        // the split has to exist even when nothing consults it for shaping. It
        // is a pure function of the notes and the same threshold, so computing
        // it unconditionally changes nothing — and it keeps the tree's ONE
        // definition of a breath serving both features from one call.
        let phrases = PhraseDetection.phrases(in: allNotes, maxGapBeats: maxGapBeats)

        // ⚠️ The GATE is now "did ANY note's dot have phrase content", not "does
        // the dot have phrase content" — a wander can cross into the phrase
        // gestures partway through the clip. `curve(scope:)` is nil exactly when
        // that scope's weight is 0 (members are built only from non-zero
        // weights), so on a fixed dot this asks P2's question unchanged.
        if dot.maxPhraseWeight > 0 {
            var phraseOf: [UUID: PhraseDetection.Phrase] = [:]
            for phrase in phrases {
                for id in phrase.noteIDs { phraseOf[id] = phrase }
            }
            let touched = Set(selected.compactMap { phraseOf[$0.id]?.startBeat })
            phraseCount = max(1, touched.count)
            for note in selected {
                guard let noteBlend = blendByNote[note.id],
                      noteBlend.phraseWeight > 0 else {
                    // This note's dot had no phrase content even though another
                    // note's did — full effort, the same answer the whole call
                    // used to give when no dot anywhere had any.
                    //
                    // ⚠️ `phraseWeight > 0` is EXACTLY the old `curve(scope:) != nil`
                    // gate, not an approximation of it: `Blend.members` is built
                    // `where weight > 0` (`EffortRing.blend(atAngle:radius:)`), so
                    // the scope's group is non-empty iff its weight is non-zero.
                    effortByNote[note.id] = 1
                    continue
                }
                // A note with no phrase cannot happen (every note of the clip is
                // in exactly one), but a caller-supplied id list is validated
                // against the clip and NOT against `allNotes` order, so the
                // fallback is stated rather than force-unwrapped: mid-phrase is
                // the least-wrong constant.
                let u = phraseOf[note.id]?.position(ofBeat: note.startBeat) ?? 0.5
                // ⭐ THE LAW, NOT THE VEHICLE (m28-p2-followup). `Blend.level` is
                // the blend law "pointwise and exact"; `Blend.curve` is the
                // PROJECTION of that law onto the `EffortPattern` family, which
                // exists because leg D's generator is parameterised and cannot be
                // handed a law. Here we need ONE scalar at ONE `u`, so the
                // projection is pure loss — and `u` is a note's position inside
                // its phrase, an arbitrary value that is almost never a knot,
                // which is precisely where the projection is inexact.
                //
                // ⚠️ This previously read `curve(scope:.phrase).evaluate(u:)` and
                // was wrong by up to 0.0048 of effort on a genuine two-pattern
                // ring (MEASURED, hairpinDiminuendo+terraced). It also broke
                // `EffortRing`'s stated invariant that every value the store reads
                // off a curve is a knot property and therefore exact — the ring of
                // ONE that P1/P2 shipped is a self-blend, whose union curve is the
                // pattern bit for bit, so no single-pattern test could see it.
                // `Blend.refinementSteps` stays at 8: it guards the vehicle for
                // leg D, and nothing now samples the vehicle between knots.
                let raw = noteBlend.level(scope: .phrase, u: u)
                // `amount` pulls effort toward FULL pressure, so amount 0 is
                // "no shaping" rather than "no air" — the same direction the
                // note-scoped branch's depth scaling goes. `phraseWeight` is
                // the dot's share of this axis; radius is ALREADY inside `raw`.
                effortByNote[note.id] = 1 - strength * noteBlend.phraseWeight * (1 - raw)
            }
        } else {
            for note in selected { effortByNote[note.id] = 1 }
        }

        // --- P5: THE 1/f DRIFT, applied to the REQUESTED effort --------------
        //
        // ⚠️ **Before the air sweep, and that ordering is load-bearing.** A
        // player who has drifted down is blowing less hard and therefore
        // consuming less air; sweeping the undrifted efforts and then drifting
        // afterwards would report a budget for a performance nobody gave.
        //
        // ⚠️ **It lands in `effortByNote`, which is what `minEffort`/`maxEffort`
        // are built from — deliberately, and the opposite of where P4 put the
        // air budget.** The distinction is what those two fields promise: *the
        // shape ran and varied nothing*. The budget is a CONSTRAINT on the
        // gesture, so it must not read as gesture variation; the drift IS
        // gesture — an involuntary one, but the pad asked for it, and a
        // note-scoped pattern whose written efforts really do differ must not
        // report `1.00 … 1.00`.
        //
        // ⚠️ **DOWNWARD ONLY** — see `Humanisation.driftDepth`. Effort 1 means
        // "as authored", so it is a ceiling, and `BreathContour.scaled` clamps
        // to it: a symmetric drift would be half rectified here and would ship
        // a lowered mean under the name "drift".
        let humanisation = rawHumanisation.sanitized()
        var driftMovedEffort = false
        if humanisation.driftDepth > 0 {
            for note in selected {
                let before = effortByNote[note.id] ?? 1
                let after = EffortField.drifted(effort: before, atBeat: note.startBeat,
                                                seed: field.seed, humanisation: humanisation)
                effortByNote[note.id] = after
                if after != before { driftMovedEffort = true }
            }
        }

        // --- Capability gating, through the ONE routing table ----------------
        var base = options
        // ⭐ m28-bug: gated on the RATE's image ratio, not on the mere fact of
        // hosting an AU. With the offline block at 512 frames the sampler runs
        // at 93.75 Hz and a 5.5 Hz vibrato's image is 6 % of it — far under the
        // 25 % cap — so this no longer fires for musical rates, and the vibrato
        // is written. It still fires above the ceiling, where it is true.
        let suppressVibrato = base.vibratoDepthCents > 0
            && MIDIControllerRouting.modulationAliasesUnacceptably(
                instrument: instrument, rateHz: base.vibratoRateHz)
        if suppressVibrato,
           let warning = MIDIControllerRouting.bendVibratoWarning(
               for: instrument, requestedRateHz: base.vibratoRateHz) {
            warnings.append(warning)
            base.vibratoDepthCents = 0
        }

        // ⛔ P5: THE MEASURED TREMOR CEILING. On a hosted AU our own offline
        // renderer feeds MIDI a block at a time, so a tremor comes back with a
        // sample-and-hold image at |f_s − rate| Hz. MEASURED for CC 11, not
        // inherited from the bend result — see
        // `MIDIControllerRouting.controllerModulationSamplingHz`.
        //
        // ⭐ **m28-bug LIFTED THIS FOR THE PHYSIOLOGICAL BAND.** P5 suppressed
        // unconditionally because at a 4096-frame block the ceiling was 2.34 Hz
        // — below the whole 4–8 Hz band a tremor IS, so there was no rate worth
        // writing. At 512 frames the ceiling is **18.75 Hz** and the band is
        // entirely under it: a 4.565 Hz tremor's image is 5 % of it, and the
        // rendered measurement agrees (87.7 % of authored depth at both 5.5 and
        // 8 Hz, image ratios 0.022 and 0.036 — `measure-gm-sax-cc.md` §6.6).
        // The gate stays, because it is still true above 18.75 Hz and
        // `tremorRateHz` is authorable to 20.
        //
        // Written as the same shape as the vibrato gate above, one line apart,
        // because they are the same law arriving on two lanes.
        var effectiveHumanisation = humanisation
        let suppressTremor = humanisation.tremorDepth > 0
            && MIDIControllerRouting.modulationAliasesUnacceptably(
                instrument: instrument, rateHz: humanisation.tremorRateHz)
        if suppressTremor,
           let warning = MIDIControllerRouting.tremorSuppressionWarning(
               for: instrument, requestedRateHz: humanisation.tremorRateHz) {
            warnings.append(warning)
            effectiveHumanisation.tremorDepth = 0
        }

        // --- Pattern → intra-note shape (note scope only) --------------------
        //
        // A phrase-scoped pattern leaves the intra-note shape at leg D's
        // default on purpose: it is authoring the phrase's arc, and overwriting
        // each note's internal gesture as well would make two different musical
        // statements from one control.
        //
        // ⚠️ P3 moved this INSIDE the per-note closure. It has to be there: with
        // a moving dot each note has its own note-scoped curve and its own note
        // weight. `base` keeps only what `applyBreathContourVarying` reads from
        // it (the lane's `expressionCC` and the point budget — see its doc) plus
        // the caller's own values, which is what every per-note lerp starts from.
        let tempo = transport.tempoMap
        let clipStart = clip.startBeat

        // --- P4: THE AIR BUDGET ----------------------------------------------
        //
        // Precomputed HERE, at prepare time, from the note layout — the render
        // path never computes a budget, it only plays back the CC events this
        // produced (design §9.1). Three decisions worth stating rather than
        // discovering:
        //
        // ⭐ **It sweeps EVERY note of the clip, not just the selection.** A
        // player who has been blowing since bar 1 does not arrive at bar 9 with
        // a full lungful because the caller only selected bar 9. Notes outside
        // the selection consume air at their authored level (effort 1) and can
        // be reported as short of air, but cannot be rewritten — `shaped` on
        // each constrained note is what says which is which, and a warning
        // names the count rather than letting it pass as a change that happened.
        //
        // ⭐ **The report is produced whether or not `enforced` is on.**
        // `enforced` decides only whether the lane changes; the prediction is
        // identical either way, which is what makes "what would this do?" a
        // question a caller can ask without mutating a project.
        //
        // ⛔ **`enforced` DEFAULTS TO FALSE — a USER RULING (2026-08-19).** An
        // air budget overrides what the composer wrote, and in this tree that is
        // opted into, once, visibly. `air == nil` means the caller never
        // mentioned it and gets the model switched off.
        let airSettings = air ?? .standard
        let selectedIDs = Set(selected.map(\.id))
        let airReport = AirBudget.sweep(
            voices: AirBudget.Voice.voices(
                from: allNotes,
                effort: { effortByNote[$0.id] ?? 1 },
                shaped: { selectedIDs.contains($0.id) }),
            phrases: phrases,
            tempo: tempo, clipStartBeat: clipStart,
            peakValue: base.peakValue, response: effectiveResponse,
            settings: airSettings)
        // The efforts that will actually be WRITTEN. When enforcement is off
        // this is `effortByNote` unchanged, by construction rather than by a
        // promise — `allowedByNote` is left empty.
        var allowedByNote: [UUID: Double] = [:]
        if airReport.applied {
            for note in airReport.constrainedNotes where note.shaped {
                allowedByNote[note.noteID] = note.effortAllowed
            }
        }
        func writtenEffort(_ id: UUID) -> Double {
            allowedByNote[id] ?? effortByNote[id] ?? 1
        }
        // ⛔⛔ **REQUESTED EFFORT, NOT WRITTEN — AND THE DIFFERENCE IS THE WHOLE
        // POINT OF THE FIELD.** `minEffort`/`maxEffort` are P1's "did this run
        // and shape nothing?" diagnostic, and the wire, the MCP tool and the
        // Copilot catalog all promise the same thing in the same words: *equal
        // values mean the shape ran and varied nothing*.
        //
        // I briefly built these from `writtenEffort`, and MEASURED what that
        // does: on a NOTE-SCOPED pattern, where every gesture asks for effort 1
        // and the P1 invariant is `min == max == 1`, enforcement turned it into
        // `min ≈ 0, max = 1` — which every one of those descriptions reads as
        // "the shape varied something". It did not. The BUDGET did.
        //
        // That is the one-symptom-two-causes ambiguity this feature is built to
        // avoid, smuggled into the one field that exists to be unambiguous. The
        // budget's effect on the lane already has a dedicated, per-note surface:
        // `air.constrainedNotes`, where `effortRequested` sits beside
        // `effortAllowed`. Nothing is hidden by keeping this pair about the
        // GESTURE; something is broken by making it about both.
        let efforts = selected.map { effortByNote[$0.id] ?? 1 }
        let minEffort = efforts.min() ?? 1
        let maxEffort = efforts.max() ?? 1

        func noteCurve(for note: MIDINote) -> EffortPattern? {
            blendByNote[note.id]?.curve(scope: .note)
        }

        // A pattern whose lowest point sits just after the attack (sforzando-
        // piano) needs the settling dip to be AT that point, and leg D measures
        // the dip in SECONDS. Convert per note through the tempo map so a tempo
        // ramp under the note is accounted for, exactly as the generator does.
        func settleSeconds(for note: MIDINote) -> Double? {
            guard let dipU = noteCurve(for: note)?.earlyDipPosition else { return nil }
            let start = clipStart + note.startBeat
            let duration = max(0, tempo.seconds(from: start, to: start + note.lengthBeats))
            // Interpolated away from the caller's own setting by `noteWeight`,
            // for the same reason the geometry below is: at full note weight
            // this is P1's `duration × dipU` exactly.
            let asked = duration * dipU
            let weight = blendByNote[note.id]?.noteWeight ?? 0
            return options.attackSettleSeconds
                + (asked - options.attackSettleSeconds) * weight
        }

        // ⚠️ Pure and repeatable: `applyBreathContourVarying` calls this more
        // than once per note (a budget retry re-generates everything) and the
        // reported counts must describe the contour that was written. It reads
        // only `blendByNote`, `effortByNote` and the caller's options — all
        // computed above and never mutated after.
        func optionsFor(_ note: MIDINote) -> BreathContour.Options {
            var o = base
            let noteWeight = blendByNote[note.id]?.noteWeight ?? 0
            let phraseWeight = blendByNote[note.id]?.phraseWeight ?? 0
            let curve = noteCurve(for: note)
            if let curve {
                // Interpolated AWAY FROM THE CALLER'S OWN OPTIONS, not from a
                // constant: at full note weight this is exactly P1's assignment,
                // and at zero it is exactly P1's phrase branch (which leaves the
                // intra-note shape alone). Anything in between is the dot sitting
                // between a note gesture and a phrase gesture, which is a real
                // place for it to be.
                func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * noteWeight }
                o.onsetLevel = lerp(options.onsetLevel, curve.normalisedOnsetLevel)
                o.releaseLevel = lerp(options.releaseLevel, curve.normalisedReleaseLevel)
                o.peakPosition = lerp(options.peakPosition,
                                      min(0.95, max(0.05, curve.peakPosition)))
            }
            // `travel` is the blended curve's own peak-to-trough excursion on
            // its 0...1 scale (radius already inside it); multiplying leg D's
            // depth by it is what makes a FLAT pattern (travel 0) produce a flat
            // lane rather than leg D's swell. The `+ phraseWeight` term is what
            // leaves a phrase-scoped dot at leg D's ordinary per-note contour.
            o.depth = options.depth
                * (noteWeight * (curve?.travel ?? 0) * strength + phraseWeight)
            if let settle = settleSeconds(for: note) { o.attackSettleSeconds = settle }
            // P4: the budget's answer when enforcement is on, the gesture's own
            // otherwise. `writtenEffort` reads only dictionaries computed above
            // and never mutated, so this stays pure across the budget retry.
            let effort = writtenEffort(note.id)
            // P5: the micro-tremor, per note.
            //
            // ⚠️ Depth deepens with the effort the note is actually WRITTEN at,
            // not the requested one — a note the budget pulled down is a note
            // the player has less pressure behind, which is the direction
            // §10.1's `effort^exponent` is arguing for in the first place.
            //
            // ⚠️ The phase is derived from the note's ONSET IN SECONDS FROM THE
            // CLIP START, so one continuous oscillator spans the clip rather
            // than restarting at every note. A per-note reset would put a step
            // in the pressure at every legato join (m27-o ⓑ deliberately
            // overlaps those) — and the involuntary layer is precisely the one
            // that should not know where the notes are. Clip-relative keeps it
            // loop-invariant for the same structural reason the dot is.
            if effectiveHumanisation.tremorDepth > 0 {
                o.tremorDepth = EffortField.tremorDepth(forEffort: effort,
                                                        humanisation: effectiveHumanisation)
                o.tremorRateHz = effectiveHumanisation.tremorRateHz
                o.tremorPhase = EffortField.tremorPhase(
                    atSeconds: tempo.seconds(from: clipStart, to: clipStart + note.startBeat),
                    seed: field.seed, humanisation: effectiveHumanisation)
            }
            return BreathContour.scaled(o, effort: effort, response: effectiveResponse)
        }

        let result = try applyBreathContourVarying(
            clipID: clipID, noteIDs: noteIDs, baseOptions: base,
            undoLabel: "Effort Shape", perNoteOptions: optionsFor)

        warnings += result.warnings
        warnings += padWarnings(dot: dot,
                                noteCurve: noteCurve,
                                reportRing: reportRing,
                                instrument: instrument,
                                strength: strength,
                                minEffort: minEffort,
                                maxEffort: maxEffort,
                                selected: selected,
                                settleSeconds: settleSeconds,
                                tempo: tempo,
                                clipStart: clipStart,
                                requestedResponse: response,
                                air: airReport,
                                airAsked: air != nil,
                                effectiveResponse: effectiveResponse,
                                driftMovedEffort: driftMovedEffort,
                                writtenTremorRateHz: effectiveHumanisation.tremorDepth > 0
                                    ? effectiveHumanisation.tremorRateHz : nil)

        // The DOMINANT member names the result. On the single-pattern form it
        // IS that pattern; on the ring it is the nearest gesture; on a MOVING
        // dot it is the gesture that carried the most weight summed over the
        // notes — which reduces to the other two exactly when the dot is still.
        let named = dot.dominantPattern
        return EffortShapeApplication(
            clip: result.clip,
            patternID: named.id,
            patternName: named.displayName,
            scope: named.scope,
            notesTouched: result.notesTouched,
            phraseCount: phraseCount,
            notesWithVibrato: result.notesWithVibrato,
            expressionPointCount: result.expressionPointCount,
            pitchBendPointCount: result.pitchBendPointCount,
            perNotePointBudget: result.perNotePointBudget,
            minEffort: minEffort,
            maxEffort: maxEffort,
            warnings: warnings,
            ring: reportRing
                // ⚠️ On a moving dot this is the ORIGIN — what the hand set —
                // and the weights are the ones AT the origin. Where the dot
                // actually travelled is `path`, which exists because folding a
                // wander into one angle would report a place the dot may never
                // have been.
                ? EffortRingReport(
                    angleDegrees: EffortRing.degrees(fromRadians: originBlend.angle),
                    radius: originBlend.radius,
                    patternIDs: originBlend.patternIDs,
                    weights: originBlend.weights,
                    noteWeight: originBlend.noteWeight,
                    phraseWeight: originBlend.phraseWeight)
                : nil,
            path: field.path == .fixed
                ? nil
                : EffortPathReport(
                    pathID: excursion.pathID,
                    seed: field.seed,
                    angleSweepDegrees: excursion.angleSweepDegrees,
                    startAngleDegrees: excursion.startAngleDegrees,
                    endAngleDegrees: excursion.endAngleDegrees,
                    minRadius: excursion.minRadius,
                    maxRadius: excursion.maxRadius,
                    patternIDs: excursion.patternIDs,
                    moved: excursion.moved,
                    outrunsNotes: excursion.outrunsNotes),
            air: airReport)
    }

    /// The dot's behaviour over the whole selection, reduced to the questions
    /// the warnings ask (P3).
    ///
    /// ⭐ **Every field here collapses to P2's exact question when the dot does
    /// not move**, which is what lets P1's and P2's warning assertions stay
    /// green word for word: with one blend repeated, a max over the notes is
    /// that blend's own value and the weight sum's argmax is its own dominant.
    fileprivate struct PadDotSummary {
        let blends: [EffortRing.Blend]
        /// The dot at the path's zero offset — where the hand put it.
        let origin: EffortRing.Blend
        let excursion: EffortField.Excursion

        /// The heaviest pattern SUMMED over the notes. Ties go to the lower ring
        /// index — the same rule `EffortRing.Blend.dominant` uses, restated here
        /// rather than assumed, so a tie at an exact midpoint resolves the same
        /// way on both paths.
        var dominantPattern: EffortPattern {
            guard let first = blends.first else { return origin.dominant.pattern }
            var totals = [Double](repeating: 0, count: first.weights.count)
            for blend in blends {
                for (i, w) in blend.weights.enumerated() where i < totals.count { totals[i] += w }
            }
            var best = 0
            for (i, total) in totals.enumerated() where total > totals[best] { best = i }
            // The ring is the same object at every note, so any blend's member
            // list resolves the index; `origin` is the one guaranteed present.
            for blend in blends {
                if let member = blend.members.first(where: { $0.index == best }) {
                    return member.pattern
                }
            }
            return origin.dominant.pattern
        }

        var maxPhraseWeight: Double { blends.map(\.phraseWeight).max() ?? origin.phraseWeight }
        var maxNoteWeight: Double { blends.map(\.noteWeight).max() ?? origin.noteWeight }
        var maxRadius: Double { blends.map(\.radius).max() ?? origin.radius }
    }

    /// The sentences leg D's own warnings cannot produce, because they are
    /// about the PATTERN rather than about the lane.
    ///
    /// Every capability claim here comes from `MIDIControllerRouting`, the ONE
    /// routing table — nothing in this file decides for itself what an
    /// instrument can do.
    ///
    /// ⚠️ **The scope tests here are WEIGHT tests, not `pattern.scope` tests**
    /// (P2). `phraseWeight == 0` is what "note-scoped" means once a dot can sit
    /// between two gestures, and on the single-pattern form the two are the
    /// same question — which is why P1's sentences are unchanged, word for word.
    fileprivate func padWarnings(dot: PadDotSummary,
                                 noteCurve: (MIDINote) -> EffortPattern?,
                                 reportRing: Bool,
                                 instrument: InstrumentDescriptor?,
                                 strength: Double,
                                 minEffort: Double,
                                 maxEffort: Double,
                                 selected: [MIDINote],
                                 settleSeconds: (MIDINote) -> Double?,
                                 tempo: TempoMap,
                                 clipStart: Double,
                                 requestedResponse: BreathContour.EffortResponse?,
                                 air: AirBudget.Report,
                                 airAsked: Bool,
                                 effectiveResponse: BreathContour.EffortResponse,
                                 driftMovedEffort: Bool,
                                 writtenTremorRateHz: Double?) -> [String] {
        var out: [String] = []
        let pattern = dot.dominantPattern

        // ⭐ THE INERT-PARAMETER WARNING. With no phrase-scoped content every
        // note is at effort 1, so `BreathContour.scaled` is the identity and the
        // response NEVER reaches the lane. Only an EXPLICIT response earns this
        // sentence: the default is non-identity, so warning on every default
        // call would bury the case where someone is really being ignored.
        //
        // ⚠️ **P4 ADDED THE SECOND CLAUSE AND IT REVERSES THE SENTENCE.** Air
        // enforcement can pull effort BELOW 1 on a note-scoped pattern, and then
        // `loudnessDepth`/`swellDepth` are exactly what makes the sag audible —
        // telling the caller they "did NOTHING" would be false, and would send
        // them to remove the two parameters that are carrying the effect. The
        // gate is written as the positive condition ("the budget really did not
        // touch this call") rather than as "the budget found something", because
        // the enforcement-off case must still warn: effort is still pinned at 1
        // there and the response really is inert.
        // ⚠️ SAME PREDICATE AS `wrote` IN `airWarnings` BELOW — "the budget
        // changed a note THIS CALL WROTE". Deliberately spelled out at both
        // sites rather than hoisted, because they are used for opposite
        // purposes (this one suppresses a warning, that one enables several);
        // if you change what it means, change BOTH.
        // ⚠️⚠️ **P5 ADDS THE THIRD CLAUSE AND IT REVERSES THE SENTENCE AGAIN,
        // in exactly the way P4's air clause did.** The 1/f drift pulls effort
        // BELOW 1 on a note-scoped pattern, and then `loudnessDepth`/
        // `swellDepth` are precisely what makes the drift audible — telling the
        // caller they "did NOTHING" would be false, and would send them to
        // delete the two parameters that are carrying the feature. Same shape,
        // same reason, one line apart, so the next layer that moves effort has
        // an obvious place to add itself.
        let airTouchedTheLane = air.applied && air.constrainedShapedCount > 0
        if dot.maxPhraseWeight == 0, !airTouchedTheLane, !driftMovedEffort,
           let asked = requestedResponse, asked != .identity {
            out.append(
                "loudnessDepth/swellDepth did NOTHING here and were not applied: they scale a "
                + "note by where it sits in a PHRASE, and \(pattern.displayName) is a note-scoped "
                + "pattern, so every note is at full effort. The phrase-scoped patterns are "
                + EffortPattern.library.filter { $0.scope == .phrase }
                    .map(\.id).joined(separator: ", ")
                + " — use one of those, or drop the two parameters")
        }

        // ⭐ P5: humanisation that cannot reach the lane. Effort — and so the
        // drift, which is only a change to effort — arrives at the CC lane
        // through `EffortResponse` and nowhere else, so with BOTH depths at 0 a
        // drifted note writes the byte-identical lane. This is P4's
        // `writtenEffortMakesNoDifference` finding arriving on a second feature,
        // and the reason it earns a sentence rather than a shrug is that the
        // call SUCCEEDS, writes a lane, and reports a drift that did nothing.
        //
        // ⚠️ Gated on `driftMovedEffort`, not on `driftDepth > 0`: a drift on a
        // single note at a lattice zero can legitimately move nothing, and a
        // sentence about a response that "will not be heard" would then be
        // naming the wrong cause.
        if driftMovedEffort, effectiveResponse == .identity {
            out.append(
                "the 1/f drift moved the effort but NOTHING will be heard: it reaches the lane "
                + "only through loudnessDepth/swellDepth, and both are 0 on this call, so every "
                + "drifted note writes the identical contour. Set loudnessDepth above 0 (0.35 is "
                + "the library default) or drop driftDepth")
        }

        // ⭐ P5: the tremor's own inert case, which is NOT the one above. A
        // tremor rides the contour directly and never passes through the effort
        // response, so it is live where the drift is not — but a tremor on a
        // note too short to complete one cycle is a level offset wearing an
        // oscillator's name. One cycle at the default 4.565 Hz is 219 ms.
        if let tremorRate = writtenTremorRateHz, !selected.isEmpty {
            let period = 1 / tremorRate
            var tooShort = 0
            for note in selected {
                let start = clipStart + note.startBeat
                let duration = max(0, tempo.seconds(from: start, to: start + note.lengthBeats))
                if duration > 0, duration < period { tooShort += 1 }
            }
            if tooShort > 0 {
                out.append(
                    "\(tooShort) of \(selected.count) selected notes are shorter than one "
                    + "micro-tremor cycle (\(String(format: "%.0f", period * 1000)) ms at "
                    + "\(String(format: "%.3g", tremorRate)) Hz), so on those the tremor is a "
                    + "small level offset rather than an oscillation. That is not a failure — a real player's tremor does not "
                    + "complete a cycle on a semiquaver either — but do not expect to hear it "
                    + "there")
            }
        }

        // The measured sound-bank limit. Deliberately NOT the same sentence leg
        // D emits for a built-in sampler with its filter off: that one names a
        // switch you can turn on, and this one names a capability that is not
        // there at all. Telling a sound-bank user to "set expressionFilterDepth"
        // would send them looking for a control their track does not have.
        if let kind = instrument?.kind, kind == .soundBank || kind == .audioUnit,
           !MIDIControllerRouting.expressionMovesBrightness(instrument: instrument) {
            out.append(
                "on this track the shape changes LOUDNESS only, not brightness: the instrument "
                + "is a hosted Audio Unit, where CC11 (expression) was measured to be exactly a "
                + "gain (any non-gain difference is below -104 dB). That is not a setting to "
                + "turn on — brightness shaping is a built-in Sampler capability. The gesture "
                + "still reads, it is a dynamics gesture")
        }

        // The one pattern whose accent depends on a feature the note may be too
        // short to afford — and the check is per note, because "too short" is a
        // property of the note, not of the pattern.
        // ⚠️ P3: the curve is fetched PER NOTE. With a moving dot the accent may
        // be present on some notes and absent on others, and asking one curve
        // for all of them would either invent an accent or hide one.
        if selected.contains(where: { noteCurve($0)?.earlyDipPosition != nil }) {
            var lost = 0
            for note in selected {
                guard let curve = noteCurve(note), curve.earlyDipPosition != nil,
                      let asked = settleSeconds(note) else { continue }
                let start = clipStart + note.startBeat
                let duration = max(0, tempo.seconds(from: start, to: start + note.lengthBeats))
                let peakTime = duration * min(0.95, max(0.05, curve.peakPosition))
                let granted = min(asked, duration * BreathContour.maxSettleFraction, peakTime * 0.5)
                if asked > 0, granted < asked * 0.5 { lost += 1 }
            }
            if lost > 0 {
                out.append(
                    "\(lost) of \(selected.count) notes are too short to hold the "
                    + "\(pattern.displayName) accent: the drop after the attack is clamped to a "
                    + "quarter of the note, so on those notes the gesture reads as an ordinary "
                    + "swell. It is not an error — the shape scales down rather than breaking")
            }
        }

        // ⚠️ Scope-specific, because "amount 0" does two DIFFERENT things and one
        // sentence covering both would be wrong for one of them — MEASURED: a
        // phrase-scoped pattern at amount 0 does NOT write a flat lane (33
        // distinct CC values in the wire test), because each note still gets the
        // ordinary contour; only the phrase ARC is gone. The single sentence
        // this replaced claimed the lane was flat, which was a plain untruth on
        // that path.
        //
        // ⭐ P2: `ringRadius` 0 produces the SAME silence for a DIFFERENT
        // reason, and it gets its own sentence rather than being folded in.
        // Telling a user who dragged the dot to the middle to "raise amount"
        // would send them to a control they never touched — the failure this
        // whole round exists to stop.
        let lever = reportRing && dot.maxRadius <= 0
            ? (name: "ringRadius is 0 (the dot is at the centre)", fix: "Drag the dot outwards")
            : (name: "amount is 0", fix: "Raise amount above 0")
        if strength <= 0 || dot.maxRadius <= 0 {
            if dot.maxPhraseWeight == 0 {
                out.append(
                    "\(lever.name), so the pattern shaped nothing: the expression lane was written "
                    + "flat at peakValue. \(lever.fix) to hear \(pattern.displayName)")
            } else {
                out.append(
                    "\(lever.name), so the phrase arc was flattened: every note got the same "
                    + "ordinary contour instead of its own place in the "
                    + "\(pattern.displayName). The lane is NOT flat — each note still breathes; "
                    + "what is missing is the shape across the phrase. \(lever.fix)")
            }
        } else if dot.maxNoteWeight == 0, maxEffort - minEffort < 0.01 {
            out.append(
                "the \(pattern.displayName) shape produced almost no variation across the "
                + "selected notes (effort \(String(format: "%.2f", minEffort)) to "
                + "\(String(format: "%.2f", maxEffort))): they all sit at nearly the same point "
                + "of one phrase, so a phrase-scoped pattern has nothing to travel across. Select "
                + "a longer span, or use a note-scoped pattern such as messaDiVoce")
        }

        // --- P3: what the PATH did, said out loud ----------------------------
        //
        // A moving dot has exactly two silent failures and both are reported
        // here rather than left for the caller to find by diffing lanes. Neither
        // is an error: the call succeeded and the lane is written.
        let excursion = dot.excursion
        if excursion.pathID != "fixed" {
            if !excursion.moved {
                out.append(
                    "the '\(excursion.pathID)' path did NOT move the dot over these notes "
                    + "(total travel \(String(format: "%.2f", excursion.angleSweepDegrees))°), so "
                    + "every note got the same gesture. For an orbit, revolutionBeats is longer "
                    + "than the part; for a drift, angleSwing is ~0 or scaleBeats is far longer "
                    + "than the notes span")
            } else if excursion.travelIsInsideOneGesture {
                // ⚠️ NAME THE DOMINANT GESTURE, NOT `patternIDs.first`. That
                // array is sorted by RING INDEX, so `.first` is the lowest index
                // the wander touched — and a small wander sitting ON a pattern
                // straddles its boundary and touches two. At 45° that made the
                // message say "never left flat" about a dot parked on
                // messaDiVoce: a warning that names the wrong gesture is worse
                // than no warning, because the caller then edits the wrong
                // thing. `dominantPattern` is weight-summed across the notes and
                // reduces to exactly this pattern when the dot is still.
                out.append(
                    "the dot moved (\(String(format: "%.1f", excursion.angleSweepDegrees))°) but "
                    + "never left \(pattern.displayName): the travel is "
                    + "less than a quarter of the "
                    + "\(String(format: "%.0f", excursion.ringSpacingDegrees))° gap between "
                    + "gestures, so nothing blended in. Widen angleSwing to flow from one gesture "
                    + "to another")
            }
            // ⭐ THE ALIASING WARNING. The dot is sampled ONCE PER NOTE, so the
            // note grid — not the render block rate — is what limits how fast a
            // path can be heard. Above its Nyquist the motion the caller hears
            // is an alias of the one they asked for, and it looks like a bug in
            // the pattern rather than a sampling limit.
            if excursion.outrunsNotes, let top = excursion.effectiveRateCyclesPerBeat {
                out.append(
                    "the path moves faster than these notes can sample it "
                    + "(\(String(format: "%.2f", top)) cycles per beat against notes arriving "
                    + "\(String(format: "%.2f", excursion.noteRatePerBeat)) per beat), so what "
                    + "you hear is an ALIAS of the motion, not the motion. The dot is read once "
                    + "per note by design — it chooses each note's gesture and cannot shape "
                    + "inside one. Slow the path (raise revolutionBeats or scaleBeats, or lower "
                    + "octaves) or shape within notes with a note-scoped pattern instead")
            }
        }

        out += airWarnings(air: air, airAsked: airAsked,
                           effectiveResponse: effectiveResponse)
        return out
    }

    /// ⭐⭐⭐ **THE LEGIBILITY SURFACE, LAYER 2** (design §9.4). Plain sentences
    /// beside a SUCCESSFUL result, the `MIDIControllerRouting.inertLaneWarning`
    /// idiom.
    ///
    /// The rule these obey: **whenever the budget changed the lane, the fact
    /// that it did is stated unconditionally**, even if nobody reads the detail.
    /// A phrase that goes quiet because a model decided the player ran out of
    /// air, with nothing saying so, is the silent modification of composer
    /// intent this whole round exists to remove.
    ///
    /// ⚠️ **Nothing here is emitted to a caller who never mentioned air.** The
    /// whole function is gated on `applied || airAsked` — the same presence
    /// idiom `requestedResponse` uses. With enforcement off and no air key sent,
    /// nothing was modified and nothing is being advised about; the report still
    /// ships in the result either way, so nothing is hidden, it is just not
    /// shouted at someone who never asked. Send one air key and the "it WOULD
    /// have" advisory appears; turn enforcement on and the sentences become
    /// unconditional.
    ///
    /// ⚠️ **And every claim of a CHANGE is gated on `wrote`, not `applied`.**
    /// Enforcement can be on and constrain only notes outside `noteIDs`, in
    /// which case this call wrote nothing and no sentence may quote a dB figure
    /// as if it had.
    ///
    /// ⚠️ Every sentence names the WIRE key that fixes it (`airCapacitySeconds`,
    /// `airEnforced`, …), not the design document's `air.capacitySeconds`.
    /// Sending someone to a key that does not exist is worse than saying nothing.
    fileprivate func airWarnings(air: AirBudget.Report,
                                 airAsked: Bool,
                                 effectiveResponse: BreathContour.EffortResponse)
        -> [String] {
        guard air.constrainedAnything else { return [] }
        // ⛔ **NOTHING BELOW IS UNSOLICITED.** Every sentence in this function is
        // about air, and a caller who neither turned enforcement on nor sent a
        // single air key asked for none of it. Without this gate a plain
        // `applyEffortShape(clipID:pattern:)` on any part with more than a few
        // seconds of continuous sounding time starts answering with "in the
        // worst phrase, the last 5 notes would be attenuated…" — a behaviour
        // change to a live verb, wearing the costume of help. The report still
        // ships in the result either way, so nothing is hidden; it is simply not
        // shouted at someone who never mentioned air.
        guard air.applied || airAsked else { return [] }
        var out: [String] = []
        func f(_ value: Double, _ places: Int = 2) -> String {
            String(format: "%.\(places)f", value)
        }

        // ⭐⭐ **DID ANY OF THIS REACH THE LANE THIS CALL WROTE?** `applied` alone
        // does not answer that. Enforcement can be ON, the budget can constrain
        // five notes, and every one of them can sit outside `noteIDs` — nothing
        // is rewritten, and a sentence reading "changed 0 of 2 shaped notes …
        // pulled down by up to 13.9 dB" then quotes an attenuation that never
        // happened to anything. That is precisely the defect class this round
        // exists to remove, committed by the warning written to prevent it.
        // ⚠️ Same expression as `airTouchedTheLane` at the inert-response
        // warning above. If you change what it means, change BOTH.
        let wrote = air.applied && air.constrainedShapedCount > 0
        // So every figure a sentence quotes is measured over the notes that
        // sentence is ABOUT: what was written, when something was; what would
        // be, when nothing was.
        func quoted(_ notes: [AirBudget.ConstrainedNote]) -> [AirBudget.ConstrainedNote] {
            wrote ? notes.filter(\.shaped) : notes
        }
        func loudestLoss(_ notes: [AirBudget.ConstrainedNote]) -> Double {
            quoted(notes).map { -$0.attenuationDb }.max() ?? 0
        }

        // The worst phrase, for the detail sentence. Chosen by attenuation, not
        // by position: "the phrase that lost the most" is the one a composer
        // will hear first.
        let worst = air.phrases
            .filter { !quoted($0.constrainedNotes).isEmpty }
            .max { a, b in
                loudestLoss(a.constrainedNotes) < loudestLoss(b.constrainedNotes)
            }

        if wrote {
            // ⭐ EMITTED UNCONDITIONALLY WHENEVER THE BUDGET CHANGED A NOTE THIS
            // CALL WROTE — §9.4 layer 2's third example, verbatim in intent. The
            // EXISTENCE of the effect is never silent even if nobody reads the
            // rest.
            out.append(
                "air enforcement changed \(air.constrainedShapedCount) of "
                + "\(air.notesShaped) shaped notes on this clip: the simulated player ran short "
                + "of breath and those notes were pulled down by up to "
                + "\(f(loudestLoss(air.constrainedNotes), 1)) dB. Every one of them is named in "
                + "this response's air.phrases[].constrainedNotes, with what it asked for "
                + "(effortRequested) beside what the budget allowed (effortAllowed). Set "
                + "airEnforced=false to turn this off")
        } else if air.applied {
            // Enforcement ON, budget bit, and not one bitten note was in the
            // selection. The lane this call wrote is byte-for-byte what it would
            // have been with `airEnforced=false`, and saying so is the whole
            // point — the `unshaped` sentence below carries the detail.
            out.append(
                "air enforcement is ON but changed NOTHING this call wrote: none of the "
                + "\(air.notesShaped) note\(air.notesShaped == 1 ? "" : "s") in your noteIds ran "
                + "short of air. The \(air.constrainedNoteCount) that did are elsewhere in this "
                + "clip and are named below")
        } else if airAsked {
            out.append(
                "air enforcement is OFF, so NOTHING was changed — but the model says the player "
                + "would have run short on \(air.constrainedNoteCount) of "
                + "\(air.notesConsidered) notes (down to \(f(air.maxAttenuationDb, 1)) dB, with "
                + "air reaching \(f(air.lowestAir)) of a lungful). Set airEnforced=true to hear "
                + "it. The air report in this response names every note either way")
        }

        if let worst {
            // ⚠️ COUNT AND dB OVER `quoted`, AND TENSE OFF `wrote`, NOT `applied`
            // — for the same reason as the summary above. "were attenuated" is a
            // claim about a lane that exists.
            let lost = quoted(worst.constrainedNotes).count
            let db = loudestLoss(worst.constrainedNotes)
            let after = worst.exhaustedAfterSeconds.map { "\(f($0, 1)) s into a " } ?? ""
            out.append(
                "\(wrote ? "the last" : "in the worst phrase, the last") \(lost) "
                + "note\(lost == 1 ? "" : "s") of the phrase starting at beat "
                + "\(f(worst.startBeat, 2)) "
                + "\(wrote ? "were" : "would be") attenuated by up to \(f(db, 1)) dB "
                + "because the simulated player ran out of air \(after)"
                + "\(f(worst.soundingSeconds, 1)) s phrase — raise airCapacitySeconds, play the "
                + "part softer (lower ringRadius or amount), or set airEnforced=false")
        }

        // §9.4's second example: a phrase the player never got a breath before.
        // Only when air actually carried over short — a full lungful arriving at
        // a phrase with no gap in front of it is not a problem worth a sentence.
        let starved = air.phrases.filter {
            if case .tooShort = $0.breath { return $0.airAtStart < 1 }
            return false
        }
        if let first = starved.first {
            let seconds = first.breath.seconds ?? 0
            out.append(
                "\(starved.count) phrase\(starved.count == 1 ? " has" : "s have") no gap longer "
                + "than \(f(air.settings.minBreathSeconds)) s before "
                + "\(starved.count == 1 ? "it" : "them"), so the player never got a breath — the "
                + "one at beat \(f(first.startBeat, 2)) follows a \(f(seconds)) s gap and "
                + "started on \(f(first.airAtStart)) of a lungful. Write a longer rest, or lower "
                + "airMinBreathSeconds")
        }

        if air.neverRecovered {
            // ⚠️ Two different situations wear the same flag and they need
            // different sentences: a part whose rests are too SHORT, and a part
            // with no rest at all. "The rests are too brief" is a confusing
            // thing to read about music that has none.
            let breathsTaken = air.phrases.reduce(0) {
                if case .taken = $1.breath { return $0 + 1 }
                return $0
            }
            let cause = breathsTaken == 0
                ? "there is no rest anywhere in this part longer than "
                    + "\(f(air.settings.minBreathSeconds)) s, so the player never gets to breathe"
                : "the rests in this part are too brief for airRefillSecondsPerSecond "
                    + "(\(f(air.settings.refillSecondsPerSecond)) of a lungful per second) to keep up"
            out.append(
                "air never came back to a full lungful after the first shortfall: \(cause), so the "
                + "sag ACCUMULATES across the part instead of resetting at each breath. Write "
                + "longer rests, or raise airRefillSecondsPerSecond")
        }

        // ⛔ THE INERT-ENFORCEMENT TRAP, and it is reachable from the wire:
        // `loudnessDepth: 0, swellDepth: 0` makes `BreathContour.scaled` the
        // identity, so a constrained effort writes the SAME lane. Without this
        // sentence the call reports "air enforcement changed 23 notes" and
        // nothing whatsoever is audible — a success, a written lane, and no
        // effect, which is precisely the defect class this round exists to end.
        // ⚠️ `wrote`, not `applied`: with nothing written there is no inert lane
        // to warn about, and the branch above has already said so.
        if wrote, effectiveResponse == .identity {
            out.append(
                "air enforcement constrained \(air.constrainedShapedCount) notes and NONE of it "
                + "will be audible: loudnessDepth and swellDepth are both 0, so a lower effort "
                + "writes exactly the same lane. Raise loudnessDepth (0.55 is the default, about "
                + "9 dB across a full hairpin), or set airEnforced=false")
        }

        // Notes the budget says are short of air that this call could not touch.
        let unshaped = air.constrainedNoteCount - air.constrainedShapedCount
        if unshaped > 0 {
            out.append(
                "\(unshaped) note\(unshaped == 1 ? " is" : "s are") short of air but "
                + "\(unshaped == 1 ? "is" : "are") NOT in the noteIds you selected, so "
                + "\(unshaped == 1 ? "it was" : "they were") left exactly as written — they still "
                + "consume air (the player is blowing on them) and the air report names them with "
                + "shaped=false. Shape the whole phrase, or omit noteIds")
        }

        return out
    }

    /// Extension-local clip lookup — `ProjectStore.locateClip(_:)` is private to
    /// ProjectStore.swift and not visible cross-file (the same reason
    /// ProjectStore+BreathContour.swift and ProjectStore+Humanize.swift each
    /// keep their own copy).
    private func locateClipForPad(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
