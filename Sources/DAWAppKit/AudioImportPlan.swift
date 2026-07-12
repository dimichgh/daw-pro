import Foundation
import DAWCore

/// The routing / fan-out / naming decision for a HUMAN audio import (File→Import
/// Audio… or a drag-drop onto the arrange, beta m10-k) — HEADLESS and tested, so
/// the two UI paths and the `debug.importAudio` staging command share one contract
/// (the `ClipEdit`/`LoopRuler` precedent). Given N file URLs + a drop/import
/// context it produces per-file ACTIONS (place on an existing audio track, or
/// create a new audio track) plus the list of REJECTED non-audio files. The store
/// executes the actions in one undo step (`importAudioBatch`); SNAPPING lives here
/// (the plan owns the grid), so the store just places clips.
///
/// Routing (single tested rule):
/// - a **single** file onto an **existing audio** track → a clip on that track at
///   the snapped beat;
/// - a **single** file onto empty space / no target / a **MIDI/instrument/bus**
///   lane → a NEW audio track + clip (a non-audio lane is not a valid target);
/// - **multiple** files (the stems case) → one NEW audio track per file, all clips
///   at the same snapped start beat, each track named from its filename.
/// Non-audio extensions are filtered out and reported (`rejected`).

/// The drop/import context: an optional target track (its id + kind), the raw
/// landing beat (drop-x mapped to beats, or the playhead for a menu import), and
/// the active grid.
public struct AudioImportContext: Sendable, Equatable {
    /// The hovered/target track id, or nil for a drop onto empty space / a menu
    /// import with no target.
    public var targetTrackID: UUID?
    /// The target track's kind — only `.audio` is a valid single-file target;
    /// a MIDI/instrument/bus target falls through to new-track routing.
    public var targetTrackKind: TrackKind?
    /// The raw beat where the import lands (unsnapped); the plan snaps it.
    public var atBeatRaw: Double
    /// The active clip-lane snap (the arrange effective snap).
    public var snap: ClipSnap
    /// Beats per bar (governs `.bar` snapping in odd meters).
    public var beatsPerBar: Int

    public init(targetTrackID: UUID? = nil, targetTrackKind: TrackKind? = nil,
                atBeatRaw: Double, snap: ClipSnap, beatsPerBar: Int) {
        self.targetTrackID = targetTrackID
        self.targetTrackKind = targetTrackKind
        self.atBeatRaw = atBeatRaw
        self.snap = snap
        self.beatsPerBar = beatsPerBar
    }
}

/// One planned import action for a single file.
public enum AudioImportAction: Sendable, Equatable {
    /// Place a clip on an existing audio track at `startBeat`.
    case existingTrack(trackID: UUID, startBeat: Double, url: URL)
    /// Create a new audio track named `trackName` and place a clip at `startBeat`.
    case newTrack(trackName: String, startBeat: Double, url: URL)
}

/// A file the plan refused (not a supported audio type), with a readable reason.
public struct RejectedImportFile: Sendable, Equatable {
    public var url: URL
    public var reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct AudioImportPlan: Sendable, Equatable {
    /// Per-file actions, in input order (audio files only).
    public var actions: [AudioImportAction]
    /// Non-audio files that were filtered out, with reasons.
    public var rejected: [RejectedImportFile]

    /// Extensions the app can import (what `AVAudioFile` reads on macOS). Lowercased,
    /// dot-free. Shared by the plan and the drag-drop / open-panel affordances so the
    /// gate is one tested set.
    public static let audioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "caf",
        "mp3", "m4a", "aac", "flac", "alac", "ogg", "opus",
    ]

    /// True when `url`'s extension is a supported audio type.
    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// A track name from a file: extension-stripped, whitespace-trimmed; a name
    /// that sanitizes to empty falls back to "Audio Track".
    public static func sanitizedTrackName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Audio Track" : trimmed
    }

    /// The single routing rule shared by the plan (execution) and the drag-drop
    /// hover highlight (preview): a lone file lands on the hovered lane ONLY when
    /// that lane is an existing audio track — otherwise it fans out to new tracks.
    public static func routesToExistingAudioTrack(fileCount: Int, targetKind: TrackKind?) -> Bool {
        fileCount == 1 && targetKind == .audio
    }

    private static func rejectReason(_ url: URL) -> String {
        let ext = url.pathExtension
        return ext.isEmpty
            ? "'\(url.lastPathComponent)' has no file extension — not a supported audio file"
            : "'\(url.lastPathComponent)' isn't a supported audio file (.\(ext.lowercased()))"
    }

    public init(actions: [AudioImportAction], rejected: [RejectedImportFile]) {
        self.actions = actions
        self.rejected = rejected
    }

    /// Plans an import of `urls` under `context`.
    public init(urls: [URL], context: AudioImportContext) {
        var rejected: [RejectedImportFile] = []
        let audioURLs = urls.filter { url in
            if Self.isAudioFile(url) { return true }
            rejected.append(RejectedImportFile(url: url, reason: Self.rejectReason(url)))
            return false
        }

        guard !audioURLs.isEmpty else {
            self.init(actions: [], rejected: rejected)
            return
        }

        let startBeat = context.snap.snap(beat: max(0, context.atBeatRaw),
                                          beatsPerBar: context.beatsPerBar)

        var actions: [AudioImportAction] = []
        if Self.routesToExistingAudioTrack(fileCount: audioURLs.count,
                                           targetKind: context.targetTrackKind),
           let targetID = context.targetTrackID {
            actions.append(.existingTrack(trackID: targetID, startBeat: startBeat, url: audioURLs[0]))
        } else {
            // Fan-out: one new audio track per file, all at the same start beat.
            for url in audioURLs {
                actions.append(.newTrack(trackName: Self.sanitizedTrackName(from: url),
                                         startBeat: startBeat, url: url))
            }
        }

        self.init(actions: actions, rejected: rejected)
    }
}

/// One file's final import result — the app-facing shape the File→Import menu and
/// `debug.importAudio` report (a combination of the plan's `rejected` list and the
/// store's `AudioImportOutcome`s). `error == nil && clipID != nil` means imported.
public struct AudioImportFileResult: Sendable, Equatable {
    public var path: String
    public var clipID: UUID?
    public var trackID: UUID?
    public var trackName: String?
    public var error: String?

    public var isImported: Bool { error == nil && clipID != nil }

    public init(path: String, clipID: UUID? = nil, trackID: UUID? = nil,
                trackName: String? = nil, error: String? = nil) {
        self.path = path
        self.clipID = clipID
        self.trackID = trackID
        self.trackName = trackName
        self.error = error
    }
}
