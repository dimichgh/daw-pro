import Foundation

/// What one `clip.sliceToSampler` produced (m32-b2). `Codable` IS the wire
/// response shape — the wire-never-drifts rule.
public struct SliceToSamplerResult: Codable, Sendable, Equatable {
    /// The instrument track that now carries the pads.
    public var trackId: UUID
    /// Set only when the track was created by this call — one undo removes
    /// the track, its zones and the reconstruction clip together.
    public var createdTrackId: UUID?
    /// The reconstruction MIDI clip, when one was generated.
    public var midiClipId: UUID?
    /// The SOURCE FILE's own sample rate and length. Reported because every
    /// `startFrame`/`endFrame` below is in these units and nothing else in the
    /// response would let a caller check that.
    public var sampleRate: Double
    public var frameCount: Int
    public var sliceCount: Int
    /// Audio before the first slice point. Always present — see
    /// `SliceToSamplerPlan.Result.headSeconds`. ⚠️ Only `"transients"` can
    /// DROP it (and warns when it does). In `"divisions"`/`"grid"` that audio
    /// IS pad 1 (`slices[0].startFrame` is the window start), so this is pad
    /// 1's own length there and nothing was discarded (m33-d).
    public var headSeconds: Double
    public var slices: [SliceReport]
    public var warnings: [String]
    /// The track this call MUTED, or nil — and nil is the default, because
    /// `muteSourceTrack` is.
    ///
    /// ⚠️ **REPORTED SEPARATELY FROM THE REQUEST, because they can differ.**
    /// Asking to mute the source when the source track IS the destination is
    /// refused (it would silence the pads that were just made), and asking to
    /// mute a track that was already muted changes nothing. A caller that read
    /// its own request back would believe both of those worked.
    public var mutedTrackId: UUID?
    /// Is the SOURCE clip's track muted NOW — whether or not this call did it?
    ///
    /// ⭐⭐ **A SECOND FIELD, NOT A SPELLING OF THE FIRST, AND THE DIFFERENCE IS
    /// THE ONE QUESTION A USER ACTUALLY ASKS.** `mutedTrackId` answers *"what
    /// did this call change, and what will undo put back?"*. This answers *"will
    /// the original play underneath my pads?"* — and the two diverge in both
    /// directions: a track that was ALREADY muted gives `mutedTrackId: nil` with
    /// this TRUE, and a chop onto the source's own track gives `nil` with this
    /// FALSE. A surface that inferred audibility from `mutedTrackId` would tell
    /// a user to go mute a track that is already silent.
    public var sourceTrackMuted: Bool

    public init(trackId: UUID, createdTrackId: UUID?, midiClipId: UUID?,
                sampleRate: Double, frameCount: Int, sliceCount: Int,
                headSeconds: Double, slices: [SliceReport], warnings: [String],
                mutedTrackId: UUID? = nil, sourceTrackMuted: Bool = false) {
        self.trackId = trackId
        self.createdTrackId = createdTrackId
        self.midiClipId = midiClipId
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.sliceCount = sliceCount
        self.headSeconds = headSeconds
        self.slices = slices
        self.warnings = warnings
        self.mutedTrackId = mutedTrackId
        self.sourceTrackMuted = sourceTrackMuted
    }
}

/// Chop-to-sampler orchestration (m32-b2). Mirrors `ProjectStore+Quantize`:
/// validate → detect → condition → resolve against the file's PCM → plan →
/// ONE `performEdit`. Every awaited step is followed by a re-locate by id.
@MainActor
extension ProjectStore {

    /// Turns an AUDIO clip into a bank of sampler pads: boundaries (detected,
    /// equally divided, or on the musical grid) become `SamplerZone`s with
    /// `startFrame`/`endFrame` on an instrument track, plus — by default — a
    /// MIDI clip that replays the original groove.
    ///
    /// **Clip-centric, and that is load-bearing.** The clip's source window IS
    /// the capture: trim a clip to the four bars you want and chop that. It
    /// inherits `locateClip`, the `clipNotFound` / `transientsRequireAudioClip`
    /// vocabulary, and the `clip.detectTransients` idiom an agent already knows.
    ///
    /// Rejections, in the order they run (fail fast BEFORE the slow detection —
    /// the `quantizeAudioClip` discipline):
    ///  - headless → `engineUnavailable`
    ///  - unknown clip/track → `clipNotFound` / `trackNotFound`
    ///  - a MIDI clip → `transientsRequireAudioClip`
    ///  - a PITCH-SHIFTED clip → `sliceToSamplerPitchShiftUnsupported`, and a
    ///    time-STRETCHED one → `audioQuantizeStretchUnsupported`.
    ///    ⚠️ These are not boilerplate, they are a correctness guard: zones
    ///    read RAW source frames, so a stretched or pitched clip SOUNDS one way
    ///    on the timeline and its source file sounds another — the
    ///    "reconstruction" would silently not match what the user is hearing.
    ///  - no audio file → `invalidClipEdit`
    ///  - `mode: .grid` ONLY, across a tempo change →
    ///    `audioQuantizeTempoBoundaryUnsupported`. ⭐ `.transients` and
    ///    `.divisions` are computed entirely in the source-seconds domain, never
    ///    consult the tempo map, and must NOT be rejected.
    ///  - a non-instrument `targetTrackId` → `instrumentRequiresInstrumentTrack`
    ///  - nothing to slice → `audioQuantizeNoTransients`; too many pads or a
    ///    pad past MIDI 127 → a teaching `invalidClipEdit`. ⭐ Both REJECT and
    ///    never truncate.
    ///
    /// ⚠️ `requireNotCompMember` is deliberately NOT applied. The source clip
    /// is READ-ONLY here — it is not sliced, moved or replaced. This is the
    /// `detectTransients` posture, not the `quantizeAudio` posture; adding the
    /// guard would refuse a legitimate chop of a comp'd take for no reason.
    ///
    /// Everything lands in ONE `performEdit("Chop to Sampler")` — ⚠️ with NO
    /// `key:`. Coalescing is an 800 ms window meant for slider scrubs; two
    /// chops inside it would fold into one undo step and the first would become
    /// unreachable (`applyAudioQuantize`'s precedent: *"NO coalescing — a
    /// re-run compounds; undo first"*). One edit is also one engine rebuild and
    /// one file read: a zones change is STRUCTURAL, so creating N zones in N
    /// edits would re-read the whole source file N times.
    ///
    /// ## ⭐⭐ `muteSourceTrack` — the +6 LU problem, made addressable (m39-pads)
    ///
    /// The source clip is READ-ONLY here and stays exactly where it is, which is
    /// correct: a chop reads the file, it does not consume the recording. The
    /// consequence is that after a chop the timeline holds BOTH the original and
    /// a reconstruction that replays it, and **measured 2026-09-19 the two
    /// together are +6.0 LU louder than the source alone and audibly
    /// comb-filtered** — the same waveform a few samples adrift.
    ///
    /// ⛔ **DEFAULTS FALSE, AND THAT DEFAULT IS NOT NEGOTIABLE.** This verb is
    /// shipped; an agent's existing `clip.sliceToSampler` call must keep meaning
    /// exactly what it meant yesterday (the additive-only law). A command that
    /// silently began muting a track the caller never named would also be the
    /// plausible-looking-success shape this whole subsystem is arranged against.
    /// The PAD GRID's card defaults it ON, because it can SHOW the toggle and
    /// name the track; a wire caller gets no such chance to see it.
    ///
    /// ⚠️ **REFUSED — with a warning, not an error — when the source track IS
    /// the destination.** Muting it would silence the pads the call just made,
    /// and returning success over a silent instrument is worse than declining.
    ///
    /// ⚠️⚠️ **THAT BRANCH IS DEFENSIVE AND CURRENTLY UNREACHABLE, said out loud
    /// so nobody "simplifies" it away.** `importAudio` guards
    /// `tracks[index].kind == .audio` (ProjectStore.swift:4465), so no path in
    /// the tree today can put an AUDIO clip on an INSTRUMENT track — and
    /// `sourceTrackID == destinationID` needs exactly that. A future
    /// audio-on-instrument path (a recording, say) would make it live the same
    /// day, and its absence then would silently mute the pads. No behavioural
    /// test can reach it; `PadGridSiteTests` pins that it exists.
    @discardableResult
    public func sliceClipToSampler(clipId: UUID,
                                   targetTrackId: UUID? = nil,
                                   settings: SliceToSamplerSettings,
                                   muteSourceTrack: Bool = false)
        async throws -> SliceToSamplerResult {
        guard let resolvedEngine = engine else { throw ProjectError.engineUnavailable }
        // A chop always changes the zones array, which is a STRUCTURAL
        // instrument change: the graph tears the node down and announces. The
        // conservative form of `setInstrument`'s routing guard — chopping
        // mid-take is not a workflow, so refusing costs nothing and an
        // announce mid-take costs a recording.
        guard !transport.isRecording else {
            throw ProjectError.transportBusy(
                "cannot chop a clip to a sampler while recording — stop first")
        }

        // --- Pre-detection validation (fast, actionable errors) -------------
        guard let (t0, c0) = locateSliceClip(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let sourceClip = tracks[t0].clips[c0]
        guard !sourceClip.isMIDI else {
            throw ProjectError.transientsRequireAudioClip(clipId)
        }
        // Pitch first, so a caller who pitched but never stretched is not told
        // to "un-stretch" (isStretchIdentity covers BOTH, hence the order).
        guard sourceClip.pitchShiftSemitones == 0 else {
            throw ProjectError.sliceToSamplerPitchShiftUnsupported(clipId)
        }
        guard sourceClip.isStretchIdentity else {
            throw ProjectError.audioQuantizeStretchUnsupported(clipId)
        }
        guard let sourceURL = sourceClip.audioFileURL else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) has no audio file to chop")
        }
        // m12-c precedent, GRID ONLY: `SliceBoundaries.gridDivisions` takes a
        // single seconds-per-beat, so a tempo change inside the window would
        // misplace every later boundary — plausible-looking wrong frames.
        if settings.mode == .grid,
           !transport.tempoMap.isConstant(
                from: sourceClip.startBeat,
                to: sourceClip.startBeat + sourceClip.lengthBeats) {
            throw ProjectError.audioQuantizeTempoBoundaryUnsupported(clipId)
        }
        if let targetTrackId {
            guard let ti = tracks.firstIndex(where: { $0.id == targetTrackId }) else {
                throw ProjectError.trackNotFound(targetTrackId)
            }
            guard tracks[ti].kind == .instrument else {
                throw ProjectError.instrumentRequiresInstrumentTrack(tracks[ti].kind)
            }
        }

        // --- Boundaries, in SOURCE-FILE seconds -----------------------------
        // Only the transient mode pays for detection; the other two are pure
        // arithmetic over the clip's window.
        var strengths: [Double] = []
        var rawBoundaries: [Double] = []
        if settings.mode == .transients {
            let markers = try await resolvedEngine.detectTransients(
                inFileAt: sourceURL, sensitivity: settings.sensitivity)
            // Re-locate by id after the await (the detectClipTransients rule):
            // detection is per-FILE, but the WINDOW that conditions it is the
            // clip's, and the clip may have moved.
            guard let (t1, c1) = locateSliceClip(clipId) else {
                throw ProjectError.clipNotFound(clipId)
            }
            let clip = tracks[t1].clips[c1]
            let window = sliceWindow(of: clip)
            rawBoundaries = SliceBoundaries.condition(
                onsetsSourceSeconds: markers.map(\.timeSeconds),
                windowStart: window.start, windowEnd: window.end,
                minSliceSeconds: settings.minSliceSeconds)
            // Strengths index-aligned with the SURVIVING boundaries: the
            // conditioner drops and merges onsets, so a positional zip against
            // the raw marker list would attach the wrong dynamics to every pad
            // after the first drop.
            let byTime = Dictionary(markers.map { ($0.timeSeconds, $0.strength) },
                                    uniquingKeysWith: { a, _ in a })
            strengths = rawBoundaries.map { byTime[$0] ?? 1 }
        } else {
            guard let (t1, c1) = locateSliceClip(clipId) else {
                throw ProjectError.clipNotFound(clipId)
            }
            let clip = tracks[t1].clips[c1]
            let window = sliceWindow(of: clip)
            switch settings.mode {
            case .divisions:
                rawBoundaries = SliceBoundaries.equalDivisions(
                    windowStart: window.start, windowEnd: window.end,
                    divisions: settings.divisions
                        ?? SliceToSamplerSettings.divisionsRange.lowerBound,
                    minSliceSeconds: settings.minSliceSeconds)
            case .grid:
                rawBoundaries = SliceBoundaries.gridDivisions(
                    clipStartBeat: clip.startBeat,
                    windowStart: window.start, windowEnd: window.end,
                    gridBeats: settings.gridBeats ?? 1,
                    tempoMap: transport.tempoMap,
                    minSliceSeconds: settings.minSliceSeconds)
            case .transients:
                break                                   // handled above
            }
        }

        // Refuse BEFORE paying for the PCM pass.
        try SliceToSamplerPlan.validateSliceCount(
            boundaryCount: rawBoundaries.count, settings: settings, clipId: clipId)

        // --- The ONE engine seam: seconds in, frames + the rate they are in
        //     out. Nothing above or below this line ever divides by a rate it
        //     guessed (see `SliceBoundaryGeometry`).
        let geometry = try await resolvedEngine.resolveSliceBoundaries(
            inFileAt: sourceURL, boundarySeconds: rawBoundaries,
            snapWindowSeconds: settings.effectiveSnapWindowSeconds)

        // Re-locate again: `resolveSliceBoundaries` is an await too.
        guard let (t2, c2) = locateSliceClip(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t2].clips[c2]
        let plan = try SliceToSamplerPlan.compute(
            clip: clip, geometry: geometry, strengths: strengths,
            settings: settings, tempoMap: transport.tempoMap)

        // --- ONE edit: track (maybe), zones, and the reconstruction clip ----
        var warnings = plan.warnings
        var createdTrackID: UUID?
        var midiClipID: UUID?
        var mutedTrackID: UUID?
        let destinationID: UUID
        // Captured by ID, not by index: the edit body below APPENDS a track,
        // and an index taken before an append is exactly the kind of quietly
        // stale handle this file's re-locate-after-every-await discipline exists
        // to avoid.
        let sourceTrackID = tracks[t2].id

        if let targetTrackId {
            guard let ti = tracks.firstIndex(where: { $0.id == targetTrackId }) else {
                throw ProjectError.trackNotFound(targetTrackId)
            }
            guard tracks[ti].kind == .instrument else {
                throw ProjectError.instrumentRequiresInstrumentTrack(tracks[ti].kind)
            }
            destinationID = targetTrackId
            let current = tracks[ti].instrument ?? .default
            let existingZones = current.kind == .sampler
                ? current.resolvedSampler.zones : []
            if !existingZones.isEmpty {
                // Zones are wholesale (the shipped `SamplerParams` contract),
                // so a chop onto a loaded sampler REPLACES its keymap. Say so
                // — silently discarding a 300-zone library would be the exact
                // plausible-looking success this command is designed against.
                warnings.append(
                    "the \(existingZones.count) zone(s) already on that track were replaced by "
                    + "the \(plan.zones.count) chop pad(s) — a zones array is wholesale. Chop "
                    + "onto a new track (omit targetTrackId) to keep the old keymap")
            }
            if current.kind == .sampler, current.sampler != nil,
               current.resolvedSampler.gain != 1 {
                warnings.append(
                    "that sampler's output gain is "
                    + "\(ClampNotice.number(current.resolvedSampler.gain))"
                    + ", so the pads will not play back at the record's own level; set it to 1 "
                    + "(track.setInstrument sampler.gain) for a level-faithful reconstruction")
            }
        } else {
            destinationID = UUID()
        }

        performEdit("Chop to Sampler") {
            let index: Int
            if let existing = tracks.firstIndex(where: { $0.id == destinationID }) {
                index = existing
            } else {
                tracks.append(Track(id: destinationID,
                                    name: chopTrackName(for: clip), kind: .instrument))
                createdTrackID = destinationID
                index = tracks.count - 1
            }

            let current = tracks[index].instrument ?? .default
            // Keep a user's own sampler globals when the track already IS a
            // sampler; otherwise start fresh with gain 1. ⭐ Not 0.8 (the
            // SamplerParams default): the total amp law is
            // `velocity/127 × zone.gain × params.gain`, so a 0.8 output gain
            // would put the whole reconstruction 1.94 dB under the record it
            // is supposed to reproduce — the same arithmetic that made
            // strength-mapped velocity the wrong default.
            let base = (current.kind == .sampler && current.sampler != nil)
                ? current.resolvedSampler
                : SamplerParams(gain: 1)
            var sampler = base
            sampler.zones = plan.zones
            // PK-F2: a STORED marker that these zones are a chop, so a key
            // change (`project.transpose`) leaves these notes alone: each one
            // picks a slice, and moving it would play a different slice. Set
            // here and nowhere else, because this is the one place that knows.
            // ⚠️ Inert until `SamplerParams.sliceKit` is stored (see
            // `SamplerParams.markSliceKit`).
            sampler.markSliceKit()
            // Provenance belongs to importSampleLibrary alone (m26-h): a chop
            // did not come from an .sfz, so it must not claim one.
            sampler.sourcePath = nil
            sampler.displayName = nil
            tracks[index].instrument = InstrumentDescriptor(
                kind: .sampler,
                polySynth: current.polySynth,
                sampler: sampler,
                audioUnit: current.audioUnit,
                soundBank: current.soundBank,
                // ⛔ m39-dm — CARRIED FORWARD LIKE EVERY OTHER PAYLOAD. This is
                // another explicit initialiser call, so omitting it would take
                // the nil default and CHOPPING A CLIP TO A SAMPLER WOULD WIPE
                // THE USER'S DRUM KIT — with a success response, on a track
                // they were not editing the drums of.
                drumKit: current.drumKit)

            if settings.generateMIDI && !plan.notes.isEmpty {
                let midiClip = Clip(
                    name: "\(clip.name) chops",
                    startBeat: plan.midiClipStartBeat,
                    lengthBeats: plan.midiClipLengthBeats,
                    notes: plan.notes)
                midiClipID = midiClip.id
                tracks[index].clips.append(midiClip)
                // The ONE no-silent-overlap choke point (m13-b) — folded into
                // THIS edit, so one undo restores both the chop and any
                // resident trim it caused.
                tracks[index].clips = Self.resolvingOverlaps(
                    in: tracks[index].clips, activeIDs: [midiClip.id],
                    start: midiClip.startBeat,
                    end: midiClip.startBeat + midiClip.lengthBeats,
                    tempoMap: transport.tempoMap).clips
            }

            // ⭐ INSIDE THE ONE `performEdit`, so ONE undo puts the pads AND the
            // mute back together. A separate `setMute` call afterwards would
            // make the user press ⌘Z twice to get back where they started, and
            // the halfway state — the original audible under a keymap that no
            // longer exists — is one nobody asked for.
            if muteSourceTrack, sourceTrackID != destinationID,
               let si = tracks.firstIndex(where: { $0.id == sourceTrackID }) {
                if tracks[si].isMuted {
                    warnings.append(
                        "“\(tracks[si].name)” was already muted, so nothing changed there")
                } else {
                    tracks[si].isMuted = true
                    mutedTrackID = sourceTrackID
                }
            }

            engine?.tracksDidChange(tracks)
        }

        // ⚠️ WARNED, NOT THROWN: the chop itself succeeded and the pads are
        // real. Appended AFTER the edit so it cannot be read as a reason the
        // edit did not happen.
        if muteSourceTrack && sourceTrackID == destinationID {
            warnings.append(
                "the source clip is on the SAME track the pads landed on, so muting it was "
                + "skipped — it would have silenced the pads too. Chop onto a new track "
                + "(omit targetTrackId) if you want the original muted")
        }

        return SliceToSamplerResult(
            trackId: destinationID, createdTrackId: createdTrackID,
            midiClipId: midiClipID, sampleRate: geometry.sampleRate,
            frameCount: geometry.frameCount, sliceCount: plan.slices.count,
            headSeconds: plan.headSeconds, slices: plan.slices, warnings: warnings,
            mutedTrackId: mutedTrackID,
            // ⚠️ READ BACK OUT OF THE STORE AFTER THE EDIT, never assembled from
            // what was requested. That is the whole reason this field exists as
            // its own measurement — see its doc.
            sourceTrackMuted: tracks.first { $0.id == sourceTrackID }?.isMuted ?? false)
    }

    /// The clip's source window in SOURCE-FILE seconds — the chop region.
    private func sliceWindow(of clip: Clip) -> (start: Double, end: Double) {
        let start = clip.startOffsetSeconds
        return (start, start + clip.sourceWindowSeconds(tempoMap: transport.tempoMap))
    }

    /// Locates a clip by id across every track (extension-local; the private
    /// helpers in ProjectStore.swift are not visible cross-file).
    private func locateSliceClip(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}

/// Name for an auto-created chop track. Free function so the edit body stays
/// non-capturing of `self` beyond `tracks`.
private func chopTrackName(for clip: Clip) -> String {
    let base = clip.name.isEmpty ? "Chop" : clip.name
    return "\(base) chops"
}
