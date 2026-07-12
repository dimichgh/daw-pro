import Foundation

/// On-disk, versioned representation of a session — the payload of a `.dawproj`
/// bundle's `project.json`. Deliberately SEPARATE from the runtime types
/// (`ProjectSnapshot`, `TransportState`, `Track`): the wire/UI snapshot and the
/// persistence schema evolve independently, and only the persistable facts live
/// here. Transient runtime state (isPlaying/isRecording, meters, last recording
/// error, selected input device) is never modeled, so it can never be written.
///
/// Additive optional fields → decode with `decodeIfPresent` + a default, no
/// version bump (see `ProjectBundle` migration seam for breaking changes).
public struct ProjectDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var savedAt: Date
    public var name: String
    public var masterVolume: Double
    public var transport: TransportDocument
    public var tracks: [TrackDocument]
    /// Project-level groove palette (M5 iii-g). Additive and optional; nil when
    /// the project has no grooves (an EMPTY palette is stored as nil so the key
    /// is omitted on encode and a pre-groove project stays byte-identical — the
    /// `sends`/`takeGroups` omit-when-empty rule, no schemaVersion bump).
    /// `GrooveTemplate` is reused directly (like `TrackDocument.automation`): it
    /// carries no media/URLs, so its Codable IS the disk shape.
    public var grooveTemplates: [GrooveTemplate]?
    /// Session markers (m11-c). Additive and optional; nil when the project has
    /// no markers (an EMPTY array is stored as nil so the key is omitted on encode
    /// and a pre-marker project stays byte-identical — the `grooveTemplates`/
    /// `sends`/`takeGroups` omit-when-empty rule, no schemaVersion bump). `Marker`
    /// is reused directly (like `grooveTemplates`): it carries no media/URLs, so
    /// its Codable IS the disk shape.
    public var markers: [Marker]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt, name, masterVolume, transport, tracks, grooveTemplates, markers
    }

    /// Builds a document from runtime state. `mediaRefs` maps each clip id to
    /// its persisted media reference (`"media/<name>"`, an absolute path for
    /// recovery bundles, or nil for "no media") — produced by
    /// `ProjectBundle.planMedia`.
    public init(
        name: String,
        transport: TransportState,
        tracks: [Track],
        masterVolume: Double,
        mediaRefs: [UUID: String?],
        grooveTemplates: [GrooveTemplate] = [],
        markers: [Marker] = []
    ) {
        self.schemaVersion = ProjectBundle.currentSchemaVersion
        self.savedAt = Date()
        self.name = name
        self.masterVolume = masterVolume
        self.transport = TransportDocument(from: transport)
        self.tracks = tracks.map { TrackDocument(from: $0, mediaRefs: mediaRefs) }
        // Empty palette persists as nil → the synthesized `encodeIfPresent`
        // omits the key, keeping a pre-groove project byte-identical.
        self.grooveTemplates = grooveTemplates.isEmpty ? nil : grooveTemplates
        // Empty markers persist as nil (same rule) → a pre-marker project stays
        // byte-identical.
        self.markers = markers.isEmpty ? nil : markers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field tolerates absence (defaults) so additive changes never
        // force a version bump. `read()` validates schemaVersion before we
        // ever get here, so the ?? 1 is belt-and-suspenders.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Session"
        masterVolume = try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 1
        transport = try c.decodeIfPresent(TransportDocument.self, forKey: .transport) ?? TransportDocument()
        tracks = try c.decodeIfPresent([TrackDocument].self, forKey: .tracks) ?? []
        // Additive optional (M5 iii-g): a pre-groove project has no key → nil.
        grooveTemplates = try c.decodeIfPresent([GrooveTemplate].self, forKey: .grooveTemplates)
        // Additive optional (m11-c): a pre-marker project has no key → nil.
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers)
    }

    /// Restores runtime state, resolving each clip's media reference against
    /// `bundleURL`. Relative refs must live under `media/` and never escape it
    /// (a `..` or non-`media/` ref is dropped with a warning); absolute refs
    /// are accepted verbatim (the recovery contract); a `media/` ref whose file
    /// is missing keeps the clip pointed at the (nonexistent) URL plus a
    /// warning. All runtime objects are rebuilt through their PUBLIC inits, so
    /// value clamps re-apply on load.
    public func runtimeState(
        bundleURL: URL
    ) -> (tracks: [Track], transport: TransportState, masterVolume: Double, warnings: [String]) {
        var warnings: [String] = []
        // Valid routing destinations are exactly the bus tracks in this document.
        let busIDs = Set(tracks.filter { $0.kind == .bus }.map(\.id))
        let runtimeTracks = tracks.map { td -> Track in
            let clips = td.clips.map { cd -> Clip in
                let (url, warning) = Self.resolveMedia(cd.media, label: "clip '\(cd.name)'", bundleURL: bundleURL)
                if let warning { warnings.append(warning) }
                return Clip(
                    id: cd.id,
                    name: cd.name,
                    startBeat: cd.startBeat,
                    lengthBeats: cd.lengthBeats,
                    audioFileURL: url,
                    notes: cd.notes,
                    isAIGenerated: cd.isAIGenerated,
                    // Edit fields (M5 i-a): absent keys read as the model default;
                    // values re-clamp through `Clip.init`.
                    startOffsetSeconds: cd.startOffsetSeconds ?? 0,
                    gainDb: cd.gainDb ?? 0,
                    fadeInBeats: cd.fadeInBeats ?? 0,
                    fadeOutBeats: cd.fadeOutBeats ?? 0,
                    fadeInCurve: cd.fadeInCurve ?? .linear,
                    fadeOutCurve: cd.fadeOutCurve ?? .linear,
                    // Stretch fields (M5 ii-c): absent keys read as the model
                    // default; values re-clamp through `Clip.init`.
                    stretchRatio: cd.stretchRatio ?? 1,
                    pitchShiftSemitones: cd.pitchShiftSemitones ?? 0,
                    formantPreserve: cd.formantPreserve ?? false,
                    // Take-group marker (M5 iii-a): restores comp members as
                    // store-managed clips; nil for ordinary clips.
                    takeGroupID: cd.takeGroupId
                )
            }
            let instrument = td.instrument.map { instDoc in
                instDoc.instrumentDescriptor(bundleURL: bundleURL) { warnings.append($0) }
            }
            // Sanitize routing (mirrors the media-warning policy): a bus track
            // carries no routing in v0 (stripped with a warning); a source track's
            // dangling output falls back to master and sends with a destination
            // that isn't a live bus are dropped — each with a warning.
            var outputBusID = td.outputBusId
            var sends: [Send] = []
            if td.kind == .bus {
                if td.outputBusId != nil || !(td.sends ?? []).isEmpty {
                    warnings.append("routing fields on bus track '\(td.name)' — stripped (buses output to master in v0)")
                }
                outputBusID = nil
            } else {
                for sd in td.sends ?? [] {
                    if busIDs.contains(sd.busId) {
                        sends.append(Send(id: sd.id, destinationBusID: sd.busId, level: sd.level))
                    } else {
                        warnings.append("unknown send bus for track '\(td.name)' — send dropped")
                    }
                }
                if let ob = outputBusID, !busIDs.contains(ob) {
                    warnings.append("unknown output bus for track '\(td.name)' — routed to master")
                    outputBusID = nil
                }
            }
            // Resolve the insert chain (M4 ii): an effect whose stored `kind`
            // string isn't a kind THIS build knows is DROPPED with a warning
            // (forward-compat with iii/iv files, the unresolvable-zone policy);
            // the rest rebuild through the model init (value clamps re-apply).
            let effects: [EffectDescriptor] = (td.effects ?? []).compactMap { ed in
                guard let effect = ed.effectDescriptor() else {
                    warnings.append("unknown effect kind '\(ed.kind)' on track '\(td.name)' — effect dropped")
                    return nil
                }
                return effect
            }
            // Take groups (M5 iii-a): each lane payload's media ref resolves
            // against the bundle, mirroring clip media (missing → silent URL +
            // warning). The materialized comp members already ride in `clips`.
            let takeGroups: [TakeGroup] = (td.takeGroups ?? []).map { tgd in
                tgd.takeGroup(bundleURL: bundleURL) { warnings.append($0) }
            }
            return Track(
                id: td.id,
                name: td.name,
                kind: td.kind,
                volume: td.volume,
                pan: td.pan,
                isMuted: td.isMuted,
                isSoloed: td.isSoloed,
                isArmed: td.isArmed,
                isAIGenerated: td.isAIGenerated,
                clips: clips,
                instrument: instrument,
                outputBusID: outputBusID,
                sends: sends,
                effects: effects,
                // Automation lanes round-trip verbatim (a lane orphaned by a
                // dropped effect/send is inert — harmless, and healed by the
                // store's live cascades on the next edit).
                automation: td.automation ?? [],
                takeGroups: takeGroups
            )
        }
        return (runtimeTracks, transport.transportState(), masterVolume, warnings)
    }

    /// Resolves one persisted media reference to a runtime URL. Returns the URL
    /// (or nil when the item should be silent) and an optional warning. `label`
    /// is the noun phrase used in warnings (e.g. "clip 'Vox'" or "sampler zone")
    /// so the same resolver serves both clip media and sampler zones.
    static func resolveMedia(
        _ ref: String?, label: String, bundleURL: URL
    ) -> (URL?, String?) {
        guard let ref, !ref.isEmpty else { return (nil, nil) }
        if ref.hasPrefix("/") {
            // Absolute reference — recovery bundles record these. Accept as-is;
            // the original file is the take on disk, outside any bundle.
            return (URL(fileURLWithPath: ref), nil)
        }
        // Relative references must stay inside media/ and never climb out.
        if ref.contains("..") || !ref.hasPrefix("media/") {
            return (nil, "invalid media reference '\(ref)' for \(label) — ignored")
        }
        let resolved = bundleURL.appendingPathComponent(ref)
        if !FileManager.default.fileExists(atPath: resolved.path) {
            // Keep the item and its resolved URL so a later re-link (or the file
            // reappearing) heals it; today it simply plays silent.
            return (resolved, "missing media: \(ref) — \(label) will be silent")
        }
        return (resolved, nil)
    }
}

/// Persistable transport facts. DROPS `isPlaying`/`isRecording` by construction
/// — there are no such fields, so a saved session can never resurrect a
/// rolling transport.
public struct TransportDocument: Codable, Sendable, Equatable {
    public var positionBeats: Double
    public var tempoBPM: Double
    public var timeSignature: TimeSignature
    public var isLoopEnabled: Bool
    public var loopStartBeat: Double
    public var loopEndBeat: Double
    public var isPunchEnabled: Bool
    public var punchInBeat: Double
    public var punchOutBeat: Double
    public var isMetronomeEnabled: Bool
    public var countInBars: Int

    private enum CodingKeys: String, CodingKey {
        case positionBeats, tempoBPM, timeSignature
        case isLoopEnabled, loopStartBeat, loopEndBeat
        case isPunchEnabled, punchInBeat, punchOutBeat
        case isMetronomeEnabled, countInBars
    }

    /// Default document = a fresh transport's persistable fields.
    public init() { self.init(from: TransportState()) }

    public init(from t: TransportState) {
        positionBeats = t.positionBeats
        tempoBPM = t.tempoBPM
        timeSignature = t.timeSignature
        isLoopEnabled = t.isLoopEnabled
        loopStartBeat = t.loopStartBeat
        loopEndBeat = t.loopEndBeat
        isPunchEnabled = t.isPunchEnabled
        punchInBeat = t.punchInBeat
        punchOutBeat = t.punchOutBeat
        isMetronomeEnabled = t.isMetronomeEnabled
        countInBars = t.countInBars
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TransportState()  // defaults for any absent field
        positionBeats = try c.decodeIfPresent(Double.self, forKey: .positionBeats) ?? d.positionBeats
        tempoBPM = try c.decodeIfPresent(Double.self, forKey: .tempoBPM) ?? d.tempoBPM
        timeSignature = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? d.timeSignature
        isLoopEnabled = try c.decodeIfPresent(Bool.self, forKey: .isLoopEnabled) ?? d.isLoopEnabled
        loopStartBeat = try c.decodeIfPresent(Double.self, forKey: .loopStartBeat) ?? d.loopStartBeat
        loopEndBeat = try c.decodeIfPresent(Double.self, forKey: .loopEndBeat) ?? d.loopEndBeat
        isPunchEnabled = try c.decodeIfPresent(Bool.self, forKey: .isPunchEnabled) ?? d.isPunchEnabled
        punchInBeat = try c.decodeIfPresent(Double.self, forKey: .punchInBeat) ?? d.punchInBeat
        punchOutBeat = try c.decodeIfPresent(Double.self, forKey: .punchOutBeat) ?? d.punchOutBeat
        isMetronomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .isMetronomeEnabled) ?? d.isMetronomeEnabled
        countInBars = try c.decodeIfPresent(Int.self, forKey: .countInBars) ?? d.countInBars
    }

    /// Rebuilds a runtime transport — always STOPPED (no play/record flags
    /// persisted) — through `TransportState.init`, so its range clamps re-apply.
    public func transportState() -> TransportState {
        TransportState(
            isPlaying: false,
            isRecording: false,
            positionBeats: positionBeats,
            tempoBPM: tempoBPM,
            timeSignature: timeSignature,
            isLoopEnabled: isLoopEnabled,
            loopStartBeat: loopStartBeat,
            loopEndBeat: loopEndBeat,
            isPunchEnabled: isPunchEnabled,
            punchInBeat: punchInBeat,
            punchOutBeat: punchOutBeat,
            isMetronomeEnabled: isMetronomeEnabled,
            countInBars: countInBars
        )
    }
}

/// Persistable track facts.
public struct TrackDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var volume: Double
    public var pan: Double
    public var isMuted: Bool
    public var isSoloed: Bool
    public var isArmed: Bool
    public var isAIGenerated: Bool
    public var clips: [ClipDocument]
    /// Selected built-in instrument (instrument tracks only). Additive and
    /// optional — a v1 project without the key decodes to nil, which the runtime
    /// reads as `InstrumentDescriptor.default`. Omitted on encode when nil, so an
    /// audio-only project stays byte-identical to a pre-instrument save. Uses a
    /// document type (not `InstrumentDescriptor`) so sampler-zone media persists
    /// as a bundle-relative `media/…` ref instead of a live URL — self-contained,
    /// like clips.
    public var instrument: InstrumentDocument?
    /// Mix-destination bus id (M4 i). Additive and optional; nil = master. Omitted
    /// on encode when nil, so a pre-routing project stays byte-identical.
    public var outputBusId: UUID?
    /// Post-fader sends (M4 i). Additive and optional; nil when the track has no
    /// sends (an EMPTY array is stored as nil so the key is omitted on encode and a
    /// pre-routing project stays byte-identical).
    public var sends: [SendDocument]?
    /// Insert-effect chain (M4 ii), in processing order. Additive and optional;
    /// nil when the track has no effects (an EMPTY chain is stored as nil so the
    /// key is omitted on encode and a pre-FX project stays byte-identical — the
    /// `sends` rule).
    public var effects: [EffectDocument]?
    /// Automation lanes (M4 vii). Additive and optional; nil when the track has
    /// no automation (an EMPTY collection is stored as nil so the key is omitted
    /// on encode and a pre-automation project stays byte-identical — the `sends`
    /// rule). `AutomationLane` is reused directly (like `ClipDocument.notes`
    /// reuses `MIDINote`): it carries no media/URLs and its Codable IS the
    /// disk shape.
    public var automation: [AutomationLane]?
    /// Take groups (M5 iii-a). Additive and optional; nil when the track has no
    /// takes (an EMPTY collection is stored as nil so the key is omitted on
    /// encode and a pre-take project stays byte-identical — the `sends` rule).
    /// Lane payloads persist as `TakeLaneDocument` so their media rides as a
    /// bundle-relative `media/…` ref (the clip/sampler-zone precedent).
    public var takeGroups: [TakeGroupDocument]?

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, volume, pan, isMuted, isSoloed, isArmed, isAIGenerated, clips, instrument
        case outputBusId, sends, effects, automation, takeGroups
    }

    init(from track: Track, mediaRefs: [UUID: String?]) {
        id = track.id
        name = track.name
        kind = track.kind
        volume = track.volume
        pan = track.pan
        isMuted = track.isMuted
        isSoloed = track.isSoloed
        isArmed = track.isArmed
        isAIGenerated = track.isAIGenerated
        instrument = track.instrument.map { InstrumentDocument(from: $0, mediaRefs: mediaRefs) }
        // mediaRefs[id] is String?? — flatten a present-but-nil ref (no media)
        // and an absent one both to "no media".
        clips = track.clips.map { ClipDocument(from: $0, media: mediaRefs[$0.id] ?? nil) }
        outputBusId = track.outputBusID
        // Empty sends persist as nil → the synthesized `encodeIfPresent` omits the
        // key, keeping a pre-routing project byte-identical.
        sends = track.sends.isEmpty ? nil : track.sends.map { SendDocument(from: $0) }
        // Empty effects persist as nil (same rule) → a pre-FX project stays
        // byte-identical.
        effects = track.effects.isEmpty ? nil : track.effects.map { EffectDocument(from: $0) }
        // Empty automation persists as nil (same rule) → a pre-automation project
        // stays byte-identical.
        automation = track.automation.isEmpty ? nil : track.automation
        // Empty take groups persist as nil (same rule) → a pre-take project
        // stays byte-identical.
        takeGroups = track.takeGroups.isEmpty
            ? nil
            : track.takeGroups.map { TakeGroupDocument(from: $0, mediaRefs: mediaRefs) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity is required — a missing id is a damaged file
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? .audio
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        isArmed = try c.decodeIfPresent(Bool.self, forKey: .isArmed) ?? false
        isAIGenerated = try c.decodeIfPresent(Bool.self, forKey: .isAIGenerated) ?? false
        clips = try c.decodeIfPresent([ClipDocument].self, forKey: .clips) ?? []
        // Additive optional: a pre-instrument (v1) track has no key → nil ⇒ default.
        instrument = try c.decodeIfPresent(InstrumentDocument.self, forKey: .instrument)
        // Additive optional (M4 i): a pre-routing track has neither key.
        outputBusId = try c.decodeIfPresent(UUID.self, forKey: .outputBusId)
        sends = try c.decodeIfPresent([SendDocument].self, forKey: .sends)
        // Additive optional (M4 ii): a pre-FX track has no key.
        effects = try c.decodeIfPresent([EffectDocument].self, forKey: .effects)
        // Additive optional (M4 vii): a pre-automation track has no key.
        automation = try c.decodeIfPresent([AutomationLane].self, forKey: .automation)
        // Additive optional (M5 iii-a): a pre-take track has no key.
        takeGroups = try c.decodeIfPresent([TakeGroupDocument].self, forKey: .takeGroups)
    }
}

/// Persistable send facts (M4 i) — mirrors `Send`. The destination bus id is
/// keyed `busId` on disk (same wire key as the model). `id`/`level` are
/// additive-optional with the model defaults; `busId` is required (a send with
/// no destination is meaningless — the runtime sanitizer drops any whose
/// destination isn't a bus).
public struct SendDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var busId: UUID
    public var level: Double

    private enum CodingKeys: String, CodingKey { case id, busId, level }

    init(from send: Send) {
        id = send.id
        busId = send.destinationBusID
        level = send.level
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        busId = try c.decode(UUID.self, forKey: .busId)
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 1
    }
}

/// Persistable insert-effect facts (M4 ii) — mirrors `EffectDescriptor`. `kind`
/// is stored as a RAW STRING (not the enum) so a file written by a later build,
/// carrying effect kinds this build doesn't know, still DECODES; the runtime
/// then DROPS any unknown-kind effect with a warning (forward-compat). `id` is
/// required (a missing id is a damaged file); `bypassed`/`gain` are additive-
/// optional with the model defaults.
public struct EffectDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: String
    public var bypassed: Bool?
    public var gain: GainParams?
    public var eq: EQParams?
    public var compressor: CompressorParams?
    public var limiter: LimiterParams?
    public var reverb: ReverbParams?
    public var delay: DelayParams?
    public var saturator: SaturatorParams?
    public var gate: GateParams?
    public var chorus: ChorusParams?
    /// Hosted Audio Unit selection + inlined state (stateData rides as base64
    /// through Codable's Data default) — the InstrumentDocument.audioUnit
    /// mirror. Additive optional: pre-M4 (v) files have no key and stay
    /// byte-identical across a round trip.
    public var audioUnit: AudioUnitConfig?

    private enum CodingKeys: String, CodingKey {
        case id, kind, bypassed, gain, eq, compressor, limiter
        case reverb, delay, saturator, gate, chorus, audioUnit
    }

    init(from effect: EffectDescriptor) {
        id = effect.id
        kind = effect.kind.rawValue
        // Store `bypassed` only when true (the false default is omitted), keeping
        // a never-bypassed effect compact.
        bypassed = effect.isBypassed ? true : nil
        // Store per-kind params only when the descriptor carries them.
        gain = effect.gain
        eq = effect.eq
        compressor = effect.compressor
        limiter = effect.limiter
        reverb = effect.reverb
        delay = effect.delay
        saturator = effect.saturator
        gate = effect.gate
        chorus = effect.chorus
        audioUnit = effect.audioUnit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity is required — a missing id is a damaged file
        kind = try c.decode(String.self, forKey: .kind)
        bypassed = try c.decodeIfPresent(Bool.self, forKey: .bypassed)
        gain = try c.decodeIfPresent(GainParams.self, forKey: .gain)
        eq = try c.decodeIfPresent(EQParams.self, forKey: .eq)
        compressor = try c.decodeIfPresent(CompressorParams.self, forKey: .compressor)
        limiter = try c.decodeIfPresent(LimiterParams.self, forKey: .limiter)
        reverb = try c.decodeIfPresent(ReverbParams.self, forKey: .reverb)
        delay = try c.decodeIfPresent(DelayParams.self, forKey: .delay)
        saturator = try c.decodeIfPresent(SaturatorParams.self, forKey: .saturator)
        gate = try c.decodeIfPresent(GateParams.self, forKey: .gate)
        chorus = try c.decodeIfPresent(ChorusParams.self, forKey: .chorus)
        audioUnit = try c.decodeIfPresent(AudioUnitConfig.self, forKey: .audioUnit)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        // Omit `bypassed` when nil/false and every param struct when nil, so a
        // defaults-only effect stays compact on disk (and pre-existing files
        // never grow keys they didn't carry).
        try c.encodeIfPresent(bypassed, forKey: .bypassed)
        try c.encodeIfPresent(gain, forKey: .gain)
        try c.encodeIfPresent(eq, forKey: .eq)
        try c.encodeIfPresent(compressor, forKey: .compressor)
        try c.encodeIfPresent(limiter, forKey: .limiter)
        try c.encodeIfPresent(reverb, forKey: .reverb)
        try c.encodeIfPresent(delay, forKey: .delay)
        try c.encodeIfPresent(saturator, forKey: .saturator)
        try c.encodeIfPresent(gate, forKey: .gate)
        try c.encodeIfPresent(chorus, forKey: .chorus)
        try c.encodeIfPresent(audioUnit, forKey: .audioUnit)
    }

    /// Rebuilds a runtime `EffectDescriptor`, routing params through the clamping
    /// init. Returns nil when `kind` is not a kind this build knows (forward-
    /// compat drop; the caller emits the warning).
    func effectDescriptor() -> EffectDescriptor? {
        guard let resolvedKind = EffectDescriptor.Kind(rawValue: kind) else { return nil }
        return EffectDescriptor(id: id, kind: resolvedKind,
                                isBypassed: bypassed ?? false, gain: gain,
                                eq: eq, compressor: compressor, limiter: limiter,
                                reverb: reverb, delay: delay, saturator: saturator,
                                gate: gate, chorus: chorus, audioUnit: audioUnit)
    }
}

/// Persistable instrument facts — mirrors `InstrumentDescriptor`, but each
/// sampler zone stores its media as a bundle-relative `media/…` string ref
/// (like `ClipDocument.media`) rather than a live URL, so a saved bundle is
/// self-contained and survives relocation. `sampler` is additive-optional: a
/// pre-sampler `{kind, polySynth}` instrument decodes with `sampler == nil`.
public struct InstrumentDocument: Codable, Sendable, Equatable {
    public var kind: InstrumentDescriptor.Kind
    public var polySynth: PolySynthParams
    public var sampler: SamplerDocument?
    /// Hosted Audio Unit selection + inlined state (stateData rides as base64
    /// through Codable's Data default). Additive optional — a pre-AU project
    /// has no key and stays byte-identical across a round trip.
    public var audioUnit: AudioUnitConfig?
    /// Sound-bank program selection (m10-n). Additive optional — a
    /// pre-soundBank project has no key and stays byte-identical across a
    /// round trip. `SoundBankConfig` persists directly (the AutomationLane
    /// rule): its source is the `"gm"` sentinel or an absolute path — bank
    /// files are deliberately NOT bundle media (design §4.2).
    public var soundBank: SoundBankConfig?

    private enum CodingKeys: String, CodingKey { case kind, polySynth, sampler, audioUnit, soundBank }

    init(from d: InstrumentDescriptor, mediaRefs: [UUID: String?]) {
        kind = d.kind
        polySynth = d.polySynth
        // Persist sampler only when the descriptor carries one (even empty
        // zones), preserving "was a sampler configured" across a round trip.
        sampler = d.sampler.map { SamplerDocument(from: $0, mediaRefs: mediaRefs) }
        audioUnit = d.audioUnit
        soundBank = d.soundBank
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InstrumentDescriptor.default
        kind = try c.decodeIfPresent(InstrumentDescriptor.Kind.self, forKey: .kind) ?? d.kind
        polySynth = try c.decodeIfPresent(PolySynthParams.self, forKey: .polySynth) ?? d.polySynth
        sampler = try c.decodeIfPresent(SamplerDocument.self, forKey: .sampler)
        audioUnit = try c.decodeIfPresent(AudioUnitConfig.self, forKey: .audioUnit)
        soundBank = try c.decodeIfPresent(SoundBankConfig.self, forKey: .soundBank)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(polySynth, forKey: .polySynth)
        // Omit sampler when absent, so a poly-synth-only instrument stays
        // byte-identical to a pre-sampler save. Same rule for audioUnit and
        // soundBank.
        try c.encodeIfPresent(sampler, forKey: .sampler)
        try c.encodeIfPresent(audioUnit, forKey: .audioUnit)
        try c.encodeIfPresent(soundBank, forKey: .soundBank)
    }

    /// Rebuilds a runtime `InstrumentDescriptor`, resolving each zone's media
    /// ref against `bundleURL`. Zones with no resolvable media are dropped
    /// (a zone can't exist without a file, unlike an optional clip URL); a
    /// missing `media/` file keeps the zone pointed at the (silent) URL, mirroring
    /// the clip policy. Warnings are reported through `warn`.
    func instrumentDescriptor(bundleURL: URL, warn: (String) -> Void) -> InstrumentDescriptor {
        let params = sampler.map { s -> SamplerParams in
            let zones = s.zones.compactMap { zd -> SamplerZone? in
                let (url, warning) = ProjectDocument.resolveMedia(
                    zd.media, label: "sampler zone", bundleURL: bundleURL)
                if let warning { warn(warning) }
                guard let url else { return nil }  // unresolvable media → drop the zone
                return SamplerZone(
                    id: zd.id, audioFileURL: url, rootPitch: zd.rootPitch,
                    minPitch: zd.minPitch, maxPitch: zd.maxPitch, gain: zd.gain)
            }
            return SamplerParams(zones: zones, oneShot: s.oneShot,
                                 attack: s.attack, release: s.release, gain: s.gain)
        }
        // The AU config round-trips intact even when the component isn't
        // installed on this machine — the engine reports `.missing` and
        // renders the placeholder; the selection (and state) is never lost.
        // The sound-bank config likewise: a bank missing on THIS machine
        // surfaces as a `.failed` status at prepare time (LAW L5), never as a
        // dropped selection.
        return InstrumentDescriptor(kind: kind, polySynth: polySynth,
                                    sampler: params, audioUnit: audioUnit,
                                    soundBank: soundBank)
    }
}

/// Persistable sampler facts. Mirrors `SamplerParams`; every field is
/// additive-optional with the model's defaults so a partial payload still decodes.
public struct SamplerDocument: Codable, Sendable, Equatable {
    public var zones: [SamplerZoneDocument]
    public var oneShot: Bool
    public var attack: Double
    public var release: Double
    public var gain: Double

    private enum CodingKeys: String, CodingKey { case zones, oneShot, attack, release, gain }

    init(from s: SamplerParams, mediaRefs: [UUID: String?]) {
        zones = s.zones.map { SamplerZoneDocument(from: $0, media: mediaRefs[$0.id] ?? nil) }
        oneShot = s.oneShot
        attack = s.attack
        release = s.release
        gain = s.gain
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplerParams()
        zones = try c.decodeIfPresent([SamplerZoneDocument].self, forKey: .zones) ?? []
        oneShot = try c.decodeIfPresent(Bool.self, forKey: .oneShot) ?? d.oneShot
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? d.attack
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? d.release
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? d.gain
    }
}

/// Persistable sampler-zone facts. `media` is a `media/<name>` reference
/// (self-contained bundle), an absolute path (recovery bundles only), or null
/// (source missing at save). `id` is required (identity); pitch/gain fields are
/// additive-optional with the model's defaults.
public struct SamplerZoneDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var media: String?
    public var rootPitch: Int
    public var minPitch: Int
    public var maxPitch: Int
    public var gain: Double

    private enum CodingKeys: String, CodingKey {
        case id, media, rootPitch, minPitch, maxPitch, gain
    }

    init(from z: SamplerZone, media: String?) {
        id = z.id
        self.media = media
        rootPitch = z.rootPitch
        minPitch = z.minPitch
        maxPitch = z.maxPitch
        gain = z.gain
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity is required — a missing id is a damaged file
        media = try c.decodeIfPresent(String.self, forKey: .media)
        rootPitch = try c.decodeIfPresent(Int.self, forKey: .rootPitch) ?? 60
        minPitch = try c.decodeIfPresent(Int.self, forKey: .minPitch) ?? 0
        maxPitch = try c.decodeIfPresent(Int.self, forKey: .maxPitch) ?? 127
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        // Encode media as an explicit `null` when absent (schema shape), matching
        // ClipDocument rather than omitting the key.
        try c.encode(media, forKey: .media)
        try c.encode(rootPitch, forKey: .rootPitch)
        try c.encode(minPitch, forKey: .minPitch)
        try c.encode(maxPitch, forKey: .maxPitch)
        try c.encode(gain, forKey: .gain)
    }
}

/// Persistable clip facts. `media` is a `media/<name>` reference (self-contained
/// bundle), an absolute path (recovery bundles only), or null (no media).
/// `notes` carries the MIDI payload (nil for audio clips); it is additive and
/// optional, so a v1 project without the key decodes as an audio clip.
public struct ClipDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var startBeat: Double
    public var lengthBeats: Double
    public var media: String?
    public var notes: [MIDINote]?
    public var isAIGenerated: Bool
    /// Clip-edit fields (M5 i-a) — additive optional, each with the model
    /// default. Stored only when non-default (source offset / gain / fade
    /// lengths non-zero, a fade curve non-`.linear`) so a pre-edit project stays
    /// byte-identical across a round trip (the `bypassed`/`sends` omit-when-
    /// default rule). `nil` reads as the model default on load.
    public var startOffsetSeconds: Double?
    public var gainDb: Double?
    public var fadeInBeats: Double?
    public var fadeOutBeats: Double?
    public var fadeInCurve: FadeCurve?
    public var fadeOutCurve: FadeCurve?
    /// Stretch fields (M5 ii-c) — additive optional, same omit-when-default rule
    /// as the i-a edit fields: stored only when non-default (`stretchRatio != 1`,
    /// `pitchShiftSemitones != 0`, `formantPreserve` true), so a pre-stretch
    /// project stays byte-identical across a round trip. `nil` reads as the model
    /// default on load.
    public var stretchRatio: Double?
    public var pitchShiftSemitones: Double?
    public var formantPreserve: Bool?
    /// Take-group marker (M5 iii-a) — additive optional, same omit-when-nil rule.
    /// Set only on comp member clips; a pre-take clip has no key and stays
    /// byte-identical across a round trip.
    public var takeGroupId: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, name, startBeat, lengthBeats, media, notes, isAIGenerated
        case startOffsetSeconds, gainDb, fadeInBeats, fadeOutBeats, fadeInCurve, fadeOutCurve
        case stretchRatio, pitchShiftSemitones, formantPreserve, takeGroupId
    }

    init(from clip: Clip, media: String?) {
        id = clip.id
        name = clip.name
        startBeat = clip.startBeat
        lengthBeats = clip.lengthBeats
        self.media = media
        notes = clip.notes
        isAIGenerated = clip.isAIGenerated
        // Store each edit field only when it departs from its default, so an
        // unedited clip carries no new keys (byte-identical to a pre-edit save).
        startOffsetSeconds = clip.startOffsetSeconds != 0 ? clip.startOffsetSeconds : nil
        gainDb = clip.gainDb != 0 ? clip.gainDb : nil
        fadeInBeats = clip.fadeInBeats != 0 ? clip.fadeInBeats : nil
        fadeOutBeats = clip.fadeOutBeats != 0 ? clip.fadeOutBeats : nil
        fadeInCurve = clip.fadeInCurve != .linear ? clip.fadeInCurve : nil
        fadeOutCurve = clip.fadeOutCurve != .linear ? clip.fadeOutCurve : nil
        stretchRatio = clip.stretchRatio != 1 ? clip.stretchRatio : nil
        pitchShiftSemitones = clip.pitchShiftSemitones != 0 ? clip.pitchShiftSemitones : nil
        formantPreserve = clip.formantPreserve ? true : nil
        takeGroupId = clip.takeGroupID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity is required — a missing id is a damaged file
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Clip"
        startBeat = try c.decodeIfPresent(Double.self, forKey: .startBeat) ?? 0
        lengthBeats = try c.decodeIfPresent(Double.self, forKey: .lengthBeats) ?? 0
        media = try c.decodeIfPresent(String.self, forKey: .media)
        notes = try c.decodeIfPresent([MIDINote].self, forKey: .notes)
        isAIGenerated = try c.decodeIfPresent(Bool.self, forKey: .isAIGenerated) ?? false
        startOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .startOffsetSeconds)
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb)
        fadeInBeats = try c.decodeIfPresent(Double.self, forKey: .fadeInBeats)
        fadeOutBeats = try c.decodeIfPresent(Double.self, forKey: .fadeOutBeats)
        fadeInCurve = try c.decodeIfPresent(FadeCurve.self, forKey: .fadeInCurve)
        fadeOutCurve = try c.decodeIfPresent(FadeCurve.self, forKey: .fadeOutCurve)
        stretchRatio = try c.decodeIfPresent(Double.self, forKey: .stretchRatio)
        pitchShiftSemitones = try c.decodeIfPresent(Double.self, forKey: .pitchShiftSemitones)
        formantPreserve = try c.decodeIfPresent(Bool.self, forKey: .formantPreserve)
        takeGroupId = try c.decodeIfPresent(UUID.self, forKey: .takeGroupId)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(startBeat, forKey: .startBeat)
        try c.encode(lengthBeats, forKey: .lengthBeats)
        // Encode media as an explicit `null` when absent (schema shape), rather
        // than omitting the key the way synthesized `encodeIfPresent` would.
        try c.encode(media, forKey: .media)
        // notes: OMITTED for audio clips (nil), so an audio-only project stays
        // byte-identical to a pre-MIDI save; an empty array persists for empty
        // MIDI clips, preserving the MIDI-clip identity across a round trip.
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(isAIGenerated, forKey: .isAIGenerated)
        // Edit fields: omitted when nil (the field held its default), so a
        // pre-edit clip never grows keys.
        try c.encodeIfPresent(startOffsetSeconds, forKey: .startOffsetSeconds)
        try c.encodeIfPresent(gainDb, forKey: .gainDb)
        try c.encodeIfPresent(fadeInBeats, forKey: .fadeInBeats)
        try c.encodeIfPresent(fadeOutBeats, forKey: .fadeOutBeats)
        try c.encodeIfPresent(fadeInCurve, forKey: .fadeInCurve)
        try c.encodeIfPresent(fadeOutCurve, forKey: .fadeOutCurve)
        try c.encodeIfPresent(stretchRatio, forKey: .stretchRatio)
        try c.encodeIfPresent(pitchShiftSemitones, forKey: .pitchShiftSemitones)
        try c.encodeIfPresent(formantPreserve, forKey: .formantPreserve)
        try c.encodeIfPresent(takeGroupId, forKey: .takeGroupId)
    }
}

/// Persistable take-group facts (M5 iii-a) — mirrors `TakeGroup`. `comp` reuses
/// `CompSegment` directly (it carries no media, so its Codable IS the disk
/// shape — the `TrackDocument.automation` / `ClipDocument.notes` precedent);
/// lanes persist as `TakeLaneDocument` so each lane payload's media rides as a
/// bundle-relative `media/…` ref. Every field is additive-optional with the
/// model default so a partial payload still decodes.
public struct TakeGroupDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var lanes: [TakeLaneDocument]
    public var comp: [CompSegment]
    public var crossfadeSeconds: Double

    private enum CodingKeys: String, CodingKey { case id, name, lanes, comp, crossfadeSeconds }

    init(from group: TakeGroup, mediaRefs: [UUID: String?]) {
        id = group.id
        name = group.name
        lanes = group.lanes.map { TakeLaneDocument(from: $0, media: mediaRefs[$0.clip.id] ?? nil) }
        comp = group.comp
        crossfadeSeconds = group.crossfadeSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity required — a missing id is a damaged file
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Takes"
        lanes = try c.decodeIfPresent([TakeLaneDocument].self, forKey: .lanes) ?? []
        comp = try c.decodeIfPresent([CompSegment].self, forKey: .comp) ?? []
        crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds)
            ?? TakeGroup.defaultCrossfadeSeconds
    }

    /// Rebuilds a runtime `TakeGroup`, resolving each lane payload's media ref
    /// against `bundleURL` (the clip-media policy: a missing `media/` file keeps
    /// the lane pointed at the silent URL plus a warning). Values re-clamp
    /// through the model inits.
    func takeGroup(bundleURL: URL, warn: (String) -> Void) -> TakeGroup {
        let runtimeLanes = lanes.map { ld -> TakeLane in
            let cd = ld.clip
            let (url, warning) = ProjectDocument.resolveMedia(
                cd.media, label: "take '\(ld.name)'", bundleURL: bundleURL)
            if let warning { warn(warning) }
            let clip = Clip(
                id: cd.id, name: cd.name,
                startBeat: cd.startBeat, lengthBeats: cd.lengthBeats,
                audioFileURL: url, notes: cd.notes, isAIGenerated: cd.isAIGenerated,
                startOffsetSeconds: cd.startOffsetSeconds ?? 0, gainDb: cd.gainDb ?? 0,
                fadeInBeats: cd.fadeInBeats ?? 0, fadeOutBeats: cd.fadeOutBeats ?? 0,
                fadeInCurve: cd.fadeInCurve ?? .linear, fadeOutCurve: cd.fadeOutCurve ?? .linear,
                stretchRatio: cd.stretchRatio ?? 1, pitchShiftSemitones: cd.pitchShiftSemitones ?? 0,
                formantPreserve: cd.formantPreserve ?? false)
            // TakeLane.init strips any stray takeGroupID (payloads never nest).
            return TakeLane(id: ld.id, name: ld.name, clip: clip)
        }
        return TakeGroup(id: id, name: name, lanes: runtimeLanes,
                         comp: comp, crossfadeSeconds: crossfadeSeconds)
    }
}

/// Persistable take-lane facts (M5 iii-a). The lane payload persists AS a
/// `ClipDocument` (media as a bundle-relative ref), the sampler-zone precedent
/// for non-`track.clips` media. Fields are additive-optional with model
/// defaults; `id` is required (identity).
public struct TakeLaneDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var clip: ClipDocument

    private enum CodingKeys: String, CodingKey { case id, name, clip }

    init(from lane: TakeLane, media: String?) {
        id = lane.id
        name = lane.name
        clip = ClipDocument(from: lane.clip, media: media)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity required — a missing id is a damaged file
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Take"
        clip = try c.decode(ClipDocument.self, forKey: .clip)
    }
}
