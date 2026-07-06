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
    case automationTargetNotSupported(String)
    case automationTargetUnresolvable(String)
    case automationLaneNotFound(UUID)
    case midiClipsRequireInstrumentTrack(TrackKind)
    case instrumentRequiresInstrumentTrack(TrackKind)
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
    // Groove templates (M5 iii-g).
    case grooveNotFound(UUID)
    // Loudness-normalized bounce (M5 iv-b).
    case bounceSilent
    // Stem export (M5 iv-c): a bus-routed source track has no stem of its own
    // — its signal lives in the destination bus's stem. The message is built
    // at throw time (it names both the track and its bus).
    case stemNotMasterInput(String)

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
        case .grooveNotFound(let id):
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Groove ids come from groove.list / groove.extract.
            return "no groove template with id \(id.uuidString) — use groove.list to see saved templates and built-in swings"
        case .bounceSilent:
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim). Thrown ONLY when a lufsTarget was requested; a silent
            // measure-only bounce succeeds with all-nil measurement fields.
            return "program is silent below the -70 LUFS gate — cannot loudness-normalize"
        case .stemNotMasterInput(let message):
            // The store/plan builds the message at throw time (which track,
            // which bus); surfaced verbatim — the invalidClipEdit precedent.
            return message
        }
    }
}
