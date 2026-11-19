import Foundation

/// What a sing job snapshots when it plans, and checks when it lands (design
/// `docs/design/2026-09-27-p2-sing-integration.md` §4.5 "Project identity").
public struct SungVocalLandingGuard: Sendable, Equatable {
    /// `ProjectStore.projectGeneration` at planning time. It is bumped on
    /// every open, new and recover, so a different value means a different
    /// project is open.
    public var projectGeneration: UInt64
    /// `SingPlan.signature` at planning time.
    public var signature: String
    /// The whole plan at planning time (p2-sing-e, additive; nil in a guard
    /// built by hand). With it, landing can tell a PURE transposition of the
    /// song from any other change (`SungVocalReplanComparison`): the signature
    /// alone changes the same way for both. `planSungVocal` always fills it.
    public var plan: SingPlan?

    public init(projectGeneration: UInt64, signature: String, plan: SingPlan? = nil) {
        self.projectGeneration = projectGeneration
        self.signature = signature
        self.plan = plan
    }
}

/// A plan and the guard its landing will check.
public struct SungVocalPlanning: Sendable, Equatable {
    public var plan: SingPlan
    public var landingGuard: SungVocalLandingGuard

    public init(plan: SingPlan, landingGuard: SungVocalLandingGuard) {
        self.plan = plan
        self.landingGuard = landingGuard
    }
}

/// What `landSungVocal` did.
public struct SungVocalLanding: Sendable, Equatable {
    public var trackID: UUID
    public var clipID: UUID
    /// True when the melody, the words or the tempo changed after the take
    /// was planned: it landed at the planned beat, following the earlier
    /// version, and `notice` says so. For a part DERIVED from the melody (a
    /// harmony or chord-notes part, `SungVocalTake.derived`), also true when
    /// the chords or the key it was derived over changed (design
    /// `2026-10-06-p2-sing-expansion.md` §16): `notice` then names the part.
    public var melodyChanged: Bool
    /// Design §5.7 "Melody changed", the transposition notice, or nil.
    public var notice: String?
    /// The semitones the song was moved by (a PURE transposition) between
    /// planning and landing; the landed clip carries them as its
    /// `pitchShiftSemitones`. 0 when it was not moved (p2-sing-e, additive).
    public var transposedSemitones: Int

    public init(trackID: UUID, clipID: UUID, melodyChanged: Bool, notice: String?,
                transposedSemitones: Int = 0) {
        self.trackID = trackID
        self.clipID = clipID
        self.melodyChanged = melodyChanged
        self.notice = notice
        self.transposedSemitones = transposedSemitones
    }
}

/// Why a finished take did not land.
public enum SungVocalLandingError: Error, Equatable, LocalizedError {
    /// A different project is open than the one the take was planned in.
    /// Nothing landed; the take was kept at `savedPath` (in the Generations
    /// folder, `ProjectStore.generationImportsDirectory`).
    case projectChanged(savedPath: String)

    public var errorDescription: String? {
        switch self {
        case .projectChanged(let savedPath):
            // §5.7 "Project closed", naming the folder that holds the take.
            let folder = URL(fileURLWithPath: savedPath).deletingLastPathComponent().path
            return "The project was closed before the singing finished. The take is saved in \(folder)."
        }
    }
}

/// `landSungVocals` stopped partway (W8-RV6 review N4): a copy into the
/// Generations folder, or reading a copy's length, failed after earlier takes
/// were already copied. Nothing landed. The copies it had already made were
/// removed, so nothing is left there that no track uses, and this names them.
public struct SungVocalLandingStopped: Error, Equatable, LocalizedError {
    /// What failed, in its own words.
    public var cause: String
    /// The copies that were made and then removed, in order.
    public var removedPaths: [String]

    public init(cause: String, removedPaths: [String]) {
        self.cause = cause
        self.removedPaths = removedPaths
    }

    public var errorDescription: String? {
        let names = removedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        return "\(cause) Nothing was added, and the copies made before it stopped were removed: \(names)."
    }
}

/// One finished line of a multi-part sing job (p2-sing-x6, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §4.4 "Landing"), for
/// `ProjectStore.landSungVocals`.
public struct SungVocalTake: Sendable, Equatable {
    /// The finished take, a local WAV (copied into the Generations folder on
    /// landing, as `landSungVocal` does).
    public var fileURL: URL
    public var trackName: String
    /// The beat the clip goes at (this part's `SingPlan.atBeat`).
    public var atBeat: Double
    public var provenance: SungVocalProvenance
    /// The post-render expression table (p2-sing-x5); nil = none.
    public var pitchEdits: PitchEditSet?
    /// −1...1; nil = `Track`'s own default (centre).
    public var pan: Double?
    /// Linear gain, 1 = unity; nil = `Track`'s own default.
    public var volume: Double?
    /// nil: the line was sung from the job's own melody clip (the lead, a
    /// harmony or chord-tones part, a double), so it follows the JOB's
    /// identity check. Set: a line sung from ANOTHER clip, checked on its own.
    public var ownSource: SungVocalPartSource?
    /// Set for a part DERIVED from the job's melody clip (a harmony or
    /// chord-notes part): how it was derived and the notes it was sung from,
    /// so landing can derive it again over the project as it is NOW (design
    /// §16). nil: the lead, a double, a line from another clip.
    public var derived: SungVocalDerivedPart?

    public init(fileURL: URL, trackName: String, atBeat: Double, provenance: SungVocalProvenance,
                pitchEdits: PitchEditSet? = nil, pan: Double? = nil, volume: Double? = nil,
                ownSource: SungVocalPartSource? = nil, derived: SungVocalDerivedPart? = nil) {
        self.fileURL = fileURL
        self.trackName = trackName
        self.atBeat = atBeat
        self.provenance = provenance
        self.pitchEdits = pitchEdits
        self.pan = pan
        self.volume = volume
        self.ownSource = ownSource
        self.derived = derived
    }
}

/// A part DERIVED from the job's own melody clip: a harmony part or a
/// chord-notes part (design `2026-10-06-p2-sing-expansion.md` §4.2). Its notes
/// depend on more than the melody: on the key (estimated from every track when
/// none was given) and on the chords of the other tracks. So landing derives
/// it again and compares (§16, the amendment to §4.4 rule 1, from W8-RV6 S2).
///
/// `derive` is THE ONE derivation: a sing job plans a part with it at submit,
/// and `landSungVocals` derives the part again with it at landing, so the two
/// can never disagree about what "the same part" means.
public struct SungVocalDerivedPart: Sendable, Equatable {
    /// How the part is made from the melody.
    public enum Rule: Sendable, Equatable {
        /// `HarmonyPlanner.derivedPart` with `spec`, in the resolved key.
        case harmony(HarmonySpec)
        /// `HarmonyPlanner.chordTonePart`: the melody clip's own chord notes,
        /// filled with "`fillInterval` below" where it has none.
        case chordTones(rank: ChordToneRank, fillInterval: HarmonySpec.Interval,
                        fillChordSource: HarmonySpec.ChordSource)
    }

    public var rule: Rule
    /// The key the request gave (`sing.render`'s `key`/`mode`); nil = the
    /// project's estimated key, estimated again each time.
    public var givenKey: SongKey?
    /// The part's place in its job (1, 2, 3): with each melody note's id, it
    /// names the part's note ids, so a part derived again pairs note by note.
    public var partIndex: Int
    /// The part's name, for the notice ("third above").
    public var name: String
    /// What the derivation gave when the part was planned
    /// (`HarmonyPlan.partNotes`: written pitches, before the sung octave).
    public var plannedNotes: [MIDINote]

    public init(rule: Rule, givenKey: SongKey?, partIndex: Int, name: String, plannedNotes: [MIDINote]) {
        self.rule = rule
        self.givenKey = givenKey
        self.partIndex = partIndex
        self.name = name
        self.plannedNotes = plannedNotes
    }

    /// THE ONE derivation of a part from `clip` on `track`, over `tracks`.
    /// The key comes from `HarmonyPlanner.resolveKey` (`givenKey`, else the
    /// estimate); a chord-notes part asks for one only if it needs a fill.
    ///
    /// - Throws: `HarmonyRefusal.needsKey` when a harmony part has no key
    ///   given and the project's key is not clear, or a chord-notes part needs
    ///   a fill note and has no key.
    public static func derive(_ rule: Rule, givenKey: SongKey?, partIndex: Int, clip: Clip, on track: Track,
                              tracks: [Track], tempoMap: TempoMap) throws(HarmonyRefusal) -> HarmonyPlan {
        switch rule {
        case .harmony(let spec):
            let key = try HarmonyPlanner.resolveKey(given: givenKey, tracks: tracks, tempoMap: tempoMap)
            return HarmonyPlanner.derivedPart(clip: clip, on: track, tracks: tracks, spec: spec, key: key,
                                              partIndex: partIndex)
        case .chordTones(let rank, let fillInterval, let fillChordSource):
            let key = try? HarmonyPlanner.resolveKey(given: givenKey, tracks: tracks, tempoMap: tempoMap)
            return try HarmonyPlanner.chordTonePart(clip: clip, on: track, tracks: tracks, rank: rank,
                                                    fillInterval: fillInterval, fillChordSource: fillChordSource,
                                                    key: key, partIndex: partIndex)
        }
    }

    /// True when `again` (the part derived now; nil when it can no longer be
    /// derived) holds the planned notes, each moved by `semitones`: the same
    /// ids, each pitch planned + `semitones`. A pure transposition of the song
    /// moves the melody, the chords and the key by the same amount, so the
    /// part moves with them. Only the ids and pitches count: timing and words
    /// are the melody's, which the job's own check already compares.
    public func matches(_ again: HarmonyPlan?, movedBy semitones: Int) -> Bool {
        guard let now = again?.partNotes, now.count == plannedNotes.count else { return false }
        return zip(plannedNotes, now).allSatisfy { $0.id == $1.id && $0.pitch + semitones == $1.pitch }
    }
}

/// A part sung from ANOTHER MIDI clip (design §4.2 "Another MIDI clip"), as a
/// sing job plans it and as `landSungVocals` plans it again to check it.
public struct SungVocalPartSource: Sendable, Equatable {
    /// The plan the part was rendered from (its clip id and octave shift).
    public var plan: SingPlan
    /// The lead's words, when the clip had none of its own and borrowed them
    /// for this job (§4.2); nil = the clip's own lyrics.
    public var borrowedLyrics: ClipLyrics?

    public init(plan: SingPlan, borrowedLyrics: ClipLyrics?) {
        self.plan = plan
        self.borrowedLyrics = borrowedLyrics
    }

    /// THE ONE plan of a part sung from another clip, at submit and at landing:
    /// the clip as it is, with `borrowedLyrics` written onto a transient copy
    /// when it has no words of its own (never stored). Pure.
    public static func plan(clip: Clip, on track: Track, borrowedLyrics: ClipLyrics?, octaveShift: Int,
                            tempoMap: TempoMap, meterMap: MeterMap) throws(SingPlanRefusal) -> SingPlan {
        var sung = clip
        if sung.lyrics == nil, let borrowedLyrics { sung.lyrics = borrowedLyrics }
        return try SingPlanner.plan(clip: sung, on: track, tempoMap: tempoMap, meterMap: meterMap,
                                    octaveShift: octaveShift)
    }
}

/// Sung vocals: planning and landing (p2-sing-d2, design §3.4, §3.9, §4.5).
///
/// DAWCore stays AI-free: nothing here talks to the singing engine. A sing job
/// (`SingJobCoordinator` in AIServices, p2-sing-e part 1) plans through
/// `planSungVocal`, renders elsewhere, normalises through
/// `normalizeSungVocalTake`, and hands back a finished local WAV to
/// `landSungVocal`.
///
/// TODO(p2-sing-e part 2): the wire. The coordinator exists; nothing here is
/// reachable from the wire yet. Design §6 rows 13-15, in
/// `Sources/DAWControl/Commands.swift` and `mcp-server/src/server.ts`:
/// `sing.render` (MCP tool `sing_render`) submits to `SingJobCoordinator`
/// (`dryRun` returns `planSungVocal`'s plan alone); `sing.jobStatus` (MCP tool
/// `sing_job_status`) reports the coordinator's status, which carries the
/// `SungVocalLanding` and the checks; `clip.getLyrics` (MCP tool
/// `clip_get_lyrics`) derives its assignment through
/// `SingPlanner.assignment(for:tempoMap:)`, the one derivation.
@MainActor
extension ProjectStore {

    /// Design §5.7 "Melody changed".
    public static let sungVocalMelodyChangedNotice =
        "The melody changed while I was singing; this take follows the earlier version."

    /// The notice for a take that landed moved with the song (design §4.5,
    /// amended 2026-09-27 10:10). PROVISIONAL copy (p2-sing-e, in §5.7's voice;
    /// not yet in §5.7): "The song moved up 3 half-steps while I was singing,
    /// so I moved this take up 3 to match."
    public nonisolated static func sungVocalTransposedNotice(semitones: Int) -> String {
        let way = semitones > 0 ? "up" : "down"
        let size = abs(semitones)
        let unit = size == 1 ? "half-step" : "half-steps"
        return "The song moved \(way) \(size) \(unit) while I was singing, so I moved this take \(way) \(size) \(unit) to match."
    }

    /// The notice for a derived part whose chords or key changed while it was
    /// being sung (design `2026-10-06-p2-sing-expansion.md` §16). PROVISIONAL
    /// copy, §16's words.
    public nonisolated static func sungVocalPartDriftedNotice(part: String) -> String {
        "The chords changed while '\(part)' was being sung, so it may not fit now. Sing it again to match."
    }

    /// The track name design §4.5 gives a sung vocal: "Vocals — Built-in
    /// singer", "Vocals — <voice name>". A caller's own `trackName` wins.
    public static func sungVocalTrackName(voiceName: String) -> String {
        "Vocals — \(voiceName)"
    }

    /// The loudness a sung take is gained toward (design §4.5 step 3): the
    /// TARGET, not a gate (§7.1: the take the user picked measured −19.2 LUFS,
    /// held down by the ceiling).
    public nonisolated static let sungVocalLufsTarget = -18.0
    /// The true-peak ceiling the static gain is clamped to (design §4.5, L3).
    public nonisolated static let sungVocalTruePeakCeilingDbtp = -1.0

    /// A sung take's static gain (design §4.5 steps 2-4): measure, gain toward
    /// `sungVocalLufsTarget`, clamped so the true peak stays at or under
    /// `sungVocalTruePeakCeilingDbtp`, then RE-measure. It is the bounce's own
    /// policy (`deliveryNormalized`, the ONE home for "measure → gain → clamp
    /// → re-measure"), made reachable from the sing job; nothing is restated.
    ///
    /// - Throws: `ProjectError.bounceSilent` when the take has no gated
    ///   loudness at all (the job reads that as "no singing", gate L2/L4).
    public static func normalizeSungVocalTake(
        _ audio: consuming RenderedAudio
    ) async throws -> (audio: RenderedAudio, report: BounceLoudnessReport) {
        try await deliveryNormalized(consume audio, lufsTarget: sungVocalLufsTarget,
                                     truePeakCeilingDb: sungVocalTruePeakCeilingDbtp)
    }

    /// Plans `clipId` for singing and snapshots what `landSungVocal` will
    /// check. A pure read: nothing in the project changes.
    ///
    /// - Throws: `ProjectError.clipNotFound`, or the planner's
    ///   `SingPlanRefusal` (audio clip, drum track, no notes, the lyrics, the
    ///   octave shift, a note or word longer than 20 s).
    public func planSungVocal(clipId: UUID, octaveShift: Int) throws -> SungVocalPlanning {
        try planSungVocal(clipId: clipId, octaveShift: octaveShift, lyrics: nil)
    }

    /// The same plan over a copy of the clip with `lyrics` in place of the words it holds (p2-sing-x7d), so a
    /// request can be planned over words that are not stored yet. Nothing in the project changes.
    /// `lyrics == nil` keeps the clip's own words (the overload above); `.some(nil)` plans as if they were cleared.
    public func planSungVocal(clipId: UUID, octaveShift: Int, lyrics: ClipLyrics??) throws -> SungVocalPlanning {
        for track in tracks {
            guard var clip = track.clips.first(where: { $0.id == clipId }) else { continue }
            if let lyrics { clip.lyrics = lyrics }
            let plan = try SingPlanner.plan(clip: clip, on: track, tempoMap: transport.tempoMap,
                                            meterMap: transport.meterMap, octaveShift: octaveShift)
            return SungVocalPlanning(
                plan: plan,
                landingGuard: SungVocalLandingGuard(projectGeneration: projectGeneration,
                                                    signature: plan.signature, plan: plan))
        }
        throw ProjectError.clipNotFound(clipId)
    }

    /// Lands a finished sung take as ONE new violet AI track holding one clip
    /// at `atBeat`, in ONE undo step (design §4.5 step 6). Undo removes the
    /// track exactly.
    ///
    /// Built on the `importConvertedVoice` path
    /// (`ProjectStore+VoiceConversion.swift`): the same stable copy into the
    /// Generations folder, the same on-disk duration, the same AI flags. It
    /// repeats those few lines rather than calling it, because that method
    /// journals its own undo step and this one must also set the provenance.
    ///
    /// The checks, in order (design §4.5 "Project identity"):
    /// 1. **A different project is open** (`planned.projectGeneration` differs):
    ///    nothing lands. The take is copied into the Generations folder and
    ///    `SungVocalLandingError.projectChanged` names where.
    /// 2. The clip is planned again from `provenance.sourceClipId` and
    ///    `provenance.octaveShift`, and compared with the plan the take was
    ///    rendered from (`SungVocalReplanComparison`; with a guard that carries
    ///    no plan, by signature alone, the pre-p2-sing-e rule):
    ///    - **the same**: it lands as planned;
    ///    - **the song was transposed by Δ and nothing else changed** (amended
    ///      2026-09-27 10:10): it lands with `Clip.pitchShiftSemitones = Δ`,
    ///      INSIDE the same edit (one undo step), with its own notice;
    ///    - **anything else** (the melody, the words or the tempo changed, or
    ///      the clip is gone or can no longer be planned): it still lands, at
    ///      the planned beat, with `melodyChanged` and the §5.7 notice.
    ///
    /// `pitchEdits` (p2-sing-x5, design `2026-10-06-p2-sing-expansion.md`
    /// §5.4 "Landing"): the post-render expression table for the take
    /// (vibrato, per-note level), carried by the new clip INTO the same edit,
    /// so a styled take is still one track in ONE undo step and a redo brings
    /// the table back with it. nil (the default) is exactly the call before
    /// x5, byte for byte; an empty set is nil (`Clip.init`'s one spelling).
    ///
    /// - Throws: `ProjectError.mediaServiceUnavailable`,
    ///   `ProjectError.generationAudioMissing`, or
    ///   `SungVocalLandingError.projectChanged`.
    @discardableResult
    public func landSungVocal(fileURL: URL, trackName: String, atBeat: Double,
                              provenance: SungVocalProvenance,
                              planned: SungVocalLandingGuard,
                              pitchEdits: PitchEditSet? = nil) throws -> SungVocalLanding {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProjectError.generationAudioMissing(fileURL.path)
        }
        let copyKey = "sing-\(UUID().uuidString)"
        guard planned.projectGeneration == projectGeneration else {
            let kept = try copyGeneratedAudioToStableLocation(from: fileURL, jobID: copyKey)
            throw SungVocalLandingError.projectChanged(savedPath: kept.path)
        }
        let current = provenance.sourceClipId.flatMap {
            try? planSungVocal(clipId: $0, octaveShift: provenance.octaveShift)
        }
        let comparison: SungVocalReplanComparison
        if let plannedPlan = planned.plan {
            comparison = SungVocalReplanComparison.compare(planned: plannedPlan, current: current?.plan)
        } else {
            comparison = current?.plan.signature == planned.signature ? .unchanged : .changed
        }
        let melodyChanged: Bool
        let transposed: Int
        switch comparison {
        case .unchanged: (melodyChanged, transposed) = (false, 0)
        case .transposed(let semitones): (melodyChanged, transposed) = (false, semitones)
        case .changed: (melodyChanged, transposed) = (true, 0)
        }

        // The importConvertedVoice mechanics: a stable copy (the file must
        // outlive the engine's cache and undo/redo, until a save folds it into
        // the project), and the duration measured from the file on disk.
        let stableURL = try copyGeneratedAudioToStableLocation(from: fileURL, jobID: copyKey)
        let info = try media.audioFileInfo(at: stableURL)
        let startBeat = max(0, atBeat)
        let lengthBeats = transport.tempoMap.beat(from: startBeat, elapsedSeconds: info.durationSeconds)
            - startBeat
        // Violet always means AI-generated (DESIGN-LANGUAGE.md): the track and
        // its clip are both flagged.
        var clip = Clip(name: trackName, startBeat: startBeat, lengthBeats: lengthBeats,
                        audioFileURL: stableURL, isAIGenerated: true, pitchEdits: pitchEdits)
        if transposed != 0 {
            // Exactly what `project.transpose` does to a recorded or generated
            // audio clip (design §3.6), so the take sits in the song's new key.
            clip.pitchShiftSemitones = Double(transposed)
        }
        let newTrack = Track(name: trackName, kind: .audio, isAIGenerated: true, clips: [clip],
                             sungVocalProvenance: provenance)

        // The take, its pitch edits (p2-sing-x5) and its record enter the
        // project together, in this ONE edit.
        performEdit("Land Sung Vocal") {
            tracks.append(newTrack)
            engine?.tracksDidChange(tracks)
        }
        let notice: String?
        if melodyChanged {
            notice = Self.sungVocalMelodyChangedNotice
        } else if transposed != 0 {
            notice = Self.sungVocalTransposedNotice(semitones: transposed)
        } else {
            notice = nil
        }
        return SungVocalLanding(trackID: newTrack.id, clipID: clip.id, melodyChanged: melodyChanged,
                                notice: notice, transposedSemitones: transposed)
    }

    /// Lands every finished line of a multi-part sing job (the lead, harmony
    /// parts, a double: design `2026-10-06-p2-sing-expansion.md` §4.4) as one
    /// new violet AI track each, ALL in ONE undo step, "Land Sung Harmony", so
    /// one undo removes every line. `landSungVocal` (one take, its own step) is
    /// unchanged and is what a single-part job still calls.
    ///
    /// Project identity (§4.4, the base §4.5 rules):
    /// 1. **Once for the job.** A different project is open: nothing lands,
    ///    EVERY take is copied into the Generations folder, and
    ///    `projectChanged` names the first. Otherwise the job's melody clip
    ///    (`planned.plan`'s clip and octave shift) is planned again and
    ///    compared (`SungVocalReplanComparison`): the same; a pure
    ///    transposition by Δ, and EVERY line lands moved by the same Δ; or
    ///    changed, and every line lands as sung, with the notice.
    /// 2. **Per part** for a line sung from another clip (`ownSource`): its
    ///    own clip is planned again (with the words it borrowed) and compared
    ///    the same way.
    /// 3. **Per part** for a part derived from the melody (`derived`, design
    ///    §16): when the melody itself is the same or only transposed, the
    ///    part is derived again over the tracks and key as they are NOW
    ///    (`SungVocalDerivedPart.derive`, the one derivation; a given key
    ///    moves with a pure transposition). If it no longer gives the notes
    ///    that were sung (moved by the same Δ), the part STILL lands, with
    ///    `melodyChanged` and a notice that names it.
    ///
    /// `pan`/`volume` set the new track's own mix (nil keeps `Track`'s
    /// defaults); `pitchEdits` ride on the new clip, as in `landSungVocal`.
    /// Returns one `SungVocalLanding` per take, in order. Everything that can
    /// throw runs before the edit, so a throw lands nothing; no takes lands
    /// nothing and journals no step. A copy or a length read that fails after
    /// earlier copies were made removes those copies and throws
    /// `SungVocalLandingStopped`, which names them (W8-RV6 N4).
    @discardableResult
    public func landSungVocals(_ takes: [SungVocalTake],
                               planned: SungVocalLandingGuard) throws -> [SungVocalLanding] {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        for take in takes where !FileManager.default.fileExists(atPath: take.fileURL.path) {
            throw ProjectError.generationAudioMissing(take.fileURL.path)
        }
        guard !takes.isEmpty else { return [] }
        // Every stable copy made so far: removed again if a later step throws.
        var made: [URL] = []
        guard planned.projectGeneration == projectGeneration else {
            do {
                for take in takes {
                    made.append(try copyGeneratedAudioToStableLocation(from: take.fileURL,
                                                                        jobID: "sing-\(UUID().uuidString)"))
                }
            } catch {
                throw Self.removingSungVocalCopies(made, after: error)
            }
            throw SungVocalLandingError.projectChanged(savedPath: made[0].path)
        }
        let leadClipID = planned.plan?.clipID ?? takes[0].provenance.sourceClipId
        let leadOctave = planned.plan?.octaveShift ?? takes[0].provenance.octaveShift
        let current = leadClipID.flatMap { try? planSungVocal(clipId: $0, octaveShift: leadOctave) }
        let jobVerdict: SungVocalReplanComparison
        if let plannedPlan = planned.plan {
            jobVerdict = SungVocalReplanComparison.compare(planned: plannedPlan, current: current?.plan)
        } else {
            jobVerdict = current?.plan.signature == planned.signature ? .unchanged : .changed
        }

        // The melody clip as it is now, for a derived part's second derivation.
        var leadNow: (clip: Clip, track: Track)?
        if let leadClipID {
            for track in tracks {
                if let clip = track.clips.first(where: { $0.id == leadClipID }) { leadNow = (clip, track); break }
            }
        }
        let jobDelta: Int
        if case .transposed(let semitones) = jobVerdict { jobDelta = semitones } else { jobDelta = 0 }

        var newTracks: [Track] = []
        var landings: [SungVocalLanding] = []
        for take in takes {
            var verdict = jobVerdict
            // Design §16: a derived part over chords or a key that changed while it was being sung. Asked only
            // when the melody itself is the same or only transposed (a changed melody already says so).
            var drifted = false
            if let derived = take.derived, jobVerdict != .changed {
                let key = derived.givenKey.map {
                    SongKey(tonicPitchClass: $0.tonicPitchClass + jobDelta, mode: $0.mode, source: $0.source,
                            confidence: $0.confidence)
                }
                let again = leadNow.flatMap { lead in
                    try? SungVocalDerivedPart.derive(derived.rule, givenKey: key, partIndex: derived.partIndex,
                                                     clip: lead.clip, on: lead.track, tracks: tracks,
                                                     tempoMap: transport.tempoMap)
                }
                drifted = !derived.matches(again, movedBy: jobDelta)
            }
            if let source = take.ownSource {
                var again: SingPlan?
                for track in tracks {
                    guard let clip = track.clips.first(where: { $0.id == source.plan.clipID }) else { continue }
                    again = try? SungVocalPartSource.plan(
                        clip: clip, on: track, borrowedLyrics: source.borrowedLyrics,
                        octaveShift: source.plan.octaveShift, tempoMap: transport.tempoMap,
                        meterMap: transport.meterMap)
                    break
                }
                verdict = SungVocalReplanComparison.compare(planned: source.plan, current: again)
            }
            var melodyChanged: Bool
            let transposed: Int
            switch verdict {
            case .unchanged: (melodyChanged, transposed) = (false, 0)
            case .transposed(let semitones): (melodyChanged, transposed) = (false, semitones)
            case .changed: (melodyChanged, transposed) = (true, 0)
            }
            if drifted { melodyChanged = true }
            // `landSungVocal`'s mechanics, take by take: a stable copy, the
            // duration measured from the file on disk, violet flags.
            let stableURL: URL
            let info: AudioFileInfo
            do {
                stableURL = try copyGeneratedAudioToStableLocation(from: take.fileURL,
                                                                   jobID: "sing-\(UUID().uuidString)")
                made.append(stableURL)
                info = try media.audioFileInfo(at: stableURL)
            } catch {
                throw Self.removingSungVocalCopies(made, after: error)
            }
            let startBeat = max(0, take.atBeat)
            let lengthBeats = transport.tempoMap.beat(from: startBeat, elapsedSeconds: info.durationSeconds)
                - startBeat
            var clip = Clip(name: take.trackName, startBeat: startBeat, lengthBeats: lengthBeats,
                            audioFileURL: stableURL, isAIGenerated: true, pitchEdits: take.pitchEdits)
            if transposed != 0 { clip.pitchShiftSemitones = Double(transposed) }
            var newTrack = Track(name: take.trackName, kind: .audio, isAIGenerated: true, clips: [clip],
                                 sungVocalProvenance: take.provenance)
            if let pan = take.pan, pan.isFinite { newTrack.pan = pan.clamped(to: Track.panRange) }
            if let volume = take.volume, volume.isFinite { newTrack.volume = volume.clamped(to: Track.volumeRange) }
            newTracks.append(newTrack)
            let notice: String?
            if drifted, let derived = take.derived {
                notice = Self.sungVocalPartDriftedNotice(part: derived.name)
            } else if melodyChanged {
                notice = Self.sungVocalMelodyChangedNotice
            } else if transposed != 0 {
                notice = Self.sungVocalTransposedNotice(semitones: transposed)
            } else {
                notice = nil
            }
            landings.append(SungVocalLanding(trackID: newTrack.id, clipID: clip.id, melodyChanged: melodyChanged,
                                             notice: notice, transposedSemitones: transposed))
        }

        // Every line enters the project in this ONE edit.
        performEdit("Land Sung Harmony") {
            tracks.append(contentsOf: newTracks)
            engine?.tracksDidChange(tracks)
        }
        return landings
    }

    /// W8-RV6 N4: removes the stable copies `landSungVocals` made before
    /// `error`, and returns the error to throw: `error` itself when there were
    /// none (the call before N4, unchanged), else `SungVocalLandingStopped`
    /// naming them.
    private nonisolated static func removingSungVocalCopies(_ made: [URL], after error: any Error) -> any Error {
        guard !made.isEmpty else { return error }
        for url in made { try? FileManager.default.removeItem(at: url) }
        return SungVocalLandingStopped(cause: error.localizedDescription, removedPaths: made.map(\.path))
    }

    /// Writes the advisory checks that finish AFTER landing (design §4.6) into
    /// the landed track's `sungVocalProvenance` (§3.9: "the word-check result,
    /// filled in later"). Returns false, and changes nothing, when the track
    /// is gone (undone, deleted) or a different project is open
    /// (`projectGeneration` moved).
    ///
    /// ⚠️ NOT an undo step, on purpose: the user did not make this edit, and an
    /// undo that first took back a check result and only then the take would
    /// be a step nobody asked for. Consequence, accepted: the landing's redo
    /// snapshot predates it.
    ///
    /// It DOES mark the project dirty when it changes the record (p2-sing-x5,
    /// from W8-SE1's report). Before, a save made between the landing and the
    /// end of the checks kept a clean flag over an unsaved result, so closing
    /// the project lost it without asking. A call that changes nothing (both
    /// results nil, or the same results again) leaves the flag alone.
    @discardableResult
    public func recordSungVocalChecks(trackId: UUID, projectGeneration expected: UInt64,
                                      noteAccuracy: SungNoteAccuracy?, wordCheck: SungWordCheck?) -> Bool {
        guard expected == projectGeneration,
              let t = tracks.firstIndex(where: { $0.id == trackId }),
              var record = tracks[t].sungVocalProvenance else { return false }
        if let noteAccuracy { record.noteAccuracy = noteAccuracy }
        if let wordCheck { record.wordCheck = wordCheck }
        guard record != tracks[t].sungVocalProvenance else { return true }
        tracks[t].sungVocalProvenance = record
        markDirtyWithoutUndoStep()
        return true
    }
}
