import Foundation
import UniformTypeIdentifiers
import DAWCore

/// The routing / fan-out / naming decision for a HUMAN file import (File→Import
/// Audio… / Import MIDI…, or a drag-drop onto the arrange, beta m10-k) — HEADLESS
/// and tested, so the two UI paths and the `debug.importAudio` staging command
/// share one contract (the `ClipEdit`/`LoopRuler` precedent). Given N file URLs +
/// a drop/import context it produces per-file ACTIONS (place on an existing audio
/// track, or create a new audio track), the MIDI files to hand to
/// `ProjectStore.importMIDIFile`, and the list of REJECTED files. The store
/// executes the audio actions in one undo step (`importAudioBatch`). SNAPPING no
/// longer lives here (m23-f) — it lives in `ArrangeDropSnap`, the one home shared
/// by the drop PREVIEW and this execution path, and the plan receives the already
/// resolved beat.
///
/// Routing (single tested rule):
/// - a **single** file onto an **existing audio** track → a clip on that track at
///   the snapped beat;
/// - a **single** file onto empty space / no target / a **MIDI/instrument/bus**
///   lane → a NEW audio track + clip (a non-audio lane is not a valid target);
/// - **multiple** files (the stems case) → one NEW audio track per file, all clips
///   at the same snapped start beat, each track named from its filename;
/// - a **MIDI** file (m23-k4b) is never a clip placement — it goes to
///   `midiImports` and is imported by `ProjectStore.importMIDIFile` at the SAME
///   landing beat, creating its own instrument tracks. A drag that carries ANY
///   MIDI therefore never routes its audio onto the hovered lane either (see
///   `routesToExistingAudioTrack`).
/// Everything else is filtered out and reported (`rejected`).

/// The drop/import context: an optional target track (its id + kind) and the
/// ALREADY-RESOLVED landing beat.
///
/// m23-f: this deliberately carries NO `snap` and NO `meterMap`. It used to
/// carry a raw beat plus the grid and snap it here, while the drop preview
/// snapped the same raw beat independently — two computations that agreed only
/// because their inputs happened to match, which magnetic snap would have
/// broken (the view knows the target lane's clip edges; this type never could).
/// The beat now arrives already decided by the single `ArrangeDropSnap.resolve`
/// call that also drew the drop line, and `ResolvedDropBeat` cannot be
/// constructed any other way — so preview/landing divergence is not merely
/// absent, it is unrepresentable.
public struct AudioImportContext: Sendable, Equatable {
    /// The hovered/target track id, or nil for a drop onto empty space / a menu
    /// import with no target.
    public var targetTrackID: UUID?
    /// The target track's kind — only `.audio` is a valid single-file target;
    /// a MIDI/instrument/bus target falls through to new-track routing.
    public var targetTrackKind: TrackKind?
    /// Where the import lands — resolved once, by `ArrangeDropSnap.resolve`.
    public var startBeat: ResolvedDropBeat

    public init(targetTrackID: UUID? = nil, targetTrackKind: TrackKind? = nil,
                startBeat: ResolvedDropBeat) {
        self.targetTrackID = targetTrackID
        self.targetTrackKind = targetTrackKind
        self.startBeat = startBeat
    }
}

/// What a live arrange drag carries, as far as the HOVER can know it (m23-k4b).
///
/// A hover runs before the drag's URLs have loaded (`NSItemProvider` is async),
/// but `DropInfo.hasItemsConforming(to:)` answers synchronously — so this is the
/// hover's only honest source for "does this drag carry MIDI", and it is the
/// input `routesToExistingAudioTrack` takes. Headless on purpose: `DropInfo`
/// never reaches this type, so the staging seam and the tests build the same
/// value the real drag builds.
public struct ArrangeDragContents: Sendable, Equatable {
    /// How many files the drag carries (routing depends on it).
    public var fileCount: Int
    /// True when at least one member is a Standard MIDI File.
    public var carriesMIDI: Bool

    public init(fileCount: Int, carriesMIDI: Bool) {
        self.fileCount = fileCount
        self.carriesMIDI = carriesMIDI
    }

    /// The contents of an ALREADY-RESOLVED url set — the drop half of a real
    /// drag, and what the staging seam derives from its `paths`. Classifies with
    /// `AudioImportPlan.isMIDIFile`, the same predicate the plan routes on.
    public static func of(urls: [URL]) -> ArrangeDragContents {
        ArrangeDragContents(fileCount: urls.count,
                            carriesMIDI: urls.contains(where: AudioImportPlan.isMIDIFile))
    }
}

/// One planned import action for a single file.
public enum AudioImportAction: Sendable, Equatable {
    /// Place a clip on an existing audio track at `startBeat`.
    case existingTrack(trackID: UUID, startBeat: Double, url: URL)
    /// Create a new audio track named `trackName` and place a clip at `startBeat`.
    case newTrack(trackName: String, startBeat: Double, url: URL)
}

/// One planned MIDI-file import (m23-k4b): a `.mid`/`.midi` in the same human
/// import, landing at the SAME already-resolved beat the audio actions carry.
///
/// The beat is BAKED IN for the same reason `AudioImportAction` bakes it in: the
/// executor must not be handed a bare URL and left to ask "at which beat?" —
/// there is one landing per import and it was decided by the single
/// `ArrangeDropSnap.resolve` call that drew the drop line. `ProjectStore.
/// importMIDIFile(atBeat:)` takes a plain `Double` (unlike `AudioImportContext`,
/// which is TYPED as a `ResolvedDropBeat`), so this type is what stands in for
/// the compiler there.
public struct MIDIImportAction: Sendable, Equatable {
    public var url: URL
    public var startBeat: Double

    public init(url: URL, startBeat: Double) {
        self.url = url
        self.startBeat = startBeat
    }
}

/// A file the plan refused (not a supported audio or MIDI type), with a readable
/// reason.
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
    /// MIDI files in the same import (m23-k4b), in input order — ROUTED, not
    /// rejected. Each carries the same landing beat the audio actions do.
    public var midiImports: [MIDIImportAction]
    /// Files that are neither audio nor MIDI, with reasons.
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

    /// True when `url` is a Standard MIDI File this app imports (m23-k4b).
    ///
    /// Reads `ProjectStore.midiFileExtensions` — the SAME set the importer
    /// itself gates on — rather than spelling `["mid", "midi"]` a second time
    /// here. A plan that routed a file the store then refuses as "not a MIDI
    /// file" is precisely the accept-then-reject shape this item removes.
    public static func isMIDIFile(_ url: URL) -> Bool {
        ProjectStore.midiFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// The open-panel content types for File→**Import Audio…** — exactly the
    /// extensions this plan accepts, resolved to UTTypes.
    ///
    /// Derived rather than simply `[.audio]` because **`.mid` CONFORMS TO
    /// `public.audio`** (`UTType(filenameExtension: "mid")` is
    /// `public.midi-audio`, which conforms): under `[.audio]` a `.mid` was
    /// SELECTABLE in ⌘I and then died downstream with "isn't a supported audio
    /// file". `NSOpenPanel` can only allow, never subtract, so the fix is to
    /// name the concrete types (m23-k4b). Dynamic (`dyn.*`) types — what the OS
    /// hands back for an extension it does not know — are dropped: they enable
    /// nothing and would only make the list lie about its own contents.
    public static var audioContentTypes: [UTType] {
        contentTypes(for: audioExtensions)
    }

    /// The panel content types for File→**Import MIDI…** / **Export MIDI…**,
    /// derived from `ProjectStore.midiFileExtensions` the same way.
    public static var midiContentTypes: [UTType] {
        contentTypes(for: ProjectStore.midiFileExtensions)
    }

    /// Extensions → concrete UTTypes, de-duplicated (`mid` and `midi` resolve to
    /// the same type) and in a stable order so a panel's list does not reshuffle
    /// between launches.
    private static func contentTypes(for extensions: Set<String>) -> [UTType] {
        var seen: Set<UTType> = []
        return extensions.sorted().compactMap { ext -> UTType? in
            guard let type = UTType(filenameExtension: ext), !type.isDynamic,
                  seen.insert(type).inserted else { return nil }
            return type
        }
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
    ///
    /// m23-k4b adds ONE input rather than a second rule in the view. A drag that
    /// carries MIDI never lands on the hovered lane: a `.mid` becomes its own
    /// instrument tracks, so highlighting an audio lane would promise a landing
    /// the import cannot honour, and in a MIXED drop the audio member must not
    /// quietly take the lane the preview said nothing about. The hover reads
    /// `dragCarriesMIDI` from the drag's UTIs (synchronously available, before
    /// the URLs load); the plan reads it from the URLs it was handed. Same
    /// function, same answer.
    ///
    /// The parameter is DEFAULTED so every pure-audio caller — and the shipped
    /// m10-k routing table — reads exactly as it did.
    public static func routesToExistingAudioTrack(fileCount: Int, targetKind: TrackKind?,
                                                  dragCarriesMIDI: Bool = false) -> Bool {
        fileCount == 1 && targetKind == .audio && !dragCarriesMIDI
    }

    private static func rejectReason(_ url: URL) -> String {
        let ext = url.pathExtension
        return ext.isEmpty
            ? "'\(url.lastPathComponent)' has no file extension — not a supported audio file"
            : "'\(url.lastPathComponent)' isn't a supported audio file (.\(ext.lowercased()))"
    }

    public init(actions: [AudioImportAction],
                midiImports: [MIDIImportAction] = [],
                rejected: [RejectedImportFile]) {
        self.actions = actions
        self.midiImports = midiImports
        self.rejected = rejected
    }

    /// Plans an import of `urls` under `context`.
    public init(urls: [URL], context: AudioImportContext) {
        // No snapping happens here any more (m23-f): the beat arrived resolved,
        // from the same call that drew the drop line. EVERY member of the import
        // — audio clip or MIDI file — lands on this one value (m23-k4b).
        let startBeat = context.startBeat.beat

        var rejected: [RejectedImportFile] = []
        var midiImports: [MIDIImportAction] = []
        var audioURLs: [URL] = []
        for url in urls {
            if Self.isAudioFile(url) {
                audioURLs.append(url)
            } else if Self.isMIDIFile(url) {
                midiImports.append(MIDIImportAction(url: url, startBeat: startBeat))
            } else {
                rejected.append(RejectedImportFile(url: url, reason: Self.rejectReason(url)))
            }
        }

        guard !audioURLs.isEmpty else {
            // A MIDI-ONLY import takes this path — the headline k4b case — so it
            // must carry `midiImports` out with it. (It used to be a bare
            // `actions: []` early return.)
            self.init(actions: [], midiImports: midiImports, rejected: rejected)
            return
        }

        var actions: [AudioImportAction] = []
        if Self.routesToExistingAudioTrack(fileCount: audioURLs.count,
                                           targetKind: context.targetTrackKind,
                                           dragCarriesMIDI: !midiImports.isEmpty),
           let targetID = context.targetTrackID {
            actions.append(.existingTrack(trackID: targetID, startBeat: startBeat, url: audioURLs[0]))
        } else {
            // Fan-out: one new audio track per file, all at the same start beat.
            for url in audioURLs {
                actions.append(.newTrack(trackName: Self.sanitizedTrackName(from: url),
                                         startBeat: startBeat, url: url))
            }
        }

        self.init(actions: actions, midiImports: midiImports, rejected: rejected)
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
    /// MIDI imports only (m23-k4b): how many tracks the file created. An audio
    /// file always creates 0 or 1 and leaves this nil; a `.mid` can create
    /// several, and then `clipID`/`trackID` name only its FIRST imported part —
    /// this field is what stops that first id from reading as the whole story.
    /// The full ledger is `MIDIImportReport`, which `project.importMIDI` returns.
    public var tracksCreated: Int?

    public var isImported: Bool { error == nil && clipID != nil }

    public init(path: String, clipID: UUID? = nil, trackID: UUID? = nil,
                trackName: String? = nil, error: String? = nil,
                tracksCreated: Int? = nil) {
        self.path = path
        self.clipID = clipID
        self.trackID = trackID
        self.trackName = trackName
        self.error = error
        self.tracksCreated = tracksCreated
    }
}
