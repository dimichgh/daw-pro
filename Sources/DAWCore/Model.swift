import Foundation

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case audio
    case instrument
    case bus
}

/// Read-only facts about a source audio file, extracted at import time by a
/// `MediaImporting` service. DAWCore never opens files itself — it only holds
/// the resulting numbers so import math (beats from seconds) stays testable.
public struct AudioFileInfo: Codable, Sendable, Equatable {
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channelCount: Int

    public init(durationSeconds: Double, sampleRate: Double, channelCount: Int) {
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// One hardware audio input device as the engine enumerates it — CoreAudio
/// facts mirrored into the domain so DAWCore stays engine-free. `uid` is the
/// stable CoreAudio device UID used to pin capture; `isDefault` flags the
/// current system default input.
public struct AudioInputDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var channelCount: Int
    public var isDefault: Bool

    public init(uid: String, name: String, sampleRate: Double,
                channelCount: Int, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isDefault = isDefault
    }
}

/// One MIDI input source as the engine enumerates it — CoreMIDI facts
/// mirrored into the domain so DAWCore stays engine-free. `uniqueID` is the
/// endpoint's persistent `kMIDIPropertyUniqueID` (the stable key; names are
/// display-only, never keys).
public struct MIDIInputDevice: Codable, Sendable, Equatable, Identifiable {
    public var uniqueID: Int32
    public var name: String
    public var isVirtual: Bool
    public var isOnline: Bool
    public var id: Int32 { uniqueID }

    public init(uniqueID: Int32, name: String, isVirtual: Bool, isOnline: Bool) {
        self.uniqueID = uniqueID
        self.name = name
        self.isVirtual = isVirtual
        self.isOnline = isOnline
    }
}

/// Microphone permission as the domain layer sees it — mirrors the engine's
/// AVAudioApplication state without leaking AVFoundation types upward.
public enum RecordPermission: String, Codable, Sendable {
    case undetermined
    case granted
    case denied
}

/// Outcome of one finished recording take, reported by the engine after the
/// capture file is finalized.
public struct RecordingResult: Sendable, Equatable {
    /// Where the take's WAV landed on disk.
    public var fileURL: URL
    /// Facts about the written file (duration, rate, channels).
    public var info: AudioFileInfo
    /// Seconds between the requested record start anchor and the first
    /// captured frame, always >= 0. Anchor-relative BY CONTRACT: for punched
    /// takes this includes the record-start → punch-in gap (it is NOT
    /// measured from the punch window), which is what lets ProjectStore's
    /// placement formula `recordStart + offset × tempo/60` land the clip at
    /// the punch-in point. Round-trip (input + output) latency is NOT
    /// compensated here — plugin/hardware delay compensation lands in M4.
    public var startOffsetSeconds: Double

    public init(fileURL: URL, info: AudioFileInfo, startOffsetSeconds: Double) {
        self.fileURL = fileURL
        self.info = info
        self.startOffsetSeconds = startOffsetSeconds
    }
}

/// One note inside a MIDI clip. Times are in beats RELATIVE to the clip start,
/// so a note moves with its clip. All fields clamp through `init` (the only way
/// to build one, and the path Codable routes through), so out-of-range pitches,
/// velocities, or negative times can never enter the model. The scheduler
/// contract: notes are stored canonically ordered (`canonicallyOrdered`), a
/// zero-length note is impossible (`minLengthBeats` floor), and overlapping
/// notes on the same pitch are legal (the M3 scheduler resolves them).
public struct MIDINote: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// MIDI note number, 0...127 (60 = middle C).
    public var pitch: Int
    /// Note-on velocity, 1...127 (0 would be a note-off — never stored).
    public var velocity: Int
    /// Onset in beats, relative to the clip start (>= 0).
    public var startBeat: Double
    /// Duration in beats (>= `minLengthBeats`).
    public var lengthBeats: Double

    public static let pitchRange: ClosedRange<Int> = 0...127
    public static let velocityRange: ClosedRange<Int> = 1...127
    /// A note can never be shorter than this — guards against a zero-length note
    /// the scheduler could never sound.
    public static let minLengthBeats: Double = 0.001

    public init(
        id: UUID = UUID(),
        pitch: Int,
        velocity: Int = 100,
        startBeat: Double,
        lengthBeats: Double = 1.0
    ) {
        self.id = id
        self.pitch = pitch.clamped(to: Self.pitchRange)
        self.velocity = velocity.clamped(to: Self.velocityRange)
        self.startBeat = max(0, startBeat)
        self.lengthBeats = max(Self.minLengthBeats, lengthBeats)
    }

    /// End of the note in beats, relative to the clip start.
    public var endBeat: Double { startBeat + lengthBeats }

    /// Canonical scheduler order: by onset, then pitch, then id — stable
    /// regardless of the order notes were edited in.
    public static func canonicallyOrdered(_ notes: [MIDINote]) -> [MIDINote] {
        notes.sorted {
            if $0.startBeat != $1.startBeat { return $0.startBeat < $1.startBeat }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, pitch, velocity, startBeat, lengthBeats
    }

    /// `id`, `velocity`, and `lengthBeats` tolerate absence (defaults); `pitch`
    /// and `startBeat` are required. Everything routes through the clamping
    /// `init`, so a hand-authored or older payload can never smuggle in an
    /// out-of-range value.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let pitch = try c.decode(Int.self, forKey: .pitch)
        let velocity = try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100
        let startBeat = try c.decode(Double.self, forKey: .startBeat)
        let lengthBeats = try c.decodeIfPresent(Double.self, forKey: .lengthBeats) ?? 1.0
        self.init(id: id, pitch: pitch, velocity: velocity,
                  startBeat: startBeat, lengthBeats: lengthBeats)
    }

    /// Writes all five keys explicitly (the full note shape on the wire and on
    /// disk), never relying on synthesized `encodeIfPresent` omission.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(startBeat, forKey: .startBeat)
        try c.encode(lengthBeats, forKey: .lengthBeats)
    }
}

/// Interpolation shape of a clip fade (M5 i-a). `linear` ramps straight;
/// `equalPower` is a quarter sine/cosine so two adjacent, opposite fades sum to
/// unit power (the constant-power crossfade). Persisted as its raw string;
/// omitted from Codable at the `.linear` default, and new shapes are additive
/// cases (the `AutomationCurve` precedent).
public enum FadeCurve: String, Codable, Sendable, Equatable, CaseIterable {
    case linear
    case equalPower
}

/// One breakpoint in a clip's gain envelope (m13-e): a CLIP-RELATIVE time in
/// beats and a gain in dB. `beat` clamps to `>= 0` and `gainDb` to
/// `Clip.gainDbRange` at init — the ONLY construction path, and where Codable
/// routes (the `AutomationPoint` / `MIDINote` pattern), so an out-of-range
/// value can never enter the model. The store additionally clamps `beat` into
/// `[0, lengthBeats]` and enforces the sorted/distinct invariant
/// (`Clip.canonicalGainEnvelope`); the envelope interpolates LINEARLY IN dB
/// between adjacent points (see `Clip.envelopeDb`).
public struct ClipGainPoint: Codable, Sendable, Equatable {
    /// Clip-relative position in beats (>= 0).
    public var beat: Double
    /// Gain at this point in dB (clamped to `Clip.gainDbRange`; 0 = unity).
    public var gainDb: Double

    public init(beat: Double, gainDb: Double) {
        self.beat = max(0, beat)
        self.gainDb = gainDb.clamped(to: Clip.gainDbRange)
    }

    private enum CodingKeys: String, CodingKey { case beat, gainDb }

    /// Decoding routes through the clamping init (the `AutomationPoint`
    /// precedent), so a hand-authored payload can't smuggle a negative beat or
    /// an out-of-range gain into the model.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            beat: try c.decode(Double.self, forKey: .beat),
            gainDb: try c.decode(Double.self, forKey: .gainDb))
    }

    /// Writes both keys explicitly (the full point shape on wire and disk).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(beat, forKey: .beat)
        try c.encode(gainDb, forKey: .gainDb)
    }
}

/// Which controller stream a lane carries (m16-b). Flat Codable `{type,
/// controller?}` — the `AutomationTarget` discriminator precedent
/// (`Automation.swift:18-70`): a String raw discriminator so an unknown `type`
/// on decode is a HARD error (not a silent misread), and `controller` rides
/// only for `.cc`. Unlike `AutomationTarget` (the mixer/effect OUTPUT plane),
/// this is the instrument INPUT plane — it drives `ScheduledMIDIEvent` kinds
/// 2/3/4, never `AutomationLane` (design-m16b §1).
public enum MIDIControllerType: Hashable, Sendable, Codable {
    /// A Control Change stream; `controller` is the CC number 0...127
    /// (1 = mod wheel, 7 = channel volume, 10 = pan, 11 = expression,
    /// 64 = sustain pedal…). Built-in instruments honour CC 64 (sustain); every
    /// other CC is forwarded to hosted Audio Units (design-m16b §4.3).
    case cc(controller: Int)
    /// Pitch bend; value 0...16383, center 8192 (±2 semitones on built-ins).
    case pitchBend
    /// Channel (mono) aftertouch; value 0...127. Per-note (poly) aftertouch is a
    /// different model shape, deferred past v1 (design-m16b §3).
    case channelPressure

    /// The raw MIDI value domain a point on this lane occupies — the schedule
    /// path emits these as MIDI data bytes, so they are stored RAW (a normalized
    /// float would round-trip lossily and obscure teaching copy). `MIDIController-
    /// Lane` clamps every point's value into this range at canonicalization.
    public var valueRange: ClosedRange<Int> {
        switch self {
        case .cc, .channelPressure: return 0...127
        case .pitchBend: return 0...16383
        }
    }

    /// The neutral value a chase snapshot falls back to when NO scheduled point
    /// precedes a block's start beat (design-m16b §5): bend center, no pressure,
    /// and a small GM/RP-015-informed CC table (7 = channel volume 100,
    /// 10 = pan center 64, 11 = expression full, else 0). Consumed by the
    /// phase-2 schedule chase; defined here so "the neutral default" has ONE
    /// definition in DAWCore.
    public var neutralDefault: Int {
        switch self {
        case .pitchBend: return 8192
        case .channelPressure: return 0
        case .cc(let controller):
            switch controller {
            case 7: return 100    // channel volume
            case 10: return 64    // pan (center)
            case 11: return 127   // expression (full)
            default: return 0
            }
        }
    }

    /// Stable canonical order key (design-m16b §3): CC ascending BY CONTROLLER,
    /// then pitchBend, then channelPressure. A CC controller is clamp-bounded to
    /// 0...127, so it never collides with the 1000/1001 sentinels.
    var sortKey: Int {
        switch self {
        case .cc(let controller): return controller
        case .pitchBend: return 1000
        case .channelPressure: return 1001
        }
    }

    /// The wire/undo key form: "cc11", "pitchBend", "channelPressure". Used for
    /// the per-lane undo-coalescing key and the "existing lanes" teaching list.
    public var wireKey: String {
        switch self {
        case .cc(let controller): return "cc\(controller)"
        case .pitchBend: return "pitchBend"
        case .channelPressure: return "channelPressure"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, controller }

    /// A String raw enum so an unknown `type` on decode is a hard error.
    private enum Discriminator: String, Codable { case cc, pitchBend, channelPressure }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cc(let controller):
            try c.encode(Discriminator.cc, forKey: .type)
            try c.encode(controller, forKey: .controller)
        case .pitchBend:
            try c.encode(Discriminator.pitchBend, forKey: .type)
        case .channelPressure:
            try c.encode(Discriminator.channelPressure, forKey: .type)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Discriminator.self, forKey: .type) {
        case .cc:
            // Controller number re-clamps into 0...127 on decode (defensive; the
            // wire validates first) — the `MIDINote` self-healing discipline.
            let raw = try c.decode(Int.self, forKey: .controller)
            self = .cc(controller: raw.clamped(to: 0...127))
        case .pitchBend:
            self = .pitchBend
        case .channelPressure:
            self = .channelPressure
        }
    }
}

/// One controller point (m16-b): a clip-relative `beat` and a RAW MIDI `value`.
/// Deliberately NO id and NO curve — points are identity-free value data (the
/// `AutomationPoint` precedent) with STEPWISE semantics: a value holds until the
/// next point steps it; a ramp is a DENSE run of points (exactly what capture
/// produces). `beat` floors at 0 through `init` (the only construction path, and
/// where Codable routes); `value` is stored raw and clamped to the OWNING lane's
/// type range at `MIDIControllerLane` canonicalization (the point itself is
/// type-agnostic, so it can't clamp its own value).
public struct MIDIControllerPoint: Codable, Sendable, Equatable {
    /// Clip-relative position in beats (>= 0).
    public var beat: Double
    /// Raw MIDI value; range depends on the owning lane's type (see
    /// `MIDIControllerType.valueRange`).
    public var value: Int

    public init(beat: Double, value: Int) {
        self.beat = max(0, beat)
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case beat, value }

    /// Decoding routes through the flooring `init`, so a hand-authored payload
    /// can't smuggle in a negative beat (the `AutomationPoint`/`MIDINote`
    /// precedent). Both keys are required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            beat: try c.decode(Double.self, forKey: .beat),
            value: try c.decode(Int.self, forKey: .value))
    }

    /// Writes both keys explicitly (the full point shape on wire and disk).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(beat, forKey: .beat)
        try c.encode(value, forKey: .value)
    }
}

/// One controller lane (m16-b): a controller stream (`type`) plus its
/// canonically-ordered points. AT MOST ONE lane per type per clip (store- and
/// canonicalization-enforced, the automation at-most-one-per-target rule). No
/// lane UUID — the `type` IS the identity (one identity per thing, so nothing to
/// re-mint on duplicate — the identity-free-points design sidesteps the F8d
/// note-id trap). Every construction path routes points through
/// `canonicalPoints` (sorted by beat, equal-beat last-wins dedupe, values
/// clamped to the type range), so the stored invariant always holds.
public struct MIDIControllerLane: Codable, Sendable, Equatable {
    public var type: MIDIControllerType
    /// Canonically ordered: ascending by beat, distinct beats, values clamped to
    /// `type.valueRange`.
    public var points: [MIDIControllerPoint]

    public init(type: MIDIControllerType, points: [MIDIControllerPoint]) {
        self.type = type
        self.points = Self.canonicalPoints(points, type: type)
    }

    /// The value IN EFFECT at clip-relative `beat` (design-m16b §5): the value of
    /// the latest point with `point.beat <= beat`, else nil (no state established
    /// yet — the caller applies `type.neutralDefault`). Stepwise: a value holds
    /// until the next point. Points are canonical (ascending), so this is the
    /// last point at or before `beat`. THE ONE definition of "the value in effect
    /// at beat B" — reused by `windowedControllerLanes` (split/trim/take) and the
    /// phase-2 schedule chase.
    public func value(atBeat beat: Double) -> Int? {
        var result: Int?
        for p in points {
            if p.beat <= beat { result = p.value } else { break }
        }
        return result
    }

    /// Canonical point order: values clamped to `type.valueRange`, beats floored
    /// at 0 (through `MIDIControllerPoint.init`), sorted ascending by beat with
    /// equal-beat duplicates deduped LAST-WINS (the `AutomationLane.canonicalize`
    /// / gain-envelope contract). Empty stays empty. NO size cap here — the
    /// 16384-points-per-lane policy is a store/wire teaching boundary
    /// (design-m16b §7), the notes-cap precedent, so canonicalization never
    /// silently drops captured data.
    public static func canonicalPoints(_ points: [MIDIControllerPoint],
                                       type: MIDIControllerType) -> [MIDIControllerPoint] {
        guard !points.isEmpty else { return [] }
        let range = type.valueRange
        // Clamp values, then stable-sort by beat (preserving input order for
        // equal beats so the LAST wins the dedupe below).
        let clamped = points.enumerated().map { (offset, p) in
            (offset, MIDIControllerPoint(beat: p.beat, value: p.value.clamped(to: range)))
        }
        let sorted = clamped.sorted {
            $0.1.beat != $1.1.beat ? $0.1.beat < $1.1.beat : $0.0 < $1.0
        }.map(\.1)
        var out: [MIDIControllerPoint] = []
        out.reserveCapacity(sorted.count)
        for p in sorted {
            if let last = out.last, last.beat == p.beat {
                out[out.count - 1] = p          // equal beat → last wins
            } else {
                out.append(p)
            }
        }
        return out
    }

    private enum CodingKeys: String, CodingKey { case type, points }

    /// Decoding routes points through the canonicalizing `init` (so a
    /// hand-authored lane heals to its invariant); `type` is required (an
    /// unknown discriminator is a hard error via `MIDIControllerType`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try c.decode(MIDIControllerType.self, forKey: .type),
            points: try c.decodeIfPresent([MIDIControllerPoint].self, forKey: .points) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(points, forKey: .points)
    }
}

public struct Clip: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Position on the timeline, in beats.
    public var startBeat: Double
    public var lengthBeats: Double
    /// Source media for audio clips; nil for MIDI clips.
    public var audioFileURL: URL?
    /// MIDI note payload; nil for audio clips. A non-nil array (even empty)
    /// makes this a MIDI clip — see `isMIDI`. Stored canonically ordered, and
    /// MUTUALLY EXCLUSIVE with `audioFileURL` (notes win in `init`).
    public var notes: [MIDINote]?
    /// AI-generated content is surfaced distinctly in the UI (violet accent).
    public var isAIGenerated: Bool
    /// Playback offset INTO the source audio file, in seconds (M5 i-a): the clip
    /// sounds its source starting this far from the file's head. 0 for a whole
    /// file or any MIDI clip. `splitClip`/`trimClip` advance it so an edited clip
    /// keeps playing the right region of its source. Clamped >= 0; omitted from
    /// Codable when 0 (a pre-edit clip stays byte-identical). The engine ignores
    /// it in v0 (read path lands in M5 i-b).
    public var startOffsetSeconds: Double
    /// Per-clip gain in decibels (M5 i-a), applied on top of the track fader.
    /// Clamped to `gainDbRange`; 0 dB = unity. Omitted from Codable when 0.
    public var gainDb: Double
    /// Fade-in / fade-out lengths in beats (M5 i-a), measured from the clip's
    /// head / tail. Clamped >= 0; each additionally clamped to <= `lengthBeats`
    /// at USE time in `envelopeGain`, and the store enforces
    /// fadeIn + fadeOut <= lengthBeats by proportional reduction. Omitted from
    /// Codable when 0.
    public var fadeInBeats: Double
    public var fadeOutBeats: Double
    /// Interpolation shapes of the two fades. Omitted from Codable at `.linear`.
    public var fadeInCurve: FadeCurve
    public var fadeOutCurve: FadeCurve
    /// Output-time stretch multiplier applied to the SOURCE material (M5 ii-c):
    /// 2.0 = twice as long / half speed, 0.5 = half as long / double speed.
    /// ABSOLUTE and tempo-independent in v0 — a tempo change slides the clip
    /// window over more or less of the (already stretched) material, never a
    /// re-render. `lengthBeats` stays the timeline authority; the source window
    /// consumed is DERIVED (`sourceWindowSeconds`), so `stretchRatio == 1`
    /// collapses to today's behavior exactly (the structural null case).
    /// Clamped to `stretchRatioRange`; omitted from Codable at 1. The engine
    /// ignores it until ii-d.
    public var stretchRatio: Double
    /// Pitch shift independent of time, in semitones (M5 ii-c; +12 = up one
    /// octave). Clamped to `pitchShiftSemitonesRange`; omitted from Codable at
    /// 0. The engine ignores it until ii-d.
    public var pitchShiftSemitones: Double
    /// Keep formants at the source position while pitch-shifting (vocal mode,
    /// M5 ii-c) so a shifted voice doesn't chipmunk. Omitted from Codable when
    /// false. The engine ignores it until ii-d.
    public var formantPreserve: Bool
    /// Set on clips MATERIALIZED from a take group's comp (M5 iii-a, §2). Such
    /// clips are store-managed: the clip-edit ops (split/trim/move/gain/fades/
    /// stretch), `setClipNotes`, and `removeClip` all REJECT them (edit the comp
    /// with `take.setComp`, or `take.flatten` first). nil for every ordinary
    /// clip; omitted from Codable when nil (pre-take projects stay
    /// byte-identical).
    public var takeGroupID: UUID?
    /// Per-clip breakpoint GAIN ENVELOPE (m13-e): a clip-relative curve of dB
    /// breakpoints that MULTIPLIES on top of the static `gainDb` and the fades
    /// (it does not replace them — `envelopeGain(atBeat:)` folds all three).
    /// Empty == ABSENT == today's behavior EXACTLY; omitted from Codable when
    /// empty (a pre-m13-e clip stays byte-identical). Stored CANONICALLY
    /// ordered (ascending, distinct beats, each beat in `[0, lengthBeats]`,
    /// each gain in `gainDbRange`) — `Clip.init` heals any input through
    /// `canonicalGainEnvelope`, and the store's `setClipGainEnvelope` is the
    /// edit boundary. Audio clips only: the engine realizes it in the offline
    /// fade-bake (ClipFadeBake) — MIDI clips have no per-clip player to bake
    /// onto, so `setClipGainEnvelope` rejects them.
    public var gainEnvelope: [ClipGainPoint]
    /// Per-clip MIDI controller lanes (m16-b): mod wheel, sustain, pitch bend,
    /// channel pressure — the instrument INPUT plane, delivered interleaved with
    /// notes on the schedule path (design-m16b §1/§3), NOT the mixer automation
    /// plane. Empty == ABSENT == today's behavior EXACTLY; encoded ONLY when
    /// non-empty (a pre-m16-b clip stays byte-identical — the `gainEnvelope`
    /// mechanism byte-for-byte, encode `:568`). MIDI clips only: a non-MIDI clip
    /// forces `[]` in `init` (the notes-wins invariant cousin, `:366`), so a
    /// non-empty `controllerLanes` always implies `isMIDI`. A CC-only clip is
    /// legal as `notes: []` + lanes. Stored CANONICALLY ordered (at most one lane
    /// per type, sorted by type key, points canonical per lane) — `Clip.init`
    /// heals any input through `canonicalControllerLanes`, and the store's
    /// `setControllerLane`/`removeControllerLane` are the edit boundary. NOTE (the
    /// m12-f MIRROR-DTO lesson, as `gainEnvelope` warns): the disk path is
    /// `ClipDocument`, not this Codable — the field is threaded through
    /// `ClipDocument` init/encode/decode AND `runtimeState`.
    public var controllerLanes: [MIDIControllerLane]

    /// Per-clip gain bounds: a generous studio range, matching the fader's
    /// mental model (a clip can be pulled 72 dB down toward silence or pushed
    /// 24 dB hot).
    public static let gainDbRange: ClosedRange<Double> = -72...24

    /// Time-stretch bounds (M5 ii-c): 0.25× (four times faster) to 4× (four
    /// times slower). signalsmith is transparent-ish in 0.75–1.5×; beyond that
    /// it works but smears — a UI amber-tint hint, never a hard block.
    public static let stretchRatioRange: ClosedRange<Double> = 0.25...4
    /// Pitch-shift bounds (M5 ii-c): ±24 semitones (±two octaves).
    public static let pitchShiftSemitonesRange: ClosedRange<Double> = -24...24

    /// True when this clip carries MIDI (any `notes`, including an empty array);
    /// false for audio clips.
    public var isMIDI: Bool { notes != nil }

    /// True when the stretch is a structural identity — ratio exactly 1 and no
    /// pitch shift — so the engine (ii-d) bypasses rendering and plays the
    /// original file byte-for-byte. `formantPreserve` alone (no pitch shift) is
    /// still identity.
    public var isStretchIdentity: Bool {
        stretchRatio == 1 && pitchShiftSemitones == 0
    }

    /// Source-material window this clip consumes, in SECONDS, DERIVED from the
    /// timeline span and the stretch ratio (spec §1): the tempo-map integral
    /// over [startBeat, startBeat + lengthBeats], divided by the ratio. The
    /// single evaluator of "how much of the source file this clip reads" (the
    /// mirror of `envelopeGain`'s role). Holding this constant across a length
    /// change is exactly what `ProjectStore.stretchClip` does — with a TRIVIAL
    /// map the tempo factor cancels, so window invariance is equivalently
    /// `lengthBeats / stretchRatio == const`; across a multi-segment boundary
    /// that cancellation no longer holds and `stretchToLength` must re-derive
    /// the ratio from this integral (design §6 — Phase B re-proves it).
    /// The map's bpm is clamp-guaranteed positive, so only the ratio guards.
    public func sourceWindowSeconds(tempoMap: TempoMap) -> Double {
        guard stretchRatio > 0 else { return 0 }
        return tempoMap.seconds(from: startBeat, to: startBeat + lengthBeats) / stretchRatio
    }

    public init(
        id: UUID = UUID(),
        name: String,
        startBeat: Double = 0,
        lengthBeats: Double = 4,
        audioFileURL: URL? = nil,
        notes: [MIDINote]? = nil,
        isAIGenerated: Bool = false,
        startOffsetSeconds: Double = 0,
        gainDb: Double = 0,
        fadeInBeats: Double = 0,
        fadeOutBeats: Double = 0,
        fadeInCurve: FadeCurve = .linear,
        fadeOutCurve: FadeCurve = .linear,
        stretchRatio: Double = 1,
        pitchShiftSemitones: Double = 0,
        formantPreserve: Bool = false,
        gainEnvelope: [ClipGainPoint] = [],
        controllerLanes: [MIDIControllerLane] = [],
        takeGroupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.takeGroupID = takeGroupID
        self.startBeat = max(0, startBeat)
        self.lengthBeats = max(0, lengthBeats)
        self.notes = notes.map(MIDINote.canonicallyOrdered)
        // Invariant: notes wins — a MIDI clip never also carries audio media.
        self.audioFileURL = notes == nil ? audioFileURL : nil
        self.isAIGenerated = isAIGenerated
        self.startOffsetSeconds = max(0, startOffsetSeconds)
        self.gainDb = gainDb.clamped(to: Self.gainDbRange)
        self.fadeInBeats = max(0, fadeInBeats)
        self.fadeOutBeats = max(0, fadeOutBeats)
        self.fadeInCurve = fadeInCurve
        self.fadeOutCurve = fadeOutCurve
        self.stretchRatio = stretchRatio.clamped(to: Self.stretchRatioRange)
        self.pitchShiftSemitones = pitchShiftSemitones.clamped(to: Self.pitchShiftSemitonesRange)
        self.formantPreserve = formantPreserve
        // Heal the envelope to its invariant at every construction path (decode,
        // split/trim, overlap trim): beats clamped into the clip, sorted, and
        // deduped last-wins. Empty stays empty.
        self.gainEnvelope = Self.canonicalGainEnvelope(gainEnvelope, lengthBeats: self.lengthBeats)
        // Controller lanes (m16-b) require MIDI: an audio clip has no instrument
        // to feed, so its lanes force to [] (the notes-wins invariant cousin
        // above). A MIDI clip heals its lanes to canonical form (at most one lane
        // per type, sorted, points canonical). Empty stays empty.
        self.controllerLanes = notes == nil ? [] : Self.canonicalControllerLanes(controllerLanes)
    }

    /// Linear playback gain at `beat` (measured from the clip start): the static
    /// gain `10^(gainDb/20)` multiplied by the fade-in and fade-out ramps. Pure
    /// and engine/UI-shared (M5 i-b/i-d reuse it). `beat` is clamped into
    /// `[0, lengthBeats]`; sounding NOTHING before the clip or after its end is
    /// the caller's job, not this evaluator's.
    ///
    /// Fade shapes, with progress `t` running 0 -> 1 across the fade:
    ///  - `.linear`: rising factor = t (the fade-out passes `1 - t`, so it
    ///    falls 1 -> 0).
    ///  - `.equalPower`: rising factor = `sin(t · π/2)`; the fade-out's
    ///    `1 - t` argument makes it `cos`, so an equal-power fade-out is
    ///    `cos(u · π/2)` across its own progress `u`. Two adjacent equal-power
    ///    fades sum to unit power (sin² + cos² = 1).
    /// Midpoints: linear = 0.5, equal-power = `sin(π/4)` ≈ 0.7071.
    ///
    /// Each fade length is clamped to `<= lengthBeats` HERE, independently of the
    /// other; if they still overlap (a clip built directly with
    /// fadeIn + fadeOut > length), BOTH ramps apply and MULTIPLY at the overlap.
    /// `ProjectStore.setClipFades`/`trimClip` enforce fadeIn + fadeOut <= length
    /// by proportional reduction, so a store-built clip never overlaps.
    public func envelopeGain(atBeat beat: Double) -> Double {
        let staticGain = pow(10.0, gainDb / 20.0)
        guard lengthBeats > 0 else { return staticGain }
        let b = beat.clamped(to: 0...lengthBeats)
        var factor = staticGain
        let inLen = min(max(0, fadeInBeats), lengthBeats)
        if inLen > 0, b < inLen {
            factor *= Self.fadeShape(progress: b / inLen, curve: fadeInCurve)
        }
        let outLen = min(max(0, fadeOutBeats), lengthBeats)
        if outLen > 0, b > lengthBeats - outLen {
            // `progress` runs 0 -> 1 across the fade-out; passing `1 - progress`
            // to the rising shape makes the factor fall 1 -> 0.
            let progress = (b - (lengthBeats - outLen)) / outLen
            factor *= Self.fadeShape(progress: 1 - progress, curve: fadeOutCurve)
        }
        // Breakpoint gain envelope (m13-e): a clip-relative dB curve MULTIPLIED
        // on top of the static gain and fades. The `isEmpty` guard keeps the
        // pre-m13-e path byte-identical — an empty envelope never even touches
        // `factor` (no `× 1.0` to round-trip), so a clip without an envelope
        // renders and hashes exactly as before (the null-case byte gate).
        if !gainEnvelope.isEmpty {
            let db = Self.envelopeDb(points: gainEnvelope, atBeat: b)
            factor *= pow(10.0, db / 20.0)
        }
        return factor
    }

    /// dB value of the breakpoint gain envelope at clip-relative `beat`,
    /// LINEARLY interpolated in dB between adjacent points, held CONSTANT before
    /// the first point and at/after the last — the `AutomationLane.value(atBeat:)`
    /// idiom, linear-only (a gain envelope carries no `.hold` segments). `points`
    /// must be canonically ordered (ascending, distinct beats), which
    /// `canonicalGainEnvelope` guarantees. Empty → 0 dB (unity); callers guard
    /// emptiness so the null path never multiplies. Pure — the engine bake and
    /// the UI overlay share this single evaluator (the `envelopeGain` contract).
    public static func envelopeDb(points: [ClipGainPoint], atBeat beat: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if beat <= first.beat { return first.gainDb }
        if beat >= last.beat { return last.gainDb }
        for i in 0..<(points.count - 1) {
            let lo = points[i]
            let hi = points[i + 1]
            guard beat >= lo.beat, beat < hi.beat else { continue }
            let span = hi.beat - lo.beat
            guard span > 0 else { return lo.gainDb }
            let t = (beat - lo.beat) / span
            return lo.gainDb + (hi.gainDb - lo.gainDb) * t
        }
        return last.gainDb  // unreachable given the guards, but keeps this total
    }

    /// Canonical order for a gain envelope: every point's `beat` clamped into
    /// `[0, lengthBeats]`, `gainDb` re-clamped through `ClipGainPoint.init`,
    /// then sorted ascending with equal-beat duplicates deduped LAST-WINS (the
    /// `AutomationLane.canonicalize` contract). Empty stays empty. `Clip.init`
    /// and `ProjectStore.setClipGainEnvelope` both route through this so the
    /// stored invariant holds no matter how the envelope was built.
    public static func canonicalGainEnvelope(_ points: [ClipGainPoint],
                                             lengthBeats: Double) -> [ClipGainPoint] {
        guard !points.isEmpty else { return [] }
        let upper = max(0, lengthBeats)
        var byBeat: [Double: ClipGainPoint] = [:]
        byBeat.reserveCapacity(points.count)
        for p in points {
            let clampedBeat = p.beat.clamped(to: 0...upper)
            byBeat[clampedBeat] = ClipGainPoint(beat: clampedBeat, gainDb: p.gainDb)
        }
        return byBeat.values.sorted { $0.beat < $1.beat }
    }

    /// Re-windows a gain envelope for a trim / overlap-trim / split edit that
    /// shifts the clip head by `delta` beats (new clip-relative beat = old −
    /// `delta`) and sets the length to `newLength`. Interior points inside the
    /// new window survive (rebased by `−delta`); an interpolated boundary point
    /// is PINNED at each new edge (beat 0 and `newLength`) so the audible gain
    /// stays CONTINUOUS with the pre-edit curve across the seam. Empty stays
    /// empty. The caller's `Clip.init` canonicalizes the result (a boundary that
    /// coincides with an interior point dedupes last-wins). This is the split
    /// partition too: the two halves are the windows `[0, splitBeat]` and
    /// `[splitBeat, length]`, so their shared seam value is identical by
    /// construction.
    public static func windowedGainEnvelope(_ points: [ClipGainPoint],
                                            delta: Double, newLength: Double) -> [ClipGainPoint] {
        guard !points.isEmpty else { return [] }
        var out: [ClipGainPoint] = [
            ClipGainPoint(beat: 0, gainDb: envelopeDb(points: points, atBeat: delta))
        ]
        for p in points where p.beat > delta && p.beat < delta + newLength {
            out.append(ClipGainPoint(beat: p.beat - delta, gainDb: p.gainDb))
        }
        out.append(ClipGainPoint(beat: newLength,
                                 gainDb: envelopeDb(points: points, atBeat: delta + newLength)))
        return out
    }

    /// Canonical order for a clip's controller lanes (m16-b, design-m16b §3): at
    /// most ONE lane per type — duplicate-type lanes MERGE last-wins (their
    /// points concatenate in input order, so a later lane's point overrides at an
    /// equal beat through `canonicalPoints`) — each lane's points canonicalized,
    /// empty lanes dropped, and the result sorted by a stable type key (cc
    /// ascending by controller, then pitchBend, then channelPressure). `Clip.init`
    /// and the store's `setControllerLane`/`removeControllerLane` both route
    /// through this so the stored invariant holds no matter how lanes were built.
    public static func canonicalControllerLanes(_ lanes: [MIDIControllerLane]) -> [MIDIControllerLane] {
        guard !lanes.isEmpty else { return [] }
        var byType: [MIDIControllerType: [MIDIControllerPoint]] = [:]
        var order: [MIDIControllerType] = []
        for lane in lanes {
            if byType[lane.type] == nil { order.append(lane.type) }
            byType[lane.type, default: []].append(contentsOf: lane.points)
        }
        var merged: [MIDIControllerLane] = []
        for type in order {
            let lane = MIDIControllerLane(type: type, points: byType[type] ?? [])
            if !lane.points.isEmpty { merged.append(lane) }
        }
        return merged.sorted { $0.type.sortKey < $1.type.sortKey }
    }

    /// Re-windows a clip's controller lanes for a trim / split / take-comp / (in
    /// phase 2) schedule-build edit that shifts the window head by `delta` beats
    /// (new clip-relative beat = old − `delta`) into a `newLength`-beat window
    /// (design-m16b §11). STEP semantics — the `windowedGainEnvelope` sibling
    /// without an end point:
    ///
    ///  - an injected beat-0 point carries THE VALUE IN EFFECT at `delta`
    ///    (`MIDIControllerLane.value(atBeat:)` — the §5 chase scan reused), so the
    ///    windowed clip opens with honest controller state, but ONLY when the lane
    ///    has established a value at/before `delta` (else the chase supplies the
    ///    neutral default at play — no spurious point);
    ///  - interior points STRICTLY inside `(delta, delta+newLength)` rebase by
    ///    `−delta` (a point exactly at `delta` is absorbed into the beat-0
    ///    injection, never double-counted; a point at the window END belongs to
    ///    the next region);
    ///  - a lane that ends up empty is dropped.
    ///
    /// For a split, the two halves are the windows `delta: 0, newLength:
    /// firstLength` (the left keeps its points < the split verbatim) and
    /// `delta: splitBeat, newLength: secondLength` (the right opens with the
    /// value in effect at the split) — the seam value is identical to the pre-edit
    /// curve by construction. Pure; the caller's `Clip.init` re-canonicalizes.
    public static func windowedControllerLanes(_ lanes: [MIDIControllerLane],
                                               delta: Double, newLength: Double) -> [MIDIControllerLane] {
        guard !lanes.isEmpty else { return [] }
        var out: [MIDIControllerLane] = []
        for lane in lanes {
            var pts: [MIDIControllerPoint] = []
            if let v = lane.value(atBeat: delta) {
                pts.append(MIDIControllerPoint(beat: 0, value: v))
            }
            for p in lane.points where p.beat > delta && p.beat < delta + newLength {
                pts.append(MIDIControllerPoint(beat: p.beat - delta, value: p.value))
            }
            let windowed = MIDIControllerLane(type: lane.type, points: pts)
            if !windowed.points.isEmpty { out.append(windowed) }
        }
        return out.sorted { $0.type.sortKey < $1.type.sortKey }
    }

    /// Rising fade factor for `progress` (0 -> 1): 0 at progress 0, 1 at progress
    /// 1. A fade-out passes `1 - progress` to reuse this single rising shape.
    private static func fadeShape(progress: Double, curve: FadeCurve) -> Double {
        let p = progress.clamped(to: 0...1)
        switch curve {
        case .linear: return p
        case .equalPower: return sin(p * .pi / 2)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startBeat, lengthBeats, audioFileURL, notes, isAIGenerated
        case startOffsetSeconds, gainDb, fadeInBeats, fadeOutBeats, fadeInCurve, fadeOutCurve
        case stretchRatio, pitchShiftSemitones, formantPreserve, gainEnvelope, controllerLanes, takeGroupID
    }

    /// Decoding routes through the clamping `init`; every edit field tolerates
    /// absence (defaults), so a pre-edit payload decodes unchanged and a
    /// hand-authored one can't smuggle in an out-of-range value (the `MIDINote`
    /// precedent). `id` is required — a clip with no identity is a damaged
    /// payload.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Clip",
            startBeat: try c.decodeIfPresent(Double.self, forKey: .startBeat) ?? 0,
            lengthBeats: try c.decodeIfPresent(Double.self, forKey: .lengthBeats) ?? 4,
            audioFileURL: try c.decodeIfPresent(URL.self, forKey: .audioFileURL),
            notes: try c.decodeIfPresent([MIDINote].self, forKey: .notes),
            isAIGenerated: try c.decodeIfPresent(Bool.self, forKey: .isAIGenerated) ?? false,
            startOffsetSeconds: try c.decodeIfPresent(Double.self, forKey: .startOffsetSeconds) ?? 0,
            gainDb: try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0,
            fadeInBeats: try c.decodeIfPresent(Double.self, forKey: .fadeInBeats) ?? 0,
            fadeOutBeats: try c.decodeIfPresent(Double.self, forKey: .fadeOutBeats) ?? 0,
            fadeInCurve: try c.decodeIfPresent(FadeCurve.self, forKey: .fadeInCurve) ?? .linear,
            fadeOutCurve: try c.decodeIfPresent(FadeCurve.self, forKey: .fadeOutCurve) ?? .linear,
            stretchRatio: try c.decodeIfPresent(Double.self, forKey: .stretchRatio) ?? 1,
            pitchShiftSemitones: try c.decodeIfPresent(Double.self, forKey: .pitchShiftSemitones) ?? 0,
            formantPreserve: try c.decodeIfPresent(Bool.self, forKey: .formantPreserve) ?? false,
            gainEnvelope: try c.decodeIfPresent([ClipGainPoint].self, forKey: .gainEnvelope) ?? [],
            controllerLanes: try c.decodeIfPresent([MIDIControllerLane].self, forKey: .controllerLanes) ?? [],
            takeGroupID: try c.decodeIfPresent(UUID.self, forKey: .takeGroupID)
        )
    }

    /// Writes the pre-edit keys exactly as the synthesized encoder did (so an
    /// unedited clip is byte-identical), then each edit field ONLY when it
    /// departs from its default — the `Track` omit-when-default precedent, so a
    /// pre-edit project never grows keys it didn't carry.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(startBeat, forKey: .startBeat)
        try c.encode(lengthBeats, forKey: .lengthBeats)
        try c.encodeIfPresent(audioFileURL, forKey: .audioFileURL)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(isAIGenerated, forKey: .isAIGenerated)
        if startOffsetSeconds != 0 { try c.encode(startOffsetSeconds, forKey: .startOffsetSeconds) }
        if gainDb != 0 { try c.encode(gainDb, forKey: .gainDb) }
        if fadeInBeats != 0 { try c.encode(fadeInBeats, forKey: .fadeInBeats) }
        if fadeOutBeats != 0 { try c.encode(fadeOutBeats, forKey: .fadeOutBeats) }
        if fadeInCurve != .linear { try c.encode(fadeInCurve, forKey: .fadeInCurve) }
        if fadeOutCurve != .linear { try c.encode(fadeOutCurve, forKey: .fadeOutCurve) }
        if stretchRatio != 1 { try c.encode(stretchRatio, forKey: .stretchRatio) }
        if pitchShiftSemitones != 0 { try c.encode(pitchShiftSemitones, forKey: .pitchShiftSemitones) }
        if formantPreserve { try c.encode(formantPreserve, forKey: .formantPreserve) }
        // Gain envelope (m13-e): written ONLY when non-empty, so a clip without
        // one carries no new key (byte-identical to a pre-m13-e save).
        if !gainEnvelope.isEmpty { try c.encode(gainEnvelope, forKey: .gainEnvelope) }
        // Controller lanes (m16-b): written ONLY when non-empty, so a clip
        // without any carries no new key (byte-identical to a pre-m16-b save).
        if !controllerLanes.isEmpty { try c.encode(controllerLanes, forKey: .controllerLanes) }
        // Members carry their group marker; ordinary clips (nil) omit it, so a
        // pre-take clip stays byte-identical.
        try c.encodeIfPresent(takeGroupID, forKey: .takeGroupID)
    }
}

/// Outcome of `ProjectStore.moveClip` (m11-d): the moved clip in its final
/// geometry, plus the ids of ordinary same-track clips the move's overlap policy
/// TRIMMED (edge-trimmed, id preserved) or REMOVED (fully covered / a
/// sub-minimum sliver). Both arrays are empty for a plain move onto free space.
public struct ClipMoveResult: Sendable, Equatable {
    public var clip: Clip
    public var trimmedClipIDs: [UUID]
    public var removedClipIDs: [UUID]

    public init(clip: Clip, trimmedClipIDs: [UUID] = [], removedClipIDs: [UUID] = []) {
        self.clip = clip
        self.trimmedClipIDs = trimmedClipIDs
        self.removedClipIDs = removedClipIDs
    }
}

/// Outcome of `ProjectStore.insertBars` (m15-d): where the empty bars landed
/// (absolute beat) and how many beats were inserted (meter-aware: `count` bars
/// of the meter governing the insertion point).
public struct InsertBarsResult: Sendable, Equatable {
    public var atBeat: Double
    public var insertedBeats: Double
    /// Beats-per-bar of the inserted bars (the meter that continues across the
    /// insertion point — see `ProjectStore.insertBars`).
    public var beatsPerBar: Int

    public init(atBeat: Double, insertedBeats: Double, beatsPerBar: Int) {
        self.atBeat = atBeat
        self.insertedBeats = insertedBeats
        self.beatsPerBar = beatsPerBar
    }
}

/// Outcome of `ProjectStore.deleteBars` (m15-d): where the deleted range began
/// (absolute beat), how many beats were removed (meter-aware, summed across any
/// meter changes inside the range), and the ids of clips/markers the delete
/// dropped entirely (a straddling clip is trimmed/split, not listed here — only
/// fully-swallowed ids appear).
public struct DeleteBarsResult: Sendable, Equatable {
    public var fromBeat: Double
    public var deletedBeats: Double
    public var removedClipIDs: [UUID]
    public var removedMarkerIDs: [UUID]

    public init(fromBeat: Double, deletedBeats: Double,
                removedClipIDs: [UUID] = [], removedMarkerIDs: [UUID] = []) {
        self.fromBeat = fromBeat
        self.deletedBeats = deletedBeats
        self.removedClipIDs = removedClipIDs
        self.removedMarkerIDs = removedMarkerIDs
    }
}

/// Outcome of `ProjectStore.crossfadeClips` (m11-d): the two clips in their final
/// geometry (left/right by timeline start) and the beat length of the overlap
/// their complementary equal-power fades now span.
public struct CrossfadeResult: Sendable, Equatable {
    public var left: Clip
    public var right: Clip
    public var overlapBeats: Double

    public init(left: Clip, right: Clip, overlapBeats: Double) {
        self.left = left
        self.right = right
        self.overlapBeats = overlapBeats
    }
}

public struct Track: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: TrackKind
    /// Linear gain, 0...2 where 1 is unity.
    public var volume: Double
    /// -1 (hard left) ... 1 (hard right).
    public var pan: Double
    public var isMuted: Bool
    public var isSoloed: Bool
    public var isArmed: Bool
    public var isAIGenerated: Bool
    public var clips: [Clip]
    /// Which built-in instrument this track plays. Only meaningful on
    /// instrument tracks; `nil` means `InstrumentDescriptor.default`.
    /// Optional so v1 project files without the field still decode (additive).
    public var instrument: InstrumentDescriptor?
    /// Mix destination for audio/instrument tracks: nil = master, else a bus
    /// track's id. Never meaningful on bus tracks (buses output to master in
    /// v0). Wire/persistence key: `outputBusId`.
    public var outputBusID: UUID?
    /// Post-fader sends into buses (M4 i). Empty on bus tracks in v0.
    public var sends: [Send]
    /// Pre-fader insert-effect chain (M4 ii), in processing order. Allowed on
    /// every track kind.
    public var effects: [EffectDescriptor]
    /// Automation lanes (M4 vii), at most one per target (store-enforced). Empty
    /// on a track with no drawn automation; additive like `sends`/`effects`.
    public var automation: [AutomationLane]
    /// Take groups (M5 iii-a), out-of-band from `clips`. Each group's comp is
    /// materialized into ordinary `clips` marked by `Clip.takeGroupID`; the
    /// engine, renderer, snapshot, and media pipeline see only those clips.
    /// Empty on a track with no takes; additive like `automation`.
    public var takeGroups: [TakeGroup]

    public static let volumeRange: ClosedRange<Double> = 0...2
    public static let panRange: ClosedRange<Double> = -1...1

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind = .audio,
        volume: Double = 1,
        pan: Double = 0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isArmed: Bool = false,
        isAIGenerated: Bool = false,
        clips: [Clip] = [],
        instrument: InstrumentDescriptor? = nil,
        outputBusID: UUID? = nil,
        sends: [Send] = [],
        effects: [EffectDescriptor] = [],
        automation: [AutomationLane] = [],
        takeGroups: [TakeGroup] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.volume = volume.clamped(to: Self.volumeRange)
        self.pan = pan.clamped(to: Self.panRange)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.isArmed = isArmed
        self.isAIGenerated = isAIGenerated
        self.clips = clips
        self.instrument = instrument
        self.outputBusID = outputBusID
        self.sends = sends
        self.effects = effects
        self.automation = automation
        self.takeGroups = takeGroups
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, volume, pan, isMuted, isSoloed, isArmed
        case isAIGenerated, clips, instrument
        case outputBusID = "outputBusId"
        case sends, effects, automation, takeGroups
    }

    /// Routing/FX fields tolerate absence so pre-M4 payloads still decode;
    /// all values route through the clamping `init`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            kind: try c.decode(TrackKind.self, forKey: .kind),
            volume: try c.decode(Double.self, forKey: .volume),
            pan: try c.decode(Double.self, forKey: .pan),
            isMuted: try c.decode(Bool.self, forKey: .isMuted),
            isSoloed: try c.decode(Bool.self, forKey: .isSoloed),
            isArmed: try c.decode(Bool.self, forKey: .isArmed),
            isAIGenerated: try c.decode(Bool.self, forKey: .isAIGenerated),
            clips: try c.decode([Clip].self, forKey: .clips),
            instrument: try c.decodeIfPresent(InstrumentDescriptor.self, forKey: .instrument),
            outputBusID: try c.decodeIfPresent(UUID.self, forKey: .outputBusID),
            sends: try c.decodeIfPresent([Send].self, forKey: .sends) ?? [],
            effects: try c.decodeIfPresent([EffectDescriptor].self, forKey: .effects) ?? [],
            automation: try c.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? [],
            takeGroups: try c.decodeIfPresent([TakeGroup].self, forKey: .takeGroups) ?? []
        )
    }

    /// `sends`/`effects` are always on the wire (possibly empty);
    /// `outputBusId` and `instrument` only when present — matches the
    /// synthesized behavior the rest of the codebase pinned before routing
    /// existed.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(volume, forKey: .volume)
        try c.encode(pan, forKey: .pan)
        try c.encode(isMuted, forKey: .isMuted)
        try c.encode(isSoloed, forKey: .isSoloed)
        try c.encode(isArmed, forKey: .isArmed)
        try c.encode(isAIGenerated, forKey: .isAIGenerated)
        try c.encode(clips, forKey: .clips)
        try c.encodeIfPresent(instrument, forKey: .instrument)
        try c.encodeIfPresent(outputBusID, forKey: .outputBusID)
        try c.encode(sends, forKey: .sends)
        try c.encode(effects, forKey: .effects)
        // Always on the wire (possibly empty), the sends/effects precedent — the
        // live snapshot carries automation even when a lane collection is empty.
        try c.encode(automation, forKey: .automation)
        // Omitted when empty (unlike automation) so a pre-take snapshot/wire
        // payload stays byte-identical — the `outputBusId`/`instrument` rule.
        if !takeGroups.isEmpty { try c.encode(takeGroups, forKey: .takeGroups) }
    }
}

/// One post-fader send from a source track into a bus (M4 i). Level is linear
/// gain clamped to `Track.volumeRange`; the wire/persistence key for the
/// destination is `busId`.
public struct Send: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var destinationBusID: UUID
    public var level: Double

    public static let levelRange: ClosedRange<Double> = Track.volumeRange

    public init(id: UUID = UUID(), destinationBusID: UUID, level: Double = 1) {
        self.id = id
        self.destinationBusID = destinationBusID
        self.level = level.clamped(to: Self.levelRange)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case destinationBusID = "busId"
        case level
    }

    /// Decoding routes through the clamping init (MIDINote precedent); `id`
    /// and `level` tolerate absence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            destinationBusID: try c.decode(UUID.self, forKey: .destinationBusID),
            level: try c.decodeIfPresent(Double.self, forKey: .level) ?? 1
        )
    }
}

/// A named song-section anchor on the timeline (m11-c) — "Intro", "Chorus",
/// "Drop". Markers give agents and humans stable, human-meaningful positions to
/// navigate to ("drop at the second chorus"): `transport.seek {marker}` jumps to
/// one, and the arrange ruler renders them as flags you can drag/rename. A pure
/// value type: no media, no engine involvement — it rides `EditState` (undo) and
/// persists additively, exactly like a groove template.
///
/// `beat` is an ABSOLUTE timeline position in beats (quarter notes), floored at 0
/// by the clamping init (the `Clip`/`MIDINote` precedent — a hand-authored or
/// decoded payload can never smuggle in a negative anchor). Markers carry no
/// ordering of their own; the store exposes them SORTED by beat (ties stable).
public struct Marker: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// Display name, e.g. "Chorus". Free text; the store auto-names an empty one
    /// "Marker N" so a marker always reads as something.
    public var name: String
    /// Absolute timeline position in beats (quarter notes), >= 0.
    public var beat: Double

    public init(id: UUID = UUID(), name: String, beat: Double) {
        self.id = id
        self.name = name
        self.beat = max(0, beat)
    }

    private enum CodingKeys: String, CodingKey { case id, name, beat }

    /// Decoding routes through the clamping init (the `MIDINote`/`Send` precedent):
    /// `id` is required (identity — a missing id is a damaged payload), `name`/
    /// `beat` tolerate absence with the model defaults, and `beat` re-floors at 0.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Marker",
            beat: try c.decodeIfPresent(Double.self, forKey: .beat) ?? 0
        )
    }
}

/// Component identity of a hosted Audio Unit, FourCCs as exactly-4-ASCII-char
/// strings ("aumu", "dls "). Init normalizes: right-pad with spaces, truncate
/// to 4, non-ASCII scalars → "?". Decoding routes through the normalizing init
/// so a hand-authored payload can never smuggle in a malformed code.
public struct AudioUnitComponentID: Hashable, Sendable, Codable {
    public var type: String            // "aumu" always for v0
    public var subType: String
    public var manufacturer: String

    public init(type: String = "aumu", subType: String, manufacturer: String) {
        self.type = Self.normalizedFourCC(type)
        self.subType = Self.normalizedFourCC(subType)
        self.manufacturer = Self.normalizedFourCC(manufacturer)
    }

    /// Exactly four ASCII characters: non-ASCII scalars map to "?", longer
    /// strings truncate, shorter strings right-pad with spaces.
    static func normalizedFourCC(_ raw: String) -> String {
        var characters = raw.unicodeScalars.prefix(4).map { scalar in
            scalar.isASCII ? Character(scalar) : Character("?")
        }
        while characters.count < 4 { characters.append(" ") }
        return String(characters)
    }

    private enum CodingKeys: String, CodingKey { case type, subType, manufacturer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try c.decodeIfPresent(String.self, forKey: .type) ?? "aumu",
            subType: try c.decode(String.self, forKey: .subType),
            manufacturer: try c.decode(String.self, forKey: .manufacturer)
        )
    }
}

/// Selects one installed Audio Unit music device for a track, plus its saved
/// document state (`fullStateForDocument` as a binary plist). `name` /
/// `manufacturerName` are display facts captured at selection time so a
/// missing plugin still shows readably.
public struct AudioUnitConfig: Codable, Sendable, Equatable {
    public var component: AudioUnitComponentID
    public var name: String            // display, e.g. "DLSMusicDevice"
    public var manufacturerName: String
    public var stateData: Data?        // fullStateForDocument as binary plist

    public init(component: AudioUnitComponentID, name: String = "",
                manufacturerName: String = "", stateData: Data? = nil) {
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        self.stateData = stateData
    }
}

/// Selects a built-in instrument for an instrument track, with its parameters.
public struct InstrumentDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Bare sine voices — the engine-test instrument.
        case testTone
        /// The built-in subtractive poly synth.
        case polySynth
        /// The built-in sample player (zones of audio files mapped across keys).
        case sampler
        /// A hosted Audio Unit music device (see `audioUnit`).
        case audioUnit
        /// An AUSampler-backed SoundFont2/DLS bank program (m10-n). The
        /// hosting AU is an implementation detail — identity lives entirely
        /// in `soundBank`.
        case soundBank
    }

    public var kind: Kind
    /// Per-kind parameters are all carried regardless of the active kind so
    /// switching kinds round-trips the user's settings.
    public var polySynth: PolySynthParams
    /// Optional so pre-sampler project files still decode (additive).
    /// `nil` reads as `SamplerParams()` (no zones — silent until configured).
    public var sampler: SamplerParams?
    /// Hosted Audio Unit selection (additive optional, carried across kind
    /// switches like `sampler`). `kind == .audioUnit && audioUnit == nil` is
    /// legal and renders as the missing placeholder (silence).
    public var audioUnit: AudioUnitConfig?
    /// Sound-bank program selection (m10-n; additive optional, carried
    /// across kind switches like `sampler`/`audioUnit`, so pre-soundBank
    /// project files still decode). `kind == .soundBank && soundBank == nil`
    /// is legal and renders the silent placeholder — the
    /// componentless-`.audioUnit` rule.
    public var soundBank: SoundBankConfig?

    public static let `default` = InstrumentDescriptor()

    /// The sampler params with the nil-default resolved.
    public var resolvedSampler: SamplerParams { sampler ?? SamplerParams() }

    public init(
        kind: Kind = .polySynth,
        polySynth: PolySynthParams = PolySynthParams(),
        sampler: SamplerParams? = nil,
        audioUnit: AudioUnitConfig? = nil,
        soundBank: SoundBankConfig? = nil
    ) {
        self.kind = kind
        self.polySynth = polySynth
        self.sampler = sampler
        self.audioUnit = audioUnit
        self.soundBank = soundBank
    }
}

/// Parameters for the built-in sampler. Zones are wholesale-replaced (like
/// clip notes): a zone edit submits the full zones array.
public struct SamplerParams: Codable, Sendable, Equatable {
    /// Key zones in array order; the FIRST zone whose pitch span contains a
    /// note's pitch plays it (deterministic on overlap).
    public var zones: [SamplerZone]
    /// When true, noteOff is ignored — every trigger plays the sample to its
    /// end (drums/percussion).
    public var oneShot: Bool
    /// Anti-click ramps, seconds.
    public var attack: Double
    public var release: Double
    /// Output gain, 0...1.
    public var gain: Double

    public static let attackRange: ClosedRange<Double> = 0...1
    public static let releaseRange: ClosedRange<Double> = 0.001...8
    public static let gainRange: ClosedRange<Double> = 0...1

    public init(
        zones: [SamplerZone] = [],
        oneShot: Bool = false,
        attack: Double = 0.001,
        release: Double = 0.05,
        gain: Double = 0.8
    ) {
        self.zones = zones
        self.oneShot = oneShot
        self.attack = attack.clamped(to: Self.attackRange)
        self.release = release.clamped(to: Self.releaseRange)
        self.gain = gain.clamped(to: Self.gainRange)
    }
}

/// One sampler key zone: an audio file mapped across a pitch span, played
/// back resampled relative to its root pitch.
///
/// m19-a selection dimension (design 2026-07-16 §3): everything below `gain`
/// is ADDITIVE-OPTIONAL — pre-m19 project files decode the new fields as nil,
/// and nil is defined to reproduce the original pitch-only first-match
/// behavior exactly (implicit group 0, full velocity span, no round-robin or
/// random gate).
///
/// m19-b playback scalars (design §3/§4.4/§4.5): the fields from `tuneCents`
/// down are the same additive-optional contract — nil reproduces the pre-m19
/// playback law byte-for-byte (no retune, unity dual-mono, velocity/127 amp,
/// global one-shot, full file span, global attack/release with no decay stage
/// and full sustain).
/// Loop behavior (m20-g). nil = no loop — the pre-m20-g playback law
/// byte-for-byte. `.sustain` loops while the note (or CC64) holds and plays
/// through past the loop end on release; `.continuous` loops through the
/// release. A looping zone's voices are never one-shot (loopMode wins over
/// `oneShot` — see SamplerInstrument).
public enum SamplerLoopMode: String, Codable, Sendable { case sustain, continuous }

public struct SamplerZone: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var audioFileURL: URL
    /// The MIDI pitch at which the file plays back unshifted.
    public var rootPitch: Int
    /// Inclusive pitch span this zone responds to (clamped; swapped if reversed).
    public var minPitch: Int
    public var maxPitch: Int
    /// Per-zone gain, 0...2 (m19-b, amendment A5: relaxed from 0...1 so SFZ
    /// `volume` up to +6 dB imports at level).
    public var gain: Double
    /// Inclusive velocity span (m19-a): the zone responds only to note-ons
    /// whose velocity falls inside it (clamped; swapped if reversed).
    /// nil = 0 / 127 — all velocities, today's behavior.
    public var minVelocity: Int?
    public var maxVelocity: Int?
    /// Layering identity (m19-a): zones in DIFFERENT groups layer (one voice
    /// per group per note-on); within the SAME group the first eligible zone
    /// wins. nil = implicit group 0, reserved for hand-built/legacy zones so
    /// their relative order — and first-match behavior — is preserved exactly.
    public var group: Int?
    /// Round-robin (m19-a): with `seqLength` N > 1 the zone plays only on the
    /// `seqPosition`-th of every N consecutive range matches (ARIA per-region
    /// counters). nil/1 = no round-robin gate; `seqPosition` nil = 1.
    public var seqLength: Int?
    public var seqPosition: Int?
    /// Random alternation (m19-a): one random draw in [0, 1) per note-on
    /// selects zones whose [randMin, randMax) span contains it (randMax 1
    /// closes the interval). nil = 0 / 1 — always eligible.
    public var randMin: Double?
    public var randMax: Double?
    /// Pitch offset in cents, ±4800 (±4 octaves — the design elides the clamp;
    /// documented here as the m19-b choice, wide enough for SFZ
    /// `transpose`×100 + `tune`). nil = 0 = no retune.
    public var tuneCents: Double?
    /// Stereo placement, −1 (hard left) ... +1 (hard right), constant-power
    /// −3 dB-center law. nil is NOT the same as an explicit 0: nil keeps the
    /// legacy unity dual-mono gains (1.0/1.0) byte-for-byte, while a PRESENT 0
    /// sits at the pan law's 0.7071 center — see
    /// `SamplerInstrument.LoadedZone`.
    public var pan: Double?
    /// Velocity→amplitude depth, 0...1: 1 = today's velocity/127 law, 0 =
    /// velocity ignored (full level at any velocity). nil = 1.
    public var ampVelTrack: Double?
    /// Per-zone one-shot override: true/false forces it for this zone's
    /// voices; nil = inherit the live `SamplerParams.oneShot` global.
    public var oneShot: Bool?
    /// Playback span in SOURCE-FILE frames: `startFrame` ≥ 0 (nil = 0) is
    /// where the playhead starts, `endFrame` (nil = file end) is where the
    /// voice frees itself. Clamped so end > start (end raises to start + 1
    /// rather than swapping — a swap would silently invert skip-vs-stop
    /// intent); the engine further clamps both to the real file length.
    public var startFrame: Int?
    public var endFrame: Int?
    /// Per-zone envelope (m19-b, design §4.4), seconds/level. `attack` nil =
    /// the live `SamplerParams.attack` global (clamped to its 0...1 range);
    /// `decay` nil = 0 = no decay stage (present-0 stays legal, so the clamp
    /// is 0...8 with NO minimum floor); `sustain` nil = 1 (hold at peak);
    /// `release` nil = the live `SamplerParams.release` global (clamped to
    /// its 0.001...8 range).
    public var attack: Double?
    public var decay: Double?
    public var sustain: Double?
    public var release: Double?
    /// Loop behavior (m20-g). nil = no loop — the pre-m20-g playback law
    /// byte-for-byte. See `SamplerLoopMode`.
    public var loopMode: SamplerLoopMode?
    /// Loop span in SOURCE-FILE frames, same conventions as startFrame/endFrame:
    /// loopStart inclusive (nil = 0), loopEnd EXCLUSIVE (nil = the zone's
    /// resolved end). Ignored when loopMode is nil. Clamped so loopEnd >
    /// loopStart (raised, not swapped — the endFrame idiom); the engine further
    /// clamps both into the real playable span.
    public var loopStart: Int?
    public var loopEnd: Int?

    public static let pitchRange: ClosedRange<Int> = 0...127
    /// m19-b (A5): 0...2 (+6 dB), relaxed from 0...1 — decode-safe for every
    /// pre-m19-b project (a range relaxation never re-clamps old values).
    public static let gainRange: ClosedRange<Double> = 0...2
    public static let velocityRange: ClosedRange<Int> = 0...127
    public static let randRange: ClosedRange<Double> = 0...1
    public static let tuneCentsRange: ClosedRange<Double> = -4_800...4_800
    public static let panRange: ClosedRange<Double> = -1...1
    public static let ampVelTrackRange: ClosedRange<Double> = 0...1
    /// Per-zone decay: 0...8 s. Deliberately NOT SamplerParams.releaseRange —
    /// present-0 must stay legal because it equals the nil default (no decay
    /// stage).
    public static let decayRange: ClosedRange<Double> = 0...8
    public static let sustainRange: ClosedRange<Double> = 0...1

    public init(
        id: UUID = UUID(),
        audioFileURL: URL,
        rootPitch: Int = 60,
        minPitch: Int = 0,
        maxPitch: Int = 127,
        gain: Double = 1,
        minVelocity: Int? = nil,
        maxVelocity: Int? = nil,
        group: Int? = nil,
        seqLength: Int? = nil,
        seqPosition: Int? = nil,
        randMin: Double? = nil,
        randMax: Double? = nil,
        tuneCents: Double? = nil,
        pan: Double? = nil,
        ampVelTrack: Double? = nil,
        oneShot: Bool? = nil,
        startFrame: Int? = nil,
        endFrame: Int? = nil,
        attack: Double? = nil,
        decay: Double? = nil,
        sustain: Double? = nil,
        release: Double? = nil,
        loopMode: SamplerLoopMode? = nil,
        loopStart: Int? = nil,
        loopEnd: Int? = nil
    ) {
        self.id = id
        self.audioFileURL = audioFileURL
        self.rootPitch = min(max(rootPitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        let lo = min(max(minPitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        let hi = min(max(maxPitch, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        self.minPitch = min(lo, hi)
        self.maxPitch = max(lo, hi)
        self.gain = gain.clamped(to: Self.gainRange)
        // Optionals stay nil when passed nil (the additive-Codable contract);
        // present values clamp/swap with the same idiom as the pitch span.
        let vlo = minVelocity.map { $0.clamped(to: Self.velocityRange) }
        let vhi = maxVelocity.map { $0.clamped(to: Self.velocityRange) }
        if let vlo, let vhi, vlo > vhi {
            self.minVelocity = vhi
            self.maxVelocity = vlo
        } else {
            self.minVelocity = vlo
            self.maxVelocity = vhi
        }
        // Negative groups are reserved for engine sentinels — clamp to ≥ 0.
        self.group = group.map { max(0, $0) }
        let length = seqLength.map { max(1, $0) }
        self.seqLength = length
        self.seqPosition = seqPosition.map { min(max(1, $0), length ?? Int.max) }
        let rlo = randMin.map { $0.clamped(to: Self.randRange) }
        let rhi = randMax.map { $0.clamped(to: Self.randRange) }
        if let rlo, let rhi, rlo > rhi {
            self.randMin = rhi
            self.randMax = rlo
        } else {
            self.randMin = rlo
            self.randMax = rhi
        }
        // m19-b playback scalars: same idiom — optionals stay nil when nil,
        // present values clamp to their documented ranges.
        self.tuneCents = tuneCents.map { $0.clamped(to: Self.tuneCentsRange) }
        self.pan = pan.map { $0.clamped(to: Self.panRange) }
        self.ampVelTrack = ampVelTrack.map { $0.clamped(to: Self.ampVelTrackRange) }
        self.oneShot = oneShot
        // start ≥ 0; end > start (raised, not swapped — see the field doc).
        let start = startFrame.map { max(0, $0) }
        self.startFrame = start
        self.endFrame = endFrame.map { max($0, (start ?? 0) + 1) }
        self.attack = attack.map { $0.clamped(to: SamplerParams.attackRange) }
        self.decay = decay.map { $0.clamped(to: Self.decayRange) }
        self.sustain = sustain.map { $0.clamped(to: Self.sustainRange) }
        self.release = release.map { $0.clamped(to: SamplerParams.releaseRange) }
        // m20-g loops: loopStart ≥ 0; loopEnd > loopStart (raised, not swapped
        // — the endFrame idiom); the engine further clamps to the real span.
        self.loopMode = loopMode
        let ls = loopStart.map { max(0, $0) }
        self.loopStart = ls
        self.loopEnd = loopEnd.map { max($0, (ls ?? 0) + 1) }   // raise, never swap
    }

    public func contains(pitch: Int) -> Bool { pitch >= minPitch && pitch <= maxPitch }

    /// Pitch ∩ velocity span membership (m19-a), nil-tolerant: nil velocity
    /// bounds read as the full 0/127 span.
    public func contains(pitch: Int, velocity: Int) -> Bool {
        contains(pitch: pitch)
            && velocity >= (minVelocity ?? 0)
            && velocity <= (maxVelocity ?? 127)
    }
}

/// Parameters for the built-in subtractive poly synth. All values are clamped
/// on init so a descriptor is always renderable as-is.
public struct PolySynthParams: Codable, Sendable, Equatable {
    public enum Waveform: String, Codable, Sendable, CaseIterable {
        case saw, square, triangle, sine
    }

    public var waveform: Waveform
    /// ADSR: attack/decay/release in seconds, sustain a 0...1 level.
    public var attack: Double
    public var decay: Double
    public var sustain: Double
    public var release: Double
    /// Low-pass filter.
    public var cutoffHz: Double
    public var resonance: Double
    /// Output gain, 0...1.
    public var gain: Double

    public static let attackRange: ClosedRange<Double> = 0.0005...5
    public static let decayRange: ClosedRange<Double> = 0.001...5
    public static let sustainRange: ClosedRange<Double> = 0...1
    public static let releaseRange: ClosedRange<Double> = 0.001...8
    public static let cutoffRange: ClosedRange<Double> = 40...18_000
    public static let resonanceRange: ClosedRange<Double> = 0...1
    public static let gainRange: ClosedRange<Double> = 0...1

    public init(
        waveform: Waveform = .saw,
        attack: Double = 0.005,
        decay: Double = 0.08,
        sustain: Double = 0.7,
        release: Double = 0.15,
        cutoffHz: Double = 8_000,
        resonance: Double = 0.1,
        gain: Double = 0.8
    ) {
        self.waveform = waveform
        self.attack = attack.clamped(to: Self.attackRange)
        self.decay = decay.clamped(to: Self.decayRange)
        self.sustain = sustain.clamped(to: Self.sustainRange)
        self.release = release.clamped(to: Self.releaseRange)
        self.cutoffHz = cutoffHz.clamped(to: Self.cutoffRange)
        self.resonance = resonance.clamped(to: Self.resonanceRange)
        self.gain = gain.clamped(to: Self.gainRange)
    }
}

public struct TimeSignature: Codable, Sendable, Equatable {
    public var beatsPerBar: Int
    public var beatUnit: Int

    public init(beatsPerBar: Int = 4, beatUnit: Int = 4) {
        self.beatsPerBar = max(1, beatsPerBar)
        self.beatUnit = max(1, beatUnit)
    }
}

public struct TransportState: Codable, Sendable, Equatable {
    public var isPlaying: Bool
    public var isRecording: Bool
    /// Playhead position in beats from project start.
    public var positionBeats: Double
    public var tempoBPM: Double
    public var timeSignature: TimeSignature
    /// When true, playback wraps from `loopEndBeat` back to `loopStartBeat`.
    public var isLoopEnabled: Bool
    /// Loop region start, in beats.
    public var loopStartBeat: Double
    /// Loop region end, in beats. Kept at least `minLoopLengthBeats` past the start.
    public var loopEndBeat: Double
    /// When true, a `record()` take keeps ONLY the audio captured inside
    /// [`punchInBeat`, `punchOutBeat`]; transport and capture still start from
    /// the current position.
    public var isPunchEnabled: Bool
    /// Punch window start, in beats.
    public var punchInBeat: Double
    /// Punch window end, in beats. Kept at least `minPunchLengthBeats` past the start.
    public var punchOutBeat: Double
    /// When true, playback ticks a metronome click. v0: the engine reads this
    /// at each start/restart — toggling while playing goes through the store's
    /// seek/restart path so it still takes effect audibly.
    public var isMetronomeEnabled: Bool
    /// Bars of count-in clicks before a `record()` take begins, clamped to
    /// `countInBarsRange`. Count-in implies clicks: they sound even when the
    /// metronome itself is disabled.
    public var countInBars: Int

    /// The project's TEMPO MAP when it is non-trivial (m12-d) — nil for a
    /// single-tempo project, where `tempoMap` (TempoMap.swift) synthesizes the
    /// trivial single-segment map from `tempoBPM`. `tempoBPM` stays authoritative
    /// for segment 0 (the store keeps the two in sync at mutation time). Held on
    /// `TransportState` so every engine consumer that already reads
    /// `transport.tempoMap` sees it for free. EXCLUDED from `CodingKeys` — this
    /// struct's synthesized Codable is the snapshot's `transport` payload AND the
    /// document's scalar transport shape, both of which must stay byte-identical
    /// for a trivial project; the map persists instead as the ProjectDocument
    /// TOP-LEVEL `tempoMap` field and is surfaced by the top-level snapshot
    /// `tempoMap` field (the markers precedent). It IS undoable: it rides
    /// `EditState.transport`, so a `tempo.setMap` mutation journals and undo
    /// restores it exactly. Reset with the transport on project open/new.
    public var tempoMapOverride: TempoMap? = nil

    /// The project's METER MAP when it is non-trivial (m12-d) — the meter twin
    /// of `tempoMapOverride`; nil for a single-time-signature project, where
    /// `meterMap` synthesizes the trivial map from `timeSignature` (authoritative
    /// for change 0). Same excluded-from-Codable / top-level-persist / undoable
    /// story as `tempoMapOverride`.
    public var meterMapOverride: MeterMap? = nil

    /// Wire/persist surface = exactly the scalar transport keys. The synthesized
    /// Codable uses this enum, so `tempoMapOverride`/`meterMapOverride` never
    /// leak into a snapshot's `transport`, a broadcast, or a document's
    /// `TransportDocument` — they ride the document/snapshot TOP level instead
    /// (the markers precedent), keeping a trivial project byte-identical.
    private enum CodingKeys: String, CodingKey {
        case isPlaying, isRecording, positionBeats, tempoBPM, timeSignature
        case isLoopEnabled, loopStartBeat, loopEndBeat
        case isPunchEnabled, punchInBeat, punchOutBeat
        case isMetronomeEnabled, countInBars
    }

    public static let tempoRange: ClosedRange<Double> = 20...400
    /// Count-in length bound — more than 4 bars of pre-roll is never useful.
    public static let countInBarsRange: ClosedRange<Int> = 0...4
    /// A loop can never be shorter than this — guards against a zero/negative
    /// region that would make the wrap logic thrash.
    public static let minLoopLengthBeats: Double = 0.25
    /// A punch window can never be shorter than this — same guard as the loop
    /// region.
    public static let minPunchLengthBeats: Double = 0.25

    public init(
        isPlaying: Bool = false,
        isRecording: Bool = false,
        positionBeats: Double = 0,
        tempoBPM: Double = 120,
        timeSignature: TimeSignature = TimeSignature(),
        isLoopEnabled: Bool = false,
        loopStartBeat: Double = 0,
        loopEndBeat: Double = 16,
        isPunchEnabled: Bool = false,
        punchInBeat: Double = 0,
        punchOutBeat: Double = 4,
        isMetronomeEnabled: Bool = false,
        countInBars: Int = 0
    ) {
        self.isPlaying = isPlaying
        self.isRecording = isRecording
        self.positionBeats = max(0, positionBeats)
        self.tempoBPM = tempoBPM.clamped(to: Self.tempoRange)
        self.timeSignature = timeSignature
        self.isLoopEnabled = isLoopEnabled
        self.loopStartBeat = loopStartBeat
        self.loopEndBeat = max(loopEndBeat, loopStartBeat + Self.minLoopLengthBeats)
        self.isPunchEnabled = isPunchEnabled
        self.punchInBeat = punchInBeat
        self.punchOutBeat = max(punchOutBeat, punchInBeat + Self.minPunchLengthBeats)
        self.isMetronomeEnabled = isMetronomeEnabled
        self.countInBars = countInBars.clamped(to: Self.countInBarsRange)
    }

    public var positionSeconds: TimeInterval {
        tempoMap.seconds(fromBeatZeroTo: positionBeats)
    }

    /// 1-based "bar.beat" display, e.g. "3.2" for bar 3, beat 2.
    public var barsBeatsDisplay: String {
        let position = meterMap.barBeat(atBeat: positionBeats)
        return "\(position.bar + 1).\(Int(position.beatInBar) + 1)"
    }

    /// "m:ss.mmm" clock display of the playhead.
    public var clockDisplay: String {
        let total = positionSeconds
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }
}

/// Codable snapshot of the whole session — the payload of `project.snapshot`
/// on the control protocol and the state MCP agents orient from.
public struct ProjectSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var transport: TransportState
    public var tracks: [Track]
    /// Master output gain 0...2 (1 = unity), mirrored from `ProjectStore`.
    public var masterVolume: Double
    /// The MASTER insert chain (m13-d), mirrored from `ProjectStore` — the
    /// second mirror surface (the m12-f mirror-DTO discipline: descriptor
    /// Codable alone proves nothing; snapshot AND disk each carry the field
    /// explicitly). Default `[]` — always encoded, never optional.
    public var masterEffects: [EffectDescriptor]
    /// MASTER volume automation (m15-c), mirrored from `ProjectStore` — the
    /// snapshot leg of the m12-f triple-mirror discipline (store + snapshot +
    /// disk DTO each carry the field explicitly). Lane shape is EXACTLY the
    /// per-track `automation` shape ({id, target, points, isEnabled}) with the
    /// master as owner. Additive and optional; nil (key omitted) when there is
    /// no master lane, so a pre-m15-c snapshot stays byte-identical (the
    /// `grooveTemplates` rule).
    public var masterAutomation: [AutomationLane]?
    /// Project-level groove palette (M5 iii-g). Additive and optional; nil (key
    /// omitted) when the project has no grooves, so a pre-groove snapshot stays
    /// byte-identical. Built-in swing presets are NOT included — pull them via
    /// `groove.list`.
    public var grooveTemplates: [GrooveTemplate]?
    /// Session markers (m11-c), SORTED by beat. Additive and optional; nil (key
    /// omitted) when the session has no markers, so a pre-marker snapshot stays
    /// byte-identical. Full fidelity — id/name/beat — so an agent orienting from
    /// `project.snapshot` can seek to a section without a separate `marker.list`.
    public var markers: [Marker]?
    /// Non-trivial project TEMPO MAP segments (m12-d). Additive and optional;
    /// nil (key omitted) when the project has a single project-wide tempo, so a
    /// single-tempo snapshot stays byte-identical (the `markers` rule).
    /// `transport.tempoBPM` remains = segment 0's bpm. The always-present read is
    /// `tempo.map` (synthesizes a single segment for a trivial project); this
    /// field is the omit-when-trivial mirror for orient-from-snapshot.
    public var tempoMap: [TempoMap.Segment]?
    /// Non-trivial project METER MAP changes (m12-d) — the meter twin of
    /// `tempoMap`; nil (key omitted) for a single-time-signature project.
    public var meterChanges: [MeterMap.Change]?
    public var meters: SessionMeters
    /// Human-readable reason the last record attempt failed (or why the last
    /// take was discarded); nil when the last attempt succeeded. Additive and
    /// optional so older snapshots still decode.
    public var lastRecordingError: String?
    /// UID of the input device pinned for recording; nil = system default.
    /// Additive and optional so older snapshots still decode.
    public var selectedInputDeviceUID: String?
    /// Absolute path of the `.dawproj` bundle this session lives in; nil until
    /// the session is first saved (untitled).
    public var projectPath: String?
    /// True when the session has unsaved edits since the last save/open.
    public var isDirty: Bool
    /// Label of the operation `edit.undo` would reverse (e.g. "Add Track
    /// 'Vox'"); nil when there is nothing to undo. Presence IS `canUndo` on the
    /// wire. Additive and optional so older snapshots still decode.
    public var undoLabel: String?
    /// Label of the operation `edit.redo` would reapply; nil when there is
    /// nothing to redo. Presence IS `canRedo` on the wire. Additive and
    /// optional so older snapshots still decode.
    public var redoLabel: String?
    /// MIDI input sources as the engine enumerates them (hot-plug refreshes
    /// the list); nil when running headless. Additive and optional so older
    /// snapshots still decode.
    public var midiInputs: [MIDIInputDevice]?
    /// Monotonic count of live MIDI note events received — agents poll the
    /// delta to detect activity. Additive and optional.
    public var midiEventCount: Int?
    /// Engine notices (m15-e): schedule-time degradations coalesced by code —
    /// see `EngineNotice`. Session-transient (NEVER persisted to disk; the
    /// project file knows nothing of them) and untouched by undo/redo.
    /// Additive and optional; nil (key omitted) when the ring is empty, so a
    /// clean session's snapshot stays byte-identical (the `masterAutomation`
    /// rule).
    public var engineNotices: [EngineNotice]?
    /// Reference-track slot (m22-g), mirrored from `ProjectStore.reference`
    /// — the snapshot leg of the m12-f three-surface mirror-DTO discipline
    /// (store + snapshot + disk DTO land together, never drift). Additive
    /// and optional; nil (key omitted) when no reference is loaded, so a
    /// pre-m22-g snapshot stays byte-identical. Carries the SLOT ONLY —
    /// the transient A/B monitor state is never snapshotted (the
    /// transient-state law; read it via `reference.status`).
    public var reference: ReferenceSlot?

    public init(
        name: String,
        transport: TransportState,
        tracks: [Track],
        masterVolume: Double = 1,
        masterEffects: [EffectDescriptor] = [],
        masterAutomation: [AutomationLane]? = nil,
        grooveTemplates: [GrooveTemplate]? = nil,
        markers: [Marker]? = nil,
        tempoMap: [TempoMap.Segment]? = nil,
        meterChanges: [MeterMap.Change]? = nil,
        meters: SessionMeters = SessionMeters(),
        lastRecordingError: String? = nil,
        selectedInputDeviceUID: String? = nil,
        projectPath: String? = nil,
        isDirty: Bool = false,
        undoLabel: String? = nil,
        redoLabel: String? = nil,
        midiInputs: [MIDIInputDevice]? = nil,
        midiEventCount: Int? = nil,
        engineNotices: [EngineNotice]? = nil,
        reference: ReferenceSlot? = nil
    ) {
        self.name = name
        self.transport = transport
        self.tracks = tracks
        self.masterVolume = masterVolume
        self.masterEffects = masterEffects
        // Empty master automation → nil so the encoder omits the key
        // (pre-m15-c snapshots stay byte-identical — the grooveTemplates rule).
        self.masterAutomation = (masterAutomation?.isEmpty ?? true) ? nil : masterAutomation
        // Empty palette → nil so the encoder omits the key (pre-groove snapshots
        // stay byte-identical).
        self.grooveTemplates = (grooveTemplates?.isEmpty ?? true) ? nil : grooveTemplates
        // Empty marker list → nil so the encoder omits the key (pre-marker
        // snapshots stay byte-identical — the grooveTemplates rule).
        self.markers = (markers?.isEmpty ?? true) ? nil : markers
        // Tempo/meter maps (m12-d): passed as the non-trivial override's
        // segments/changes (nil for a trivial project) → the encoder omits the
        // keys, keeping a single-tempo snapshot byte-identical.
        self.tempoMap = (tempoMap?.isEmpty ?? true) ? nil : tempoMap
        self.meterChanges = (meterChanges?.isEmpty ?? true) ? nil : meterChanges
        self.meters = meters
        self.lastRecordingError = lastRecordingError
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.projectPath = projectPath
        self.isDirty = isDirty
        self.undoLabel = undoLabel
        self.redoLabel = redoLabel
        self.midiInputs = midiInputs
        self.midiEventCount = midiEventCount
        // Empty notices ring → nil so the encoder omits the key (a clean
        // session's snapshot stays byte-identical — the masterAutomation rule).
        self.engineNotices = (engineNotices?.isEmpty ?? true) ? nil : engineNotices
        // No reference → key omitted (pre-m22-g snapshots stay byte-identical).
        self.reference = reference
    }
}

/// Result of a `project.save` — the bundle path written, how many media files
/// were copied in, and any non-fatal warnings (e.g. a missing source that was
/// saved without media). Exactly the wire shape the control protocol returns.
public struct ProjectSaveResult: Codable, Sendable, Equatable {
    public var path: String
    public var mediaFilesCopied: Int
    public var warnings: [String]

    public init(path: String, mediaFilesCopied: Int, warnings: [String]) {
        self.path = path
        self.mediaFilesCopied = mediaFilesCopied
        self.warnings = warnings
    }
}

/// Result of a `render.mixdown` bounce — where the WAV landed plus its audio
/// facts, exactly the wire shape the control protocol returns.
public struct MixdownResult: Codable, Sendable, Equatable {
    /// Absolute filesystem path of the written WAV.
    public var path: String
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channels: Int

    public init(path: String, durationSeconds: Double, sampleRate: Double, channels: Int) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Master + per-track meter levels as captured at snapshot time. Track keys
/// are UUID `uuidString`s — String keys deliberately, because Swift encodes
/// `[UUID:]` dictionaries as flat arrays, which agents can't index into.
public struct SessionMeters: Codable, Sendable, Equatable {
    public var master: MeterFrame
    public var tracks: [String: MeterFrame]

    public init(master: MeterFrame = .silence, tracks: [String: MeterFrame] = [:]) {
        self.master = master
        self.tracks = tracks
    }
}

/// One master-mix analysis snapshot (M8 vm-a, "session vibe meter"),
/// published from the audio engine at UI rate alongside the meters and
/// polled by the app / `mixer.masterAnalysis`. Every field is FINITE by
/// contract (floor-clamped — JSON has no NaN/Inf); a stopped or silent
/// session decays to `.floor`.
public struct MasterAnalysisSnapshot: Codable, Sendable, Equatable {
    /// Number of spectral bands (24 log-spaced, 40 Hz → 16 kHz).
    public static let bandCount = 24
    /// dB floor shared by `bands`, `levelDB`, and `peakDB`.
    public static let floorDB: Float = -80

    /// Per-band energy in dB (floor −80), 24 log-spaced bands 40 Hz → 16 kHz.
    public var bands: [Float]
    /// Short-term RMS level of the master mix, dB (floor −80). NOT LUFS —
    /// use `render.measureLoudness` for gated BS.1770 loudness.
    public var levelDB: Float
    /// Held sample peak, dB (floor −80), −20 dB/s release.
    public var peakDB: Float
    /// Spectral centroid ("brightness"), Hz; 0 when silent.
    public var centroidHz: Float
    /// Normalized spectral flux 0–1 ("energy movement" between frames);
    /// 0 when silent or steady-state.
    public var flux: Float
    /// L/R correlation coefficient −1…+1 (m22-d): +1 = identical channels
    /// (mono-safe), 0 = fully decorrelated, −1 = perfectly inverted (the mix
    /// CANCELS when summed to mono). ~300 ms integration. FLOOR is +1.0 —
    /// silence, mono, and 1-channel sessions contain nothing out of phase,
    /// so "no evidence of a phase problem" honestly reads +1, never 0
    /// (0 would claim decorrelation that isn't there). A dead channel
    /// (hard-panned mono source) also reads +1: mono-summing it loses no
    /// content to cancellation, which is the question this meter answers.
    public var correlation: Float
    /// Stereo width 0…1 (m22-d): side energy over total mid+side energy,
    /// S²/(M²+S²). 0 = pure mono, 0.5 = uncorrelated (or a hard-panned
    /// single channel), 1 = pure anti-phase (all side, no mid). Floor 0.
    public var width: Float
    /// L/R energy balance −1…+1 (m22-d): (R²−L²)/(L²+R²) — the normalized
    /// mid·side cross-term expressed in pan-knob direction. −1 = all left,
    /// 0 = balanced, +1 = all right. Floor 0 (a silent image is centered).
    public var balance: Float

    /// New m22-d params default to the stereo floors so pre-m22-d call
    /// sites compile unchanged (additive-fields law).
    public init(bands: [Float], levelDB: Float, peakDB: Float,
                centroidHz: Float, flux: Float,
                correlation: Float = 1, width: Float = 0, balance: Float = 0) {
        self.bands = bands
        self.levelDB = levelDB
        self.peakDB = peakDB
        self.centroidHz = centroidHz
        self.flux = flux
        self.correlation = correlation
        self.width = width
        self.balance = balance
    }

    /// Additive-decode compatibility (m22-d): JSON produced before the
    /// stereo fields existed decodes to the stereo floors instead of
    /// throwing. Encoding stays synthesized — the new keys ALWAYS ride the
    /// wire alongside the byte-stable original fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bands = try container.decode([Float].self, forKey: .bands)
        levelDB = try container.decode(Float.self, forKey: .levelDB)
        peakDB = try container.decode(Float.self, forKey: .peakDB)
        centroidHz = try container.decode(Float.self, forKey: .centroidHz)
        flux = try container.decode(Float.self, forKey: .flux)
        correlation = try container.decodeIfPresent(Float.self, forKey: .correlation) ?? 1
        width = try container.decodeIfPresent(Float.self, forKey: .width) ?? 0
        balance = try container.decodeIfPresent(Float.self, forKey: .balance) ?? 0
    }

    /// The all-floors snapshot: what stopped/silent/engine-less sessions
    /// read. Stereo floors are correlation +1 (nothing out of phase — see
    /// `correlation`), width 0 (mono), balance 0 (centered).
    public static let floor = MasterAnalysisSnapshot(
        bands: [Float](repeating: floorDB, count: bandCount),
        levelDB: floorDB, peakDB: floorDB, centroidHz: 0, flux: 0,
        correlation: 1, width: 0, balance: 0)
}

/// One goniometer/vectorscope frame (m22-d): the most recent DECIMATED L/R
/// sample pairs from the master tap, oldest → newest, for the phase-scope
/// view. Deliberately NOT part of `MasterAnalysisSnapshot` and NOT on the
/// always-on `mixer.masterAnalysis` wire payload (512 floats at poll rate
/// would bloat it) — the app polls it in-process through
/// `AudioEngineProtocol.masterScopeFrame()` / `ProjectStore.masterScopeFrame()`
/// (the engine-side-accessor choice; a debug-tier wire command can be added
/// later if captures need one). Every sample is finite by contract; slots
/// the ring has not filled yet read 0 (the scope's center point).
public struct MasterScopeFrame: Codable, Sendable, Equatable {
    /// Ring capacity: 256 pairs. At the analyzer's fixed ×8 decimation this
    /// spans ~43 ms at 48 kHz — a few cycles of anything above ~50 Hz.
    public static let pairCount = 256

    /// Left-channel samples, oldest → newest, `pairCount` entries.
    public var left: [Float]
    /// Right-channel samples, oldest → newest, `pairCount` entries
    /// (== `left` for mono/1-channel sessions).
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    /// The all-zero frame: fresh engines, fakes, headless sessions.
    public static let empty = MasterScopeFrame(
        left: [Float](repeating: 0, count: pairCount),
        right: [Float](repeating: 0, count: pairCount))
}

/// Engine render-performance telemetry (M9 perf-b): render-load / overrun
/// counters accumulated per render callback by the engine's two Tier-1
/// workhorses (instrument source nodes and per-strip chain hosts — their sum
/// ≈ the engine's own DSP work; AVFoundation-internal work is not measured).
/// Offline renders count too, so headless bounces are profilable. Every
/// field is FINITE by contract (JSON has no NaN/Inf); a stopped engine
/// freezes the counters but the snapshot stays readable. Counters are a
/// WINDOW: since engine start or the last `reset` (`engine.performanceStats`
/// with `reset: true` returns the closing window and starts a fresh one —
/// the windowed-profiling idiom).
public struct EnginePerformanceStats: Codable, Sendable, Equatable {
    /// Render callbacks observed in this window (each instrumented block
    /// counts once per quantum, so this scales with strip count).
    public var callbackCount: Int
    /// Frames rendered in this window, summed across instrumented blocks —
    /// one engine quantum of N frames through K blocks adds K × N.
    public var renderedFrames: Int
    /// Wall-clock nanoseconds spent inside instrumented render callbacks,
    /// accumulated over the window.
    public var renderTimeNs: Int
    /// Slowest single callback in the window, nanoseconds.
    public var peakCallbackNs: Int
    /// Callbacks whose elapsed time exceeded their own quantum's real-time
    /// budget (frames / sampleRate). A budget-overrun PROXY, not a CoreAudio
    /// xrun observation (AVAudioEngine exposes no xrun count): one block
    /// alone ate a whole quantum's budget — the true overload threshold is
    /// the sum of all blocks, so treat any nonzero value as trouble.
    public var overrunCount: Int
    /// renderTimeNs / the window's accumulated per-callback budget — the
    /// average fraction of its real-time budget each instrumented callback
    /// consumed (0 = idle, 1.0 = callbacks on average ate their whole
    /// quantum). Derived reader-side, never on the render thread.
    public var averageLoad: Double
    /// One-pole EMA of the per-callback load (~1 s time constant at
    /// 512-frame quanta on one block; N blocks shorten it to ~1/N s) — the
    /// "load right now" feel to averageLoad's calibrated integral.
    public var recentLoad: Double
    /// Sample rate (Hz) of the most recent instrumented callback; 0 until
    /// anything has rendered.
    public var sampleRate: Double
    /// Frame count of the most recent instrumented callback (the typical
    /// render quantum); 0 until anything has rendered.
    public var quantumFrames: Int
    /// Seconds since this window opened (engine start or last reset).
    public var sinceResetSeconds: Double

    public init(callbackCount: Int, renderedFrames: Int, renderTimeNs: Int,
                peakCallbackNs: Int, overrunCount: Int, averageLoad: Double,
                recentLoad: Double, sampleRate: Double, quantumFrames: Int,
                sinceResetSeconds: Double) {
        self.callbackCount = callbackCount
        self.renderedFrames = renderedFrames
        self.renderTimeNs = renderTimeNs
        self.peakCallbackNs = peakCallbackNs
        self.overrunCount = overrunCount
        self.averageLoad = averageLoad
        self.recentLoad = recentLoad
        self.sampleRate = sampleRate
        self.quantumFrames = quantumFrames
        self.sinceResetSeconds = sinceResetSeconds
    }

    /// The all-zero snapshot: engines without telemetry (fakes, headless
    /// stores) and freshly reset windows before any render work.
    public static let idle = EnginePerformanceStats(
        callbackCount: 0, renderedFrames: 0, renderTimeNs: 0,
        peakCallbackNs: 0, overrunCount: 0, averageLoad: 0, recentLoad: 0,
        sampleRate: 0, quantumFrames: 0, sinceResetSeconds: 0)
}

/// Engine watchdog state (M9 crash-c): the stall-detector's view of the
/// render side, surfaced over `engine.watchdogStatus`. The watchdog reads
/// the perf-b telemetry heartbeat (a lifetime-monotone callback counter):
/// while the engine claims to be running that counter must advance every
/// check window, so a frozen heartbeat across consecutive checks means the
/// render side is dead (HAL stall, device death without a configuration-
/// change notification) and the watchdog drives the same auto-restart the
/// config-change path uses. Simple, always-finite types by contract.
public struct EngineWatchdogStatus: Codable, Sendable, Equatable {
    /// Watchdog state machine position, encoded as a plain JSON string.
    public enum State: String, Codable, Sendable {
        /// Engine intentionally stopped (or headless / no heartbeat signal
        /// expected) — an idle engine is NOT a stall; nothing to watch.
        case idle
        /// Engine running and the heartbeat advanced on the last check.
        case ok
        /// Stall declared; an auto-restart attempt is in progress (or has
        /// failed fewer than the give-up threshold of times and will retry).
        case recovering
        /// Auto-restart failed repeatedly; the watchdog stands down until a
        /// later successful engine start re-arms it. Manual intervention.
        case failed
    }

    public var state: State
    /// Lifetime count of successful watchdog auto-restarts. Nonzero means
    /// the engine died and self-healed at least once this session.
    public var restartCount: Int
    /// Consecutive failed restart attempts in the CURRENT stall (resets when
    /// a heartbeat advances); reaching the give-up threshold flips `failed`.
    public var consecutiveFailures: Int
    /// The heartbeat value (lifetime render-callback count) the watchdog saw
    /// on its most recent check; 0 before anything has rendered.
    public var lastHeartbeat: Int
    /// The engine's own running claim at read time (the protocol surface's
    /// `isRunning`, not the watchdog's armed view).
    public var engineRunning: Bool

    public init(state: State, restartCount: Int, consecutiveFailures: Int,
                lastHeartbeat: Int, engineRunning: Bool) {
        self.state = state
        self.restartCount = restartCount
        self.consecutiveFailures = consecutiveFailures
        self.lastHeartbeat = lastHeartbeat
        self.engineRunning = engineRunning
    }

    /// The zero/idle default: engines without a watchdog (fakes, headless
    /// stores) and fresh engines before their first start.
    public static let idle = EngineWatchdogStatus(
        state: .idle, restartCount: 0, consecutiveFailures: 0,
        lastHeartbeat: 0, engineRunning: false)
}

/// Wire-facing result of writing one local diagnostics bundle (M9 beta): the
/// receipt a tester (or an agent) gets back after `app.feedbackBundle`. Points
/// at the folder to attach to a bug report and summarizes what landed in it —
/// enough for a client to say "wrote N files (M crashes), share this folder"
/// without re-scanning the disk. Value type; `Codable`/`Sendable`. See
/// `DiagnosticsReporter` for the bundle layout and privacy rationale.
public struct FeedbackBundleSummary: Codable, Sendable, Equatable {
    /// Absolute path to the `feedback-<timestamp>/` folder just written.
    public var path: String
    /// Total regular files in the bundle (manifest/engine/overview + any
    /// crash reports + any opted-in project snapshot files).
    public var fileCount: Int
    /// Total bytes of those files.
    public var byteCount: Int
    /// Recent `DAWApp*.ips` crash reports copied into `crashes/`.
    public var crashReportCount: Int
    /// Whether the full project snapshot was included (the opt-in toggle).
    public var includesProject: Bool

    public init(path: String, fileCount: Int, byteCount: Int,
                crashReportCount: Int, includesProject: Bool) {
        self.path = path
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.crashReportCount = crashReportCount
        self.includesProject = includesProject
    }
}

/// One frame of output metering, published from the audio engine at UI rate.
public struct MeterFrame: Codable, Sendable, Equatable {
    /// Linear peak 0...1+ (>1 means clipping).
    public var peak: Float
    /// Linear RMS 0...1.
    public var rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    public static let silence = MeterFrame(peak: 0, rms: 0)
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
