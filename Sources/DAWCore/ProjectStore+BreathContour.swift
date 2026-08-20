import Foundation

/// What `ProjectStore.applyBreathContour` did, in enough detail that a caller
/// can tell "it worked" from "it looked like it worked" (m27 leg D).
///
/// Every field here answers a question a bare `Clip` could not: how many notes
/// were long enough for vibrato, whether the point budget forced a coarser
/// contour than asked, and — the one that matters most — whether the track's
/// instrument will actually consume what was just written.
public struct BreathContourApplication: Sendable, Equatable {
    /// The updated clip, with its rebuilt controller lanes.
    public var clip: Clip
    /// How many notes received a contour.
    public var notesTouched: Int
    /// How many of those were long enough for delayed vibrato. The remainder
    /// got the expression contour only, by design — see
    /// `BreathContour.Options.vibratoOnsetSeconds`.
    public var notesWithVibrato: Int
    /// Total points now on the expression lane (including any that were already
    /// there, outside the touched notes).
    public var expressionPointCount: Int
    /// Total points now on the pitch-bend lane, or 0 if no note earned one.
    public var pitchBendPointCount: Int
    /// The per-note point budget actually used. Equal to
    /// `Options.maxPointsPerLane` unless the CLIP-wide total forced a smaller
    /// one — a whole clip shares one lane, so 60 long notes at the per-note
    /// default would blow a cap each of them individually clears.
    public var perNotePointBudget: Int
    /// Non-fatal, human-readable. The call SUCCEEDED and the lanes ARE stored;
    /// these say what will and will not be audible (the `clip.setControllerLane`
    /// / media-import idiom). Empty means nothing is known to be wrong.
    public var warnings: [String]
}

/// Breath/air expression authoring (m27 leg D). New domain, its own extension
/// file — the ProjectStore.swift-is-7k-lines rule, and the same shape
/// `ProjectStore+Humanize.swift` uses for the legato pass.
@MainActor
extension ProjectStore {

    /// Writes a realistic breath contour onto a MIDI clip: one **expression
    /// (CC) lane** carrying the loudness-and-brightness swell, and one **pitch
    /// bend lane** carrying delayed vibrato plus micro-sharpening. The shape
    /// and every default are argued in `BreathContour`; this method is the
    /// store boundary — selection, merging, the clip-wide point budget, undo,
    /// and the warnings.
    ///
    /// ## What it writes, and what it leaves alone
    ///
    /// `noteIDs` selects the notes to shape; **nil (the default) means every
    /// note in the clip**. An id that is not in the clip is an all-or-nothing
    /// rejection naming it — a partially-applied contour would be worse than
    /// none, because the caller could not tell which notes it got.
    ///
    /// The lanes are **merged, not replaced**. Existing points OUTSIDE every
    /// touched note's span survive exactly as authored; points inside a touched
    /// span are replaced by the generated contour. So a hand-drawn shape
    /// elsewhere on the clip is not destroyed by running this on one note, and
    /// running it note by note across a phrase accumulates instead of each call
    /// wiping the last. (Contrast `setControllerLane`, which is wholesale by
    /// contract — that is the primitive; this is the composer.)
    ///
    /// A span is CLOSED, `[startBeat, startBeat + lengthBeats]`, so the exact
    /// boundary between two adjacent notes is owned by the later one: the
    /// canonical last-wins dedupe keeps the incoming note's onset value over
    /// the previous note's taper end, which is the musically correct winner.
    ///
    /// ## The clip-wide point budget
    ///
    /// A controller lane belongs to the CLIP, not the note, and caps at
    /// `maxControllerPointsPerLane` (16384). Sixty long notes that each clear
    /// the cap individually can blow it together. So: generate once at the
    /// requested resolution and, only if the total overruns, regenerate the
    /// whole clip at an evenly-divided per-note budget and SAY SO in
    /// `warnings` + `perNotePointBudget`. The generator's own widen-then-
    /// truncate logic then does the work, rather than a second budget algorithm
    /// existing here to disagree with it. If even that overruns (thousands of
    /// notes), the call is REFUSED with a teaching error naming both counts and
    /// the fix — silently thinning a caller's data is the defect class this
    /// whole round exists to end.
    ///
    /// ## Rejections
    ///
    /// An audio clip → `notAMIDIClip` naming this verb. An unknown clip id →
    /// `clipNotFound`. A comp member → the store's standing refusal. A clip
    /// with no notes, an unknown note id, a clip already holding
    /// `maxControllerLanesPerClip` lanes of other types, or an unsatisfiable
    /// point budget → `invalidClipEdit` with the reason and the fix.
    ///
    /// `performEdit("Breath Contour")` — ONE undo step restoring the exact
    /// prior lanes, with NO coalescing (a second run is a second edit, since it
    /// may legitimately follow an options change). Reschedules: lanes ride the
    /// schedule, so `tracksDidChange` fires.
    @discardableResult
    public func applyBreathContour(
        clipID: UUID,
        noteIDs: [UUID]? = nil,
        options: BreathContour.Options = .init()
    ) throws -> BreathContourApplication {
        // ONE options for every note — the leg D contract, unchanged. The core
        // below is the same code this method has always run; breath-pad P1
        // factored it out so an effort SHAPE can vary the options per note
        // without a second lane-writing path existing to disagree about merge
        // semantics, the point budget, undo or the warnings.
        try applyBreathContourVarying(clipID: clipID, noteIDs: noteIDs,
                                      baseOptions: options, undoLabel: "Breath Contour") { _ in
            options
        }
    }

    /// The shared engine behind `applyBreathContour` and
    /// `applyEffortShape` — everything the two have in common, which is
    /// everything except how each note's options are chosen.
    ///
    /// - Parameters:
    ///   - baseOptions: the options that describe the CALL rather than a note.
    ///     `expressionCC` (one lane serves the whole call, so it cannot vary
    ///     per note) and `maxPointsPerLane` (the requested budget, quoted in the
    ///     coarsening warning) are read from here. Everything else is read from
    ///     `perNoteOptions`.
    ///   - undoLabel: the `performEdit` label, so the two verbs name themselves
    ///     honestly in the undo history.
    ///   - perNoteOptions: called once per selected note, in the sorted order
    ///     described below, and again on each budget retry. Must be PURE — it
    ///     is invoked more than once for the same note and the two calls must
    ///     agree, or the reported counts describe a different contour than the
    ///     one written.
    @discardableResult
    func applyBreathContourVarying(
        clipID: UUID,
        noteIDs: [UUID]?,
        baseOptions: BreathContour.Options,
        undoLabel: String,
        perNoteOptions: (MIDINote) -> BreathContour.Options
    ) throws -> BreathContourApplication {
        let options = baseOptions
        guard let (t, c) = locateClipForBreath(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard let notes = clip.notes else {
            throw ProjectError.notAMIDIClip(clipID, verb: "clip.applyBreathContour")
        }
        guard !notes.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' has no notes to shape — author notes with clip.setNotes first")
        }

        // Selection: all-or-nothing, and ordered BY START BEAT below — never by
        // the order the caller listed ids in, and never by the clip's array
        // order either.
        //
        // ⚠️ The start-beat sort is LOAD-BEARING, not tidiness. Two adjacent
        // notes share a boundary beat (note 1 ends where note 2 begins), and
        // both generate a point exactly there; `MIDIControllerLane
        // .canonicalPoints` resolves an equal-beat tie LAST-WINS, so the winner
        // is whichever note came later in the generated array. The musically
        // correct winner is the note that is STARTING (its onset value), not the
        // one that is ending (its taper value, and for bend an exact centre) —
        // and a clip's `notes` array is NOT guaranteed ascending: `humanize`
        // deliberately preserves input order rather than re-canonicalizing. So
        // without this sort, a clip whose notes happen to be stored out of
        // order would leave the second note starting on the first note's
        // hand-off value: audible as a note that begins slightly sharp or
        // slightly loud, intermittently, depending on array order.
        let chosen: [MIDINote]
        if let noteIDs {
            let wanted = Set(noteIDs)
            let found = notes.filter { wanted.contains($0.id) }
            let missing = wanted.subtracting(found.map(\.id))
            guard missing.isEmpty else {
                throw ProjectError.invalidClipEdit(
                    "clip '\(clip.name)' has no note with id "
                    + missing.map(\.uuidString).sorted().joined(separator: ", ")
                    + " — read the clip's note ids from clip.getNotes")
            }
            chosen = found
        } else {
            chosen = notes
        }
        // A TOTAL order, not merely a start-beat one: `sorted(by:)` is not
        // documented stable, so ties must be broken explicitly or the output
        // would vary run to run.
        //
        // ⚠️ This is (startBeat, lengthBeats, id) and NOT `MIDINote
        // .canonicallyOrdered`, which tiebreaks on PITCH. The divergence is
        // deliberate and the reason is the overlap case: where two notes start
        // together but end apart, last-wins hands the shared beats to whichever
        // sorts later, and under a pitch tiebreak that can be the SHORTER note —
        // whose taper falls to `releaseLevel` at its own end, so the lane would
        // dip and then jump back onto the longer note's contour, a step in the
        // middle of a still-sounding chord. Ordering by length puts the longest
        // note last, so the note that is still sounding owns the shared beats
        // and its contour stays smooth. (A per-clip lane cannot express one
        // chord note bending independently of another in any case — pitch bend
        // is channel-wide — so the only question here is which single contour
        // survives, and the longest note is the defensible answer.)
        let selected = chosen.sorted {
            if $0.startBeat != $1.startBeat { return $0.startBeat < $1.startBeat }
            if $0.lengthBeats != $1.lengthBeats { return $0.lengthBeats < $1.lengthBeats }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard !selected.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "no notes selected on clip '\(clip.name)' — omit noteIds to shape every note")
        }

        let map = transport.tempoMap
        let clipStart = clip.startBeat

        // One options per note. `expressionCC` is forced back to the call's —
        // the merge below computes exactly ONE expression lane type, and a note
        // that generated points for a different CC would have them silently
        // written to the wrong lane. `maxPointsPerLane` is likewise the call's,
        // since the budget is a property of the clip's lane, not of a note.
        func optionsFor(_ note: MIDINote, perNoteBudget: Int) -> BreathContour.Options {
            var scoped = perNoteOptions(note)
            scoped.expressionCC = options.expressionCC
            scoped.maxPointsPerLane = perNoteBudget
            return scoped
        }

        func generateAll(perNoteBudget: Int) -> [BreathContour.Generated] {
            selected.map {
                BreathContour.generate(noteStartBeat: $0.startBeat,
                                       noteLengthBeats: $0.lengthBeats,
                                       clipStartBeat: clipStart,
                                       tempoMap: map,
                                       options: optionsFor($0, perNoteBudget: perNoteBudget))
            }
        }

        // The spans this call OWNS. Closed, and computed from the notes rather
        // than from the generated points so a note that produced no bend lane
        // still clears any stale bend points sitting under it.
        let spans = selected.map { ($0.startBeat, $0.startBeat + $0.lengthBeats) }
        let expressionType = MIDIControllerType.cc(controller: min(127, max(0, options.expressionCC)))
        let survivingExpression = pointsOutside(spans,
                                                in: clip.controllerLanes, type: expressionType)
        let survivingBend = pointsOutside(spans, in: clip.controllerLanes, type: .pitchBend)

        let cap = Self.maxControllerPointsPerLane
        var budget = options.maxPointsPerLane
        var generated = generateAll(perNoteBudget: budget)
        var warnings: [String] = []

        func totals(_ g: [BreathContour.Generated]) -> (expression: Int, bend: Int) {
            (survivingExpression.count + g.reduce(0) { $0 + $1.expression.count },
             survivingBend.count + g.reduce(0) { $0 + $1.pitchBend.count })
        }

        var total = totals(generated)
        if total.expression > cap || total.bend > cap {
            // Divide what is left after the surviving points evenly. Floor 8:
            // the generator's own sanitized minimum.
            let headroom = cap - max(survivingExpression.count, survivingBend.count)
            budget = max(8, headroom / selected.count)
            generated = generateAll(perNoteBudget: budget)
            let retried = totals(generated)
            guard retried.expression <= cap, retried.bend <= cap else {
                throw ProjectError.invalidClipEdit(
                    "a breath contour over \(selected.count) notes needs "
                    + "\(retried.expression) expression and \(retried.bend) pitch-bend points, "
                    + "past the \(cap)-points-per-lane limit even at the smallest per-note "
                    + "budget — shape fewer notes per call (noteIds), or split the clip")
            }
            warnings.append(
                "the contour was coarsened to fit the \(cap)-points-per-lane limit across "
                + "\(selected.count) notes: each note got a \(budget)-point budget instead of "
                + "\(options.maxPointsPerLane), so vibrato is sampled less finely than requested")
            total = retried
        }

        // Merge and rebuild. An empty result REMOVES the lane (the
        // setControllerLane empty-clears contract), which is what makes running
        // this with vibrato off, or on notes too short for it, tidy up after
        // itself instead of leaving a stale bend lane behind.
        let expressionPoints = survivingExpression + generated.flatMap(\.expression)
        let bendPoints = survivingBend + generated.flatMap(\.pitchBend)
        var rebuilt = clip.controllerLanes.filter { $0.type != expressionType && $0.type != .pitchBend }
        if !expressionPoints.isEmpty {
            rebuilt.append(MIDIControllerLane(type: expressionType, points: expressionPoints))
        }
        if !bendPoints.isEmpty {
            rebuilt.append(MIDIControllerLane(type: .pitchBend, points: bendPoints))
        }
        guard rebuilt.count <= Self.maxControllerLanesPerClip else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' would hold \(rebuilt.count) controller lanes, past the "
                + "\(Self.maxControllerLanesPerClip)-lanes-per-clip limit — remove a lane first "
                + "with clip.removeControllerLane")
        }
        let canon = Clip.canonicalControllerLanes(rebuilt)

        performEdit(undoLabel) {
            tracks[t].clips[c].controllerLanes = canon
            // A ClipKey-affecting edit — the lanes ride the schedule build.
            engine?.tracksDidChange(tracks)
        }

        // ⚠️ A note counts as having vibrato only if it was long enough AND the
        // options it was generated with asked for a non-zero width. Before
        // breath-pad P1 this read `vibratoStartBeat != nil` alone, which is a
        // property of the note's LENGTH only: a caller who turned vibrato off
        // with `vibratoDepthCents: 0` was told every long note "got vibrato",
        // and got back a bend lane carrying nothing but micro-sharpening. That
        // is the "returns something that looks like a valid answer" shape this
        // whole round exists to end, and P1 could not report honestly on the
        // sound-bank path (where it MUST suppress bend vibrato) without it.
        let vibratoRequested = selected.contains {
            optionsFor($0, perNoteBudget: budget).vibratoDepthCents > 0
        }
        let notesWithVibrato = zip(selected, generated).filter { note, g in
            g.vibratoStartBeat != nil
                && optionsFor(note, perNoteBudget: budget).vibratoDepthCents > 0
        }.count

        warnings += breathWarnings(trackIndex: t,
                                   expressionType: expressionType,
                                   wroteBend: !bendPoints.isEmpty,
                                   vibratoRequested: vibratoRequested,
                                   notesWithVibrato: notesWithVibrato,
                                   notesTouched: selected.count,
                                   truncated: generated.contains { $0.vibratoTruncatedAtBeat != nil })

        let stored = tracks[t].clips[c]
        return BreathContourApplication(
            clip: stored,
            notesTouched: selected.count,
            notesWithVibrato: notesWithVibrato,
            expressionPointCount: stored.controllerLanes
                .first { $0.type == expressionType }?.points.count ?? 0,
            pitchBendPointCount: stored.controllerLanes
                .first { $0.type == .pitchBend }?.points.count ?? 0,
            perNotePointBudget: budget,
            warnings: warnings)
    }

    /// The notes `applyBreathContourVarying` WOULD shape, resolved exactly the
    /// way it resolves them — same all-or-nothing id check, same total order.
    /// Exists so `applyEffortShape` can compute a per-note effort curve BEFORE
    /// the write, over the same notes and in the same order, instead of
    /// re-deriving the selection and hoping the two agree.
    func breathSelection(clipID: UUID, noteIDs: [UUID]?) throws -> [MIDINote] {
        guard let (t, c) = locateClipForBreath(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        let clip = tracks[t].clips[c]
        guard let notes = clip.notes else {
            throw ProjectError.notAMIDIClip(clipID, verb: "clip.applyEffortShape")
        }
        guard !notes.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' has no notes to shape — author notes with clip.setNotes first")
        }
        let chosen: [MIDINote]
        if let noteIDs {
            let wanted = Set(noteIDs)
            let found = notes.filter { wanted.contains($0.id) }
            let missing = wanted.subtracting(found.map(\.id))
            guard missing.isEmpty else {
                throw ProjectError.invalidClipEdit(
                    "clip '\(clip.name)' has no note with id "
                    + missing.map(\.uuidString).sorted().joined(separator: ", ")
                    + " — read the clip's note ids from clip.getNotes")
            }
            chosen = found
        } else {
            chosen = notes
        }
        return chosen.sorted {
            if $0.startBeat != $1.startBeat { return $0.startBeat < $1.startBeat }
            if $0.lengthBeats != $1.lengthBeats { return $0.lengthBeats < $1.lengthBeats }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Points of `type` that fall OUTSIDE every touched span — the ones this
    /// call must leave exactly as authored.
    private nonisolated func pointsOutside(_ spans: [(Double, Double)],
                                           in lanes: [MIDIControllerLane],
                                           type: MIDIControllerType) -> [MIDIControllerPoint] {
        guard let lane = lanes.first(where: { $0.type == type }) else { return [] }
        return lane.points.filter { point in
            !spans.contains { point.beat >= $0.0 - 1e-9 && point.beat <= $0.1 + 1e-9 }
        }
    }

    /// The "will this actually sound?" sentences. Separate from the write path
    /// for the reason `controllerLaneWarning` is: the edit must succeed and
    /// return its result whatever these say, and a warning is not a property of
    /// a clip.
    ///
    /// ⭐ The brightness sentence is the one that matters for this feature. Legs
    /// A and C are what make a CC11 contour move loudness AND brightness
    /// together, but the brightness half is opt-in
    /// (`SamplerParams.expressionFilterDepth`, nil/0 = off so every pre-m27
    /// project renders bit-identically). A contour written to a track that
    /// never opted in is a fader move — audible, correct, and only half of what
    /// the caller asked for. Saying nothing there would be exactly the silent
    /// half-success this round exists to end.
    func breathWarnings(trackIndex: Int,
                        expressionType: MIDIControllerType,
                        wroteBend: Bool,
                        vibratoRequested: Bool,
                        notesWithVibrato: Int,
                        notesTouched: Int,
                        truncated: Bool) -> [String] {
        var out: [String] = []
        let instrument = tracks[trackIndex].instrument
        if let warning = MIDIControllerRouting.inertLaneWarning(for: expressionType,
                                                               instrument: instrument) {
            out.append(warning)
        }
        if wroteBend,
           let warning = MIDIControllerRouting.inertLaneWarning(for: .pitchBend,
                                                               instrument: instrument) {
            out.append(warning)
        }
        if instrument?.kind == .sampler,
           (instrument?.sampler?.expressionFilterDepth ?? 0) <= 0 {
            out.append(
                "the swell will change LOUDNESS but not BRIGHTNESS: this track's sampler has "
                + "expressionFilterDepth off (0), so nothing sweeps the per-voice low-pass. Set "
                + "sampler.expressionFilterDepth above 0 (try 0.6) to make a held note read as a "
                + "player leaning in rather than a fader move")
        }
        // Both sentences below explain "you asked for vibrato and some notes did
        // not get it". When vibrato was not requested at all — a caller passing
        // vibratoDepthCents 0, or P1 suppressing bend vibrato on a hosted-AU
        // track — neither is true, and the caller has its own, accurate
        // explanation to give. Saying "no note got vibrato: every one is too
        // short" about notes that are not too short is worse than silence.
        if !vibratoRequested {
            // Nothing to say here; the caller turned it off deliberately.
        } else if notesWithVibrato == 0 {
            out.append(
                "no note got vibrato: every one of the \(notesTouched) selected is shorter than "
                + "the straight opening plus one vibrato cycle, so only the expression contour "
                + "was written. Lower vibratoOnsetSeconds to add vibrato to shorter notes")
        } else if notesWithVibrato < notesTouched {
            out.append(
                "\(notesTouched - notesWithVibrato) of \(notesTouched) notes were too short for "
                + "vibrato and got the expression contour only — that is the intended shape for "
                + "short notes, not an error")
        }
        if truncated {
            out.append(
                "vibrato was cut short on at least one note because the point budget ran out "
                + "even at the coarsest spacing that still represents an oscillation; those "
                + "notes hold centre pitch after the cut")
        }
        return out
    }

    /// Extension-local clip lookup — `ProjectStore.locateClip(_:)` is private to
    /// ProjectStore.swift and not visible cross-file (the same reason
    /// ProjectStore+Humanize.swift and ProjectStore+Quantize.swift each keep
    /// their own copy).
    private func locateClipForBreath(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
