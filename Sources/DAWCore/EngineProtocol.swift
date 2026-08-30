import Foundation

/// One installed Audio Unit music device as the engine enumerates it —
/// AudioComponent facts mirrored into the domain so DAWCore stays engine-free.
public struct AudioUnitComponentInfo: Sendable, Equatable, Codable {
    public let component: AudioUnitComponentID
    public let name: String
    public let manufacturerName: String
    public let versionString: String
    public let isV3: Bool

    public init(component: AudioUnitComponentID, name: String,
                manufacturerName: String, versionString: String, isV3: Bool) {
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        self.versionString = versionString
        self.isV3 = isV3
    }
}

/// Lifecycle state of one track's hosted Audio Unit instrument, as the engine
/// reports it. `pending` while async preparation runs; `missing` when no
/// installed component matches; `failed` carries a readable reason. Any state
/// other than `ready` renders as the silent placeholder.
public enum AudioUnitTrackStatus: Sendable, Equatable {
    case pending
    case ready
    case missing
    case failed(String)

    /// THE wire spelling of this status — "pending" / "ready" / "missing" /
    /// "failed: <reason>". ONE home (m23-br-1): the `project.snapshot`
    /// instrument objects and `engine.auPrepareStats`' per-slot `status`
    /// must never be able to disagree about what "failed" looks like on the
    /// wire, so DAWControl's `instrumentStatusString` and the engine's
    /// prepare-stats builder both read this and nothing else. Deliberately
    /// NOT `Codable` conformance: the enum is a payload-carrying case and a
    /// synthesized encoding would emit an object, changing the existing
    /// snapshot bytes.
    public var wireLabel: String {
        switch self {
        case .pending: return "pending"
        case .ready: return "ready"
        case .missing: return "missing"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// Identity of one hosted-AU parameter-surface target (au.describeParams /
/// au.setParam, design-au-parameter-surface §3): a track's hosted `.audioUnit`
/// INSTRUMENT, or one `.audioUnit` insert EFFECT (the engine's registry keys
/// effects by effectID alone). Foundation-only so DAWCore stays engine-free —
/// the `HostedAUEndpoint` shape, mirrored here because DAWEngine's endpoint
/// type must not leak into the protocol seam.
public enum HostedAUTarget: Sendable, Equatable {
    case instrument(trackID: UUID)
    case effect(effectID: UUID)
}

/// One live `AUParameter` of a hosted Audio Unit, mirrored into Foundation-only
/// facts (design-au-parameter-surface §3). `address` is the AU's
/// `AUParameterAddress` (UInt64) as a DECIMAL STRING — JSON numbers are doubles
/// and lose exactness past 2^53, and vendor addresses routinely use high bits.
/// Addresses are opaque and PER-INSTANCE: never guessed, never reused across
/// instances. `value` is read at build time — describe re-reads on every call,
/// and a set's returned info is the post-write READ-BACK (quantizing/stepping
/// units answer with the truth).
public struct HostedAUParameterInfo: Sendable, Equatable, Codable {
    /// `AUParameter.address` as a decimal string ("281474976710659").
    public var address: String
    /// `AUParameter.identifier` — the vendor's stable short name.
    public var identifier: String
    public var displayName: String
    /// "group.param" key path — the flat v1 nod to group hierarchy.
    public var keyPath: String
    /// `AudioUnitParameterUnit` mapped to a stable label ("seconds", "hertz",
    /// "decibels", …, "unknown(n)" for future cases).
    public var unit: String
    /// The vendor's custom unit string — populated for `customUnit` only.
    public var unitName: String?
    public var minValue: Double
    public var maxValue: Double
    /// Current value at read time (describe) / post-set read-back (set).
    public var value: Double
    /// `flags.contains(.flag_IsWritable)` — sets on a non-writable parameter
    /// are rejected readably.
    public var writable: Bool
    public var readable: Bool
    /// Display names of the discrete steps — indexed parameters only.
    public var valueStrings: [String]?

    public init(address: String, identifier: String, displayName: String,
                keyPath: String, unit: String, unitName: String? = nil,
                minValue: Double, maxValue: Double, value: Double,
                writable: Bool, readable: Bool, valueStrings: [String]? = nil) {
        self.address = address
        self.identifier = identifier
        self.displayName = displayName
        self.keyPath = keyPath
        self.unit = unit
        self.unitName = unitName
        self.minValue = minValue
        self.maxValue = maxValue
        self.value = value
        self.writable = writable
        self.readable = readable
        self.valueStrings = valueStrings
    }
}

/// One page of a hosted AU's parameter tree (design-au-parameter-surface §3).
/// An AU that publishes NO tree (opaque state — Kontakt-style units are
/// healthy hosts that simply don't publish) answers `hasParameterTree: false,
/// totalCount: 0` — SUCCESS, never an error. `truncated` is the honest paging
/// flag: `offset + parameters.count < totalCount`.
public struct HostedAUParameterPage: Sendable, Equatable, Codable {
    /// false ⇔ the AU publishes a nil `parameterTree` (opaque state).
    public var hasParameterTree: Bool
    /// Full tree size, pre-paging.
    public var totalCount: Int
    /// The applied page start (post-clamp).
    public var offset: Int
    /// True when parameters beyond this page exist.
    public var truncated: Bool
    public var parameters: [HostedAUParameterInfo]
    /// Misses of an `addresses` exact-get filter — reported, never an error;
    /// empty otherwise.
    public var unknownAddresses: [String]

    public init(hasParameterTree: Bool, totalCount: Int, offset: Int,
                truncated: Bool, parameters: [HostedAUParameterInfo],
                unknownAddresses: [String] = []) {
        self.hasParameterTree = hasParameterTree
        self.totalCount = totalCount
        self.offset = offset
        self.truncated = truncated
        self.parameters = parameters
        self.unknownAddresses = unknownAddresses
    }
}

/// Engine-side failures of the hosted-AU parameter surface. `LocalizedError`
/// with the design's teaching messages so the wire surfaces them verbatim
/// (design-au-parameter-surface §4). `noHostedAU` normally never reaches the
/// wire — `ProjectStore` maps it to the status-naming teaching error (the
/// plugin-window open-failure precedent).
public enum HostedAUParameterError: Error, Sendable, Equatable, LocalizedError {
    /// No `.ready` hosted instance for the target.
    case noHostedAU
    /// A SET on a nil tree (describe answers `hasParameterTree: false`).
    case noParameterTree
    /// The address parsed but names no parameter in the live tree.
    case unknownAddress(String)
    /// The parameter exists but is read-only.
    case notWritable(String)
    /// The address is not a UInt64 decimal string.
    case invalidAddress(String)
    /// NaN/±Inf value on set.
    case nonFiniteValue

    public var errorDescription: String? {
        switch self {
        case .noHostedAU:
            return "no hosted Audio Unit is ready for that target"
        case .noParameterTree:
            return "this Audio Unit publishes no parameter tree (opaque state) — use plugin.openUI to edit it visually"
        case .unknownAddress(let address):
            return "unknown AU parameter address '\(address)' — call au.describeParams to list addresses"
        case .notWritable(let identifier):
            return "parameter '\(identifier)' is not writable"
        case .invalidAddress:
            return "'address' must be the decimal string form of the parameter address (see au.describeParams)"
        case .nonFiniteValue:
            return "'value' must be a finite number"
        }
    }
}

/// Render state of one audio clip's offline stretch render (M5 ii-d), as the
/// engine reports it at snapshot-build time (pull-based — never persisted).
/// `.rendering` = the clip is scheduled as SILENCE until the render lands
/// (honest silence, never wrong-speed audio); `.failed` carries a readable
/// reason (the clip stays silent; re-editing the params retries); `.idle` =
/// nothing pending (identity clips and committed renders alike).
public enum ClipStretchStatus: Sendable, Equatable {
    case idle
    case rendering
    case failed(String)
}

/// One schedule-time degradation as the engine reports it (m15-e, audit F6):
/// playback proceeded, but not exactly as the project describes (a fade/
/// envelope bake failed, a stretched clip is still rendering, …). Posted from
/// CONTROL-side schedule code only — the render thread never produces these.
/// The store coalesces events into its `engineNotices` ring; this event type
/// carries just the facts one occurrence knows.
public struct EngineNoticeEvent: Sendable, Equatable {
    /// Stable machine code (kebab-case) naming the degradation family — the
    /// store's coalescing key. Current codes: `clip-envelope-skipped`,
    /// `clip-fades-skipped`, `clip-stretch-pending`, `clip-unplayable`,
    /// `engine-exception` (m16-a), `clip-file-missing` (m16-c — the
    /// build-time open catch and the store's open/recover echo).
    public var code: String
    /// Beginner-readable description of what the listener actually got
    /// (design-language copy — no wire-speak, names the clip).
    public var message: String
    /// Timeline beat of the affected clip's start, when the site knows one.
    public var beat: Double?

    public init(code: String, message: String, beat: Double? = nil) {
        self.code = code
        self.message = message
        self.beat = beat
    }
}

/// One COALESCED engine notice as surfaced on `project.snapshot` (m15-e):
/// repeat posts of the same `code` increment `count` and refresh
/// `message`/`beat`/`lastAt` instead of appending. Session-transient
/// diagnostics — never persisted to disk, never journaled (undo/redo does
/// not touch notices), cleared on `project.new`/`project.open`/
/// `project.recover` (every session replacement).
public struct EngineNotice: Sendable, Equatable, Codable {
    /// The coalescing key — see `EngineNoticeEvent.code`.
    public var code: String
    /// Latest occurrence's message (latest wins under coalescing).
    public var message: String
    /// Latest occurrence's clip-start beat, when known.
    public var beat: Double?
    /// How many times this code has posted since the ring was last cleared.
    public var count: Int
    /// Session-monotonic post sequence (1 = the first post since the last
    /// clear) — deliberately NOT wall-clock: a scripted scenario produces
    /// byte-identical snapshots on every run (gate scripts diff them), and
    /// relative order across notices stays exactly comparable. It is an
    /// ordering token, not a timestamp.
    public var lastAt: Int

    public init(code: String, message: String, beat: Double? = nil,
                count: Int = 1, lastAt: Int) {
        self.code = code
        self.message = message
        self.beat = beat
        self.count = count
        self.lastAt = lastAt
    }
}

/// One detected onset in an audio SOURCE file (M5 iii-e). `timeSeconds` is the
/// position in source-file seconds — geometry-free by design: clip trims and
/// splits never move it, mirroring the stretch cache's whole-source-file rule.
/// `strength` is 0...1, normalized against the strongest onset found in the
/// same analysis (1 = strongest). Produced by offline analysis, cached
/// content-keyed; regenerable by definition, never persisted in the project.
public struct TransientMarker: Sendable, Equatable, Codable {
    public var timeSeconds: Double
    public var strength: Double

    public init(timeSeconds: Double, strength: Double) {
        self.timeSeconds = timeSeconds
        self.strength = strength
    }
}

/// m32-b2 — slice boundaries resolved against a source file's OWN PCM.
///
/// ⭐ **THE POINT OF THIS TYPE IS THAT IT KEEPS THE RATE AND THE FRAMES
/// TOGETHER.** Transients arrive in SECONDS; sampler zones want FRAMES at the
/// FILE's own sample rate. A 48 kHz rip chopped against a hardcoded 44100
/// lands every chop 8.8 % off — and it would still sound like music, which is
/// why the usual "just be careful" rule is not enough. Here the ONLY way to
/// obtain a frame number is from a value that also carries the rate those
/// frames are in, produced by the code that actually opened the file. The unit
/// trap is unrepresentable rather than merely forbidden, so **do not flatten
/// this into loose parameters.**
///
/// All three arrays are index-aligned with the `boundarySeconds` the caller
/// passed in, so a caller can always say which candidate a result belongs to.
public struct SliceBoundaryGeometry: Codable, Sendable, Equatable {
    /// The FILE's own sample rate (its `processingFormat`), never the graph's.
    public var sampleRate: Double
    /// The FILE's own length in frames.
    public var frameCount: Int
    /// The snapped boundary positions, in frames at `sampleRate`. Ascending
    /// and STRICTLY increasing (the snapper enforces it defensively even when
    /// a caller's snap window was wide enough to let two candidates meet).
    public var boundaryFrames: [Int]
    /// Signed movement applied to each boundary (`chosen − candidate`), so a
    /// caller can reconstruct the unsnapped position exactly.
    public var snapOffsetFrames: [Int]
    /// `max_c |x_c[k]|` at the chosen frame, 0...1 — the residual
    /// discontinuity. ⚠️ Reported HONESTLY rather than implied away: a stereo
    /// file often has no simultaneous zero crossing inside the search window,
    /// so this says whether a real crossing was found or merely the quietest
    /// available point. That is also why the operation is called a "boundary
    /// snap" and not a "zero-crossing snap".
    public var residualAmplitude: [Double]

    public init(sampleRate: Double, frameCount: Int, boundaryFrames: [Int],
                snapOffsetFrames: [Int], residualAmplitude: [Double]) {
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.boundaryFrames = boundaryFrames
        self.snapOffsetFrames = snapOffsetFrames
        self.residualAmplitude = residualAmplitude
    }
}

/// The MIDI side of one finished take, reported by the engine when the take
/// finalizes. Notes are clip-relative beats, canonically ordered.
public struct MIDIRecordingResult: Sendable, Equatable {
    public var notes: [MIDINote]
    /// Whole-beat clip length covering the take (min 1) — matches
    /// `addMIDIClip` sizing.
    public var lengthBeats: Double
    /// True when the capture ring overflowed mid-take (events were lost).
    public var droppedEvents: Bool
    /// Captured controller streams (m16-b3): CC / pitch bend / channel
    /// pressure as clip-relative lanes (same beat domain as `notes`), already
    /// thinned at ingest per the design-m16b §7 capture law. ADDITIVE with a
    /// `[]` default so fake engines and pre-CC constructions stay valid
    /// unchanged (C12).
    public var controllerLanes: [MIDIControllerLane]

    public init(notes: [MIDINote], lengthBeats: Double, droppedEvents: Bool = false,
                controllerLanes: [MIDIControllerLane] = []) {
        self.notes = notes
        self.lengthBeats = lengthBeats
        self.droppedEvents = droppedEvents
        self.controllerLanes = controllerLanes
    }
}

/// Outcome of one finished take: the audio side (nil for MIDI-only takes) and
/// the MIDI side (nil when MIDI capture was off or unsupported). One-take
/// semantics: if the audio side aborts, the WHOLE take fails and captured
/// MIDI is discarded.
public struct TakeResult: Sendable {
    public var audio: RecordingResult?
    public var midi: MIDIRecordingResult?
    /// LINEAR transport beat at which the take stopped (m15-b): the engine's
    /// capture-clamp beat — the frozen map's inverse integral from the record
    /// anchor, NEVER modular under a loop. Loop-cycle slicing derives the
    /// exact MIDI cycle count from it (`MIDIRecordingResult.lengthBeats` is
    /// rounded UP to whole beats, which would fabricate a phantom cycle at a
    /// wrap). nil from engines/fakes that never derived one — consumers fall
    /// back to the rounded length.
    public var stopBeats: Double?

    public init(audio: RecordingResult? = nil, midi: MIDIRecordingResult? = nil,
                stopBeats: Double? = nil) {
        self.audio = audio
        self.midi = midi
        self.stopBeats = stopBeats
    }
}

/// Why a note audition did or did not reach the speakers (m23-d). REPORTING,
/// not policy: the events are delivered in every `inaudible*` case — the strip
/// is simply silent for a reason the caller can act on. Only `noRenderer` and
/// `unsupported` mean nothing was delivered.
public enum AuditionOutcome: String, Sendable, Equatable, Codable {
    /// Delivered to a live renderer on an audible strip.
    case sounded
    /// Muted, or excluded by an active solo. The strip is the mute authority,
    /// so the events go out anyway and the mixer swallows them.
    case inaudibleMuted
    /// A hosted AU is still preparing — the strip renders the silent
    /// placeholder, so the events land on nothing that makes sound yet.
    case inaudibleNotReady
    /// The audio engine is not running and would not start.
    case inaudibleEngineStopped
    /// No live renderer for that track (unknown id, an audio/bus track, or a
    /// mid-rebuild gap); nothing was delivered.
    case noRenderer
    /// The engine has no audition support at all (fakes, headless).
    case unsupported

    /// The wire's `audible` flag — `.sounded` is the only audible outcome.
    public var isAudible: Bool { self == .sounded }
}

/// The contract between the domain layer and the real-time audio engine.
/// DAWCore (and everything above it) never sees AVFoundation types.
@MainActor
public protocol AudioEngineControlling: AnyObject {
    var isRunning: Bool { get }

    /// Build/refresh the graph and start the hardware. Idempotent.
    func prepare() throws
    func shutdown()

    /// Reconcile the engine graph with the domain track list. Called after any
    /// track/clip mutation. Safe while playing: schedule-affecting changes
    /// trigger an internal stop-reschedule-resume from the current position;
    /// parameter-only changes never interrupt audio.
    func tracksDidChange(_ tracks: [Track])

    /// The WHOLE project is about to be replaced (`project.new` /
    /// `project.open`) — called immediately before the `tracksDidChange`
    /// that carries the new session's tracks. m13-a: a real engine that has
    /// rendered discards its entire graph + hardware engine and rebuilds
    /// from the new model (no per-node teardown of a once-rendered engine
    /// is ever attempted — the proven crash class); engines that never ran,
    /// and engines without the capability, ignore it.
    func projectWillReplace()

    /// Per-clip gain edit (M5 i-b): applied LIVE as one input-gain write on
    /// the clip's player — never a stop-reschedule-resume, so mid-play gain
    /// trims are seamless. Audio clips only in v0 (MIDI clips have no
    /// per-clip player); unknown ids are a safe no-op. Callers still follow
    /// with `tracksDidChange` so the engine's cached track state stays fresh
    /// for later restarts (loop wraps re-apply parameters from it).
    func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double)

    /// Offline stretch-render state for one clip (M5 ii-d): `.rendering`
    /// while the engine's cache job is in flight (the clip plays silence
    /// until the render lands), `.failed(reason)` after a render error.
    /// Pull-based: the control snapshot queries this at build time and emits
    /// the transient `stretchRendering`/`stretchError` fields. nil/`.idle`
    /// for engines without stretch support.
    func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus?

    /// Transient onset markers for the audio file at `url` (M5 iii-e):
    /// offline spectral-flux analysis, content-key cached on disk. Times are
    /// SOURCE-FILE seconds (geometry-free — callers map to clip windows and
    /// timeline beats themselves). `sensitivity` 0...1: higher finds more
    /// onsets. Runs in async/detached context only — never touches the
    /// render thread.
    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker]

    /// m32-b2: resolve slice boundaries against a source file's own PCM.
    ///
    /// `boundarySeconds` are SOURCE-FILE seconds (the `detectTransients`
    /// domain), ascending. Each is snapped to the frame within
    /// ±`snapWindowSeconds` that minimises `max_c |x_c[k]|` — a true zero
    /// crossing on a mono file, and on a stereo file the point of least
    /// combined discontinuity, which is what "no click" physically means.
    /// `snapWindowSeconds: 0` disables snapping and returns the candidates
    /// rounded to frames, exactly.
    ///
    /// ⭐ The result carries the file's OWN sample rate and frame count
    /// alongside the snapped positions IN FRAMES, so no caller ever converts
    /// seconds to frames against a rate it guessed — see
    /// `SliceBoundaryGeometry`.
    ///
    /// Runs in async/detached context only — never touches the render thread.
    func resolveSliceBoundaries(inFileAt url: URL, boundarySeconds: [Double],
                                snapWindowSeconds: Double) async throws -> SliceBoundaryGeometry

    /// Offline audio-content analysis of the file at `url` over the source
    /// window `[windowStartSeconds, +windowDurationSeconds)` (m21-e,
    /// design-clip-analyze-audio): key / tempo / spectral-balance / level
    /// measurement, content-key cached on disk. Results are SOURCE-domain
    /// (before any clip stretch/pitch — the store attaches the playback
    /// projection). Runs in async/detached context only — never touches the
    /// render thread.
    func analyzeAudioContent(inFileAt url: URL, windowStartSeconds: Double,
                             windowDurationSeconds: Double) async throws -> AudioContentAnalysis

    /// One-time whole-file REFERENCE analysis (m22-g, the `analyzeAudioContent`
    /// sibling): integrated/max-momentary/max-short-term LUFS, true peak, and
    /// LRA through the SAME `Loudness.Stream` math as `Loudness.measure`, the
    /// shared 24-band mean-power spectrum, and whole-file stereo aggregates —
    /// streamed in bounded chunks, never a full-file buffer. Runs in
    /// async/detached context only — never touches the render thread. No
    /// cache: the result persists in the project's reference slot.
    func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis

    /// Offline windowed peak/RMS profile of an ARBITRARY file on disk
    /// (m25-z, the `analyzeReferenceFile` sibling for a windowing question
    /// instead of a program-loudness one): `FileProfiler`, streamed in
    /// bounded chunks, never a full-file buffer. Runs in async/detached
    /// context only — never touches the render thread. Read-only: no
    /// cache, no project slot, nothing persisted, nothing copied.
    func profileFile(at url: URL, windowSeconds: Double, fromSeconds: Double,
                     durationSeconds: Double?) async throws -> FileProfile

    /// Offline per-frame pitch detection over the source window
    /// `[fromSeconds, fromSeconds + durationSeconds)` of the file at `url`
    /// (m23-ap-3, wiring m23-ap-2b's `PitchTracker`/`SwiftF0PitchTracker`
    /// seam — the PROTOCOL, never the concrete backend, by name, in this
    /// signature). Results are SOURCE-domain (before any clip stretch/pitch
    /// — `ProjectStore.detectClipPitch` attaches that echo). HONEST
    /// ABSENCE crosses this boundary too: an unvoiced frame in the returned
    /// `PitchDetectionResult` omits its frequency rather than reporting a
    /// sentinel. Never result-cached (see `ClipPitchAnalyzer`'s header for
    /// why). Runs in async/detached context only — never touches the
    /// render thread.
    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult

    /// The project's reference SLOT changed (m22-g P2) — the
    /// `masterEffectsChanged` twin for the monitor lane: live engines cache
    /// the slot (path/offset/trim) for scheduling; an offset change while
    /// monitoring during playback re-anchors the reference player LOCALLY
    /// (the metronome enable-mid-play mechanism — the transport is never
    /// touched). Pushed on every slot mutation AND every undo/redo/
    /// project-boundary restore. The transient monitor state is NOT carried
    /// here — that is `setReferenceMonitor`'s job.
    func referenceChanged(_ slot: ReferenceSlot?)

    /// A/B monitor toggle (m22-g P2, design D4/§5.4): ON gates the mix
    /// (post-master-chain) and schedules the reference player at the
    /// timeline-mapped file position with the STORE-computed level-match
    /// gain (dB); mid-play the player re-anchors locally (the metronome
    /// enable-mid-play mechanism), stopped it arms for the next transport
    /// start. OFF is a player-local stop + mix un-gate. Never a topology
    /// change, never a transport interruption.
    func setReferenceMonitor(on: Bool, matchGainDb: Double) throws

    /// Match-gain-only re-apply while monitoring (m22-g P2): a trim edit
    /// recomputes the law store-side against the toggle-ON snapshot basis
    /// and pushes just the gain — one node-volume write, NEVER a re-anchor
    /// (a mid-audition player restart would be a gratuitous dropout).
    func referenceMatchGainChanged(matchGainDb: Double)

    /// Begin playback from transport.positionBeats under transport.tempoMap
    /// (m12-b: the map is derived from transport.tempoBPM — trivial until
    /// Phase C). transport.isMetronomeEnabled is read HERE (and on every
    /// seek/restart); a mid-play toggle goes through `metronomeChanged`
    /// (m14-c: click-player-local, never a transport restart).
    func startPlayback(_ transport: TransportState)

    /// Halt sound; keep the engine hot. Pushes one final render-derived
    /// playhead update via playheadHandler before returning.
    func stopPlayback()

    /// Playhead moved; transport.positionBeats is the authoritative target.
    /// If playing, reschedule and resume from there; if stopped, no-op
    /// (position arrives with the next startPlayback).
    func seek(_ transport: TransportState)

    /// Tempo changed. If playing, the engine re-anchors from its OWN derived
    /// current beat position (transport.positionBeats may be ~33 ms
    /// display-stale) and resumes under transport.tempoMap (m12-b; any future
    /// map edit fires this same restart seam — design row 49).
    func setTempo(_ transport: TransportState)

    /// Loop settings changed; engine updates its cached loop state. Never interrupts audio.
    func loopChanged(_ transport: TransportState)

    /// Metronome settings changed (m14-c L-3): engine updates its cached
    /// metronome state and, while playing, starts/stops the CLICK PLAYER
    /// ONLY — clip playback is never interrupted (byte-identical through a
    /// toggle; the pre-m14-c seek/restart fallback is retired). Stopped
    /// engines just cache: the state is read again at the next start.
    func metronomeChanged(_ transport: TransportState)

    /// Master output gain 0...2 (1 = unity). Applied to the main mix bus.
    func masterVolumeChanged(_ volume: Double)

    /// The project's MASTER insert chain changed (m13-d) — the
    /// `masterVolumeChanged` twin. Live engines cache the descriptors, hand
    /// them to the graph, and run one parameter pass (chain sync + PDC
    /// recompute funnel — an atomic snapshot publish into the permanent
    /// master chain host, NEVER a topology change, never a transport
    /// interruption; design-m13d §1-B/D3). Pushed on every master chain
    /// mutation AND every undo/redo/project-boundary restore, exactly like
    /// the master volume.
    func masterEffectsChanged(_ effects: [EffectDescriptor])

    /// The project's MASTER volume automation changed (m15-c) — the
    /// `masterEffectsChanged` twin. Live engines cache the lanes, hand them
    /// to the graph, and run one parameter pass: while rolling the pass
    /// republishes the master schedule IN PLACE against the same anchor
    /// (never a restart — the vii-b no-restart rule); while stopped it lands
    /// the WYSIWYG lane preview on the master fader. Pushed on every master
    /// lane mutation AND every undo/redo/project-boundary restore, exactly
    /// like the master chain.
    func masterAutomationChanged(_ lanes: [AutomationLane])

    /// Bounce the given project state to a WAV file, offline (no hardware).
    /// Async so hosted Audio Unit instruments can be instantiated/prepared for
    /// the offline graph first; the render itself still stalls the main actor
    /// for its duration (v0-accepted for typical song lengths).
    ///
    /// `masterEffects` (m13-d, design D2): the master insert chain applied to
    /// this render — deliberately NO protocol default, so every call site
    /// declares its render class: MASTERED (program renders — mixdown/
    /// bounce/loudness — pass the project chain) vs STEM (material renders —
    /// stem passes, their "00 Mixdown" reference, bounce-in-place, Clip-Fix
    /// regions — pass `[]`; stems are pre-master by contract S-3′).
    ///
    /// `masterAutomation` (m15-c) rides the SAME class split, same no-default
    /// discipline: MASTERED passes the project's master volume lane (the fade
    /// is part of the master performance), STEM passes `[]` — a master fade,
    /// though linear, is performance, not material: baking it into stems or a
    /// bounce-in-place would double-apply on playback and destroy the
    /// re-mixable material (the S-3′ extension). The static `masterVolume`
    /// stays included in BOTH classes, exactly as before m15-c.
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo

    /// Offline-render the given project state to MEMORY (M5 iv-b, spec §5) —
    /// `renderMixdown` minus the file write: same WYSIWYG await of pending
    /// stretch renders, same fresh offline renderer + fresh AU instances per
    /// pass, same accepted main-actor stall for the render's duration.
    /// `forcedCompensationTargets` non-nil forces per-strip PDC ring targets
    /// (stem passes pass the FULL-SESSION plan so subset renders stay
    /// sample-aligned with the mix — spec §1.1); nil = the automatic plan
    /// (mix behavior). `masterEffects` + `masterAutomation` declare the
    /// render class — see `renderMixdown` (m13-d/m15-c: MASTERED passes the
    /// project chain + master lane, STEM passes `[]` for both; no default by
    /// design). Memory: one `RenderedAudio` alive per call (~230 MB for a
    /// 10-min stereo 48 k render) — accepted v0.
    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio

    /// The full-session per-strip compensation targets EXACTLY as the offline
    /// renderer's automatic plan would apply them (M5 iv-b, spec §5): a
    /// planning pass prepares the session's AUs (hosted latency), reconciles
    /// an offline graph, runs one parameter pass WITHOUT rendering, and reads
    /// the resulting plan — parity with a real render pass by construction.
    /// Stem export (iv-c) forces these into every per-stem subset pass so the
    /// Σ-stems ≡ mix invariant survives PDC.
    func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int]

    /// Write a rendered buffer to `url` as a Float32 interleaved WAV (the
    /// `renderMixdown` writer, split out — M5 iv-b, spec §5): parent
    /// directories created recursively, existing files overwritten, and the
    /// write is frame-exact — the file holds exactly the samples in `audio`,
    /// bit for bit (Float32 end-to-end keeps the ii-e no-baked-headroom
    /// stance; > 0 dBFS content survives to disk).
    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo

    /// `writeAudioFile` at a chosen output format (m23-m2) — bit depth and
    /// container, resolved by `DeliveryFormat.resolve`. `.default` (Float32
    /// WAV) is byte-for-byte the writer above.
    ///
    /// A SEPARATE requirement rather than a defaulted parameter because Swift
    /// forbids default arguments in protocol requirements. The
    /// protocol-extension default below therefore exists, and it is the reason
    /// **any test asserting an ON-DISK format must run through the real
    /// `AudioEngine`**: a double that implements only the legacy writer
    /// inherits that default, and a store-level on-disk assertion made through
    /// one would pass on an implementation that never plumbs the format at all.
    /// The default REFUSES a non-default format instead of discarding it
    /// silently — an engine that cannot write 24-bit AIFF says so.
    func writeAudioFile(_ audio: RenderedAudio, to url: URL,
                        format: DeliveryFormat) throws -> AudioFileInfo

    /// `renderMixdown` at a chosen output format (m23-m2). The SECOND seam the
    /// format has to cross: here the ENGINE both renders and writes, so an
    /// implementation that plumbs only `writeAudioFile` gets `render.mixdown`
    /// wrong while `render.bounce`/`render.stems` look right. Same refusing
    /// default, same reason.
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo

    /// Total fixed algorithmic latency of the track's insert-effect chain, in
    /// samples at the engine rate — the sum of the chain's non-bypassed
    /// effects (e.g. the limiter's 5 ms lookahead = 240 @ 48 kHz); M4 (viii)
    /// plugin-delay compensation consumes this without touching the render
    /// path. 0 for unknown tracks and engines without insert support.
    func insertChainLatencySamples(forTrack id: UUID) -> Int

    /// Fixed algorithmic latency of ONE live insert-effect instance, in
    /// samples at the engine rate, regardless of bypass (it is a property of
    /// the effect; the chain sum above applies the non-bypassed rule). Feeds
    /// the per-effect `latencySamples` on the control snapshot. 0 for unknown
    /// tracks/effects and engines without insert support.
    func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int

    /// Fixed algorithmic latency of ONE live MASTER-chain effect instance
    /// (m13-d), the `effectLatencySamples` twin on the post-fader master chain
    /// — feeds the per-effect `latencySamples` in the wire snapshot's
    /// `masterEffects` array. 0 for unknown effects, an empty chain, and
    /// engines without master-chain support (the default below).
    func masterEffectLatencySamples(effectID: UUID) -> Int

    /// Current held-peak gain reduction of ONE live insert-effect instance
    /// (m22-e): POSITIVE dB of reduction (0 = untouched signal), instant
    /// attack, released at −20 dB/s (the `peakDB` meter convention), capped
    /// at 80 dB (a fully closed gate's "full-range attenuation" reading —
    /// the −80 dB house floor mirrored). Only the built-in dynamics kinds
    /// (compressor / limiter / gate) measure GR; nil = no reading (every
    /// other kind, unknown ids, engines without insert metering) — the wire
    /// OMITS the field instead of fabricating a 0. A bypassed effect reads
    /// 0 (it is applying no reduction). Poll-based like the meters: the
    /// value moves while the engine renders (silence included — release
    /// plays out) and freezes when the engine stops.
    func effectGainReductionDb(trackID: UUID, effectID: UUID) -> Double?

    /// The `effectGainReductionDb` twin on the post-fader MASTER chain
    /// (m22-e) — feeds the additive `gainReductionDb` in the wire snapshot's
    /// `masterEffects` array. Same semantics, same nil rule.
    func masterEffectGainReductionDb(effectID: UUID) -> Double?

    /// Simultaneously-armed per-insert spectrum tap cap (m23-r2a design §Q4,
    /// promoted to the protocol at m23-r4 design S2): the ONE home for "how
    /// many inserts can this engine measure at once". `0` is the default for
    /// every conformer without insert-tap capability (fakes, headless
    /// engines) — "an engine that cannot tap inserts measures zero at once",
    /// matching the other no-capability defaults just below. `AudioEngine`
    /// overrides this with its real cap; `ProjectStore.setInsertAnalysisArmed`
    /// reads it BEFORE the model lookup so a `cap: 0` engine is classified
    /// `.unsupported`, never `.refusedCapFull(cap: 0)`.
    var maxArmedInsertAnalysis: Int { get }

    /// Arms or disarms the per-insert spectrum tap on ONE live insert
    /// (m23-r2a). `trackID == nil` addresses the MASTER insert chain — the
    /// m22-e track/master split, expressed as one nullable id instead of two
    /// parallel methods. Arming allocates a bounded sample ring plus its own
    /// analyzer (~230 KB) on the control plane; the render thread only ever
    /// observes an atomic pointer, copies samples into the ring, and performs
    /// NO analysis. A disarmed insert costs nothing at all.
    ///
    /// Returns false when the arm is REFUSED — unknown track/effect, or the
    /// engine's simultaneous-tap cap (`maxArmedInsertAnalysis`) is full. A
    /// refusal is never an eviction: an already-armed insert keeps measuring.
    /// Disarming reports true.
    ///
    /// The arm SURVIVES chain edits, effect rebuilds and engine rebuilds; it
    /// is dropped when the effect leaves the chain.
    ///
    /// This is the ENGINE'S OWN arm bookkeeping (one set, no owner concept).
    /// `ProjectStore.setInsertAnalysisArmed` (m23-r4, design D1) layers a
    /// NAMED-OWNER `Set<InsertAnalysisOwner>` on top of this single call so
    /// the in-app EQ card and the wire's `fx.spectrum` lease can each hold
    /// their own slot without one party's disarm silently stomping the
    /// other's live tap; this method itself stays refcount-free by design.
    @discardableResult
    func setInsertAnalysisArmed(trackID: UUID?, effectID: UUID, armed: Bool) -> Bool

    /// Latest spectrum snapshot measured POST one armed insert (m23-r2a):
    /// the SAME 24 log-spaced bands, ballistics and geometry as
    /// `masterAnalysis()`, because both funnel into one unmodified analyzer
    /// implementation — a tapped insert and the master overlay are comparable
    /// by shared code, not by shared constants. A STRIP insert (audio/bus/
    /// instrument track) is measured PRE that track's own fader — the strip
    /// sandwich is `sumMixer -> chainHost -> mixer`, so the fader sits
    /// downstream of the chain walk and moving it does not move this reading
    /// (measured delta < 0.5 dB, `InsertSpectrumCoverageTests`). A MASTER
    /// insert (`trackID == nil`) is measured POST the MASTER fader instead —
    /// `mainMixerNode.outputVolume` sits upstream of the master walk
    /// (measured delta ~6.0206 dB, same suite). This was unconditionally
    /// documented as "pre-fader" before m23-r4; that was only ever true for
    /// `trackID != nil`. `InsertSpectrumTapPoint.forInsert(trackID:)` is the
    /// one home for this label on the wire.
    ///
    /// nil = that insert is not armed (or the engine cannot tap inserts).
    /// Poll-based like the meters, and it DRAINS the tap's ring as a side
    /// effect. **N consumers are safe PROVIDED they are all on the main
    /// actor** (m23-r4 finding — design-m23r4-fx-spectrum-lease.md §1,
    /// correcting a prior "exactly one consumer" claim here): the tap's SPSC
    /// ring's single-consumer contract is about THREADS, not call count —
    /// `drainAndSnapshot()` accumulates samples across calls and every
    /// caller then reads the same fresher `snapshot()` (a pure read that
    /// advances nothing), never a corrupted or "slow" one. What is NOT safe
    /// is an UNOWNED disarm, which is exactly what
    /// `ProjectStore.setInsertAnalysisArmed`'s named-owner set exists to
    /// prevent. A freshly armed tap honestly reads `.floor` until ~2048
    /// frames have rendered; a poller slower than ~12 Hz falls behind
    /// wall-clock because the ring's `maxDrainFrames` (4096) drops the
    /// OLDEST frames rather than blocking — never pin an exact dB value
    /// across differing poll cadences, pin the band INDEX instead.
    func insertAnalysis(trackID: UUID?, effectID: UUID) -> MasterAnalysisSnapshot?

    /// The engine's latest latency-compensation report (M4 viii-c, spec §6):
    /// per-strip all-effects chain latency and applied ring targets plus the
    /// global stage maxima. Feeds the additive PDC snapshot fields. nil until
    /// the engine has run a recompute, or for engines without insert support.
    func pdcReport() -> PDCReport?

    /// All installed Audio Unit music devices ('aumu') available for hosting.
    func availableAudioUnits() -> [AudioUnitComponentInfo]

    /// Lifecycle state of the hosted Audio Unit on the given track; nil when
    /// the engine tracks no AU for that id.
    func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus?

    /// Effect mirror of `audioUnitStatus(forTrack:)` (M3 vi-b): lifecycle state
    /// of one hosted insert-effect AU, so a plugin-window open-failure can name
    /// pending/missing/failed(reason) readably. nil when the engine tracks no AU
    /// for that effect id, or for engines without AU-effect support.
    func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus?

    /// Current `fullStateForDocument` of the track's hosted Audio Unit as a
    /// binary plist, for save-time capture; nil when no prepared AU exists.
    func instrumentState(forTrack id: UUID) -> Data?

    /// All installed Audio Unit effects ('aufx') available as inserts (M4 v).
    func availableAudioUnitEffects() -> [AudioUnitComponentInfo]

    /// Current `fullStateForDocument` of one hosted insert-effect AU as a
    /// binary plist, for save-time capture; nil when no prepared AU exists.
    func effectState(forEffect id: UUID) -> Data?

    /// One page of the live `AUParameterTree` of a hosted Audio Unit
    /// (au.describeParams, design-au-parameter-surface): flat enumeration in
    /// the tree's own stable order, sliced `[offset, offset + maxParams)`;
    /// a non-nil `addresses` is the exact-get filter instead (misses land in
    /// `unknownAddresses`, never an error). nil ⇒ no `.ready` instance for
    /// the target (the store maps that to a status-naming teaching error);
    /// a healthy AU with a nil TREE is success (`hasParameterTree: false`).
    /// Control-plane only — the render thread is never involved.
    func describeHostedAUParameters(_ target: HostedAUTarget, offset: Int,
                                    maxParams: Int, addresses: [String]?) throws
        -> HostedAUParameterPage?

    /// Set ONE hosted-AU parameter by decimal-string address
    /// (au.setParam, design-au-parameter-surface): out-of-range values clamp
    /// SILENTLY to [minValue, maxValue] (the fx.setParam precedent), and the
    /// returned info's `value` is the post-set READ-BACK — some AUs
    /// quantize/step, and the echo must be the truth. Throws
    /// `HostedAUParameterError` for every refusal (no instance, no tree,
    /// unknown/malformed address, read-only parameter, non-finite value).
    @discardableResult
    func setHostedAUParameter(_ target: HostedAUTarget, address: String,
                              value: Double) throws -> HostedAUParameterInfo

    /// Current microphone permission as the OS reports it.
    var recordPermission: RecordPermission { get }

    /// Fires the system microphone prompt (or resolves immediately when the
    /// decision already exists). Completion lands on the main actor.
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void)

    /// All hardware devices currently offering input streams, with the system
    /// default input flagged. Safe to call any time; never touches the render
    /// path.
    func availableInputDevices() -> [AudioInputDevice]

    /// Pin capture to the device with this UID; nil returns to following the
    /// system default. Takes effect on the NEXT recording — a rolling take is
    /// never re-routed. Throws when no input device carries the UID.
    func setInputDevice(uid: String?) throws

    /// All hardware devices currently offering output streams (m20-j), with
    /// the system default output flagged (`isDefault`) and the app's own pin
    /// flagged (`isSelected`). Safe to call any time; never touches the render
    /// path. Optional capability — see the default in the extension below.
    func availableOutputDevices() -> [AudioOutputDevice]

    /// Pin PLAYBACK to the device with this UID; nil returns to following the
    /// system default. APP-LOCAL: this sets the engine's own output AUHAL and
    /// never writes the system default output, so a user picking an output
    /// inside DAW Pro does not move where their Mac sends notification sounds.
    ///
    /// Takes effect immediately — switching the device under a running engine
    /// bounces the hardware (an AVAudioEngine configuration change), and
    /// playback resumes from the current position through the standard
    /// recovery path. Throws when no output device carries the UID, or when
    /// the AUHAL accepts the write and then does not honour it (the read-back
    /// is what proves the set landed; `AudioUnitSetProperty` returns `noErr`
    /// on writes the unit discards). Optional capability — see the default in
    /// the extension below.
    func setOutputDevice(uid: String?) throws

    /// Start capturing the selected input (see `setInputDevice`; the system
    /// default when unset) to `url` AND start playback from
    /// transport.positionBeats — one take, one file; the engine knows nothing
    /// about tracks (ProjectStore fans the file out to armed tracks). The
    /// engine must NOT already be playing. When transport.isPunchEnabled, only
    /// capture inside [punchInBeat, punchOutBeat] (translated from the
    /// record-start position) is kept; the caller must guarantee
    /// punchOutBeat > positionBeats. When transport.countInBars > 0 the take
    /// anchor is delayed by countInBars bars and the gap is filled with
    /// count-in clicks (even when the metronome is disabled — count-in
    /// implies clicks); capture trims to the delayed anchor, so the finished
    /// take excludes the count-in and clip placement math is unchanged.
    /// Throws synchronously on input or
    /// file failure with no state change. `completion` fires exactly once on
    /// the main actor after the take is finalized (via stopRecording or an
    /// engine-initiated stop).
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws

    /// Superset of `startRecording` for one combined take: audio capture to
    /// `audioURL` when non-nil (same contract as `startRecording` — punch
    /// window, count-in, watchdog), plus MIDI capture from all connected
    /// inputs when `captureMIDI` is true (beat math shares the audio take's
    /// anchor; the punch window does NOT trim MIDI — v0). `audioURL == nil`
    /// with `captureMIDI` is a MIDI-only take: no file, no microphone, and
    /// the no-input watchdog stays unarmed (a note-less take is legal
    /// silence). Stopped via the same `stopRecording()`.
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws

    /// Stop capture AND playback, finalize the take file, and fire the
    /// startRecording completion. No-op when not recording.
    func stopRecording()

    /// MIDI input sources as CoreMIDI enumerates them (hot-plug refreshes the
    /// list). First call may lazily create the engine's MIDI client.
    func availableMIDIInputs() -> [MIDIInputDevice]

    /// Monotonic count of live MIDI note events received since the MIDI
    /// client came up (0 before then). Agents poll the delta to detect
    /// activity; the UI reads it as a cheap blinking-LED source.
    func midiEventCount() -> Int

    /// Installs (or clears, with nil) the MAIN-ACTOR sink for hardware
    /// CONTROLLER changes — the feed `MIDIControlMap` is mapped against
    /// (m28-knob). One observer; installing a second replaces the first.
    ///
    /// ## The seam, and why it is not a new one
    ///
    /// This REUSES the receive-thread → main-actor seam that already exists and
    /// is the only one: the CoreMIDI receive thread pushes every parsed event to
    /// `MIDIInputRTContext.captureRing` (SPSC, lock-free, drop-newest), and
    /// `MIDIInputManager.drainCaptureRing()` pops it on the main actor from a
    /// ~30 Hz task that is alive for as long as the MIDI client is. Nothing new
    /// touches the receive thread, and the render path is untouched entirely.
    ///
    /// ⭐ **The observer is called ONCE PER DRAIN PASS, and the batch MAY BE
    /// EMPTY.** The empty call is load-bearing, not noise: it is the idle tick a
    /// mapped-knob gesture uses to notice that the hand STOPPED, which is the
    /// only "release" a knob has. A subscriber that ignores empty batches leaves
    /// a live preview parked on the strip forever.
    ///
    /// ⚠️ **Optional capability with a SILENT default** (the
    /// `previewController` precedent, and the same hazard): an engine that
    /// forgot to override this discards every event, mapped controls would do
    /// nothing at all, and every model-layer test would still pass because the
    /// map and the pad are written to work against an engine that has no MIDI.
    /// `MIDIInputManagerTests`' control-change delivery test and
    /// `AudioEngineControlObserverTests` close that hole against the REAL types.
    func setControlChangeObserver(_ observer: (@MainActor ([MIDIControlChangeEvent]) -> Void)?)

    /// Sounds EXACTLY `pitches` on `trackID`'s instrument RIGHT NOW, outside the
    /// sequencer schedule and independent of transport state (m23-d note
    /// audition). SET semantics and idempotent: pitches already sounding are
    /// left alone, pitches no longer in the set are released, and an EMPTY set
    /// silences the track's audition entirely. Every call — including one whose
    /// set is unchanged — is also a LIVENESS HEARTBEAT: the render side kills
    /// any audition voice that goes 3 s without one, so a caller holding a note
    /// must keep calling (`AuditionController` does this every 500 ms). Never
    /// throws; the outcome reports why nothing will be heard when that is the
    /// case. Delivery is by renderer IDENTITY — the note-off reaches the SAME
    /// renderer object that got the on, so a node rebuild mid-hold can never
    /// leave a voice stranded on a dead instrument.
    @discardableResult
    func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome

    /// Sends ONE controller value to `trackID`'s instrument RIGHT NOW, outside
    /// the sequencer schedule (breath pad P6 — the live drag preview). Rides the
    /// same per-renderer audition ring `setAuditionPitches` uses, so it is
    /// delivered at offset 0 of whatever render quantum it drains in and touches
    /// no voice: it opens nothing, closes nothing, and is NOT a liveness
    /// heartbeat (bumping one would keep a stuck audition note alive).
    ///
    /// ⛔ **A PREVIEW, NEVER THE RECORD.** The controller lane on the clip is the
    /// record; this is a gesture. THE PAD LAW (design-breath-pad §5.1) survives
    /// because nothing here is ever consulted by playback, replay or bounce —
    /// they all read the same event array and agree sample-for-sample. The
    /// caller is responsible for the other half of that law: streaming happens
    /// IF AND ONLY IF a gesture is in progress, and the gesture's end restores
    /// the controller to `MIDIControllerType.neutralDefault` so no preview value
    /// is left parked on the strip (`PadPreviewController` is the ONE home for
    /// that policy — see `Sources/DAWCore/PadPreview.swift`).
    ///
    /// ⚠️ **Restoring neutral is not the same as restoring the committed lane,
    /// and on a track that HAS one it is measurably not.** The chase that emits
    /// `neutralDefault` is a schedule-BUILD-time prefix, not a per-block
    /// re-assert, so a release mid-playback holds neutral until the lane's next
    /// point. Scope, direction and the shared-merge fix are written out in
    /// `PadPreviewController`'s "THE LIMIT OF RULE 3".
    ///
    /// `controller` is a CC number 0…127 and `value` a data byte 0…127; both are
    /// masked rather than trusted. Never throws; the outcome reports why nothing
    /// will be heard when that is the case, exactly as `setAuditionPitches` does.
    @discardableResult
    func previewController(trackID: UUID, controller: UInt8, value: UInt8) -> AuditionOutcome

    /// LIVE PLAY (m23-ct): sounds exactly `pitches` on `trackID` right now AND,
    /// when `captureIntoTake` is true and a take is rolling, puts the note
    /// EDGES this call implies into that take. SET semantics, diffed against
    /// what the track already holds, exactly like `setAuditionPitches`.
    ///
    /// ⭐ **THE ONE THING THAT MAKES A TYPED PERFORMANCE RECORDABLE.** Route C
    /// (spike 2026-08-29): ONE main-actor note edge fans to BOTH pipes, entering
    /// each at its MAIN-ACTOR end — the audible half rides the existing
    /// per-renderer audition ring (`setAuditionPitches`, unchanged), and the
    /// capture half is a direct main-actor call into the take's
    /// `MIDICaptureSession`, bypassing the capture ring entirely.
    ///
    /// ⭐⭐ **NET: ZERO RINGS GAIN A PRODUCER, which is the whole RT-safety
    /// argument.** The CoreMIDI receive thread stays the sole producer of every
    /// thru ring and of the capture ring; the main actor stays the sole
    /// producer of every audition ring. `LiveEventRing.push` is a non-atomic
    /// load(head) → write slot → store(head), so a second producer on any ring
    /// would silently lose or duplicate events; nothing here goes near one.
    ///
    /// ⚠️ **`captureIntoTake` IS A DOMAIN VERDICT, NOT AN ENGINE ONE.** Only
    /// `ProjectStore` knows arm state, so it computes
    /// `isRecording && isArmed && kind == .instrument` and hands the answer
    /// down. The engine narrows it further (is a take actually capturing MIDI,
    /// does a session exist) but never widens it.
    ///
    /// Never throws; the outcome reports what was heard, how many edges went
    /// into the take, and whether a take received them at all.
    @discardableResult
    func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                            captureIntoTake: Bool) -> LivePlayOutcome

    /// Releases every audition voice on every track and requests an
    /// all-notes-off on each renderer that held one. Called at engine
    /// shutdown, project boundary, and app resign-active — the paths where the
    /// main actor is about to stop being able to send note-offs.
    func stopAllAudition()

    /// END-OF-CONTENT STOP BOUND (m25-d): the linear beat at which playback
    /// should stop because there is no more material past it, or `nil` for
    /// "run linearly forever" (today's behaviour, and the value during a
    /// recording take or an active loop).
    ///
    /// **A PRE-COMPUTED SCALAR ON PURPOSE.** `ProjectStore` derives the value
    /// off the playhead path — walking every track's clips — and hands the
    /// engine one `Double?`. The engine's playhead tick then does a single
    /// optional unwrap and one `>=` comparison per tick: no allocation, no
    /// lock, no ObjC dispatch, no actor hop, and no call back into the store.
    /// The store re-pushes on every transition that can change the answer
    /// (play / seek / loop change / preference toggle / record / stop).
    ///
    /// Optional capability: the default discards, so fakes and headless
    /// engines compile and behave exactly as before.
    func setEndStop(beat: Double?)

    /// Sink invoked once when the playhead reaches the `setEndStop` bound.
    /// The engine does NOT tear its own transport down — `ProjectStore` owns
    /// transport state and calls its ordinary `stop()`, so the end stop lands
    /// on exactly the same path as a user pressing stop (no new semantics, no
    /// journal entry: this is transport state, not an edit).
    ///
    /// A function rather than a `var` because a protocol property requirement
    /// cannot carry a default implementation, and every existing conformer
    /// must keep compiling untouched (the `setAuditionPitches` precedent).
    func setEndStopHandler(_ handler: (() -> Void)?)

    /// PANIC (m23-af): all-notes-off on EVERY instrument renderer, whatever the
    /// transport is doing. Returns how many renderers were asked.
    ///
    /// NOT a superset of `stopAllAudition()` in the direction you'd guess, which
    /// is the whole reason this exists. That one iterates `auditionVoices` and so
    /// only reaches renderers holding an AUDITION voice; a note stuck by a lost
    /// note-off from a MIDI INPUT is on a track with no audition entry at all, so
    /// nothing there touches it. This asks every renderer unconditionally.
    ///
    /// Must work while STOPPED — that is the bug it closes. `ProjectStore.stop()`
    /// early-returns unless `isPlaying || isRecording`, so the Stop button
    /// provably cannot clear a stuck note, and neither can anything routed
    /// through it. Must ALSO leave the transport alone: a panic taken mid-take is
    /// how a player rescues a stuck note without losing the take.
    @discardableResult
    func allNotesOff() -> Int

    /// Latest master-mix analysis snapshot (M8 vm-a, session vibe meter):
    /// 24 log-spaced spectral bands (40 Hz → 16 kHz, dB, −80 floor),
    /// short-term RMS level, held peak, spectral centroid, normalized
    /// spectral flux — measured POST-master-fader (what you hear is what is
    /// analyzed). Poll-based like meters: the engine refreshes its cache at
    /// UI rate (~30–60 Hz) while running; when stopped or silent the values
    /// decay to `.floor` — never an error, never NaN/Inf. `.floor` for
    /// engines without analysis support.
    func masterAnalysis() -> MasterAnalysisSnapshot

    /// Latest goniometer/vectorscope frame (m22-d): the most recent
    /// decimated L/R sample pairs from the master tap, oldest → newest —
    /// the m22-d phase-scope view's data feed. Poll-based like
    /// `masterAnalysis()` (refreshed at tap rate while running). This is
    /// the APP-ONLY seam by design: raw sample pairs stay OFF the always-on
    /// `mixer.masterAnalysis` wire payload (scalars only there); a
    /// debug-tier wire command can be layered on later if a capture needs
    /// it. `.empty` for engines without scope support.
    func masterScopeFrame() -> MasterScopeFrame

    /// The engine's live output sample rate in Hz (m22-b §3.4) — the rate the
    /// meter tap's node reports, i.e. the rate the render path actually runs
    /// at. An internal honesty read so response-curve math is truthful near
    /// Nyquist; NEVER exposed on the wire. Engines without live output
    /// (fakes, headless) report 48_000.
    func renderSampleRateHz() -> Double

    /// Latest live master-bus loudness snapshot (m22-c): streaming BS.1770-4
    /// momentary/short-term/integrated + EBU 3342 LRA + 4× true peak (plus
    /// DC offset and crest factor), measured POST-master-fader on the same
    /// tap feed as `masterAnalysis()`. Poll-based like the meters; nil
    /// fields = not enough audio yet (never a fabricated 0). `reset: true`
    /// restarts the running measurement THEN returns the fresh (empty)
    /// snapshot — transport-independent by design (see
    /// `LiveLoudnessSnapshot`). Returns nil (whole snapshot) for engines
    /// without live-loudness support (fakes, headless).
    func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot?

    /// Render-load / overrun telemetry (M9 perf-b), accumulated per render
    /// callback by the engine's instrumented render blocks — live playback
    /// and the engine's own offline renders both count. Poll-based and
    /// window-scoped: `reset: false` reads the current window; `reset: true`
    /// returns the closing window's stats AND starts a fresh one (windowed
    /// profiling). Every field finite by contract; a stopped engine freezes
    /// the counters but the snapshot stays readable. `.idle` for engines
    /// without telemetry support.
    func performanceStats(reset: Bool) -> EnginePerformanceStats

    /// Engine watchdog state (M9 crash-c): the stall-detector reading the
    /// perf-b telemetry heartbeat — a frozen heartbeat while the engine
    /// claims to be running means the render side is dead, and the watchdog
    /// drives the same auto-restart the configuration-change path uses.
    /// Poll-based and headless-safe: never throws, `.idle` for engines
    /// without watchdog support.
    func watchdogStatus() -> EngineWatchdogStatus

    /// Hosted-AU prepare bookkeeping for the LIVE graph (m23-br-1): monotone
    /// lifetime prepare/release counters plus a per-slot digest of the last
    /// attempted prepare key. Read-only, poll-based and headless-safe like
    /// `watchdogStatus()` — never throws, `.idle` for engines without AU
    /// hosting. The counters are NOT resettable by design (a reader
    /// subtracts two reads); see `EngineAUPrepareStats` for what each one
    /// counts and why it counts there.
    func auPrepareStats() -> EngineAUPrepareStats

    /// Output metering, delivered on the main actor at ~30-60 Hz while running.
    var meteringHandler: ((MeterFrame) -> Void)? { get set }

    /// Per-track output metering at UI rate while audio renders. Engine pushes
    /// .silence for every known track on stopPlayback.
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)? { get set }

    /// Engine-derived playhead in beats, pushed on the main actor at ~30 Hz
    /// while playing plus once on stop. Source of truth for
    /// transport.positionBeats during playback.
    var playheadHandler: ((Double) -> Void)? { get set }

    /// Engine-notices sink (m15-e): the engine pushes one event per
    /// schedule-time degradation (fade/envelope bake failure, stretch-pending
    /// silence, …), always on the main actor from control-side schedule code
    /// — the render thread gains nothing. Installed by `ProjectStore` (the
    /// `playheadHandler` shape), which owns the coalescing ring the wire and
    /// UI read. Optional capability: the default discards.
    var engineNoticeHandler: ((EngineNoticeEvent) -> Void)? { get set }
}

/// Audio Unit hosting and MIDI input are optional engine capability: defaults
/// keep existing conformers (test fakes, headless engines) compiling unchanged.
extension AudioEngineControlling {
    /// Per-clip gain is optional capability: engines without per-clip players
    /// pick the change up on the next `tracksDidChange` pass.
    public func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double) {}

    /// Project-boundary engine replacement is optional capability (m13-a):
    /// fakes and headless engines have no once-rendered hardware graph to
    /// protect, so the default is a no-op.
    public func projectWillReplace() {}

    /// Note audition is optional capability (m23-d, the `masterEffectsChanged`
    /// precedent): fakes and headless engines have no instrument renderers, so
    /// the default reports `.unsupported` and existing conformers compile
    /// unchanged.
    public func setAuditionPitches(trackID: UUID, pitches: [UInt8],
                                   velocity: UInt8) -> AuditionOutcome { .unsupported }

    /// The live controller preview is optional capability (breath pad P6, the
    /// `setAuditionPitches` precedent): fakes and headless engines have no
    /// instrument renderers, so the default reports `.unsupported` and every
    /// existing conformer compiles unchanged.
    ///
    /// ⚠️ THE SAME VACUITY RISK AS `availableOutputDevices` BELOW, and it is
    /// worse here because the symptom is silence rather than an empty list: an
    /// `AudioEngine` that forgot to override this would report `.unsupported`
    /// forever, the pad would preview nothing, and every model-layer test would
    /// still pass because `PadPreviewController` is written to keep working
    /// against an engine that cannot preview.
    /// `Tests/DAWEngineTests/AuditionEngineTests.swift`'s
    /// `theRealEngineImplementsTheControllerPreview` closes that hole by
    /// asserting the REAL engine returns something other than `.unsupported`
    /// for a track that has an instrument node (the `OutputDeviceTests`
    /// precedent, applied to a method whose default is a silent no-sound).
    public func previewController(trackID: UUID, controller: UInt8,
                                  value: UInt8) -> AuditionOutcome { .unsupported }

    /// Live play is optional capability (m23-ct, the `setAuditionPitches`
    /// precedent): fakes and headless engines have neither instrument renderers
    /// nor a MIDI capture session, so the default sounds nothing and captures
    /// nothing.
    ///
    /// ⚠️ **THE SAME VACUITY RISK `previewController` DOCUMENTS, and here it is
    /// worse than silence — it is a SILENTLY UNRECORDED PERFORMANCE.** An
    /// `AudioEngine` that forgot to override this would report
    /// `.unsupported` / `recording:false` forever, every typed note would go
    /// into no take, and every model-layer test would still pass because
    /// `LivePlayController` is written to keep working against an engine that
    /// cannot capture. `Tests/DAWEngineTests/LivePlayCaptureTests.swift` closes
    /// that hole by driving the REAL `AudioEngine` with a rolling take and
    /// counting the edges that reach `midiCaptureSessionForTesting`.
    public func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                                   captureIntoTake: Bool) -> LivePlayOutcome { .unsupported }

    /// The audition all-stop is optional capability (m23-d): an engine with no
    /// audition support holds no voices, so the default is a no-op.
    public func stopAllAudition() {}

    /// The end-of-content stop bound is optional capability (m25-d, the
    /// `stopAllAudition` precedent). An engine that ignores it simply never
    /// stops itself — and that is SAFE by construction, because the store's
    /// headless ticker carries the same policy for the engine-less case and
    /// `ProjectStore.stop()` remains the only thing that ends a take. A
    /// silent default here can lose the feature, never a recording.
    public func setEndStop(beat: Double?) {}

    /// The end-stop sink is optional capability (m25-d): an engine that never
    /// evaluates a bound never fires one, so the default discards.
    public func setEndStopHandler(_ handler: (() -> Void)?) {}

    /// Output-device enumeration is optional capability (m20-j, the
    /// `availableMIDIInputs` shape): fakes and headless engines drive no
    /// hardware, so they report no devices.
    ///
    /// ⚠️ A silent default is a vacuity risk — an `AudioEngine` that forgot to
    /// override this would report "no output devices" and every test would
    /// still pass. `Tests/DAWEngineTests/OutputDeviceTests.swift` closes that
    /// hole by asserting the real engine's list EQUALS `OutputDevices`'
    /// enumeration and is non-empty (the `InputDeviceTests` precedent).
    public func availableOutputDevices() -> [AudioOutputDevice] { [] }

    /// Output-device pinning is optional capability (m20-j). An engine with no
    /// hardware cannot pin anything, so a uid is rejected the same way an
    /// unknown uid is — deliberately NOT a silent success, which would let a
    /// caller believe a selection took effect on an engine that has no output
    /// AUHAL at all. nil (follow the system default) is trivially satisfied by
    /// an engine that never pinned anything, so it succeeds.
    public func setOutputDevice(uid: String?) throws {
        if let uid { throw ProjectError.outputDeviceNotFound(uid) }
    }

    /// Panic is optional capability (m23-af, same precedent): an engine with no
    /// instrument renderers has nothing to flush, so the default reports 0 asked
    /// and existing conformers compile unchanged. The 0 is honest — callers
    /// surface it as the count, and "no renderers" and "flushed none" are the
    /// same fact here.
    public func allNotesOff() -> Int { 0 }

    /// Live click toggling is optional capability (m14-c): engines without a
    /// click player pick the change up from the TransportState handed to the
    /// next start/seek, so the default is a no-op and existing conformers
    /// compile unchanged.
    public func metronomeChanged(_ transport: TransportState) {}

    /// The master insert chain is optional capability (m13-d, the
    /// `projectWillReplace` precedent): fakes and headless engines carry no
    /// master chain host, so the default is a no-op and existing conformers
    /// compile unchanged.
    public func masterEffectsChanged(_ effects: [EffectDescriptor]) {}

    /// Master volume automation is optional capability (m15-c, the
    /// `masterEffectsChanged` precedent): fakes and headless engines have no
    /// master fader to automate, so the default is a no-op and existing
    /// conformers compile unchanged.
    public func masterAutomationChanged(_ lanes: [AutomationLane]) {}

    /// Engine notices are optional capability (m15-e): engines without
    /// schedule-time degradation reporting (fakes, headless) discard the
    /// installed handler, so existing conformers compile unchanged.
    public var engineNoticeHandler: ((EngineNoticeEvent) -> Void)? {
        get { nil }
        set {}
    }

    /// Stretch rendering is optional capability: engines without it (fakes,
    /// headless) report nothing pending.
    public func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus? { nil }

    /// Transient analysis is optional capability: engines without it (fakes,
    /// headless) report no onsets.
    public func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] { [] }

    /// Slice-boundary resolution is optional capability (m32-b2) — and it
    /// deliberately DIVERGES from its neighbour `detectTransients`, which
    /// returns `[]`.
    ///
    /// ⚠️ An empty onset list is a defensible "no onsets here". A fabricated
    /// `SliceBoundaryGeometry{sampleRate: 0, frameCount: 0, boundaryFrames: []}`
    /// is not: it would flow into the planner and produce zones with nonsense
    /// frame spans — **a plausible-looking valid answer from an engine that
    /// cannot answer**, which is this tree's characteristic failure mode. So
    /// the default THROWS, following `analyzeAudioContent`/`liveLoudness`
    /// rather than `detectTransients`. Fakes that need the surface override it.
    public func resolveSliceBoundaries(inFileAt url: URL, boundarySeconds: [Double],
                                       snapWindowSeconds: Double) async throws -> SliceBoundaryGeometry {
        throw ProjectError.engineUnavailable
    }

    /// Audio-content analysis is optional capability — but unlike
    /// `detectTransients` (an empty marker list is honest data), a fabricated
    /// all-floors analysis would be a lie, so the default THROWS
    /// `engineUnavailable` (design-clip-analyze-audio §4). Fakes that need
    /// the surface override it.
    public func analyzeAudioContent(inFileAt url: URL, windowStartSeconds: Double,
                                    windowDurationSeconds: Double) async throws -> AudioContentAnalysis {
        throw ProjectError.engineUnavailable
    }

    /// Reference analysis is optional capability (m22-g) — and like
    /// `analyzeAudioContent` above, a fabricated all-floors analysis would be
    /// a lie, so the default THROWS `engineUnavailable` (the m21-e
    /// precedent). Fakes that need the surface override it; the import path
    /// catches the throw and lands the slot with `analysis: nil` + a warning.
    public func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis {
        throw ProjectError.engineUnavailable
    }

    /// File profiling is optional capability (m25-z) — and like
    /// `analyzeAudioContent`/`analyzeReferenceFile` above, a fabricated
    /// profile would be a lie, so the default THROWS `engineUnavailable`.
    /// Fakes that need the surface override it.
    public func profileFile(at url: URL, windowSeconds: Double, fromSeconds: Double,
                            durationSeconds: Double?) async throws -> FileProfile {
        throw ProjectError.engineUnavailable
    }

    /// Pitch detection is optional capability (m23-ap-3) — and like
    /// `analyzeAudioContent`/`profileFile` above, a fabricated contour would
    /// be a lie (a phantom pitch curve is exactly the sentinel hazard this
    /// subsystem exists to avoid), so the default THROWS `engineUnavailable`.
    /// Fakes that need the surface override it.
    public func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                            confidenceThreshold: Double,
                            silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        throw ProjectError.engineUnavailable
    }

    /// The reference slot push is optional capability (m22-g P2, the
    /// `masterEffectsChanged` precedent): fakes and headless engines carry
    /// no monitor lane, so the default is a no-op.
    public func referenceChanged(_ slot: ReferenceSlot?) {}

    /// The A/B monitor is optional capability (m22-g P2) — and like
    /// `liveLoudness`, a monitor is NEVER faked: an engine that cannot
    /// audibly gate the mix and play the reference must refuse, not
    /// pretend, so the default THROWS `engineUnavailable`. (The store only
    /// reaches this seam after its own refusal ladder — design §5.6.)
    public func setReferenceMonitor(on: Bool, matchGainDb: Double) throws {
        throw ProjectError.engineUnavailable
    }

    /// The match-gain re-apply is optional capability (m22-g P2): without a
    /// lane there is no gain node, so the default is a no-op (the store
    /// only pushes it while monitoring, which implies a real lane).
    public func referenceMatchGainChanged(matchGainDb: Double) {}

    /// Insert chains are optional capability: engines without them report
    /// zero latency everywhere.
    public func insertChainLatencySamples(forTrack id: UUID) -> Int { 0 }
    public func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int { 0 }
    public func masterEffectLatencySamples(effectID: UUID) -> Int { 0 }
    public func pdcReport() -> PDCReport? { nil }

    /// Gain-reduction metering is optional capability (m22-e) — and unlike
    /// `effectLatencySamples` (whose 0 is honest data), a fabricated 0 dB
    /// from an engine that cannot measure would read like a resting meter,
    /// so the default is nil (no reading) and the wire omits the field.
    public func effectGainReductionDb(trackID: UUID, effectID: UUID) -> Double? { nil }
    public func masterEffectGainReductionDb(effectID: UUID) -> Double? { nil }

    /// Per-insert spectrum analysis is optional capability (m23-r2a). Unlike
    /// `masterAnalysis()`, whose `.floor` IS honest data from a real tap, an
    /// engine that cannot tap an insert has nothing to report — a floor
    /// snapshot from it would read as a live meter on a silent insert. So the
    /// arm honestly REFUSES (false = unarmed, nothing was allocated) and the
    /// read returns nil (no reading at all): the `liveLoudness` convention,
    /// not the `masterAnalysis` one. The cap default (m23-r4) is `0` — "an
    /// engine that cannot tap inserts measures zero at once" — right below.
    public var maxArmedInsertAnalysis: Int { 0 }
    @discardableResult
    public func setInsertAnalysisArmed(trackID: UUID?, effectID: UUID,
                                       armed: Bool) -> Bool { false }
    public func insertAnalysis(trackID: UUID?,
                               effectID: UUID) -> MasterAnalysisSnapshot? { nil }

    public func availableAudioUnits() -> [AudioUnitComponentInfo] { [] }
    public func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? { nil }
    public func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus? { nil }
    public func instrumentState(forTrack id: UUID) -> Data? { nil }
    public func availableAudioUnitEffects() -> [AudioUnitComponentInfo] { [] }
    public func effectState(forEffect id: UUID) -> Data? { nil }

    /// The hosted-AU parameter surface is optional capability
    /// (design-au-parameter-surface): engines without AU hosting (fakes,
    /// headless) report no hosted instance, so existing conformers compile
    /// unchanged.
    public func describeHostedAUParameters(_ target: HostedAUTarget, offset: Int,
                                           maxParams: Int, addresses: [String]?) throws
        -> HostedAUParameterPage? { nil }
    @discardableResult
    public func setHostedAUParameter(_ target: HostedAUTarget, address: String,
                                     value: Double) throws -> HostedAUParameterInfo {
        throw HostedAUParameterError.noHostedAU
    }

    /// Default: audio-only engines forward audio takes to the legacy
    /// `startRecording` (midi side nil); a MIDI-only take is unsupported.
    public func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                          completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        guard let audioURL else {
            throw ProjectError.recordingFailed("MIDI capture unsupported by this engine")
        }
        try startRecording(transport, to: audioURL) { result in
            completion(result.map { TakeResult(audio: $0, midi: nil) })
        }
    }

    public func availableMIDIInputs() -> [MIDIInputDevice] { [] }
    public func midiEventCount() -> Int { 0 }

    /// Hardware controller observation is optional capability (m28-knob): an
    /// engine with no CoreMIDI client has nothing to observe, so the default
    /// discards the installation and every existing conformer compiles
    /// unchanged. See the requirement's ⚠️ for why that default is dangerous
    /// and which two tests hold the real engine to it.
    public func setControlChangeObserver(
        _ observer: (@MainActor ([MIDIControlChangeEvent]) -> Void)?) {}

    /// Master-mix analysis is optional capability: engines without it
    /// (fakes, headless) sit on the floor snapshot.
    public func masterAnalysis() -> MasterAnalysisSnapshot { .floor }

    /// The scope feed is optional capability (m22-d): engines without it
    /// (fakes, headless) report the all-zero frame — an honest "silent
    /// center dot", like `masterAnalysis()`'s floor.
    public func masterScopeFrame() -> MasterScopeFrame { .empty }

    /// The live render rate is optional capability: engines without live
    /// output (fakes, headless) report the 48 kHz default (m22-b §3.4).
    public func renderSampleRateHz() -> Double { 48_000 }

    /// Live loudness metering is optional capability (m22-c) — and unlike
    /// `masterAnalysis()` (whose floor snapshot is honest data), a fabricated
    /// all-nil snapshot claiming "0 s analyzed" from an engine that CANNOT
    /// analyze would still read like a real meter, so the default returns
    /// nil (no snapshot at all) and `ProjectStore` maps that to the
    /// engineUnavailable teaching error.
    public func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot? { nil }

    /// Performance telemetry is optional capability: engines without it
    /// (fakes, headless) report the all-zero window.
    public func performanceStats(reset: Bool) -> EnginePerformanceStats { .idle }

    /// The engine watchdog is optional capability: engines without one
    /// (fakes, headless) report the zero/idle status.
    public func watchdogStatus() -> EngineWatchdogStatus { .idle }

    /// AU prepare bookkeeping is optional capability (m23-br-1): engines
    /// that host no Audio Units (fakes, headless) have prepared and released
    /// nothing, so the all-zero snapshot is the HONEST answer here — unlike
    /// `liveLoudness`, where a fabricated zero would read like a real meter.
    public func auPrepareStats() -> EngineAUPrepareStats { .idle }

    /// Buffer-out offline rendering is optional capability (M5 iv-b):
    /// engines without it (fakes, headless) refuse readably instead of
    /// pretending a silent render happened.
    public func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              fromBeat: Double, durationSeconds: Double,
                              forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        throw ProjectError.engineUnavailable
    }

    /// Engines without insert support have nothing to compensate: the empty
    /// plan (every strip's forced target then reads `[:][id] ?? 0`, correct).
    public func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] { [:] }

    /// File writing is optional capability alongside `renderOffline`.
    public func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }

    /// Format-aware writing is optional capability (m23-m2). The DEFAULT format
    /// forwards to the legacy writer, so every existing conformance — the
    /// engine, the app's fakes, and the 4+ test doubles — keeps behaving
    /// exactly as it did. A NON-default format REFUSES rather than silently
    /// writing Float32 WAV and letting a response claim otherwise: the whole
    /// defect class this item exists to close is a file whose bytes disagree
    /// with what was reported, and a silently-discarding default would
    /// reintroduce it inside every test double at once.
    public func writeAudioFile(_ audio: RenderedAudio, to url: URL,
                               format: DeliveryFormat) throws -> AudioFileInfo {
        guard format.isDefault else {
            throw ProjectError.invalidOutputFormat(
                "this engine cannot write \(format.label) — only 32-bit float WAV")
        }
        return try writeAudioFile(audio, to: url)
    }

    /// Format-aware mixdown — same rule, same reason (m23-m2).
    public func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              fromBeat: Double, durationSeconds: Double,
                              to url: URL,
                              format: DeliveryFormat) async throws -> AudioFileInfo {
        guard format.isDefault else {
            throw ProjectError.invalidOutputFormat(
                "this engine cannot write \(format.label) — only 32-bit float WAV")
        }
        return try await renderMixdown(
            tracks: tracks, tempoMap: tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            fromBeat: fromBeat, durationSeconds: durationSeconds, to: url)
    }
}
