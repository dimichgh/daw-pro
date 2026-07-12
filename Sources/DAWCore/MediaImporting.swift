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
    case notAMIDIClip(UUID)
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
    // Audio quantize (M5 iii-f).
    case quantizeRequiresAudioClip(UUID)
    case audioQuantizeStretchUnsupported(UUID)
    case audioQuantizeNoTransients(UUID)
    // Audio quantize under a multi-segment tempo map (m12-c).
    case audioQuantizeTempoBoundaryUnsupported(UUID)
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
        case .notAMIDIClip(let id):
            // Exact wording is contract (control protocol + MCP surface it verbatim).
            return "clip \(id.uuidString) is an audio clip — clip.setNotes applies only to MIDI clips (created via clip.addMIDI)"
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
            // surface this string verbatim.
            return "nothing to render — project has no audio clips"
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
        }
    }
}
