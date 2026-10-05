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

    public init(projectGeneration: UInt64, signature: String) {
        self.projectGeneration = projectGeneration
        self.signature = signature
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
    /// version, and `notice` says so.
    public var melodyChanged: Bool
    /// Design §5.7 "Melody changed", or nil.
    public var notice: String?

    public init(trackID: UUID, clipID: UUID, melodyChanged: Bool, notice: String?) {
        self.trackID = trackID
        self.clipID = clipID
        self.melodyChanged = melodyChanged
        self.notice = notice
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

/// Sung vocals: planning and landing (p2-sing-d2, design §3.4, §3.9, §4.5).
///
/// DAWCore stays AI-free: nothing here talks to the singing engine. A sing job
/// (`SingJobCoordinator`, item p2-sing-e) plans through `planSungVocal`,
/// renders elsewhere, and hands back a finished local WAV to
/// `landSungVocal`.
///
/// TODO(p2-sing-e): the wire. Nothing here is reachable from it yet. Design
/// §6 rows 13-15, in `Sources/DAWControl/Commands.swift` and
/// `mcp-server/src/server.ts`: `sing.render` (MCP tool `sing_render`) plans
/// through `planSungVocal` (`dryRun` returns the plan alone) and lands
/// through `landSungVocal`; `sing.jobStatus` (MCP tool `sing_job_status`)
/// reports the `SungVocalLanding` and the provenance's `noteAccuracy` /
/// `wordCheck`; `clip.getLyrics` (MCP tool `clip_get_lyrics`) derives its
/// assignment through `SingPlanner.assignment(for:tempoMap:)`, the one
/// derivation.
@MainActor
extension ProjectStore {

    /// Design §5.7 "Melody changed".
    public static let sungVocalMelodyChangedNotice =
        "The melody changed while I was singing; this take follows the earlier version."

    /// The track name design §4.5 gives a sung vocal: "Vocals — Built-in
    /// singer", "Vocals — <voice name>". A caller's own `trackName` wins.
    public static func sungVocalTrackName(voiceName: String) -> String {
        "Vocals — \(voiceName)"
    }

    /// Plans `clipId` for singing and snapshots what `landSungVocal` will
    /// check. A pure read: nothing in the project changes.
    ///
    /// - Throws: `ProjectError.clipNotFound`, or the planner's
    ///   `SingPlanRefusal` (audio clip, drum track, no notes, the lyrics, the
    ///   octave shift, a note or word longer than 20 s).
    public func planSungVocal(clipId: UUID, octaveShift: Int) throws -> SungVocalPlanning {
        for track in tracks {
            guard let clip = track.clips.first(where: { $0.id == clipId }) else { continue }
            let plan = try SingPlanner.plan(clip: clip, on: track, tempoMap: transport.tempoMap,
                                            meterMap: transport.meterMap, octaveShift: octaveShift)
            return SungVocalPlanning(
                plan: plan,
                landingGuard: SungVocalLandingGuard(projectGeneration: projectGeneration,
                                                    signature: plan.signature))
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
    /// 2. **Same project, but the melody, the words or the tempo changed**:
    ///    the clip is planned again from `provenance.sourceClipId` and
    ///    `provenance.octaveShift`; a different signature (or a clip that is
    ///    gone, or can no longer be planned) still lands, at the planned
    ///    beat, with `melodyChanged` and the §5.7 notice.
    ///
    /// - Throws: `ProjectError.mediaServiceUnavailable`,
    ///   `ProjectError.generationAudioMissing`, or
    ///   `SungVocalLandingError.projectChanged`.
    @discardableResult
    public func landSungVocal(fileURL: URL, trackName: String, atBeat: Double,
                              provenance: SungVocalProvenance,
                              planned: SungVocalLandingGuard) throws -> SungVocalLanding {
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
        let melodyChanged = current?.plan.signature != planned.signature

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
        let clip = Clip(name: trackName, startBeat: startBeat, lengthBeats: lengthBeats,
                        audioFileURL: stableURL, isAIGenerated: true)
        let newTrack = Track(name: trackName, kind: .audio, isAIGenerated: true, clips: [clip],
                             sungVocalProvenance: provenance)

        performEdit("Land Sung Vocal") {
            tracks.append(newTrack)
            engine?.tracksDidChange(tracks)
        }
        return SungVocalLanding(trackID: newTrack.id, clipID: clip.id, melodyChanged: melodyChanged,
                                notice: melodyChanged ? Self.sungVocalMelodyChangedNotice : nil)
    }
}
