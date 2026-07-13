import Foundation

/// Multi-file audio import (beta m10-k) — the store side of the human File→Import
/// and arrange drag-drop paths. `importAudio` (used by the wire `clip.addAudio`)
/// stays the single-file primitive; this batches N files into ONE undo step so a
/// stems drop is one journal entry (the `applyLoopRegion` single-body law).
///
/// The headless routing/naming/snap decision lives in `DAWAppKit.AudioImportPlan`;
/// it emits these DAWCore-native descriptors (so the store stays UI-free). Each
/// request either appends a clip to an existing audio track or creates a new,
/// pre-named audio track for the file. `startBeat` is already snapped by the plan
/// — the store just places the clip there.

/// One resolved import instruction: a file plus WHERE it lands and at which
/// (already-snapped) beat.
public struct AudioImportRequest: Sendable, Equatable {
    public enum Destination: Sendable, Equatable {
        /// Append the clip to an existing track (must exist and be `.audio`, else
        /// the file is reported as a per-file error and skipped).
        case existingTrack(UUID)
        /// Create a new `.audio` track with this name, then place the clip on it.
        case newTrack(name: String)
    }

    public var url: URL
    public var destination: Destination
    public var startBeat: Double

    public init(url: URL, destination: Destination, startBeat: Double) {
        self.url = url
        self.destination = destination
        self.startBeat = startBeat
    }
}

/// Per-file outcome of `importAudioBatch`, in request order: the created clip +
/// the track it landed on, or a human-readable `error` (the file was unreadable,
/// or its target track vanished / isn't audio). A bad file never aborts the
/// others — it is reported and skipped, and the successes still land as ONE undo.
public struct AudioImportOutcome: Sendable, Equatable {
    public var url: URL
    public var clip: Clip?
    public var trackID: UUID?
    public var trackName: String?
    public var error: String?

    public init(url: URL, clip: Clip? = nil, trackID: UUID? = nil,
                trackName: String? = nil, error: String? = nil) {
        self.url = url
        self.clip = clip
        self.trackID = trackID
        self.trackName = trackName
        self.error = error
    }
}

@MainActor
extension ProjectStore {
    /// Imports N audio files in ONE undo step (beta m10-k). Each request appends a
    /// clip to an existing audio track or creates a freshly-named audio track for
    /// it; every clip lands at its pre-snapped `startBeat`.
    ///
    /// All file reads + target validation happen OUTSIDE the edit body (the
    /// `setTrackArm` guard precedent): a file that can't be read, or a request
    /// whose target track vanished / isn't audio, is reported as a per-file error
    /// and SKIPPED — it never aborts the others. Only the successful clips mutate
    /// the model, inside a single `performEdit`, so ONE undo removes the whole
    /// import (the `applyLoopRegion` single-body batching law). Throws only
    /// `mediaServiceUnavailable` (a hard precondition, before any per-file work).
    /// Returns per-file outcomes in request order.
    @discardableResult
    public func importAudioBatch(_ requests: [AudioImportRequest]) throws -> [AudioImportOutcome] {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        guard !requests.isEmpty else { return [] }

        let tempoMap = transport.tempoMap

        // Prepare every clip OUTSIDE the edit body: reads + target validation can
        // fail per file, and guards/throws must not journal. A prepared entry that
        // failed carries only its error string (its clip/destination stay nil).
        struct Prepared {
            let url: URL
            let clip: Clip?
            let destination: AudioImportRequest.Destination?
            let error: String?
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(requests.count)
        for request in requests {
            // Validate an existing-track target up front (existence + audio kind).
            if case .existingTrack(let id) = request.destination {
                guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                    prepared.append(Prepared(url: request.url, clip: nil, destination: nil,
                        error: ProjectError.trackNotFound(id).errorDescription))
                    continue
                }
                guard tracks[index].kind == .audio else {
                    prepared.append(Prepared(url: request.url, clip: nil, destination: nil,
                        error: ProjectError.trackKindUnsupported(tracks[index].kind).errorDescription))
                    continue
                }
            }
            // Read the file's duration → length in beats via the inverse
            // integral from THIS request's landing beat (m12-b, design row 33
            // — per-placement, not a shared factor).
            do {
                let info = try media.audioFileInfo(at: request.url)
                let placedStart = max(0, request.startBeat)
                let lengthBeats = tempoMap.beat(
                    from: placedStart, elapsedSeconds: info.durationSeconds) - placedStart
                let name = request.url.deletingPathExtension().lastPathComponent
                let clip = Clip(name: name, startBeat: placedStart,
                                lengthBeats: lengthBeats, audioFileURL: request.url)
                prepared.append(Prepared(url: request.url, clip: clip,
                                         destination: request.destination, error: nil))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                prepared.append(Prepared(url: request.url, clip: nil, destination: nil,
                    error: ProjectError.importFailed(reason).errorDescription))
            }
        }

        // Nothing readable → no mutation, just the per-file errors (no stray undo).
        let successCount = prepared.filter { $0.clip != nil }.count
        guard successCount > 0 else {
            return prepared.map { AudioImportOutcome(url: $0.url, error: $0.error) }
        }

        // ONE edit places every successful clip: new tracks append in order,
        // existing-track clips append to their lane, the engine reconciles once.
        var placedTrackID: [Int: UUID] = [:]
        var placedTrackName: [Int: String] = [:]
        let label = successCount == 1
            ? "Import '\(prepared.first { $0.clip != nil }!.clip!.name)'"
            : "Import \(successCount) Files"
        performEdit(label) {
            for (i, entry) in prepared.enumerated() {
                guard let clip = entry.clip, let destination = entry.destination else { continue }
                switch destination {
                case .existingTrack(let id):
                    guard let index = tracks.firstIndex(where: { $0.id == id }) else { continue }
                    // Place the incoming clip, then resolve any overlap it creates
                    // against ordinary same-lane residents through the ONE
                    // no-silent-overlap choke point (m11-d, unified in m13-b): the
                    // SAME trim rule as moveClip (stationary clips yield the covered
                    // region; fully-covered ones are removed), folded into this
                    // batch's single undo step. New-track placements can't overlap,
                    // so only this branch resolves.
                    tracks[index].clips.append(clip)
                    tracks[index].clips = ProjectStore.resolvingOverlaps(
                        in: tracks[index].clips, activeIDs: [clip.id],
                        start: clip.startBeat, end: clip.startBeat + clip.lengthBeats,
                        tempoMap: tempoMap).clips
                    placedTrackID[i] = id
                    placedTrackName[i] = tracks[index].name
                case .newTrack(let name):
                    let trackName = name.isEmpty ? "Audio" : name
                    let track = Track(name: trackName, kind: .audio, clips: [clip])
                    tracks.append(track)
                    placedTrackID[i] = track.id
                    placedTrackName[i] = trackName
                }
            }
            engine?.tracksDidChange(tracks)
        }

        return prepared.enumerated().map { i, entry in
            AudioImportOutcome(url: entry.url, clip: entry.clip,
                               trackID: placedTrackID[i], trackName: placedTrackName[i],
                               error: entry.error)
        }
    }
}
