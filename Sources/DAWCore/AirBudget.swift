import Foundation

/// **THE AIR BUDGET** — a wind player has a finite lungful, and a phrase that
/// runs past it sags (breath-pad P4, `docs/research/design-breath-pad.md` §9).
///
/// ## THE ONE RULE THIS FILE EXISTS TO OBEY
///
/// ⭐⭐⭐ **If the budget makes something quieter, the report says which notes
/// and by how much.** A phrase that goes quiet because a model decided the
/// player ran out of air, with nothing saying so, is a silent modification of
/// composer intent — the exact defect this whole round exists to remove (seven
/// CC 11 lanes that were stored, displayed, and completely inert). Every number
/// this file computes exists so that "why did this get quiet?" has an answer the
/// composer can read: `AirBudgetReport.constrainedNotes` names each note,
/// `effortRequested` says what the gesture asked for, `effortAllowed` says what
/// the budget left, and `attenuationDb` says the audible size of the difference.
///
/// ⛔ **`enforced` DEFAULTS TO `false`, and that is a USER RULING (2026-08-19),
/// not a preference to be optimised away.** An air budget OVERRIDES what the
/// composer wrote, and in this tree anything that does that is opted into, once,
/// visibly. Do not "helpfully" default it true. The report is computed either
/// way, so a caller can always see what enforcement *would* do before turning it
/// on.
///
/// ## "Why did this get quiet?" — the two causes, kept apart
///
/// A phrase can decay for exactly two reasons and this feature keeps them
/// distinguishable on purpose:
///
/// 1. **The composer chose a decay** — `hairpinDiminuendo`, or a dot drifting
///    toward it. That shows up as a low `effortRequested`, and the ring report
///    names the gesture.
/// 2. **The budget took it away** — that, and only that, produces
///    `effortAllowed < effortRequested`, with the note named.
///
/// ⛔ This is also why **"air runs out" is NOT in `EffortPattern.library`** and
/// must never be added: if a user could *select* the symptom the budget
/// separately *produces*, the two causes would be indistinguishable in the
/// result and the sentence above would stop being true. `EffortPatternTests`
/// guards the absence; this comment is the reason.
///
/// ## Everything here is PURE, and it runs at PREPARE time
///
/// No store, no engine, no clock, no randomness. The sweep is a function of the
/// notes, the tempo map and the settings — the `BreathContour` / `EffortField`
/// precedent. **The render path never computes a budget**; it only ever plays
/// back the CC events this produced, which is what keeps the RT side
/// arithmetic-only.
///
/// Sweeping forward IS stateful, and that does not violate THE PAD LAW (§5.1):
/// the state lives inside one call, over a deterministic note list, and nothing
/// crosses between calls. The same clip and settings always give the same
/// report.
///
/// ## FOUR LIMITS, STATED HERE RATHER THAN DISCOVERED BY EAR
///
/// ⚠️ **1. A note's effort is fixed at its START, so a long note cannot sag
/// mid-note.** A four-beat held note that begins with full air is written at
/// full effort however far air falls while it sounds; the sag lands on the
/// *next* note. That is not an oversight — leg D's generator takes one
/// `BreathContour.Options` per note, and building a second lane-writing path to
/// vary effort inside a note is forbidden (`ProjectStore+BreathPad.swift`). It
/// is the same resolution limit P3 documented for the dot, and for the same
/// reason: the note grid. `AirBudgetTests` pins it so it cannot be "fixed"
/// silently.
///
/// ⚠️ **2. Consumption reads the per-note effort SCALAR, not the shape inside
/// the note.** A note-scoped gesture (`messaDiVoce`, `subToneEntry`) leaves
/// every note at effort 1, so a whispered sub-tone consumes exactly as much air
/// as a full-voiced one. Integrating the written contour would be more
/// physical, but it is circular — the contour's peak depends on the effort the
/// budget is computing — and any non-circular substitute is an invented factor.
/// The design's §9.1 says `effort`; this is `effort`.
///
/// ⚠️ **3. WHAT THE DEFAULTS ACTUALLY DO — MEASURED, not estimated.**
/// `AirBudgetTests.realisticPartMeasurement` runs 16 bars of 4/4 at 120 bpm
/// phrased in two-bar groups with one beat of rest between them — an ordinary
/// ballad line, not a drone — and prints the answer:
///
/// | played at | constrained | phrases exhausted | worst note |
/// |---|---|---|---|
/// | effort 1 (as authored) | **34 of 56** | 7 of 8 | −9.1 dB |
/// | effort 0.6 (mezzo) | **0 of 56** | 0 of 8 | — |
///
/// So with `enforced` on, a part written at full pressure with a one-beat catch
/// breath every two bars sags over most of its second half, and `neverRecovered`
/// fires: 3.5 s of blowing costs 0.58 of a lungful and a 0.25 s rest returns
/// 0.125, so the player is permanently in debt. **That is the model working, not
/// a bug** — but it is aggressive, it is driven by `refillSecondsPerSecond`
/// (the §9.3 estimate this measurement puts the most pressure on), and it is
/// written down here so the next person changes it on evidence rather than
/// rediscovering it by ear. The same part at a mezzo dynamic is untouched, which
/// is the discrimination the feature exists for.
///
/// ⚠️ **4. The report is the ENFORCED trajectory, in both modes.** Allowed
/// effort (not requested) is what consumes air, because a player running short
/// really does blow softer and so lasts longer. When `enforced` is false the
/// lane is untouched and the report is therefore a **counterfactual**: it
/// answers "what would enforcement change?", which is the useful question, and
/// it is why the field is `effortAllowed` and not `effortDelivered`. Read
/// `applied` before quoting any of it as a description of the lane.
public enum AirBudget {

    // MARK: - Settings

    /// The model's parameters. **Every one is an estimate** (design §9.3) —
    /// which is exactly why they are all exposed rather than shipped as hidden
    /// constants. A model whose parameters are guesses and which cannot be
    /// re-tuned is a model that quietly overrides composer intent with a guess.
    public struct Settings: Sendable, Equatable {

        /// ⛔ **DEFAULTS TO `false`. USER RULING 2026-08-19.** See the type's
        /// header. When false, the sweep still runs and the report is still
        /// returned — nothing is written differently.
        public var enforced: Bool

        /// How long the player can sustain the part **as authored** (effort 1)
        /// before the lungful is gone. **(estimate)** — 6.0, the middle of the
        /// 4–8 s comfortable-phrase band design §9.3 quotes and did not find a
        /// source for.
        ///
        /// ⭐ **§9.1's `referenceEffort` is DELIBERATELY ABSENT and its absence
        /// is algebra, not an omission.** The design's rate is
        /// `(effort/referenceEffort)^k / capacitySeconds`, which expands to
        /// `effort^k / (referenceEffort^k · capacitySeconds)` — so
        /// `referenceEffort` and `capacitySeconds` are provably ONE axis and only
        /// their combination is observable. Shipping both would be two controls
        /// with one visible outcome, which is the trap P2 documented for
        /// `ringRadius` and `amount` and the ambiguity §7.2 rejects elsewhere.
        ///
        /// ⚠️ It also fixes a units mismatch that would otherwise have shipped:
        /// `effort` here is `BreathContour.scaled`'s **reduction factor**, where
        /// 1 means "exactly as authored" — *not* an absolute blowing pressure.
        /// Feeding a reduction factor of 1 into `(effort/0.6)^1.5` reads every
        /// unshaped note as fortissimo and consumes 2.15× faster than the quoted
        /// capacity, so the reserve would be crossed after 2.09 s rather than the
        /// 4.5 s the number says. Quoting capacity at the authored level is the
        /// reading in which `capacitySeconds` means what §9.3 claims it means.
        public var capacitySeconds: Double

        /// `rate = effort^k`. **(estimate)** — 1.5, superlinear because blowing
        /// pressure rises steeply into fortissimo (§2.2's >120 cm H₂O figure,
        /// itself abstract-level). At 1.5 a phrase at half the authored level
        /// lasts 2.8× longer than one at full.
        public var consumptionExponent: Double

        /// How fast a rest refills, in units of capacity per second.
        /// **(estimate)** — 0.5, so a 2-second rest fully refills an empty
        /// player.
        public var refillSecondsPerSecond: Double

        /// A rest shorter than this is an articulation, not a breath, and
        /// refills nothing. **(estimate)** — 0.15 s, cross-checked against
        /// `HumanizeLegato.defaultMaxGapBeats = 0.125` beats (0.25 s at 120 bpm)
        /// so the two thresholds sit in the same range instead of contradicting.
        ///
        /// ⚠️ **This threshold is in SECONDS and the phrase-splitting one is in
        /// BEATS**, so they genuinely disagree at extreme tempi — at 240 bpm a
        /// gap can split the phrase (0.13 beats > 0.125) and still be too short
        /// to breathe in (0.032 s < 0.15). That is not a bug: it is a player
        /// whose rest was too quick to get a breath, and the report says so with
        /// `Breath.tooShort` rather than pretending one was taken.
        public var minBreathSeconds: Double

        /// Below this fraction of a lungful the player starts running out and
        /// effort is scaled by `air / reserveFraction`, so the phrase SAGS
        /// toward the floor rather than cutting off. **(estimate)** — 0.25.
        public var reserveFraction: Double

        public init(enforced: Bool = false,
                    capacitySeconds: Double = 6,
                    consumptionExponent: Double = 1.5,
                    refillSecondsPerSecond: Double = 0.5,
                    minBreathSeconds: Double = 0.15,
                    reserveFraction: Double = 0.25) {
            self.enforced = enforced
            self.capacitySeconds = capacitySeconds
            self.consumptionExponent = consumptionExponent
            self.refillSecondsPerSecond = refillSecondsPerSecond
            self.minBreathSeconds = minBreathSeconds
            self.reserveFraction = reserveFraction
        }

        /// The defaults, `enforced` false. The name a caller reads when they
        /// mean "the model, switched off".
        public static let standard = Settings()

        /// Every value forced into its domain, with NaN mapped to the default
        /// rather than propagated.
        ///
        /// ⚠️ **`pow(negative, 1.5)` is NaN and a NaN air level compares false
        /// against every threshold**, so an unguarded hand-authored wire payload
        /// would produce a report full of NaN that reads as "nothing was
        /// constrained". The wire bounds these too; this is the second fence,
        /// because DAWCore is callable without the wire.
        public var sanitized: Settings {
            func finite(_ value: Double, _ fallback: Double, min lo: Double, max hi: Double)
                -> Double {
                guard value.isFinite else { return fallback }
                return Swift.min(hi, Swift.max(lo, value))
            }
            var out = self
            // A capacity of 0 would divide by zero. The floor is a millisecond
            // of air: absurd, but finite and monotonic, which is what the sweep
            // needs.
            out.capacitySeconds = finite(capacitySeconds, 6, min: 0.001, max: 3600)
            out.consumptionExponent = finite(consumptionExponent, 1.5, min: 0, max: 8)
            out.refillSecondsPerSecond = finite(refillSecondsPerSecond, 0.5, min: 0, max: 1000)
            out.minBreathSeconds = finite(minBreathSeconds, 0.15, min: 0, max: 60)
            out.reserveFraction = finite(reserveFraction, 0.25, min: 0, max: 1)
            return out
        }
    }

    // MARK: - What the sweep is given

    /// One sounding note, reduced to what the budget needs. Deliberately NOT
    /// `MIDINote`: the budget is about time and pressure, and a type that
    /// carried pitch would invite a model that reads it.
    public struct Voice: Sendable, Equatable {
        public var noteID: UUID
        /// Clip-relative.
        public var startBeat: Double
        public var endBeat: Double
        /// What the gesture asked for, 0…1, in `BreathContour.scaled`'s units
        /// where **1 is "exactly as authored"**.
        public var effortRequested: Double
        /// Is this note in the caller's selection — i.e. can the budget's answer
        /// actually be WRITTEN? A clip's unselected notes still consume air (the
        /// player is blowing on them) but cannot be re-shaped, and conflating
        /// the two would report a change that never reached a lane.
        public var shaped: Bool

        public init(noteID: UUID, startBeat: Double, endBeat: Double,
                    effortRequested: Double, shaped: Bool) {
            self.noteID = noteID
            self.startBeat = startBeat
            self.endBeat = endBeat
            self.effortRequested = effortRequested
            self.shaped = shaped
        }

        /// Build the whole voice list from a clip's notes.
        ///
        /// ⚠️ Pass **every** note of the clip, not just the selection: a player
        /// who has been blowing since bar 1 does not arrive at bar 9 with a full
        /// lungful because the caller only selected bar 9.
        public static func voices(from notes: [MIDINote],
                                  effort: (MIDINote) -> Double,
                                  shaped: (MIDINote) -> Bool) -> [Voice] {
            notes.map {
                Voice(noteID: $0.id,
                      startBeat: $0.startBeat,
                      endBeat: Swift.max($0.startBeat, $0.endBeat),
                      effortRequested: effort($0),
                      shaped: shaped($0))
            }
        }
    }

    // MARK: - What the sweep answers — THE LEGIBILITY SURFACE (design §9.4)

    /// What happened before a phrase started: the answer to "did he get a
    /// breath?".
    ///
    /// ⭐ **Three cases, not `Double?`.** Design §9.4 models this as
    /// `breathTakenBeforeBeat: Double?` with "nil = no breath available", which
    /// conflates *the player has not started yet* with *there was a gap and it
    /// was too short to breathe in* — two situations with opposite fixes (none,
    /// versus "insert a rest"). One symptom, two causes, no way to tell them
    /// apart is the exact ambiguity this round exists to end, so the report says
    /// which.
    public enum Breath: Sendable, Equatable {
        /// The first phrase: there is no preceding music, and the player starts
        /// on a full lungful. Never a problem, never warned about.
        case none
        /// A rest of at least `minBreathSeconds` ended here.
        case taken(beat: Double, seconds: Double)
        /// There WAS a gap and it was too short to be a breath, so air carried
        /// straight over from the previous phrase.
        case tooShort(beat: Double, seconds: Double)

        /// Where the gap began, for the two cases that have one.
        public var beat: Double? {
            switch self {
            case .none: return nil
            case let .taken(beat, _), let .tooShort(beat, _): return beat
            }
        }

        /// How long it was, in seconds.
        public var seconds: Double? {
            switch self {
            case .none: return nil
            case let .taken(_, seconds), let .tooShort(_, seconds): return seconds
            }
        }

        /// The stable wire spelling.
        public var id: String {
            switch self {
            case .none: return "none"
            case .taken: return "taken"
            case .tooShort: return "tooShort"
            }
        }
    }

    /// One note the budget pulled down, and everything needed to argue with it.
    ///
    /// ⭐ **`effortRequested` alongside `effortAllowed` is the whole point.**
    /// "This note is at 0.42" is not legible. "This note asked for 0.78 and the
    /// budget allowed 0.42, −5.4 dB, with air at 0.19" is.
    public struct ConstrainedNote: Sendable, Equatable {
        public var noteID: UUID
        /// Clip-relative start.
        public var beat: Double
        /// What the gesture asked for.
        public var effortRequested: Double
        /// What the budget left. ⚠️ **Allowed, not delivered** — when
        /// `AirBudgetReport.applied` is false this note was written at
        /// `effortRequested` and nothing was taken away.
        public var effortAllowed: Double
        /// Air at this note's start, 0…1.
        public var airAtNote: Double
        /// The expression-lane peak the gesture asked for, and the one the
        /// budget leaves. Integers, and exact — unlike the dB below, these
        /// involve no assumption about how an instrument reads CC 11.
        public var peakCCRequested: Int
        public var peakCCAllowed: Int
        /// The audible size of the difference, negative.
        ///
        /// ⚠️ **This is the SQUARE-LAW reading**, which is the MEASURED
        /// behaviour of CC 11 on the hosted-AU path — every `.soundBank` track,
        /// so the GM sax (`docs/research/measure-gm-sax-cc.md`, 2026-08-19). On
        /// the BUILT-IN sampler P2 measured CC 11 as closer to LINEAR, so the
        /// real figure there is roughly half this many dB. The two CC integers
        /// above are the unambiguous facts; this is the reading, and it is the
        /// conservative (larger) one.
        public var attenuationDb: Double
        /// Was this note in the caller's selection? A constrained note with
        /// `shaped == false` is one the budget says is short of air and the call
        /// could not rewrite.
        public var shaped: Bool
    }

    /// One phrase's account of itself.
    public struct PhraseReport: Sendable, Equatable {
        /// Clip-relative, from `PhraseDetection.Phrase`.
        public var startBeat: Double
        public var endBeat: Double
        /// What happened in the gap before it.
        public var breath: Breath
        /// Air at the first note's start, and after the last note stopped.
        public var airAtStart: Double
        public var airAtEnd: Double
        /// The lowest air reached anywhere inside the phrase.
        public var lowestAir: Double
        /// Did air fall below `reserveFraction` — i.e. did the player start
        /// running out?
        public var exhausted: Bool
        /// How long the player was actually blowing, in seconds. Overlapping
        /// notes count ONCE: this is sounding time, not summed note lengths.
        public var soundingSeconds: Double
        /// Sounding seconds elapsed when air first fell below the reserve, or
        /// nil if it never did. The number the §9.4 warning quotes.
        public var exhaustedAfterSeconds: Double?
        /// Every note the budget pulled down, in start order.
        public var constrainedNotes: [ConstrainedNote]
    }

    /// The whole answer. `Sendable`, `Equatable`, and it crosses no boundary
    /// DAWCore does not own.
    public struct Report: Sendable, Equatable {
        /// ⭐ **Did any of this reach the lane?** `false` means `enforced` was
        /// off and everything below is a counterfactual: what enforcement WOULD
        /// have done. Read this before quoting `effortAllowed` as fact.
        public var applied: Bool
        /// The settings the sweep actually ran with, after sanitising — so a
        /// caller who sent a nonsense capacity sees what it became.
        public var settings: Settings
        /// How many notes were swept. This is the whole clip, not the selection.
        public var notesConsidered: Int
        /// How many of those were the caller's to rewrite.
        public var notesShaped: Int
        public var phrases: [PhraseReport]
        /// The lowest air reached anywhere in the clip.
        public var lowestAir: Double
        /// True when air never returned to a full lungful after first running
        /// short — the rests in this part are too brief for
        /// `refillSecondsPerSecond` to keep up, so the sag accumulates instead of
        /// resetting each phrase. Its own field because the fix is different
        /// (write longer rests, or raise the refill rate) from every other
        /// warning here.
        public var neverRecovered: Bool

        /// Every constrained note across every phrase, in start order.
        public var constrainedNotes: [ConstrainedNote] {
            phrases.flatMap(\.constrainedNotes)
        }

        /// How many notes the budget pulled down at all.
        public var constrainedNoteCount: Int { constrainedNotes.count }

        /// How many of those could actually be written.
        public var constrainedShapedCount: Int {
            constrainedNotes.reduce(0) { $0 + ($1.shaped ? 1 : 0) }
        }

        /// The ids, for a caller that wants to select them.
        public var constrainedNoteIDs: [UUID] { constrainedNotes.map(\.noteID) }

        /// The biggest single attenuation, as a POSITIVE number of dB. 0 when
        /// nothing was constrained.
        public var maxAttenuationDb: Double {
            constrainedNotes.map { -$0.attenuationDb }.max() ?? 0
        }

        /// Did the budget do anything at all? **The one field a caller must read
        /// to know whether "why did this get quiet?" has an air answer.**
        public var constrainedAnything: Bool { !constrainedNotes.isEmpty }

        /// The phrases where air fell below the reserve.
        public var exhaustedPhraseCount: Int {
            phrases.reduce(0) { $0 + ($1.exhausted ? 1 : 0) }
        }

        /// A clip with no notes: the honest empty answer, not a nil.
        public static func empty(settings: Settings, applied: Bool) -> Report {
            Report(applied: applied, settings: settings, notesConsidered: 0, notesShaped: 0,
                   phrases: [], lowestAir: 1, neverRecovered: false)
        }
    }

    // MARK: - The never-silent floor (design §9.6)

    /// The smallest effort that still leaves a **sounding** note.
    ///
    /// ⛔ §9.6: the budget must never make a note silent. That is not free, and
    /// the hole is REACHABLE ONLY IN P4: `BreathContour.scaled` computes
    /// `peak × (1 − loudnessDepth × (1 − effort))`, so at `loudnessDepth == 1`
    /// (which the wire accepts) and air 0 the peak becomes exactly 0 — a written
    /// lane that mutes the note. Before enforcement existed, effort was pinned
    /// at 1 for every note that had no phrase content and the shortfall term was
    /// always 0, so nothing could reach it.
    ///
    /// Binary-searched against `BreathContour.scaled` itself rather than
    /// re-deriving the inverse, so the floor cannot drift from the law it is
    /// protecting. Monotonic in `effort`, so the search is exact to 2⁻⁴⁰.
    ///
    /// Returns 0 when the caller's own `peakValue` is already silent: a note the
    /// composer muted is not the budget's doing, and raising it would be a
    /// louder note than they asked for.
    public static func minimumEffort(peakValue: Int,
                                     response: BreathContour.EffortResponse) -> Double {
        var probe = BreathContour.Options()
        probe.peakValue = peakValue
        func peak(at effort: Double) -> Int {
            BreathContour.scaled(probe, effort: effort, response: response).peakValue
        }
        guard peak(at: 1) >= 1 else { return 0 }
        guard peak(at: 0) < 1 else { return 0 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if peak(at: mid) >= 1 { hi = mid } else { lo = mid }
        }
        return hi
    }

    // MARK: - The sweep

    /// Sweep `air ∈ [0,1]` forward over the clip and report what it cost.
    ///
    /// ## The model (design §9.1)
    ///
    /// - While anything sounds: `air −= dt · effort^k / capacitySeconds`, where
    ///   `effort` is the loudest ALLOWED effort among the notes sounding.
    /// - While resting for at least `minBreathSeconds`:
    ///   `air += dt · refillSecondsPerSecond`, clamped to 1.
    /// - A note starting while `air < reserveFraction` is allowed only
    ///   `effort × air / reserveFraction`, floored so it still sounds.
    ///
    /// ⚠️ **Seconds, through the `TempoMap`, never a scalar seconds-per-beat.**
    /// A tempo ramp under a phrase changes how long the player has been blowing,
    /// and a scalar would pass every test that has no ramp in it.
    ///
    /// ⚠️ **Overlapping notes count ONCE.** A chord is one player breathing, not
    /// four, so the sweep walks *sounding intervals* and takes the loudest
    /// demand — the same "a player who is still making a sound has not taken a
    /// breath" reasoning `PhraseDetection` uses for its own grouping.
    ///
    /// `phrases` must be the ones `PhraseDetection.phrases(in:maxGapBeats:)`
    /// returned for the same notes — the tree has ONE definition of a breath and
    /// this is not allowed to grow a second.
    public static func sweep(voices: [Voice],
                             phrases: [PhraseDetection.Phrase],
                             tempo: TempoMap,
                             clipStartBeat: Double,
                             peakValue: Int,
                             response: BreathContour.EffortResponse,
                             settings: Settings) -> Report {
        let s = settings.sanitized
        guard !voices.isEmpty else { return .empty(settings: s, applied: s.enforced) }

        // Effort floors and clamps up front: nothing below may see a NaN.
        let floorEffort = minimumEffort(peakValue: peakValue, response: response)
        let requested: [Double] = voices.map {
            $0.effortRequested.isFinite ? min(1, max(0, $0.effortRequested)) : 1
        }

        // --- The event walk -------------------------------------------------
        //
        // Marks are every distinct start and end. At each mark: retire the notes
        // that have stopped, admit the notes that begin (which is where their
        // allowed effort is decided, from the air at that instant), then retire
        // again so a ZERO-LENGTH note does not stay active forever — it is added
        // after its own end was processed, and without the second drain it would
        // consume for the rest of the clip.
        var marks: [Double] = []
        marks.reserveCapacity(voices.count * 2)
        for voice in voices where voice.startBeat.isFinite && voice.endBeat.isFinite {
            marks.append(voice.startBeat)
            marks.append(voice.endBeat)
        }
        guard !marks.isEmpty else { return .empty(settings: s, applied: s.enforced) }
        marks.sort()
        var distinct: [Double] = [marks[0]]
        for mark in marks.dropFirst() where mark != distinct[distinct.count - 1] {
            distinct.append(mark)
        }

        // ⚠️ NaN beats are filtered out of the ORDERINGS, not merely skipped in
        // the walk. `sorted(by:)` requires a strict weak ordering and a NaN
        // makes every comparison false, which is a precondition violation and
        // can trap — a hand-authored wire payload must not be able to do that.
        // A voice with a non-finite beat is simply never admitted, so it keeps
        // its requested effort and is never reported as constrained.
        let usable = voices.indices.filter {
            voices[$0].startBeat.isFinite && voices[$0].endBeat.isFinite
        }
        let byStart = usable.sorted {
            voices[$0].startBeat == voices[$1].startBeat
                ? $0 < $1 : voices[$0].startBeat < voices[$1].startBeat
        }
        let byEnd = usable.sorted {
            voices[$0].endBeat == voices[$1].endBeat
                ? $0 < $1 : voices[$0].endBeat < voices[$1].endBeat
        }

        var allowed = requested
        var airAtNote = [Double](repeating: 1, count: voices.count)
        /// Air AT each mark, before the segment starting there is consumed.
        var airAtMark = [Double](repeating: 1, count: distinct.count)
        /// One record per segment, so phrase attribution is a post-pass rather
        /// than a second walk that could disagree with this one.
        var segments: [(startBeat: Double, seconds: Double, sounding: Bool,
                        airAfter: Double, active: [Int])] = []
        segments.reserveCapacity(distinct.count)

        var air = 1.0
        var lowestAir = 1.0
        var startIndex = 0, endIndex = 0
        var active = Set<Int>()

        func drainEnds(through beat: Double) {
            while endIndex < byEnd.count, voices[byEnd[endIndex]].endBeat <= beat {
                active.remove(byEnd[endIndex])
                endIndex += 1
            }
        }

        for (k, beat) in distinct.enumerated() {
            drainEnds(through: beat)
            while startIndex < byStart.count, voices[byStart[startIndex]].startBeat <= beat {
                let index = byStart[startIndex]
                airAtNote[index] = air
                // THE CONSTRAINT. Above the reserve nothing happens at all —
                // `min(1, …)` is what makes a well-supplied phrase report an
                // empty `constrainedNotes` rather than a list of no-ops.
                let headroom = s.reserveFraction > 0
                    ? min(1, air / s.reserveFraction)
                    : 1
                var value = requested[index] * headroom
                // §9.6: never to silence. Only ever raises, and never above what
                // was asked for.
                if value < floorEffort { value = min(requested[index], floorEffort) }
                allowed[index] = value
                active.insert(index)
                startIndex += 1
            }
            drainEnds(through: beat)
            airAtMark[k] = air
            lowestAir = min(lowestAir, air)

            guard k + 1 < distinct.count else { break }
            let next = distinct[k + 1]
            let seconds = max(0, tempo.seconds(from: clipStartBeat + beat,
                                               to: clipStartBeat + next))
            let sounding = !active.isEmpty
            if sounding {
                // The loudest demand among the voices sounding here. A player
                // supporting a fortissimo note is not also resting because a
                // quiet one overlaps it.
                let effort = active.map { allowed[$0] }.max() ?? 0
                let rate = pow(max(0, effort), s.consumptionExponent) / s.capacitySeconds
                air = max(0, air - seconds * rate)
            } else if seconds >= s.minBreathSeconds {
                air = min(1, air + seconds * s.refillSecondsPerSecond)
            }
            lowestAir = min(lowestAir, air)
            segments.append((startBeat: beat, seconds: seconds, sounding: sounding,
                             airAfter: air, active: active.sorted()))
        }

        // --- Phrase attribution ----------------------------------------------
        var phraseOfNote: [UUID: Int] = [:]
        for (index, phrase) in phrases.enumerated() {
            for id in phrase.noteIDs { phraseOfNote[id] = index }
        }
        var voiceIndexOfID: [UUID: Int] = [:]
        for (index, voice) in voices.enumerated() { voiceIndexOfID[voice.noteID] = index }

        func airAt(beat: Double) -> Double {
            // The marks are sorted; a phrase's start and end are both marks by
            // construction, but a binary search that misses degrades to the
            // nearest earlier mark rather than trapping.
            var lo = 0, hi = distinct.count - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if distinct[mid] <= beat { best = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return airAtMark[best]
        }

        var probe = BreathContour.Options()
        probe.peakValue = peakValue
        func peak(_ effort: Double) -> Int {
            BreathContour.scaled(probe, effort: effort, response: response).peakValue
        }

        var phraseReports: [PhraseReport] = []
        for (index, phrase) in phrases.enumerated() {
            // Which segments belong to this phrase: any sounding segment whose
            // active voices include one of its notes.
            var soundingSeconds = 0.0
            var exhaustedAfter: Double?
            var lowest = airAt(beat: phrase.startBeat)
            for segment in segments {
                let mine = segment.active.contains {
                    phraseOfNote[voices[$0].noteID] == index
                }
                guard mine else { continue }
                if segment.sounding { soundingSeconds += segment.seconds }
                lowest = min(lowest, segment.airAfter)
                if exhaustedAfter == nil, segment.airAfter < s.reserveFraction {
                    exhaustedAfter = soundingSeconds
                }
            }

            let breath: Breath
            if index == 0 {
                breath = .none
            } else {
                let previousEnd = phrases[index - 1].endBeat
                let gap = max(0, tempo.seconds(from: clipStartBeat + previousEnd,
                                               to: clipStartBeat + phrase.startBeat))
                breath = gap >= s.minBreathSeconds
                    ? .taken(beat: previousEnd, seconds: gap)
                    : .tooShort(beat: previousEnd, seconds: gap)
            }

            var constrained: [ConstrainedNote] = []
            for id in phrase.noteIDs {
                guard let i = voiceIndexOfID[id] else { continue }
                // ⚠️ A strict inequality with a real epsilon. Floating-point
                // noise at `headroom == 1` would otherwise fill the report with
                // notes nothing happened to, and a report that always says
                // something happened is exactly as useless as one that never
                // does.
                //
                // ⭐ **THE TEST IS THE MODEL'S, NOT THE LANE'S**, and the two
                // differ by up to one CC step: at peak 127 and `loudnessDepth`
                // 0.55 a step is Δeffort ≈ 0.0143, so a note starting a hair
                // below the reserve is listed here with BOTH CC integers equal
                // and `attenuationDb == 0`. That is reachable — see
                // `aNoteConstrainedByLessThanOneCCStepIsStillNamed`, which
                // constructs it by tuning `capacitySeconds` — and it is listed
                // ON PURPOSE. Filtering on the audible change instead would drop
                // notes the budget genuinely touched, and would empty the report
                // completely under an identity response, which is the ONE case
                // where the caller most needs to be told that enforcement did
                // something inaudible. A 0.0 dB entry costs a reader a glance;
                // silently omitting a constrained note is the failure this whole
                // round exists to remove.
                guard allowed[i] < requested[i] - 1e-9 else { continue }
                let asked = peak(requested[i])
                let got = peak(allowed[i])
                let db = asked > 0 && got > 0
                    ? 40 * log10(Double(got) / Double(asked))
                    : 0
                constrained.append(ConstrainedNote(
                    noteID: id, beat: voices[i].startBeat,
                    effortRequested: requested[i], effortAllowed: allowed[i],
                    airAtNote: airAtNote[i],
                    peakCCRequested: asked, peakCCAllowed: got,
                    attenuationDb: db, shaped: voices[i].shaped))
            }
            // `phrase.noteIDs` is already in onset order (PhraseDetection sorts
            // with a total order), so the list is in start order by
            // construction — no second sort, which could only disagree.
            let airStart = airAt(beat: phrase.startBeat)
            let airEnd = airAt(beat: phrase.endBeat)

            phraseReports.append(PhraseReport(
                startBeat: phrase.startBeat, endBeat: phrase.endBeat,
                breath: breath, airAtStart: airStart, airAtEnd: airEnd,
                lowestAir: lowest, exhausted: lowest < s.reserveFraction,
                soundingSeconds: soundingSeconds,
                exhaustedAfterSeconds: exhaustedAfter,
                constrainedNotes: constrained))
        }

        // --- Did the player ever get a full lungful back? --------------------
        //
        // ⚠️ Written as "was air ever full again AFTER the first shortfall",
        // not as "was every later phrase full at its end". The second form is
        // the one that reads naturally and it is WRONG: it latches on the very
        // phrase that ran short (whose own end is by definition not full) and
        // can never be cleared by a later recovery, so it would report a ratchet
        // on every part that ran short once and then rested properly.
        var neverRecovered = false
        if let firstShortfall = phraseReports.lazy
            .flatMap(\.constrainedNotes).first?.beat {
            var recoveredLater = false
            for (k, mark) in distinct.enumerated()
            where mark > firstShortfall && airAtMark[k] >= 1 - 1e-9 {
                recoveredLater = true
                break
            }
            neverRecovered = !recoveredLater
        }

        return Report(applied: s.enforced, settings: s,
                      notesConsidered: voices.count,
                      notesShaped: voices.reduce(0) { $0 + ($1.shaped ? 1 : 0) },
                      phrases: phraseReports,
                      lowestAir: lowestAir,
                      neverRecovered: neverRecovered)
    }
}
