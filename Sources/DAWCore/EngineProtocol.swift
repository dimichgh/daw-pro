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

/// One preset of a hosted Audio Unit exactly as the unit publishes it
/// (au.listPresets / au.loadPreset, m23-cw). `number` is
/// `AUAudioUnitPreset.number`; Apple's contract (AUAudioUnit.h,
/// `saveUserPreset:error:`) is that FACTORY preset numbers are >= 0 and USER
/// preset numbers are < 0. Numbers are per-COMPONENT identity in the same
/// spirit as parameter addresses — take them from a live `au.listPresets`,
/// never guess one, never carry one across components.
public struct HostedAUPresetInfo: Sendable, Equatable, Codable {
    public var number: Int
    public var name: String

    public init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// Which list the AU's CURRENT preset was found in (m23-cw).
///
/// `.unlisted` is not a defect — it is the honest and COMMON answer, and two
/// MEASURED cases produce it on this machine:
///   1. A unit that was never put on a numbered preset reads `-1 / "Untitled"`
///      (every preset-less Apple built-in: AUDelay, AULowpass, …). -1 is a
///      NEGATIVE number, so Apple's "user presets are < 0" rule would call it
///      a user preset — it is not; `userPresets` is empty.
///   2. After a `fullStateForDocument` save/restore round trip, a unit that
///      was on factory preset 8 "Cathedral" comes back reporting
///      `-1 / "Cathedral"`: the parameter values are restored EXACTLY, but the
///      unit no longer claims to be sitting on a numbered preset.
/// So `.unlisted` means "these values came from somewhere the preset lists
/// cannot name", which is exactly what a caller needs to know. We classify by
/// NUMBER against the live lists and never back-match by name — Apple's header
/// is explicit that `currentPreset` "does not reflect whether parameters may
/// have been modified since the preset was selected", so a name match would be
/// a guess dressed as a fact.
public enum HostedAUPresetSource: String, Sendable, Equatable, Codable {
    /// The number appears in the unit's `factoryPresets`.
    case factory
    /// The number appears in the unit's `userPresets`.
    case user
    /// The number is in neither list — see the cases above.
    case unlisted
}

/// The AU's `currentPreset`, plus the classification above (m23-cw). nil ⇔ the
/// unit reports no current preset at all.
public struct HostedAUCurrentPreset: Sendable, Equatable, Codable {
    public var number: Int
    public var name: String
    public var source: HostedAUPresetSource

    public init(number: Int, name: String, source: HostedAUPresetSource) {
        self.number = number
        self.name = name
        self.source = source
    }
}

/// Everything one hosted AU can say about its own presets (m23-cw).
///
/// A unit with NO presets answers with empty arrays and
/// `hasFactoryPresets: false` — SUCCESS, never an error. That mirrors
/// `HostedAUParameterPage.hasParameterTree`: a plugin that publishes nothing
/// is a healthy host, not a failure. MEASURED here: 15 of Apple's 23 built-in
/// `aufx` units return a nil `factoryPresets`, so this is the majority path,
/// not an edge case.
public struct HostedAUPresetList: Sendable, Equatable, Codable {
    /// false ⇔ `factoryPresets` was nil (the unit publishes no factory list at
    /// all), as opposed to publishing an empty one. `factoryPresets` is `[]`
    /// either way — this flag is the only place the distinction survives.
    public var hasFactoryPresets: Bool
    /// `AUAudioUnit.supportsUserPresets`. MEASURED: false for all 23 Apple
    /// built-in effects (the v2 bridge implements no user-preset store), so a
    /// `true` here means a v3 unit with its own store.
    public var supportsUserPresets: Bool
    /// Factory presets in the unit's own published order (numbers >= 0).
    public var factoryPresets: [HostedAUPresetInfo]
    /// User presets in the unit's own published order (numbers < 0).
    public var userPresets: [HostedAUPresetInfo]
    /// What the unit currently reports, classified — nil when it reports none.
    public var currentPreset: HostedAUCurrentPreset?

    public init(hasFactoryPresets: Bool, supportsUserPresets: Bool,
                factoryPresets: [HostedAUPresetInfo],
                userPresets: [HostedAUPresetInfo],
                currentPreset: HostedAUCurrentPreset?) {
        self.hasFactoryPresets = hasFactoryPresets
        self.supportsUserPresets = supportsUserPresets
        self.factoryPresets = factoryPresets
        self.userPresets = userPresets
        self.currentPreset = currentPreset
    }
}

/// How `au.loadPreset` names the preset to load (m23-cw). Exactly one of the
/// two reaches the engine; the wire rejects both-or-neither.
public enum HostedAUPresetSelector: Sendable, Equatable {
    /// By `AUAudioUnitPreset.number` — the canonical, unambiguous form.
    case number(Int)
    /// By display name. AMBIGUITY RULE: an exact, case-SENSITIVE match wins
    /// outright (factory list searched before user list). Only if no exact
    /// match exists is a case-INSENSITIVE pass tried. At either stage, more
    /// than one match refuses with `.ambiguousPresetName` naming the candidate
    /// numbers rather than silently picking one — a plugin is free to ship two
    /// presets called "Default".
    case name(String)
}

/// Engine-side failures of the hosted-AU preset surface (m23-cw), worded as
/// teaching messages the wire surfaces verbatim — the
/// `HostedAUParameterError` precedent. `noHostedAU` normally never reaches the
/// wire: `ProjectStore` maps it to the status-naming error.
public enum HostedAUPresetError: Error, Sendable, Equatable, LocalizedError {
    /// No `.ready` hosted instance for the target.
    case noHostedAU
    /// A LOAD against a unit with no factory and no user presets. (The LIST
    /// side answers such a unit with empty arrays and success.)
    case noPresets
    /// The number names no preset in either live list. Carries the numbers the
    /// unit actually has, so the caller can retry without a second round trip.
    case unknownPresetNumber(Int, available: [Int])
    /// The name matched nothing, exactly or case-insensitively.
    case unknownPresetName(String, available: [String])
    /// The name matched more than one preset — refuse, never guess.
    case ambiguousPresetName(String, numbers: [Int])
    /// A user preset (number < 0) on a unit whose `supportsUserPresets` is
    /// false. Apple: assigning one "may result in incorrect behavior".
    case userPresetsUnsupported(Int)
    /// THE SILENT-NO-OP GUARD. MEASURED on AUMatrixReverb: assigning a
    /// `currentPreset` the unit does not recognise changes NOTHING and raises
    /// NOTHING — `currentPreset` keeps its previous value and every parameter
    /// holds. A host that trusted the setter would report a load that never
    /// happened. So every load re-READS `currentPreset` afterwards and refuses
    /// here when the number did not move. Compared by NUMBER only: MEASURED
    /// that the unit REWRITES the name (assigning number 6 with the name
    /// "JUNK NAME NOT THE REAL ONE" read back as "Medium Chamber"), which is
    /// also why the wire echoes the read-back rather than the request.
    case presetDidNotTake(requested: HostedAUPresetInfo, observed: String)

    /// At most this many numbers/names are listed in a refusal — AUDistortion
    /// ships 22 presets and a wall of them buries the instruction.
    private static let maxListed = 12

    private static func brief(_ items: [String]) -> String {
        guard !items.isEmpty else { return "none" }
        if items.count <= maxListed { return items.joined(separator: ", ") }
        return items.prefix(maxListed).joined(separator: ", ")
            + ", … (\(items.count) total)"
    }

    public var errorDescription: String? {
        switch self {
        case .noHostedAU:
            return "no hosted Audio Unit is ready for that target"
        case .noPresets:
            return "this Audio Unit publishes no presets (no factory presets, no user presets) — set its parameters directly with au.describeParams/au.setParam, or open its own window with plugin.openUI"
        case .unknownPresetNumber(let number, let available):
            return "no preset numbered \(number) on this Audio Unit — it publishes \(Self.brief(available.map(String.init))); call au.listPresets for names"
        case .unknownPresetName(let name, let available):
            return "no preset named '\(name)' on this Audio Unit — it publishes \(Self.brief(available.map { "'\($0)'" })); call au.listPresets for the full list"
        case .ambiguousPresetName(let name, let numbers):
            return "'\(name)' names \(numbers.count) different presets on this Audio Unit (numbers \(numbers.map(String.init).joined(separator: ", "))) — pass presetNumber to choose one"
        case .userPresetsUnsupported(let number):
            return "preset \(number) is a user preset and this Audio Unit reports supportsUserPresets:false — loading it could corrupt the unit's state, so it is refused; its factory presets (number >= 0) still load"
        case .presetDidNotTake(let requested, let observed):
            return "the Audio Unit silently refused preset \(requested.number) '\(requested.name)' — it still reports \(observed), and nothing was changed"
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

/// p2-ren Stage B′ (`docs/design/2026-09-25-incremental-note-render.md` §11
/// step 14): what a clip's node is ACTUALLY PLAYING right now, so an agent
/// can tell a quick stand-in from the exact result before trusting what it
/// hears. Pull-based, like `ClipStretchStatus` — the control snapshot queries
/// this at build time; never persisted.
///
/// - `.exact`: its own committed render, or its source (an identity clip).
/// - `.preview`: Stage B's PROVISIONAL — a spliced quick stand-in for the
///   pending render, notice `clip-render-preview`.
/// - `.previous`: Stage A's BRIDGE — the file the clip played a moment ago,
///   notice `clip-render-previous`.
/// - `.silent`: no node — the render is pending and no previous file
///   qualified (spec §5's honest silence), notice `clip-stretch-pending`.
public enum ClipRenderAudible: String, Sendable, Equatable, Codable {
    case exact
    case preview
    case previous
    case silent
}

/// One schedule-time degradation as the engine reports it (m15-e, audit F6):
/// playback proceeded, but not exactly as the project describes (a fade/
/// envelope bake failed, a stretched or tuned clip is still rendering, …).
/// Posted from CONTROL-side code only — the render thread never produces
/// these. The store coalesces events into its `engineNotices` ring; this
/// event type carries just the facts one occurrence knows.
public struct EngineNoticeEvent: Sendable, Equatable {
    /// Stable machine code (kebab-case) naming the degradation family — the
    /// store's coalescing key.
    ///
    /// Current codes — CENSUSED 2026-09-24 (m23-ap-p2) from every
    /// `EngineNoticeEvent(code:` construction in `Sources/`, not copied from
    /// an earlier list (the list this replaced named 6 of the 10):
    ///  * `clip-stretch-pending` — `PlaybackGraph`'s schedule pass: a clip
    ///    whose stretch OR tuning render is still pending plays as silence.
    ///    Posted only when a pass actually plays it (p2-notice), never at the
    ///    edit that started the render.
    ///  * `clip-fades-skipped`, `clip-envelope-skipped` — `PlaybackGraph`'s
    ///    bake fallbacks, linear and loop-cycle (two sites each).
    ///  * `clip-unplayable` (m16-a) — `PlaybackGraph`'s play-start wiring guard.
    ///  * `clip-file-missing` (m16-c) — `PlaybackGraph`'s build-time open
    ///    catch AND `ProjectStore`'s open/recover echo (one code, two sites).
    ///  * `engine-exception` (m16-a) — `AudioEngine`'s ObjC exception barrier.
    ///  * `instrument-unavailable` — `AudioEngine`: a hosted instrument that
    ///    never produced a playable unit plays silence.
    ///  * `clip-pitch-contour-unavailable` — `AudioEngine`: a tuning plays
    ///    WITHOUT its drift/vibrato flattening (constant-offset fallback).
    ///  * `output-device-unavailable` — `AudioEngine`: the pinned output
    ///    device vanished, sound went to the system default.
    ///  * `ai-generation-interrupted` — posted from DAWApp (not the engine)
    ///    through the same `engineNoticeHandler` funnel, when the generation
    ///    sidecar dies mid-job.
    /// `debug.postEngineNotice` (debug tier, off the wire list) can post any
    /// code through the same funnel for UI captures.
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

/// What the MIDI take currently being captured has accumulated SO FAR
/// (m34-a-2) — the live half of `MIDIRecordingResult`, read from the main
/// actor while the take is still rolling.
///
/// ⭐ **WHY THIS CROSSES THE ENGINE SEAM AT ALL, AND WHY THAT COSTS NOTHING
/// REAL-TIME.** Until this existed the take was completely invisible until it
/// stopped: `MIDICaptureSession.finish(atBeat:)` is what builds the clip, and
/// its `lengthBeats` is `max(1, ceil(stopBeat − anchorBeats))` — a value that
/// does not exist until the stop beat is known. So the timeline stayed blank
/// while the user played, which is what they reported. The session is already
/// `@MainActor` and already holds every one of these numbers privately; this
/// type carries them out. **No ring producer is added, and nothing here is
/// reachable from the render thread** — the same reasoning that made m23-ct's
/// Route C safe. If a future change finds itself adding a producer to the
/// capture ring to feed this, the design has gone wrong.
///
/// ⚠️ **BEATS ARE ABSOLUTE AND LINEAR**, in the take's own frozen-map domain —
/// the same domain `MIDICaptureSession` pairs notes in, NOT the modular
/// `transport.positionBeats` a loop take reports. `TakeRegionPreview` is where
/// the two are reconciled (and where loop takes are refused for v1).
public struct LiveTakeExtent: Sendable, Equatable {
    /// The take's clock origin — `MIDICaptureSession`'s `anchorBeats`. For an
    /// ordinary take this is the beat playback started from; for an m34-h
    /// layer it is the beat the layer joined at. Count-in delays the HOST
    /// anchor, never this one, so it is stable from the instant the take opens.
    public var anchorBeat: Double
    /// The newest ACCEPTED note edge, absolute beats — nil until the first
    /// post-anchor note-on lands. ⚠️ Pre-anchor (count-in) note-ons are DROPPED
    /// by the session and must never move this: a take that has captured
    /// nothing has no extent, and pretending otherwise would draw a region for
    /// a clip that is never going to exist.
    public var latestEventBeat: Double?
    /// How many notes would land if the take stopped now — closed notes plus
    /// still-open ones (open notes clamp to the stop beat, so they land too).
    ///
    /// ⭐ **THIS IS THE FIELD THAT DECIDES WHETHER ANYTHING IS DRAWN**, and it
    /// counts NOTES rather than events on purpose: `ProjectStore.finishTake`
    /// discards a take whose `notes` are empty ("empty take discarded — no MIDI
    /// notes received"), and it does that even when controller lanes captured
    /// plenty. Counting events would promise a clip that the store then throws
    /// away — a ghost region.
    public var noteCount: Int

    public init(anchorBeat: Double, latestEventBeat: Double?, noteCount: Int) {
        self.anchorBeat = anchorBeat
        self.latestEventBeat = latestEventBeat
        self.noteCount = noteCount
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

/// WHAT a clip-span audition plays (I1-F1, "hear the note WHILE editing it").
///
/// `.playbackFile` is I1's: the file playback plays for the clip now. The two
/// span renders are I1-F1's: the clip's SOURCE is rendered through the ONE
/// render loop playback's render uses (same curve, level mask, stretcher
/// configuration, ratio and transpose), for the span only plus a short
/// pre-roll, off the render thread, so an edit is heard without waiting for
/// the whole recording to re-render.
public enum ClipSpanAuditionSource: Sendable, Equatable {
    /// The file playback plays for the clip NOW: its committed render, or its
    /// source when it does not render. A render still in flight answers
    /// `.inaudibleNotReady` and plays nothing.
    case playbackFile
    /// A span render of the clip's STORED edits: what the clip will sound
    /// like once its whole-file render lands, without waiting for it.
    case storedSpanRender
    /// A span render with `draft` in place of the clip's stored edits (a drag
    /// still in flight). Nothing is committed; the clip's own ratio,
    /// transpose and formant setting still apply.
    case draftSpanRender(PitchEditSet)
}

/// How one ACCEPTED clip-span audition ended (I1-F1; RT review H1).
///
/// `auditionClipSpan` answers synchronously, BEFORE anything is read or
/// rendered, so its `.sounded` means "accepted: being prepared, and will play
/// when ready". This is the real result, reported exactly once, on the main
/// actor, for every call that answered `.sounded`, and never for any other.
public enum ClipSpanAuditionDelivery: Sendable, Equatable {
    /// The buffer is scheduled on the voice and sounds for `seconds`.
    case played(seconds: Double)
    /// Nothing plays: the audio could not be read or rendered, or the voice
    /// could not start. `reason` is written for a person. The engine has also
    /// written one stderr line and posted a `clip-audition-failed` notice.
    case failed(reason: String)
    /// A newer request, a stop, a transport start or a graph rebuild replaced
    /// it before it played. Its work was cancelled, not only its result.
    case dropped
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

    /// p2-ren Stage B′: what this clip's node is ACTUALLY PLAYING right now
    /// (`ClipRenderAudible`) — `.exact`, Stage B's `.preview` (a provisional
    /// splice), Stage A's `.previous` (a bridge), or `.silent` (no node).
    /// trackID is accepted for surface stability; the graph keys nodes per
    /// clip. Pull-based like `clipStretchStatus`: the control snapshot
    /// queries this at build time and emits the transient `renderAudible`
    /// field. nil for engines without bridge/preview support (the snapshot
    /// then omits the field, exactly like `clipStretchStatus`).
    func renderAudible(trackID: UUID, clipID: UUID) -> ClipRenderAudible?

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

    /// ⭐ THE contour the offline pitch render uses for a clip whose SOURCE
    /// FILE is `url` (contour-to-render, 2026-09-24): the whole file from
    /// source second 0 at the product's detection settings, cached beside the
    /// renders — the exact input the render shapes Hard Tune / drift / vibrato
    /// edits against. `analysisVersion` is the clip's
    /// `PitchEditSet.analysisVersion` (`PitchEditSet.currentAnalysisVersion`
    /// for a clip with no edits); a mismatch answers `.analysisVersionMismatch`
    /// and detects nothing. Build curves from the result with
    /// `PitchRenderContour.curve(editSet:clipPitchShiftSemitones:)` — the one
    /// the render uses. Offline, detached; never the render thread. Unlike
    /// `detectPitch`, cached: it is the render's own input, not a diagnostic.
    func renderPitchContour(inFileAt url: URL, analysisVersion: Int) async -> PitchRenderContour

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

    /// MASTER modulation changed (m39-e) — the `masterAutomationChanged` twin.
    /// Push the strip to the graph and run one parameter pass, which is where
    /// the modulation snapshot is rebuilt and published. Pushed on every master
    /// modulation mutation AND every undo/redo/project-boundary restore.
    func masterModulationChanged(sources: [ModulationSource], routes: [ModulationRoute])

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

    /// `renderOffline` carrying the MASTER strip's modulation (m39-e-2) — the
    /// sources and routes `masterModulationChanged` hands the live graph. The
    /// offline graph is a separate graph, so without this parameter pair no
    /// render could carry master modulation: an LFO or macro on the master
    /// fader moved live and was missing from every export.
    ///
    /// The render class is `masterAutomation`'s, verbatim, again with NO
    /// default: MASTERED renders (mixdown, bounce, measureLoudness, the stems'
    /// mastered sibling) pass the project's master sources and routes; STEM
    /// renders (stems, their "00 Mixdown" reference, bounce-in-place) pass `[]`
    /// for both — a master tremolo baked into a stem or a bounced clip would
    /// apply twice on playback (S-3′). The requirement above renders with no
    /// master modulation; it stays for the renders that can never have any
    /// (synthetic dry renders: AI-fix regions, voice-conversion sources,
    /// timbre probes) and for every conformer written before m39-e-2.
    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource],
                       masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio

    /// The format-aware `renderMixdown` carrying the master strip's modulation
    /// (m39-e-2), same rule and same reason as the `renderOffline` twin above.
    /// `render.mixdown` needs its own seam because here the ENGINE renders and
    /// writes (the m23-m2 lesson).
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource],
                       masterModulationRoutes: [ModulationRoute],
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

    /// Everything a hosted Audio Unit says about its own presets
    /// (au.listPresets, m23-cw): factory list, user list, user-preset support,
    /// and the classified `currentPreset`. nil ⇒ no `.ready` instance for the
    /// target (the store maps that to the status-naming teaching error); a
    /// healthy AU with NO presets is SUCCESS — empty arrays and
    /// `hasFactoryPresets: false`, the `hasParameterTree: false` precedent.
    /// Control-plane only — the render thread is never involved.
    func listHostedAUPresets(_ target: HostedAUTarget) throws -> HostedAUPresetList?

    /// Load one of the AU's OWN presets, live (au.loadPreset, m23-cw).
    ///
    /// Deliberately mutates ONLY the live `AUAudioUnit` held by the engine's
    /// registry — it never writes `stateData` into the model. m23-bx-1's root
    /// cause (eight cycles) was exactly that split: a hosted plug-in's live
    /// state lives in `AUHostRegistry`, and a model write would both go stale
    /// and change the registry's prepare identity, forcing a re-instantiate
    /// that discards the preset it was trying to save. Save/render/bounce pick
    /// the new state up through `ProjectStore.tracksWithLiveAudioUnitState()`'s
    /// existing `fullStateForDocument` capture — MEASURED to change after a
    /// load, so this composes rather than bypasses.
    ///
    /// Returns the preset ACTUALLY in effect afterwards (a re-read, not the
    /// request). Throws `HostedAUPresetError` for every refusal — including
    /// `.presetDidNotTake` when the unit accepted the assignment and did
    /// nothing, which is MEASURED behaviour, not a theoretical guard.
    @discardableResult
    func loadHostedAUPreset(_ target: HostedAUTarget,
                            selector: HostedAUPresetSelector) throws
        -> HostedAUCurrentPreset

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

    /// LIVE LOOPING (m34-h phase 1) — close the rolling take and deliver its
    /// result while the transport KEEPS PLAYING. The sibling of
    /// `stopRecording()`, not a replacement: identical capture teardown,
    /// identical linear stop-beat, identical open-note clamp, identical
    /// writer finalize — the ONE difference is that playback is not torn
    /// down, so the graph, the playhead and the render callbacks continue.
    ///
    /// Returns `true` when a take was actually closed this way. `false` means
    /// NOTHING WAS CLOSED — either no take was rolling, or this engine has no
    /// such capability (the default below). ⚠️ The Bool is load-bearing and
    /// must never be ignored: a caller that assumed success would leave
    /// `transport.isRecording` false over a still-rolling take, and the take
    /// would land later against a cleared pending record — i.e. silently lost
    /// work. `ProjectStore.finishLayer()` throws on `false` for that reason.
    func finishTakeKeepingPlayback() -> Bool

    /// The take currently being captured, as far as it has got (m34-a-2) — nil
    /// when no MIDI take is rolling. Read from the main actor at the transport
    /// tick's cadence (~30 Hz) so the arrange can draw a PROVISIONAL region
    /// that grows while the user plays; the real clip replaces it at `finish`.
    ///
    /// ⚠️ **OPTIONAL CAPABILITY WITH THE FAMILIAR VACUITY RISK** (the
    /// `previewController` / `setLivePlayPitches` hazard, stated at both): an
    /// engine that forgot to override this returns nil forever, every model
    /// and control test still passes because every caller handles "no extent"
    /// honestly, and the symptom in the product is a blank timeline during a
    /// take — i.e. exactly the defect this exists to fix, silently restored.
    /// `Tests/DAWEngineTests/LiveTakeExtentTests.swift` holds the REAL engine
    /// to it.
    func liveTakeExtent() -> LiveTakeExtent?

    /// LIVE LOOPING (m34-h phase 1) — start a take that JOINS playback already
    /// in progress, so layer N+1 can be recorded without ever stopping.
    ///
    /// Unlike `startTake`, this must NOT reschedule anything: the already
    /// sounding layers keep their existing schedule and their existing anchor,
    /// and the new capture is aligned onto that SAME running anchor. Capture
    /// begins at `transport.positionBeats` — translated onto the host clock
    /// through the running anchor exactly as a punch-in point is — so a caller
    /// whose playhead read is a display-stale tick behind still gets an honest
    /// `startOffsetSeconds` and lands its clip where capture really began.
    ///
    /// Refuses (throws) when the transport is NOT already playing, when a take
    /// is already rolling, when a count-in is requested (a count-in delays the
    /// anchor, and this take shares the running anchor), and — v1 — when a
    /// LOOP is active: a mid-cycle layer inside a loop region is overdub
    /// semantics, which this app does not model yet (the m15-b loop × punch
    /// refusal is the precedent).
    func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                             completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws

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

    /// LIVE EXPRESSION (m34-f step ②): sends ONE controller value to `trackID`'s
    /// instrument right now AND, when `captureIntoTake` is true and a take is
    /// rolling, puts that value into the take's controller lane.
    ///
    /// ⭐⭐ **THE SEAM THE PAD WAS MISSING, AND IT IS THE WHOLE ITEM.**
    /// `previewController` above is *"a preview, never the record"* — correct
    /// for auditioning a shape, and a silent lie for a performance. Something
    /// the user shapes by hand during an armed take must be IN that take, or it
    /// sounds right while played and vanishes from the bounce. `MIDICapture-
    /// Session` has ingested `controlChange` since m16-b3; nothing on the pad's
    /// side ever handed it one.
    ///
    /// ⭐⭐ **NET: ZERO RINGS GAIN A PRODUCER — the m23-ct Route C argument,
    /// unchanged.** ONE main-actor value fans to BOTH pipes at their MAIN-ACTOR
    /// ends: the audible half rides the existing per-renderer audition ring
    /// (`previewController`, untouched), and the capture half is a direct
    /// main-actor call into the take's `MIDICaptureSession`, bypassing the
    /// capture ring entirely. The CoreMIDI receive thread stays the sole
    /// producer of every thru/capture ring; the main actor stays the sole
    /// producer of every audition ring.
    ///
    /// ⚠️ **`captureIntoTake` IS A DOMAIN VERDICT, NOT AN ENGINE ONE.** Only
    /// `ProjectStore` knows arm state, so it computes
    /// `isRecording && isArmed && kind == .instrument` and hands the answer
    /// down. The engine narrows it (is a take actually capturing MIDI, does a
    /// session exist) but never widens it.
    ///
    /// Never throws; the outcome reports what was heard, how many points went
    /// into the take, and whether a take received them at all.
    @discardableResult
    func setLiveExpression(trackID: UUID, controller: UInt8, value: UInt8,
                           captureIntoTake: Bool) -> LiveExpressionOutcome

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

    /// CLIP-NOTE AUDITION (I1, design `2026-09-24-pitch-editor-interaction-batch`
    /// §4, decision (c) "hybrid, with no live DSP"): plays the SOURCE-second span
    /// `[startSourceSeconds, endSourceSeconds)` of ONE audio clip, once, right
    /// now, AS IT SOUNDS NOW. Never through a live pitch shifter.
    ///
    /// ⭐ **THE FILE IS THE ONE PLAYBACK PLAYS.** A clip that renders through the
    /// stretch cache (a tuning, a stretch, a transpose) is resolved through the
    /// SAME resolver the playback graph uses, never a second key derivation, so
    /// the audition and the next transport pass read the same bytes. A render
    /// still in flight answers `.inaudibleNotReady` and plays nothing, exactly
    /// as playback plays that clip as silence until the render lands. A clip
    /// that does not render plays its source file. Seconds map to the file's
    /// frames through the render's own output↔source mapping.
    ///
    /// **Level:** the clip's gain × the track's fader, then the master fader
    /// and the master insert chain (the voice joins the main mix). A muted
    /// track, or one an active solo leaves out, answers `.inaudibleMuted` and
    /// plays nothing. Unknown ids, a MIDI clip or an empty span answer
    /// `.noRenderer`.
    ///
    /// ⚠️ **NAMED COST: THE VOICE SKIPS THE TRACK'S OWN INSERTS**, and with them
    /// the track's pan, sends, bus routing and volume automation. It is the
    /// clip's audio at the fader's level, not the strip's output: an EQ, a
    /// compressor or a reverb on the vocal track is NOT heard in the audition.
    /// The clip's own fade-in/out and gain envelope are not applied either, so
    /// a note inside a clip fade plays at the clip's flat gain.
    ///
    /// One audition at a time: a new call replaces a sounding one. It stops by
    /// itself at the span's end, and on a transport start, a graph rebuild and
    /// `stopAllAudition()`. WHEN to call it (press, after a commit's render,
    /// never while the transport runs) is the caller's policy:
    /// `ClipNoteAuditionController`.
    ///
    /// `.sounded` means ACCEPTED: the span is being read and will start within
    /// a few milliseconds. It is answered before the read runs, so it cannot
    /// promise the read succeeds; a failure writes one stderr line and posts a
    /// `clip-audition-failed` engine notice (RT review H1), and the form with a
    /// `completion` below reports the real result. Real-time safety: the voice
    /// is a stock player node the graph attached when it was built; the span is
    /// read, faded and converted off the render thread and only scheduled from
    /// the main actor. Same as the form below with `.playbackFile` and no
    /// completion.
    @discardableResult
    func auditionClipSpan(trackID: UUID, clipID: UUID,
                          startSourceSeconds: Double, endSourceSeconds: Double) -> AuditionOutcome

    /// I1-F1: `auditionClipSpan` with a choice of WHAT plays and a report of
    /// how it ENDED.
    ///
    /// * `source`: the playback file (I1), or a span render of the stored or
    ///   a draft edit set through the one render loop
    ///   (`ClipSpanAuditionSource`). A span render never waits for the
    ///   whole-file render and never touches it.
    /// * `completion`: called exactly once, on the main actor, for every call
    ///   that answered `.sounded`, and never otherwise
    ///   (`ClipSpanAuditionDelivery`). Never called re-entrantly from inside
    ///   this call.
    ///
    /// LATEST WINS. A call cancels whatever is still being read or rendered
    /// (its completion reports `.dropped`), so a buffer that was superseded
    /// NEVER plays. A sounding audition keeps sounding until the new one's
    /// buffer is ready and then gives way to it, so a drag heard step by step
    /// has no gap between steps; a REFUSED call silences it at once.
    ///
    /// Refuses (`.noRenderer`) while the transport plays or records: the
    /// caller's policy refuses first, and this is the engine's own guard (RT
    /// review H6). The rest of the contract is the four-argument form's.
    @discardableResult
    func auditionClipSpan(trackID: UUID, clipID: UUID,
                          startSourceSeconds: Double, endSourceSeconds: Double,
                          source: ClipSpanAuditionSource,
                          completion: (@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?)
        -> AuditionOutcome

    /// Stops a sounding clip-note audition and discards one still being read
    /// or rendered (its work is cancelled). Idempotent.
    func stopClipSpanAudition()

    /// Sink invoked on the main actor each time one clip's stretch/tuning render
    /// COMMITS to the cache, with that clip's id (I1). This is the render cache's
    /// own completion signal, so a caller waiting for "that clip's render" hears
    /// about it the moment the file exists, not at the next status poll. A
    /// superseded or failed render reports nothing. A function rather than a
    /// `var` for the `setEndStopHandler` reason: a protocol property requirement
    /// cannot carry a default.
    func setClipRenderCompleteHandler(_ handler: ((UUID) -> Void)?)

    /// I1-F2 (RT re-review, the span cap): how many SOURCE seconds of a clip
    /// that plays at stretch `ratio` an audition covers so that what is HEARD
    /// lasts `heardSeconds`, through the engine's one output↔source mapping.
    /// `ClipNoteAuditionPolicy.maxSpanSeconds` caps what is heard; it used to
    /// count source seconds, so at ratio 4 an audition played 24 s. The store
    /// asks here before it resolves a span, and the engine's own plan asks the
    /// same function, so the span the store reports is the span that plays.
    /// Exact at ratio 1: `heardSeconds` itself.
    ///
    /// `nil` when this engine has no such mapping (fakes, headless): the
    /// caller then counts source seconds, the behaviour before I1-F2. DAWCore
    /// never does this arithmetic itself: the model owns source seconds, and
    /// the output↔source mapping lives in the engine (`StretchCurvePlan`).
    func clipAuditionSourceSeconds(heardSeconds: Double, ratio: Double) -> Double?

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

    /// Live expression is optional capability (m34-f step ②).
    ///
    /// ⭐⭐ **THE DEFAULT FORWARDS TO `previewController` RATHER THAN RETURNING
    /// `.unsupported`, AND THAT CHOICE IS DELIBERATE.** Every existing fake and
    /// headless engine in this tree implements the preview and is asserted
    /// against its push count; a default that answered `.unsupported` would
    /// silence the pad for all of them the moment `PadPreviewController` was
    /// pointed at this method. Forwarding keeps the AUDIBLE half exactly as it
    /// was for every conformer, and leaves the CAPTURE half — the genuinely new
    /// capability — as the only thing an engine has to opt into.
    ///
    /// ⚠️⚠️ **THAT MAKES THE VACUITY RISK SHARPER, NOT SOFTER, SO IT IS NAMED
    /// HERE: a real engine that forgot to override this would sound perfect and
    /// record nothing, forever, and every model-layer test would still pass.**
    /// That is precisely the defect this item exists to prevent, so it must be
    /// closed by a test that drives the REAL engine:
    /// `Tests/DAWEngineTests/LiveExpressionCaptureTests.swift` rolls a take and
    /// counts the controller points that reach `midiCaptureSessionForTesting`
    /// — the `LivePlayCaptureTests` precedent applied to a method whose default
    /// is a silently unrecorded performance.
    @discardableResult
    public func setLiveExpression(trackID: UUID, controller: UInt8, value: UInt8,
                                  captureIntoTake: Bool) -> LiveExpressionOutcome {
        LiveExpressionOutcome(
            audition: previewController(trackID: trackID, controller: controller, value: value),
            capturedPoints: 0, recording: false)
    }

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

    /// Closing a take without stopping playback is optional capability (m34-h,
    /// the `setLivePlayPitches` precedent): fakes and headless engines own no
    /// capture writer and no MIDI session, so the default closes NOTHING and
    /// says so.
    ///
    /// ⚠️ **THE VACUITY RISK HERE IS THE WORST OF THE FAMILY, because the
    /// default is not silence — it is a LOST TAKE.** An `AudioEngine` that
    /// forgot to override this would report `false` forever; if the store
    /// treated `false` as success it would clear `isRecording` and the pending
    /// take while the engine kept capturing, and the performance would land
    /// nowhere. Two things close that hole: the store THROWS on `false`
    /// (`ProjectStore.finishLayer()`), and
    /// `Tests/DAWEngineTests/LiveLayerCaptureTests.swift` asserts the REAL
    /// engine returns `true` for a rolling take AND leaves playback running —
    /// the `OutputDeviceTests` / `previewController` precedent applied to a
    /// method whose default silently discards a recording.
    public func finishTakeKeepingPlayback() -> Bool { false }

    /// Joining running playback with a new take is optional capability (m34-h,
    /// same precedent). The default THROWS rather than returning quietly: a
    /// silent no-op would leave the caller believing layer 2 was rolling while
    /// nothing captured, which is the same lost-performance failure
    /// `finishTakeKeepingPlayback`'s Bool exists to prevent.
    public func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                                    completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        throw ProjectError.transportBusy(
            "this engine cannot start a take while playback is running — stop first, then record"
        )
    }

    /// The audition all-stop is optional capability (m23-d): an engine with no
    /// audition support holds no voices, so the default is a no-op.
    public func stopAllAudition() {}

    /// Clip-note audition is optional capability (I1, the `setAuditionPitches`
    /// precedent): fakes and headless engines have no audition voice, so the
    /// default reports `.unsupported` and every existing conformer compiles
    /// unchanged.
    ///
    /// ⚠️ THE `previewController` VACUITY RISK: an `AudioEngine` that forgot to
    /// override this would answer `.unsupported` forever and the editor would
    /// be silent while every policy test passed. `AuditionEngineTests`'
    /// `clipSpanRealEngineOverridesTheDefault` closes it against the REAL
    /// engine, without starting any device.
    @discardableResult
    public func auditionClipSpan(trackID: UUID, clipID: UUID,
                                 startSourceSeconds: Double,
                                 endSourceSeconds: Double) -> AuditionOutcome { .unsupported }

    /// An engine with no span render (fakes, headless) answers `.unsupported`
    /// for every source and never calls `completion`, which is the contract:
    /// completion follows `.sounded` only. `ClipNoteAuditionController` reads
    /// `.unsupported` as "no span render here" and keeps I1's behaviour (the
    /// release waits for the whole-file render). ⚠️ The same vacuity risk as
    /// the four-argument form: `AuditionEngineTests`' `clipSpanRender…` tests
    /// call this through the PROTOCOL on the real engine.
    @discardableResult
    public func auditionClipSpan(trackID: UUID, clipID: UUID,
                                 startSourceSeconds: Double, endSourceSeconds: Double,
                                 source: ClipSpanAuditionSource,
                                 completion: (@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?)
        -> AuditionOutcome { .unsupported }

    /// An engine with no clip-note audition has nothing to stop.
    public func stopClipSpanAudition() {}

    /// An engine that renders nothing never completes a render, so the default
    /// discards the sink (the `setEndStopHandler` precedent).
    public func setClipRenderCompleteHandler(_ handler: ((UUID) -> Void)?) {}

    /// An engine without the output↔source mapping cannot answer; the caller
    /// counts source seconds (I1-F2). ⚠️ The `previewController` vacuity risk
    /// again: an `AudioEngine` that forgot to override this would keep the
    /// old source-second cap silently. `AuditionEngineTests`'
    /// `clipSpanCapBoundsWhatIsHeard` asks the REAL engine through the
    /// protocol.
    public func clipAuditionSourceSeconds(heardSeconds: Double, ratio: Double) -> Double? { nil }

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

    /// Master modulation is optional capability (m39-e, the
    /// `masterAutomationChanged` precedent): fakes and headless engines have no
    /// master strip to modulate, so the default is a no-op and existing
    /// conformers compile unchanged.
    public func masterModulationChanged(sources: [ModulationSource],
                                        routes: [ModulationRoute]) {}

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

    /// p2-ren Stage B′: bridge/preview reporting is optional capability —
    /// engines without it (fakes, headless) report nothing, so the snapshot
    /// omits `renderAudible` exactly as it omits `stretchRendering`.
    public func renderAudible(trackID: UUID, clipID: UUID) -> ClipRenderAudible? { nil }

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

    /// The render contour is optional capability (contour-to-render) — and,
    /// like `detectPitch`, a fabricated contour would be a lie, so an engine
    /// without it answers `.unavailable`: no frames, which every reader
    /// (render and display alike) treats as "nothing to shape against".
    public func renderPitchContour(inFileAt url: URL,
                                   analysisVersion: Int) async -> PitchRenderContour {
        .unavailable(reason: "this engine cannot analyse pitch")
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

    /// The hosted-AU PRESET surface is optional capability too (m23-cw): an
    /// engine without AU hosting reports no hosted instance, so every existing
    /// conformer — the app's real engine aside — compiles unchanged.
    public func listHostedAUPresets(_ target: HostedAUTarget) throws
        -> HostedAUPresetList? { nil }
    @discardableResult
    public func loadHostedAUPreset(_ target: HostedAUTarget,
                                   selector: HostedAUPresetSelector) throws
        -> HostedAUCurrentPreset {
        throw HostedAUPresetError.noHostedAU
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

    /// Live take extent is optional capability (m34-a-2): fakes and headless
    /// engines run no `MIDICaptureSession`, so they have no take to describe
    /// and every conformer compiles unchanged. See the requirement's ⚠️ for
    /// why this default is dangerous and which suite holds the real engine to
    /// it.
    public func liveTakeExtent() -> LiveTakeExtent? { nil }

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

    /// Master-modulation rendering is optional capability (m39-e-2), and this
    /// default REFUSES rather than drops, the m23-m2 format precedent for the
    /// same reason: the defect m39-e-2 closes IS master modulation silently
    /// missing from a render, and a discarding default would recreate it in
    /// every engine that implements only the requirement without it. When
    /// nothing could change the render (no ENABLED route: an unrouted source or
    /// a disabled route is inert, the m39-e law) it forwards unchanged, so every
    /// existing conformer, and every project without master modulation,
    /// renders exactly as before.
    public func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              masterModulationSources: [ModulationSource],
                              masterModulationRoutes: [ModulationRoute],
                              fromBeat: Double, durationSeconds: Double,
                              forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        guard !masterModulationRoutes.contains(where: { $0.enabled }) else {
            throw ProjectError.engineUnavailable
        }
        return try await renderOffline(
            tracks: tracks, tempoMap: tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            fromBeat: fromBeat, durationSeconds: durationSeconds,
            forcedCompensationTargets: forcedCompensationTargets)
    }

    /// The format-aware mixdown twin (m39-e-2): same refusal, and it forwards
    /// to the FORMAT-aware requirement, so an engine that plumbs the format but
    /// not master modulation still writes the format it was asked for.
    public func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              masterModulationSources: [ModulationSource],
                              masterModulationRoutes: [ModulationRoute],
                              fromBeat: Double, durationSeconds: Double,
                              to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        guard !masterModulationRoutes.contains(where: { $0.enabled }) else {
            throw ProjectError.engineUnavailable
        }
        return try await renderMixdown(
            tracks: tracks, tempoMap: tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            fromBeat: fromBeat, durationSeconds: durationSeconds,
            to: url, format: format)
    }
}
