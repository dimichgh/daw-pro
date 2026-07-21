import Foundation

/// Bridge to a service that can read facts out of an on-disk audio file.
/// DAWCore stays engine-free: the real implementation (AVAudioFile-backed)
/// lives in DAWEngine and is injected into `ProjectStore.media`. Tests supply
/// a fake so import logic is exercised without touching the filesystem.
public protocol MediaImporting: Sendable {
    func audioFileInfo(at url: URL) throws -> AudioFileInfo
}

/// Errors surfaced by session-level operations. Every case carries an
/// actionable message so agents (and the control protocol) get a readable
/// reason, never a Swift value dump.
public enum ProjectError: Error, LocalizedError {
    case trackNotFound(UUID)
    case trackKindUnsupported(TrackKind)
    case busRoutingFixed
    case notABus(UUID)
    case duplicateSend(UUID)
    case sendNotFound(UUID)
    case clipNotFound(UUID)
    case invalidClipEdit(String)
    case effectNotFound(UUID)
    case chainFull(Int)
    case unknownEffectParam(String)
    case audioUnitEffectRequiresComponent
    // Mixer presets (M7 macro-b): message built at throw time (lists valid names).
    case mixerPresetNotFound(String)
    // Song skeleton macro (M7 macro-c): messages built at throw time.
    case songSkeletonGenreNotFound(String)  // lists every valid genre name
    case invalidSongSkeleton(String)         // field-named validation (tempo/sections)
    case automationTargetNotSupported(String)
    case automationTargetUnresolvable(String)
    case automationLaneNotFound(UUID)
    case midiClipsRequireInstrumentTrack(TrackKind)
    case instrumentRequiresInstrumentTrack(TrackKind)
    // Sound-bank instrument identity (m10-n): audioUnit and soundBank are
    // mutually exclusive selections in one setInstrument call.
    case ambiguousInstrumentSelection
    // `verb` names the command that actually rejected the call (defaults to
    // `clip.setNotes`, the original/most common caller) so the message reads
    // correctly for every notAMIDIClip site instead of always blaming
    // setNotes — m16-g copy edit (design-m16b §14 A2 deferred this).
    case notAMIDIClip(UUID, verb: String = "clip.setNotes")
    case mediaServiceUnavailable
    case importFailed(String)
    case invalidLoopRange(String)
    case invalidPunchRange(String)
    case engineUnavailable
    case nothingToRender
    case noArmedTracks
    case recordPermissionDenied
    case recordPermissionPending
    case transportBusy(String)
    case recordingFailed(String)
    case inputDeviceNotFound(String)
    case projectPathRequired
    case saveFailed(String)
    case openFailed(String)
    case malformedProject(String)
    case newerProjectVersion(found: Int, supported: Int)
    case unsavedChanges(String)
    // Crash-recovery autosave (M9 crash-b).
    case noRecoveryAvailable
    case nothingToUndo
    case nothingToRedo
    // Takes / comping (M5 iii-a).
    case clipInTakeGroup(String)
    case takeGroupNotFound
    case laneNotFound
    case laneInUse
    case invalidComp(String)
    case cannotGroup(String)
    // Quantize (M5 iii-d).
    case quantizeRequiresMIDIClip(UUID)
    // Transient detection (M5 iii-e).
    case transientsRequireAudioClip(UUID)
    // Imported-audio content analysis (m21-e): clip.analyzeAudio resolves its
    // clipId to that clip's backing audio file — MIDI clips have notes an
    // agent can read directly.
    case analysisRequiresAudioClip(UUID)
    // Audio quantize (M5 iii-f).
    case quantizeRequiresAudioClip(UUID)
    case audioQuantizeStretchUnsupported(UUID)
    case audioQuantizeNoTransients(UUID)
    // Audio quantize under a multi-segment tempo map (m12-c).
    case audioQuantizeTempoBoundaryUnsupported(UUID)
    // Tempo map (m12-d): transport.setTempo refuses on a multi-segment map,
    // pointing the caller at tempo.setMap (silently flattening is destructive).
    case tempoMapMultiSegment
    // Groove templates (M5 iii-g).
    case grooveNotFound(UUID)
    // Session markers (m11-c).
    case markerNotFound(UUID)
    case markerAmbiguous(String)     // a transport.seek name matched >1 marker
    // Loudness-normalized bounce (M5 iv-b).
    case bounceSilent
    // Stem export (M5 iv-c): a bus-routed source track has no stem of its own
    // — its signal lives in the destination bus's stem. The message is built
    // at throw time (it names both the track and its bus).
    case stemNotMasterInput(String)
    // Generation import (M6 iii-a).
    case generationSourceUnavailable
    case generationNotReady(jobID: String, state: String)
    case generationAudioMissing(String)
    // Clip vocal-fix flow (M6 v-b).
    case clipFixRequiresAudioClip(UUID)
    case clipFixJobNotFound(String)
    case clipFixStale(String)          // message built at throw time (what changed)
    // Take micro-alignment (M6 v-d).
    case alignmentInconclusive(String) // message built at throw time (onset counts)
    case alignmentWouldCrossTimelineStart(String) // built at throw time (offset + headroom)
    // Arrange-level crossfade (m11-d): messages built at throw time (field-named).
    case crossfadeNotEligible(String)   // clips not same-track / not audio / gap / over-overlap
    case crossfadeNeedsMaterial(String) // names WHICH clip/side lacks source material to extend
    // Sidechain routing (m12-f, S-1): teaching errors, messages built at
    // throw time where they depend on session state (names, paths).
    case sidechainUnsupportedEffect(EffectDescriptor.Kind)
    case sidechainUnsupportedTrack(TrackKind)   // keyed strip must own a ChainHostAU
    case sidechainUnsupportedSource(String)     // v1: bus key sources deferred (message names the bus)
    case sidechainWouldCreateCycle(String)      // names the existing feedback path
    case sidechainOneSourcePerStrip(String)     // names the already-keyed effect
    // Master insert chain (m13-d, design D4a): built-in effects only in v1.
    case masterChainBuiltInOnly
    // Master insert chain (m13-d, design §4): the master chain cannot host a
    // sidechain-keyed effect (the wire's `trackId:"master"` sentinel on
    // `fx.setSidechain` maps here). The master output likewise cannot be a KEY
    // SOURCE, but that rejection is wire-level (Commands.swift) since the store
    // never receives "master" as a source id.
    case sidechainMasterUnsupported
    // Master volume automation (m15-c): the `trackId:"master"` sentinel on the
    // automation verbs carries the VOLUME target only in v1 — every other
    // target names where it does live.
    case masterAutomationVolumeOnly
    // Arrangement bar edits (m15-d, arrange.insertBars/deleteBars): field-named
    // validation and policy refusals (a take group in the shift range, a
    // meter-boundary-crossing delete that can't splice) built at throw time —
    // the invalidClipEdit precedent for a case carrying a ready-to-show string.
    case invalidArrangeEdit(String)
    // Voice conversion (m10-p-4): vc.convertVocals resolves its `clipId` param
    // to that clip's backing audio file — a MIDI clip (or, structurally
    // unreachable via any current store mutation, an audio clip with no
    // backing file) has none to convert.
    case voiceConversionRequiresAudioClip(UUID)
    // Hosted-AU parameter surface (au.describeParams/au.setParam,
    // design-au-parameter-surface §4): target-kind rejections (built-in
    // kinds, the `.soundBank` redirect) and the not-ready status naming —
    // messages built at throw time (the invalidClipEdit ready-to-show
    // precedent; the wording mirrors requirePluginTarget / the plugin-window
    // open-failure).
    case notAnAudioUnitParamTarget(String)
    case audioUnitNotReady(String)
    // Reference track (m22-g, design-m22g-reference-tracks §5.6/§6): each
    // teaching error names the fixing verb. All four land with P1;
    // referenceNotAnalyzed/referenceSilent are thrown by P2's setMonitor.
    case referenceNotSet
    case referenceNotAnalyzed
    case referenceSilent
    case referenceFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .trackNotFound(let id):
            return "No track with id \(id.uuidString)."
        case .trackKindUnsupported(let kind):
            return "Track kind '\(kind.rawValue)' cannot hold this content — only audio tracks accept audio clips."
        case .busRoutingFixed:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "bus tracks always output to master in v0 — cannot set output or sends on a bus"
        case .notABus(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "track \(id.uuidString) is not a bus — output and send destinations must be bus tracks"
        case .duplicateSend(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "track already has a send to bus \(id.uuidString) — use track.setSend to change its level"
        case .sendNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no send with id \(id.uuidString) on that track"
        case .clipNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no clip with id \(id.uuidString) — use project.snapshot to list clips"
        case .invalidClipEdit(let message):
            // The store builds the message at throw time (which edit was invalid,
            // with the offending value); surfaced verbatim — the invalidLoopRange
            // precedent for a case carrying a ready-to-show string.
            return message
        case .effectNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no effect with id \(id.uuidString) on that track"
        case .chainFull(let cap):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "effect chain is full — a track holds at most \(cap) effects"
        case .unknownEffectParam(let message):
            // The store builds the full message at throw time (which valid
            // parameter names to list depends on the effect kind, known only
            // there); surfaced verbatim — the transportBusy/invalidLoopRange
            // precedent for a case that carries a ready-to-show string.
            return message
        case .audioUnitEffectRequiresComponent:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "an audioUnit effect requires a component selection — pass audioUnit {type?, subType, manufacturer} (see fx.listAudioUnits)"
        case .mixerPresetNotFound(let message):
            // The store builds the full message at throw time (it lists every
            // valid preset name); surfaced verbatim — the unknownEffectParam
            // precedent for a case carrying a ready-to-show string.
            return message
        case .songSkeletonGenreNotFound(let message):
            // Built at throw time (lists every valid genre name) — the
            // mixerPresetNotFound precedent. Surfaced verbatim.
            return message
        case .invalidSongSkeleton(let message):
            // Field-named validation for tempo/sections, built at throw time —
            // the invalidClipEdit precedent. Surfaced verbatim.
            return message
        case .automationTargetNotSupported(let message):
            // The store builds the message at throw time (which target is
            // v0-deferred); surfaced verbatim (the unknownEffectParam precedent).
            return message
        case .automationTargetUnresolvable(let message):
            return message
        case .automationLaneNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no automation lane with id \(id.uuidString) on that track"
        case .midiClipsRequireInstrumentTrack(let kind):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "track kind '\(kind.rawValue)' cannot hold MIDI clips — only instrument tracks accept MIDI clips (add one with track.add kind=instrument)"
        case .instrumentRequiresInstrumentTrack(let kind):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "track kind '\(kind.rawValue)' cannot host an instrument — only instrument tracks carry an instrument (add one with track.add kind=instrument)"
        case .ambiguousInstrumentSelection:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "provide either audioUnit or soundBank, not both"
        case .notAMIDIClip(let id, let verb):
            // Exact wording is contract (control protocol + MCP surface it verbatim);
            // `verb` lets each call site name itself (m16-g).
            return "clip \(id.uuidString) is an audio clip — \(verb) applies only to MIDI clips (created via clip.addMIDI)"
        case .mediaServiceUnavailable:
            return "No media service is available to read audio files. Wire up ProjectStore.media before importing."
        case .importFailed(let reason):
            return "Audio import failed: \(reason)"
        case .invalidLoopRange(let reason):
            return reason
        case .invalidPunchRange(let reason):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return reason
        case .engineUnavailable:
            return "audio engine not available"
        case .nothingToRender:
            // Exact wording is contract: the control protocol and MCP tool
            // surface this string verbatim. Names what is actually empty — the
            // render range holds no clips of ANY kind (m16-d/F4: the old copy
            // falsely claimed "no audio clips" and dead-ended MIDI-only songs);
            // teaches the two ways forward.
            return "nothing to render — no clips found in the render range; "
                + "add clips or pass an explicit durationSeconds"
        case .noArmedTracks:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no armed audio or instrument tracks — arm a track (track.setArm) before recording"
        case .recordPermissionDenied:
            return "microphone access denied — enable it in System Settings → Privacy & Security → Microphone (running via 'swift run', the permission belongs to your terminal app)"
        case .recordPermissionPending:
            return "microphone permission not decided yet — respond to the system prompt, then hit record again"
        case .transportBusy(let message):
            return message
        case .recordingFailed(let reason):
            return "recording failed: \(reason)"
        case .inputDeviceNotFound(let uid):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no input device with uid '\(uid)' — use input.listDevices"
        case .projectPathRequired:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "project has no file yet — pass a path to project.save (e.g. ~/Documents/DAW Pro/My Song.dawproj)"
        case .saveFailed(let reason):
            return "project save failed: \(reason)"
        case .openFailed(let reason):
            return "project open failed: \(reason)"
        case .malformedProject(let reason):
            return "project file is damaged or not a DAW Pro project: \(reason)"
        case .newerProjectVersion(let found, let supported):
            return "this project was saved by a newer version of DAW Pro (schema v\(found); this build reads up to v\(supported)) — update the app to open it"
        case .unsavedChanges(let reason):
            return "unsaved changes could not be saved first (\(reason)) — fix that, or pass discardChanges: true to abandon them"
        case .noRecoveryAvailable:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no recovered work to restore — check project.recoveryStatus first (available is false when the last session exited cleanly or the autosave was already used)"
        case .nothingToUndo:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "nothing to undo"
        case .nothingToRedo:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "nothing to redo"
        case .clipInTakeGroup(let name):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "clip belongs to take group '\(name)' — edit the comp (take.setComp) or take.flatten first"
        case .takeGroupNotFound:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no take group with that id on that track"
        case .laneNotFound:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no take (lane) with that id in that group"
        case .laneInUse:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "take is referenced by the comp — change the comp (take.setComp) before deleting this take"
        case .invalidComp(let message):
            // The store builds the message at throw time; surfaced verbatim (the
            // invalidClipEdit precedent).
            return message
        case .cannotGroup(let message):
            // The store builds the message at throw time; surfaced verbatim.
            return message
        case .quantizeRequiresMIDIClip(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Audio quantize is a different operation (M5 iii-f).
            return "clip \(id.uuidString) is an audio clip — clip.quantize applies only to MIDI clips; audio quantize (clip.quantizeAudio) lands later"
        case .transientsRequireAudioClip(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). MIDI notes already carry their onsets.
            return "clip \(id.uuidString) is a MIDI clip — clip.detectTransients applies only to audio clips (MIDI notes already carry their onsets)"
        case .analysisRequiresAudioClip(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim, design-clip-analyze-audio §4).
            return "clip \(id.uuidString) is a MIDI clip — clip.analyzeAudio applies only to audio clips (read MIDI notes directly for key and timing)"
        case .quantizeRequiresAudioClip(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). MIDI quantize is the separate clip.quantize (M5 iii-d).
            return "clip \(id.uuidString) is a MIDI clip — clip.quantizeAudio applies only to audio clips; use clip.quantize for MIDI notes"
        case .audioQuantizeStretchUnsupported(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). v0 cut: slice-and-nudge assumes 1:1 source↔timeline.
            return "clip \(id.uuidString) has a non-identity time-stretch — un-stretch it (clip.setStretch ratio 1, pitch 0) or bounce it first; elastic audio-quantize (per-slice stretch) lands in a future version"
        case .audioQuantizeNoTransients(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim).
            return "clip \(id.uuidString) has fewer than 2 usable transients in its window — nothing to quantize (raise sensitivity, or pick a clip with more distinct onsets)"
        case .audioQuantizeTempoBoundaryUnsupported(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). m12-c cut: slice-and-nudge assumes one constant
            // tempo across the clip (AudioQuantizePlan.compute).
            return "clip \(id.uuidString) spans a tempo change — audio quantize needs one constant tempo across the clip; split the clip at the tempo boundary (clip.split) and quantize each part"
        case .tempoMapMultiSegment:
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). transport.setTempo is the single-tempo fast path; a
            // project with a multi-segment map must edit it via tempo.setMap.
            return "this project has a multi-segment tempo map — use tempo.setMap to edit it (transport.setTempo sets a single project-wide tempo and would flatten the map)"
        case .grooveNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Groove ids come from groove.list / groove.extract.
            return "no groove template with id \(id.uuidString) — use groove.list to see saved templates and built-in swings"
        case .markerNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Marker ids come from marker.list / project.snapshot.
            return "no marker with id \(id.uuidString) — use marker.list to see the session's markers"
        case .markerAmbiguous(let name):
            // Exact wording is contract: a transport.seek by NAME matched more
            // than one marker — the caller must disambiguate by id.
            return "more than one marker is named '\(name)' — seek by markerId instead (marker.list has the ids)"
        case .bounceSilent:
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Thrown ONLY when a lufsTarget was requested; a silent
            // measure-only bounce succeeds with all-nil measurement fields.
            return "program is silent below the -70 LUFS gate — cannot loudness-normalize"
        case .stemNotMasterInput(let message):
            // The store/plan builds the message at throw time (which track,
            // which bus); surfaced verbatim — the invalidClipEdit precedent.
            return message
        case .generationSourceUnavailable:
            return "No AI generation source is available to import from. Wire up ProjectStore.generationSource (the app does this automatically)."
        case .generationNotReady(let jobID, let state):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "generation job '\(jobID)' is not finished yet (state '\(state)') — poll ai.generationStatus with that jobId until state is 'succeeded', then import again"
        case .generationAudioMissing(let path):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "the generated audio for this job is no longer on disk (\(path)) — re-poll ai.generationStatus (it re-fetches the audio), or generate again"
        case .clipFixRequiresAudioClip(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "clip \(id.uuidString) is a MIDI clip — ai.fixClipRegion applies only to audio clips"
        case .clipFixJobNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no pending clip fix with jobId '\(id)' — pending fixes do not survive app restart or project switches; submit again with ai.fixClipRegion"
        case .clipFixStale(let message):
            // The store builds the message at throw time (what changed since
            // submit); surfaced verbatim — the invalidClipEdit precedent.
            return message
        case .alignmentInconclusive(let message):
            // The store builds the message at throw time (how many onsets
            // matched, what to try next); surfaced verbatim — the
            // invalidClipEdit precedent.
            return message
        case .alignmentWouldCrossTimelineStart(let message):
            // The store builds the message at throw time (required move,
            // available headroom, take.move advice); surfaced verbatim — the
            // invalidClipEdit precedent. Thrown instead of silently clamping
            // an apply at beat 0: `applied` must never lie.
            return message
        case .crossfadeNotEligible(let message):
            // The store builds the message at throw time (which precondition
            // failed — different tracks, a MIDI clip, a gap between them, or an
            // existing overlap larger than the requested crossfade); surfaced
            // verbatim — the invalidClipEdit precedent.
            return message
        case .crossfadeNeedsMaterial(let message):
            // The store builds the message at throw time (which clip and which
            // edge has no source audio left to extend into the overlap);
            // surfaced verbatim — the invalidClipEdit precedent.
            return message
        case .sidechainUnsupportedEffect(let kind):
            // Exact wording is contract (m12-g surfaces it verbatim on the wire).
            return "a \(kind.rawValue) effect cannot take a sidechain key — only compressor and gate support sidechain in v1 (hosted Audio Unit sidechain inputs are a later phase)"
        case .sidechainUnsupportedTrack(let kind):
            // Exact wording is contract. Instrument strips walk their insert
            // chain inside the instrument source node — no input bus exists to
            // receive a key edge (design-m11f-sidechain §2), so the teaching
            // path is: route the instrument into a bus and key the bus effect.
            return "effects on an \(kind.rawValue) track cannot take a sidechain key in v1 — route the track to a bus and put the keyed compressor/gate on the bus instead"
        case .sidechainUnsupportedSource(let message):
            // Built at throw time (names the offending bus) — bus key sources
            // are deferred in v1 because a bus output is hardwired to master,
            // so stem passes could not carry one silently (Σ stems ≡ mixdown
            // is release-blocking, design §10 condition 3).
            return message
        case .sidechainWouldCreateCycle(let message):
            // Built at throw time — names the existing signal path that the
            // new key edge would close into a feedback loop.
            return message
        case .sidechainOneSourcePerStrip(let message):
            // Built at throw time — names the effect already keyed on this
            // strip (one key input per strip in v1, design §5).
            return message
        case .masterChainBuiltInOnly:
            // Exact wording is contract (design-m13d §4; control protocol +
            // MCP surface it verbatim, gate-checked in C6).
            return "the master chain hosts built-in effects only in v1 — pick one of gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus"
        case .sidechainMasterUnsupported:
            // Exact wording is contract (design-m13d §4; surfaced verbatim over
            // the wire on `fx.setSidechain {trackId:"master"}`, gate-checked in
            // C6).
            return "the master chain cannot host a sidechain-keyed effect — key an effect on a track or bus instead"
        case .masterAutomationVolumeOnly:
            // Exact wording is contract (m15-c; surfaced verbatim over the wire
            // on `automation.addLane {trackId:"master"}` for any non-volume
            // target).
            return "master automation supports the volume target only in v1 — pan, sendLevel, and effectParam lanes live on tracks (pass a track UUID)"
        case .invalidArrangeEdit(let message):
            // Built at throw time (which policy blocked the bar edit, naming the
            // offending group / meter boundary); surfaced verbatim — the
            // invalidClipEdit precedent for a ready-to-show string.
            return message
        case .voiceConversionRequiresAudioClip(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "clip \(id.uuidString) is a MIDI clip — vc.convertVocals converts an audio clip's backing recording only (pass 'path' instead, or point clipId at a real audio clip)"
        case .notAnAudioUnitParamTarget(let message):
            // The store builds the message at throw time (which kind, which
            // redirect); surfaced verbatim — the invalidClipEdit precedent.
            return message
        case .audioUnitNotReady(let message):
            // Built at throw time from the engine's lifecycle status
            // (pending/missing/failed reason — the plugin-window open-failure
            // wording); surfaced verbatim.
            return message
        case .referenceNotSet:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "no reference track is loaded — import one with reference.import"
        case .referenceNotAnalyzed:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "the reference has not been analyzed yet — run reference.analyze first"
        case .referenceSilent:
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "the reference program is gated-silent below the -70 LUFS gate and cannot be level-matched — import a reference with audible program (reference.import)"
        case .referenceFileMissing(let path):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "the reference audio file is missing (\(path)) — restore it, or import it again with reference.import"
        }
    }
}
