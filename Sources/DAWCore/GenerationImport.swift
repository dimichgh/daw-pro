import Foundation

/// Bridge to the AI song-generation provider (M6 iii-a), as
/// `ProjectStore.importGeneration` needs it. DAWCore stays AI/network-free:
/// the real implementation wraps AIServices' `SongGenerating` and lives in
/// DAWControl (`SongGenerationImportSource`), injected into
/// `ProjectStore.generationSource` — the same seam pattern as `MediaImporting`
/// (audio-file facts) and `AudioEngineControlling` (playback). Tests supply a
/// fake so the import logic is exercised without a real sidecar/network call.
///
/// The seam IS the status poll: a finished job already carries a local
/// `audioPath` (the client fetched it once on the first succeeded poll — see
/// the `SongGenerating` protocol doc) plus the upstream `metas` DAW Pro adopts
/// on import. So `fetchGeneration` is a thin re-poll returning those fields as
/// a DAWCore value; it THROWS for an unknown/expired/failed job exactly as a
/// status poll would (the client's `jobNotFound`/`jobFailed` message is
/// surfaced to the control client verbatim).
public protocol GenerationImporting: Sendable {
    func fetchGeneration(jobID: String) async throws -> GeneratedSongResult

    /// M6 (iii-c): the multi-result sibling of `fetchGeneration`, for a
    /// stems-extraction or Lego per-track composite job — same seam (a thin
    /// re-poll returning provider-agnostic fields DAWCore can read), but MANY
    /// named results instead of one. Throws exactly like `fetchGeneration`
    /// for an unknown/expired/failed job (the provider's own message,
    /// surfaced verbatim).
    func fetchGenerationStems(jobID: String) async throws -> GeneratedStemsResult

    /// M6 (v-b): submit a repaint of a WINDOW within a bounced file — the AI
    /// hop of the clip vocal-fix flow (`ProjectStore.fixClipRegion`). Additive
    /// with a throwing default so every existing conformer/fake compiles
    /// unchanged; `SongGenerationImportSource` (DAWControl) implements it over
    /// `SongGenerating.repaintAudio`.
    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt
}

public extension GenerationImporting {
    /// Default: a conformer without repaint submission (older fakes) refuses
    /// readably rather than silently no-op — the `SongGenerating.repaintAudio`
    /// bridge-default precedent.
    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt {
        throw ProjectError.generationSourceUnavailable
    }
}

/// DAWCore-side, provider-agnostic view of a polled generation job — exactly
/// the fields `ProjectStore.importGeneration` reads (a subset of AIServices'
/// `SongGenerationStatus`, minus the wire/progress detail the import doesn't
/// use). A failed job is surfaced by THROWING from `fetchGeneration`, never as
/// a value here.
public struct GeneratedSongResult: Sendable, Equatable {
    /// Provider job state, raw string ("queued"/"running"/"succeeded").
    public var state: String
    /// Local filesystem path to the finished audio, present once succeeded.
    public var audioPath: String?
    /// Original style/caption prompt, when the provider echoes it — used to
    /// derive the default AI-track name.
    public var prompt: String?
    /// Detected/target tempo in BPM — the tempo the project can adopt.
    public var bpm: Double?
    /// Rendered length in seconds (informational; the on-disk file's actual
    /// duration is authoritative for the clip length).
    public var durationSeconds: Double?
    public var genres: String?
    public var keyScale: String?
    public var timeSignature: String?

    public init(
        state: String,
        audioPath: String? = nil,
        prompt: String? = nil,
        bpm: Double? = nil,
        durationSeconds: Double? = nil,
        genres: String? = nil,
        keyScale: String? = nil,
        timeSignature: String? = nil
    ) {
        self.state = state
        self.audioPath = audioPath
        self.prompt = prompt
        self.bpm = bpm
        self.durationSeconds = durationSeconds
        self.genres = genres
        self.keyScale = keyScale
        self.timeSignature = timeSignature
    }
}

/// DAWCore-side, provider-agnostic view of a polled stems/Lego composite job
/// (M6 iii-c) — the multi-result sibling of `GeneratedSongResult`. A failed
/// or not-yet-finished job is represented by an empty `stems` array (the
/// store reads this exactly like `GeneratedSongResult.audioPath == nil`); a
/// job that failed upstream is surfaced by THROWING from
/// `fetchGenerationStems`, never as a value here.
public struct GeneratedStemsResult: Sendable, Equatable {
    /// Provider job state, raw string ("queued"/"running"/"succeeded").
    public var state: String
    /// One entry per requested track, present ONLY once every underlying
    /// per-track job has succeeded (empty while any track is still queued or
    /// running).
    public var stems: [GeneratedStem]

    public init(state: String, stems: [GeneratedStem] = []) {
        self.state = state
        self.stems = stems
    }
}

/// One named track result inside a `GeneratedStemsResult`.
public struct GeneratedStem: Sendable, Equatable {
    /// Stem/track name, e.g. "vocals", "drums" — becomes the new track's name.
    public var trackName: String
    /// Local filesystem path to this track's finished audio.
    public var audioPath: String
    /// Detected/target tempo in BPM for this track, when the provider
    /// reports one — see `importGeneratedStems` for how a project-tempo
    /// adoption decision is made across multiple tracks.
    public var bpm: Double?
    /// Rendered length in seconds, when reported (informational; the on-disk
    /// file's actual duration is authoritative for the clip length).
    public var durationSeconds: Double?

    public init(trackName: String, audioPath: String, bpm: Double? = nil, durationSeconds: Double? = nil) {
        self.trackName = trackName
        self.audioPath = audioPath
        self.bpm = bpm
        self.durationSeconds = durationSeconds
    }
}
