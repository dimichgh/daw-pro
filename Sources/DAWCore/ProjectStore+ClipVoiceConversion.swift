import Foundation

/// One source clip's converted counterpart (m24-m leg A). `Codable` IS the
/// wire shape of `vc.convertClips`' per-clip entry (the wire-never-drifts
/// rule) — `CommandRouter` merges the CONVERTER's own metadata
/// (`realConversion`, `inferSeconds`, …) onto these keys and adds nothing
/// that changes their meaning.
public struct ConvertedClipReport: Codable, Sendable, Equatable {
    /// The clip that was converted. Unchanged by this operation — the source
    /// arrangement is read-only here.
    public var sourceClipId: UUID
    /// The track that source clip lives on.
    public var sourceTrackId: UUID
    /// The new clip on the converted track.
    public var clipId: UUID
    /// Where it landed — byte-identical to the source clip's own position and
    /// length, so the arrangement is preserved by construction (see
    /// `convertClipsToVoice`' geometry contract).
    public var startBeat: Double
    public var lengthBeats: Double
    /// The DRY extraction handed to the converter: exactly the audio that
    /// source clip presents (trim/`startOffsetSeconds`/`stretchRatio`/
    /// `pitchShiftSemitones` baked), in `NSTemporaryDirectory()/DAWPro`.
    /// Reported because it is the ONLY way a caller can check what the
    /// converter actually heard.
    public var extractedPath: String
    /// The converted audio as landed, in the project-stable media home.
    public var file: String
    /// Presented length of the source clip in seconds — the extraction's own
    /// duration, and what the converted file is expected to match.
    public var sourceSeconds: Double
    /// The converted file's authoritative on-disk duration. Differs from
    /// `sourceSeconds` only if the converter changed the length; a difference
    /// past `ClipVoiceConversion.driftWarningSeconds` raises a warning.
    public var convertedSeconds: Double

    public init(sourceClipId: UUID, sourceTrackId: UUID, clipId: UUID,
                startBeat: Double, lengthBeats: Double,
                extractedPath: String, file: String,
                sourceSeconds: Double, convertedSeconds: Double) {
        self.sourceClipId = sourceClipId
        self.sourceTrackId = sourceTrackId
        self.clipId = clipId
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.extractedPath = extractedPath
        self.file = file
        self.sourceSeconds = sourceSeconds
        self.convertedSeconds = convertedSeconds
    }
}

/// What one `vc.convertClips` produced (m24-m leg A): ONE new violet track
/// carrying a converted counterpart of every selected clip, at the same beats.
public struct ClipVoiceConversionResult: Codable, Sendable, Equatable {
    /// The new AI-flagged audio track. ALWAYS new — the user's ruling
    /// (2026-08-13): *"whenever we convert we would just create a new track
    /// with newly generated vocals"*. There is no cache and no binding back to
    /// the voice model; the result is a plain audio track.
    public var trackId: UUID
    /// The name that track landed with (the caller's, verbatim).
    public var trackName: String
    /// One entry per selected clip, ordered by `startBeat`.
    public var clips: [ConvertedClipReport]
    /// Non-fatal notices (`SliceToSamplerResult.warnings` precedent): a
    /// length drift from the converter, or a source clip whose geometry was
    /// edited while the conversion was in flight.
    public var warnings: [String]

    public init(trackId: UUID, trackName: String,
                clips: [ConvertedClipReport], warnings: [String]) {
        self.trackId = trackId
        self.trackName = trackName
        self.clips = clips
        self.warnings = warnings
    }
}

/// The DRY audio ONE clip presents, extracted to a file, plus the geometry it
/// was extracted at (m24-o). The unit `convertClipsToVoice` converts, and the
/// replacement for `voiceConversionSource`'s full-backing-recording resolution
/// on every path that feeds a converter.
public struct ClipConversionSource: Sendable, Equatable {
    public var clipId: UUID
    public var trackId: UUID
    /// The extracted WAV — transient, under `NSTemporaryDirectory()/DAWPro`
    /// (the `fixClipRegion` bounce policy). NOT project media; the CONVERTED
    /// output is what gets copied into the stable home.
    public var url: URL
    /// The source clip's timeline geometry AT EXTRACTION TIME. Landing uses
    /// these, never a re-read: the audio and its placement then agree even if
    /// the user edits the source clip during a minutes-long conversion.
    public var startBeat: Double
    public var lengthBeats: Double
    /// Presented duration in seconds — the extraction's exact length.
    public var seconds: Double
    /// Level-domain shaping that was deliberately NOT baked into `url` (see
    /// `extractClipAudioForConversion`' bake line) and is carried onto the
    /// landed clip instead.
    public var gainDb: Double
    public var fadeInBeats: Double
    public var fadeOutBeats: Double
    public var fadeInCurve: FadeCurve
    public var fadeOutCurve: FadeCurve
    public var gainEnvelope: [ClipGainPoint]
    /// The source clip's name — the landed clip reuses it, so a converted
    /// arrangement still reads like the one it came from.
    public var name: String
    /// The pitch shift BAKED into `url`: the key the converter heard the clip
    /// in (the stale-key rule, lane W7-PK round 3). `convertClipsToVoice`
    /// refuses to land when the clip no longer plays at it
    /// (`ClipVoiceConversion.pitchDrift`). Read from the SAME clip value the
    /// extraction renders, so it is the baked shift by construction. Defaulted
    /// and last, so a caller that builds a source by hand compiles unchanged.
    public var pitchShiftSemitones: Double

    public init(clipId: UUID, trackId: UUID, url: URL,
                startBeat: Double, lengthBeats: Double, seconds: Double,
                gainDb: Double, fadeInBeats: Double, fadeOutBeats: Double,
                fadeInCurve: FadeCurve, fadeOutCurve: FadeCurve,
                gainEnvelope: [ClipGainPoint], name: String,
                pitchShiftSemitones: Double = 0) {
        self.clipId = clipId
        self.trackId = trackId
        self.url = url
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.seconds = seconds
        self.gainDb = gainDb
        self.fadeInBeats = fadeInBeats
        self.fadeOutBeats = fadeOutBeats
        self.fadeInCurve = fadeInCurve
        self.fadeOutCurve = fadeOutCurve
        self.gainEnvelope = gainEnvelope
        self.name = name
        self.pitchShiftSemitones = pitchShiftSemitones
    }
}

/// Shared constants for the clip-conversion path — public so tests and the
/// wire layer quote ONE number rather than re-deriving it.
public enum ClipVoiceConversion {
    /// Beat tolerance for the "selected clips must not overlap" check: two
    /// clips that abut exactly (one ends where the next begins) are NOT an
    /// overlap. Same value as `ProjectStore+ClipFix.swift:343`'s
    /// `beatEpsilon`, restated rather than shared because that one is
    /// `private` — checked against it, not guessed.
    public static let beatEpsilon = 1e-9
    /// A converted file whose duration differs from the clip's presented
    /// length by MORE than this warns. 10 ms, not one frame: RVC resamples,
    /// so sub-10 ms drift is normal and a per-clip warning on every single
    /// conversion would be noise nobody reads. 10 ms is also the point where
    /// a placement error starts being audible against a click track.
    public static let driftWarningSeconds = 0.010

    /// A clip's pitch shift counts as unchanged within this many semitones: a
    /// fractional shift moved up and back down is float addition, not
    /// identity. The value of `ProjectStore.lanePitchEpsilon` (the PK-F3 rule
    /// for take-group fixes), restated beside the rule that uses it.
    public static let pitchShiftEpsilon = 1e-6

    /// THE STALE-KEY RULE (lane W7-PK round 3; PK-F3's rule for take-group
    /// fixes): why a conversion may not land, or nil when every converted
    /// clip's source still plays at the pitch shift its extraction baked. Each
    /// entry is a converted clip's name, the shift BAKED into what the
    /// converter heard, and the shift its source clip has NOW.
    ///
    /// The converter hears each clip at its extraction-time shift and the
    /// converted clip lands at shift 0, so it sounds in the key the source had
    /// then. A key change (`project.transpose`) or a hand edit during the
    /// minutes a conversion takes would land a voice out of tune against the
    /// song while every other check passes. Refused in words, never repaired:
    /// shifting the converted audio would move its formants too, so the honest
    /// fix is to convert again.
    public static func pitchDrift(
        _ clips: [(name: String, extracted: Double, now: Double)]
    ) -> String? {
        let moved = clips.filter { abs($0.now - $0.extracted) > pitchShiftEpsilon }
        guard let first = moved.first else { return nil }
        let delta = first.now - first.extracted
        let together = moved.count == clips.count
            && moved.allSatisfy { abs(($0.now - $0.extracted) - delta) <= pitchShiftEpsilon }
        let size = abs(delta)
        let cause = together
            ? "\(clips.count == 1 ? "the clip" : "every clip") moved "
                + "\(delta > 0 ? "up" : "down") \(ClampNotice.number(size)) "
                + "\(size == 1 ? "semitone" : "semitones"), as a key change does"
            : moved.map { "\"\($0.name)\" \(ClampNotice.number($0.extracted)) → "
                + "\(ClampNotice.number($0.now))" }.joined(separator: ", ") + " semitones"
        return "the pitch shift changed while converting (\(cause)) — the converted voice "
            + "was made at the old pitch and would sound out of tune against the song, so "
            + "nothing landed; convert again"
    }
}

/// Per-clip voice conversion (m24-m leg A / m24-o) — the selection-driven
/// action the user ratified 2026-08-13: *"we should produce same separate set
/// of clips, conversion applied to each separately, and probably we should be
/// able to select clips we want to convert"*.
///
/// **The shape, and the rulings behind it (do not relitigate):**
///  - PER-CLIP, never merged. N selected clips → N converted clips at the SAME
///    beats. The arrangement survives the conversion.
///  - A NEW track every time. No cache, no binding, no re-conversion key — the
///    result is a plain audio track with no live dependency on the converter.
///  - CLIP SELECTION drives the set; the caller passes the ids.
///  - The insert/plugin route is WITHDRAWN (the user's own first sketch, then
///    their own decision against it). There is no insert here and must not be.
///
/// **Why per-clip DISSOLVES the m24-o defect rather than patching it.** The old
/// `voiceConversionSource` handed the converter a clip's FULL BACKING
/// RECORDING: a comped, trimmed take converted its whole untrimmed source and
/// landed it at the clip's start beat — silently wrong output, not a missing
/// feature. Converting each clip separately means each conversion sees exactly
/// the audio that clip presents, because the extraction is an offline render of
/// that ONE clip over exactly its own window.
///
/// DAWCore stays AI-free: the conversion itself is an INJECTED closure (the
/// `VoicePanelModel` precedent). This file never imports AIServices; it hands
/// out a file path and takes a file path back.
@MainActor
extension ProjectStore {

    /// Extracts exactly the audio ONE clip presents, to a transient WAV, and
    /// reports the geometry it was extracted at.
    ///
    /// **The extraction is an offline render of a SYNTHETIC single-track
    /// session holding only that clip** (`fixClipRegion`'s D1 mechanism):
    /// unity volume/pan, no inserts, no sends, no automation, master
    /// untouched, window = `[clip.startBeat, clip.startBeat + lengthBeats]`
    /// with NO tail. So the file maps 1:1 onto the clip's own timeline span.
    ///
    /// **What is BAKED vs what is CARRIED — the line is time vs level:**
    ///  - BAKED, because it decides WHICH audio the converter hears:
    ///    `startOffsetSeconds`, the trim (the window itself), `stretchRatio`,
    ///    `pitchShiftSemitones`, `formantPreserve`. This is the m24-o fix.
    ///  - CARRIED to the landed clip instead of baked, because it does not
    ///    change what was sung and staying editable is worth more:
    ///    `gainDb`, both fades and their curves, `gainEnvelope`. Baking a
    ///    fade-to-silence head would also hand the converter material its f0
    ///    estimator cannot use, and a −60 dB clip gain would hand it near
    ///    silence — the `fixClipRegion` strip, for a second reason.
    ///
    /// `takeGroupID` is dropped from the synthetic copy: the render needs no
    /// group (a materialized comp member is an ordinary clip to the player),
    /// and the landed clip must NOT claim membership of a group it is not in.
    /// A comp member is otherwise perfectly convertible — this only READS the
    /// clip, so `requireNotCompMember` deliberately does not apply (the
    /// `sliceClipToSampler` posture).
    ///
    /// Stretch/pitch are NOT rejected here, unlike `clip.sliceToSampler`.
    /// That command refuses them because sampler zones read RAW source frames;
    /// this path renders through the playback engine, so they are honoured by
    /// construction — refusing would turn away the very clips m24-o exists for.
    ///
    /// - Throws: `engineUnavailable` headless; `clipNotFound`;
    ///   `voiceConversionRequiresAudioClip` for a MIDI clip or an audio clip
    ///   with no backing file; `invalidClipEdit` for a zero-length clip.
    public func extractClipAudioForConversion(clipId: UUID) async throws -> ClipConversionSource {
        guard let engine else { throw ProjectError.engineUnavailable }
        guard let (t, c) = locateConversionClip(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t].clips[c]
        let trackID = tracks[t].id
        guard !clip.isMIDI, clip.audioFileURL != nil else {
            throw ProjectError.voiceConversionRequiresAudioClip(clipId)
        }
        let tempoMap = transport.tempoMap
        let seconds = tempoMap.seconds(from: clip.startBeat,
                                       to: clip.startBeat + clip.lengthBeats)
        guard seconds > 0 else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) has zero length — there is nothing to convert")
        }

        // The DRY copy: level-domain shaping stripped, time-domain geometry
        // (offset/stretch/pitch/formant) left exactly as the clip carries it.
        // Same `id` as the source — the offline renderer's WYSIWYG await of
        // pending stretch renders keys off the clip, the reason `fixClipRegion`
        // passes the clip itself rather than a rebuilt one.
        var dry = clip
        dry.gainDb = 0
        dry.fadeInBeats = 0
        dry.fadeOutBeats = 0
        dry.fadeInCurve = .linear
        dry.fadeOutCurve = .linear
        dry.gainEnvelope = []
        dry.takeGroupID = nil

        // STEM class (m13-d): dry by contract — never mastered, never
        // master-lane-faded (m15-c). A converted vocal must not arrive with the
        // master chain baked into it.
        // W9-PFRT P2: the pan-carrying seam with its inputs stated, for the
        // AI-fix bounce's reason (`fixClipRegion`): a centred synthetic track
        // with no modulation, so `.balance` and the constant meter are exactly
        // what the rule-less call it replaces rendered.
        let rendered = try await engine.renderOffline(
            tracks: [Track(name: "Voice Convert Source", kind: .audio, clips: [dry])],
            tempoMap: tempoMap, meterMap: MeterMap(constant: TimeSignature()), panLaw: .balance,
            masterVolume: 1,
            masterEffects: [], masterAutomation: [],
            masterModulationSources: [], masterModulationRoutes: [],
            fromBeat: clip.startBeat, durationSeconds: seconds,
            forcedCompensationTargets: nil)
        let url = Self.conversionExtractionDestination()
        _ = try engine.writeAudioFile(rendered, to: url)

        return ClipConversionSource(
            clipId: clipId, trackId: trackID, url: url,
            startBeat: clip.startBeat, lengthBeats: clip.lengthBeats, seconds: seconds,
            gainDb: clip.gainDb,
            fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
            gainEnvelope: clip.gainEnvelope, name: clip.name,
            pitchShiftSemitones: clip.pitchShiftSemitones)
    }

    /// Converts EVERY clip in `clipIds` separately and lands the whole set on
    /// ONE new violet track at the same beats — the m24-m leg A action.
    ///
    /// `convert` is the injected converter seam: given a source clip id and its
    /// extraction, it returns the converted file's URL. `CommandRouter` passes
    /// the (AIServices) `VoiceConversionClient.convert` call; the UI passes the
    /// same thing through `VoicePanelModel`; a test passes a stub. DAWCore never
    /// learns what a voice model is.
    ///
    /// **All-or-nothing.** Every id is resolved, type-checked and
    /// overlap-checked BEFORE a single render or conversion runs, and if
    /// conversion k of N throws, NOTHING lands — no partial track, no half
    /// arrangement. A partial success that looks like a whole one is this
    /// tree's characteristic failure mode; this refuses to produce one.
    ///
    /// **Rejections** (all before any expensive work):
    ///  - empty selection, or the same clip id twice → `invalidClipEdit`
    ///  - unknown id → `clipNotFound`; MIDI clip → `voiceConversionRequiresAudioClip`
    ///  - two selected clips that OVERLAP in beats → `invalidClipEdit` naming
    ///    the pair. One track cannot hold both at their own beats, and silently
    ///    trimming one would break the single promise this feature makes (the
    ///    arrangement survives). Converting them in two passes costs nothing —
    ///    every conversion makes its own track anyway.
    ///
    /// **The one rejection AFTER the work** (the stale-key rule, lane W7-PK
    /// round 3): a clip whose pitch shift changed while the set was converting
    /// — a key change, or a hand edit — → `invalidClipEdit` saying what moved,
    /// and NOTHING lands. Its converted voice was made at the old pitch.
    ///
    /// **Geometry is the SOURCE clip's, not the converted file's.** The landed
    /// clip takes `startBeat`/`lengthBeats` straight from the clip it came from
    /// (captured at extraction time), so the arrangement is exact by
    /// construction and landed clips cannot overlap if their sources did not.
    /// `importConvertedVoice`'s on-disk-duration rule is deliberately NOT
    /// inherited: that is right for a lone imported stem and wrong for a set.
    /// A converter that changed the length is REPORTED (`convertedSeconds`,
    /// plus a warning past `driftWarningSeconds`) rather than allowed to move
    /// the arrangement.
    ///
    /// ONE `performEdit("Convert Voice")` — ⚠️ with NO `key:`. Coalescing is an
    /// 800 ms window for slider scrubs; two conversions inside it would fold
    /// into one undo step and the first track would become unreachable. All
    /// media work (renders, converter calls, stable-home copies) happens
    /// OUTSIDE the edit body, so a failure never journals a half-edit.
    ///
    /// - Parameters:
    ///   - clipIds: the selected clips. Order is irrelevant — the result is
    ///     ordered by `startBeat`.
    ///   - trackName: the new track's name, verbatim. The CALLER resolves the
    ///     default (`"Voice: <voiceId>"`) — the `importConvertedVoice` contract,
    ///     so an empty string lands as an empty string rather than being
    ///     silently replaced.
    ///   - provenance: WHICH VOICE made this track (m24-n) — recorded on the
    ///     new track as a fact about where its audio came from. Additive and
    ///     defaulted so no existing caller changes meaning; every PRODUCTION
    ///     route passes it, because a route that does not looks completely
    ///     correct while recording nothing. ⚠️ It is not a binding and not a
    ///     cache key — see `VoiceProvenance`. DAWCore knows nothing about
    ///     voices, so the CALLER (which called the converter and therefore
    ///     knows the id, the display name and the pitch) supplies it, exactly
    ///     as it supplies `convert` and `trackName`.
    ///   - convert: source clip id + its extraction → the converted file.
    @discardableResult
    public func convertClipsToVoice(
        clipIds: [UUID],
        trackName: String,
        provenance: VoiceProvenance? = nil,
        convert: @MainActor (UUID, ClipConversionSource) async throws -> URL
    ) async throws -> ClipVoiceConversionResult {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        guard engine != nil else { throw ProjectError.engineUnavailable }

        // --- 1. Validate the whole selection first ------------------------
        guard !clipIds.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "no clips to convert — select at least one audio clip first")
        }
        var seen = Set<UUID>()
        for id in clipIds where !seen.insert(id).inserted {
            throw ProjectError.invalidClipEdit(
                "clip \(id.uuidString) is listed twice — each clip converts once")
        }
        // Resolve + type-check every id BEFORE paying for anything.
        var spans: [(id: UUID, start: Double, end: Double, name: String)] = []
        for id in clipIds {
            guard let (t, c) = locateConversionClip(id) else {
                throw ProjectError.clipNotFound(id)
            }
            let clip = tracks[t].clips[c]
            guard !clip.isMIDI, clip.audioFileURL != nil else {
                throw ProjectError.voiceConversionRequiresAudioClip(id)
            }
            spans.append((id, clip.startBeat, clip.startBeat + clip.lengthBeats, clip.name))
        }
        let ordered = spans.sorted { $0.start < $1.start }
        for (a, b) in zip(ordered, ordered.dropFirst())
        where b.start < a.end - ClipVoiceConversion.beatEpsilon {
            throw ProjectError.invalidClipEdit(
                "\"\(a.name)\" (beats \(a.start)–\(a.end)) and \"\(b.name)\" "
                + "(beats \(b.start)–\(b.end)) overlap, so one track cannot hold both at "
                + "their own beats — convert them in two passes (each conversion makes its "
                + "own track), or trim the overlap first")
        }

        // --- 2. Extract + convert, one clip at a time, OUTSIDE any edit ----
        var warnings: [String] = []
        var landed: [(report: ConvertedClipReport, clip: Clip)] = []
        // The stale-key rule's record: each clip's shift as its extraction baked it.
        var baked: [(id: UUID, name: String, shift: Double)] = []
        for span in ordered {
            let source = try await extractClipAudioForConversion(clipId: span.id)
            baked.append((span.id, source.name, source.pitchShiftSemitones))
            // Re-locate after the await (the sliceClipToSampler law): a clip
            // that vanished mid-flight fails the whole call rather than
            // landing a partial set.
            guard locateConversionClip(span.id) != nil else {
                throw ProjectError.clipNotFound(span.id)
            }

            let convertedURL = try await convert(span.id, source)
            guard let (t2, c2) = locateConversionClip(span.id) else {
                throw ProjectError.clipNotFound(span.id)
            }
            // Placement uses the geometry captured at EXTRACTION time — the
            // audio and its position then agree. Say so if the user moved or
            // re-trimmed the clip while the conversion was running.
            let now = tracks[t2].clips[c2]
            if now.startBeat != source.startBeat || now.lengthBeats != source.lengthBeats {
                warnings.append(
                    "\"\(source.name)\" was moved or re-trimmed while it was converting — the "
                    + "converted clip is placed where it was when the conversion started "
                    + "(beat \(source.startBeat), \(source.lengthBeats) beats long)")
            }

            guard FileManager.default.fileExists(atPath: convertedURL.path) else {
                throw ProjectError.generationAudioMissing(convertedURL.path)
            }
            // The recording-take model (importConvertedVoice's own reasoning):
            // the file must outlive the facade's temp output AND undo/redo
            // resurrection, so a later save can fold it into the bundle.
            let stableURL = try copyGeneratedAudioToStableLocation(
                from: convertedURL, jobID: "voice-\(UUID().uuidString)")
            let info = try media.audioFileInfo(at: stableURL)
            if abs(info.durationSeconds - source.seconds)
                > ClipVoiceConversion.driftWarningSeconds {
                warnings.append(
                    "the converted audio for \"\(source.name)\" is "
                    + "\(ClampNotice.number(info.durationSeconds)) s but the clip presents "
                    + "\(ClampNotice.number(source.seconds)) s — the clip keeps its original "
                    + "length, so the difference is not heard; the voice engine changed the "
                    + "length")
            }

            // Level-domain shaping carried across (the extraction's bake line),
            // takeGroupID deliberately NOT: these are plain, freely editable
            // clips on a plain audio track.
            let newClip = Clip(
                name: source.name,
                startBeat: source.startBeat,
                lengthBeats: source.lengthBeats,
                audioFileURL: stableURL,
                isAIGenerated: true,
                gainDb: source.gainDb,
                fadeInBeats: source.fadeInBeats,
                fadeOutBeats: source.fadeOutBeats,
                fadeInCurve: source.fadeInCurve,
                fadeOutCurve: source.fadeOutCurve,
                gainEnvelope: source.gainEnvelope)
            landed.append((
                ConvertedClipReport(
                    sourceClipId: span.id, sourceTrackId: source.trackId, clipId: newClip.id,
                    startBeat: source.startBeat, lengthBeats: source.lengthBeats,
                    extractedPath: source.url.path, file: stableURL.path,
                    sourceSeconds: source.seconds, convertedSeconds: info.durationSeconds),
                newClip))
        }

        // --- 2b. The stale-key rule, at the moment of landing --------------
        // Checked HERE, after the last await and with none between it and the
        // edit below, because this is when the set lands: a clip re-pitched
        // while a LATER clip was converting has already had its own turn above.
        // A source deleted after its own turn is not this rule's to judge and
        // is skipped, exactly as it was before the rule.
        let pitchNow = baked.compactMap { entry -> (name: String, extracted: Double, now: Double)? in
            guard let (t, c) = locateConversionClip(entry.id) else { return nil }
            return (entry.name, entry.shift, tracks[t].clips[c].pitchShiftSemitones)
        }
        // TODO(wire round): the MCP tool `vc_convert_clips` (mcp-server/src/
        // server.ts) should list this refusal: a clip re-pitched while it was
        // converting lands nothing, and says what moved.
        if let why = ClipVoiceConversion.pitchDrift(pitchNow) {
            throw ProjectError.invalidClipEdit(why)
        }

        // --- 3. ONE edit: one new violet track carrying the whole set ------
        // Track AND clips are flagged AI-generated (violet — "violet always
        // means AI-generated", DESIGN-LANGUAGE.md): a voice conversion is
        // exactly as AI-authored as a generation.
        var newTrack = Track(name: trackName, kind: .audio)
        newTrack.isAIGenerated = true
        newTrack.clips = landed.map(\.clip)
        // m24-n: the ONE place that knows both the voice and the track it made,
        // which is why the record is attached here and nowhere else.
        newTrack.voiceProvenance = provenance
        let trackID = newTrack.id
        performEdit("Convert Voice") {
            tracks.append(newTrack)
            engine?.tracksDidChange(tracks)
        }

        return ClipVoiceConversionResult(
            trackId: trackID, trackName: trackName,
            clips: landed.map(\.report), warnings: warnings)
    }

    // MARK: - Helpers

    /// Locates a clip by id across every track (extension-local; the private
    /// helpers in `ProjectStore.swift` are not visible cross-file — the
    /// `locateSliceClip` precedent).
    private func locateConversionClip(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }

    /// Transient extraction destination:
    /// `NSTemporaryDirectory()/DAWPro/voice-source-<uuid8>.wav` (the
    /// `fixBounceDestination` policy with a conversion prefix). NOT the stable
    /// media home — only the CONVERTED output becomes project media.
    private static func conversionExtractionDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("voice-source-\(UUID().uuidString.prefix(8)).wav")
    }
}
