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
    /// Non-trivial project TEMPO MAP segments (m12-d). Additive and optional;
    /// nil when the project has a single project-wide tempo — the trivial map is
    /// synthesized from `transport.tempoBPM` on load, so a single-tempo project
    /// stays byte-identical (the `markers` omit-when-trivial rule, no
    /// schemaVersion bump). `TransportDocument.tempoBPM` stays authoritative for
    /// segment 0. `TempoMap.Segment` persists directly (it carries no media —
    /// its Codable IS the disk shape, the `markers`/`automation` precedent).
    public var tempoMap: [TempoMap.Segment]?
    /// Non-trivial project METER MAP changes (m12-d) — the meter twin of
    /// `tempoMap`; nil when the project has a single time signature (synthesized
    /// from `transport.timeSignature` on load). Same omit-when-trivial rule.
    public var meterChanges: [MeterMap.Change]?
    /// Monotonic map revision (m12-d, design row 29) — persisted ONLY alongside
    /// a non-trivial map (nil otherwise), so a trivial project stays
    /// byte-identical and a reopened non-trivial map resumes a stable count for
    /// Clip-Fix staleness / round-trip continuity.
    public var tempoMapRevision: UInt64?
    /// MASTER insert chain (m13-d). Additive and optional; nil when the chain
    /// is empty (the key is omitted on encode — the `grooveTemplates`/`markers`
    /// omit-when-empty rule, so a pre-m13-d project stays byte-identical, no
    /// schemaVersion bump). REUSES `EffectDocument` — the m12-f-repaired DTO
    /// that round-trips every field incl. `sidechainSourceTrackID` (which for
    /// master stays nil forever: sanitized on load, unreachable at the store).
    public var masterEffects: [EffectDocument]?
    /// MASTER volume automation (m15-c). Additive and optional; nil when there
    /// is no master lane (the key is omitted on encode — the `masterEffects`
    /// omit-when-empty rule, so a pre-m15-c project stays byte-identical, no
    /// schemaVersion bump). REUSES `AutomationLane` directly (the
    /// `TrackDocument.automation` precedent: it carries no media/URLs, so its
    /// Codable IS the disk shape). v1 invariants (volume target only, one lane)
    /// are SANITIZED on load, not trusted from disk.
    public var masterAutomation: [AutomationLane]?
    /// MASTER modulation (m39-e; persisted since W7-MODP, 2026-10-04) — the `masterAutomation` twin, and the
    /// strip an agent reaches with `trackId: "master"`. Additive and optional, nil when the master strip has
    /// none (the key is omitted on encode — the `masterEffects` omit-when-empty rule, so a project without
    /// master modulation stays byte-identical, no schemaVersion bump). Reuses the model types directly (no
    /// media: their Codable IS the disk shape). Restored through `runtimeMasterModulation`, which clamps the
    /// counts to `ModulationLimits` (the render side preallocates to those caps).
    public var masterModulationSources: [ModulationSource]? = nil
    public var masterModulationRoutes: [ModulationRoute]? = nil
    /// Persisted copilot conversations (chat-persist design, 2026-07-19).
    /// Additive and optional; nil when there are none (omit-when-empty — the
    /// `grooveTemplates` rule, no schemaVersion bump). Decoded LOSSILY: a
    /// corrupt element is skipped (counted into `copilotChatsDroppedOnLoad`),
    /// never fatal to the open.
    public var copilotChats: [CopilotChatDocument]?
    /// Transient decode fact, NOT coded (no CodingKey): how many chat
    /// elements failed to decode. The open path surfaces it as a warning (L6).
    public var copilotChatsDroppedOnLoad: Int = 0
    /// Reference-track slot (m22-g). Additive and optional; nil when the
    /// project has no reference (omit-when-nil — the `masterEffects` rule,
    /// no schemaVersion bump, pre-m22-g saves re-encode byte-identical).
    /// Persists as a mirror DTO so the file rides as a bundle-relative
    /// `media/…` ref (the clip precedent). Decoded TOLERANTLY: a
    /// corrupt/unknown-shape value decodes to nil plus a load warning
    /// (`referenceDroppedOnLoad`, the `copilotChats` lossy precedent) — it
    /// never fails the open.
    public var reference: ReferenceDocument?
    /// Transient decode fact, NOT coded (no CodingKey): true when a present
    /// `reference` value failed to decode and was dropped. The open path
    /// surfaces it as a warning.
    public var referenceDroppedOnLoad: Bool = false
    /// The song's pan rule (m39-panlaw-new) — see `PanLaw`. Additive and
    /// optional, and nil (key OMITTED) for `.balance`, so a song with the
    /// original rule re-saves byte-identical (the `masterEffects`
    /// omit-when-default rule, no schemaVersion bump) and an absent key always
    /// reads as the original rule (`runtimePanLaw`). Decoded TOLERANTLY: a
    /// value this build cannot read (a file from a later build) reads as the
    /// original rule plus a load warning — never a failed open.
    public var panLaw: PanLaw?
    /// Transient decode fact, NOT coded (no CodingKey): the raw pan-rule value
    /// this build could not read; nil when there was none. The open path
    /// surfaces it as a warning.
    public var panLawUnreadOnLoad: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, savedAt, name, masterVolume, transport, tracks, grooveTemplates, markers
        case tempoMap, meterChanges, tempoMapRevision
        case masterEffects
        case masterAutomation
        case masterModulationSources, masterModulationRoutes
        case copilotChats
        case reference
        case panLaw
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
        markers: [Marker] = [],
        tempoMapRevision: UInt64 = 0,
        masterEffects: [EffectDescriptor] = [],
        masterAutomation: [AutomationLane] = [],
        copilotChats: [CopilotChatDocument] = [],
        reference: ReferenceSlot? = nil,
        masterModulationSources: [ModulationSource] = [],
        masterModulationRoutes: [ModulationRoute] = [],
        panLaw: PanLaw = PanLaw.savedSongDefault
    ) {
        self.schemaVersion = ProjectBundle.currentSchemaVersion
        // m39-panlaw-new: the original rule persists as nil → the key is
        // omitted and a song with that rule stays byte-identical.
        self.panLaw = panLaw == PanLaw.savedSongDefault ? nil : panLaw
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
        // Tempo/meter maps (m12-d): a trivial project carries no override → nil
        // fields → the synthesized `encodeIfPresent` omits the keys, keeping a
        // single-tempo project byte-identical. `tempoBPM`/`timeSignature` in
        // `TransportDocument` stay authoritative for segment/change 0.
        self.tempoMap = transport.tempoMapOverride?.segments
        self.meterChanges = transport.meterMapOverride?.changes
        // Persist the revision ONLY with a non-trivial map (else omit, so a
        // project that once had a map but was flattened back to trivial does not
        // grow a stray key).
        let hasMap = transport.tempoMapOverride != nil || transport.meterMapOverride != nil
        self.tempoMapRevision = (hasMap && tempoMapRevision > 0) ? tempoMapRevision : nil
        // Master chain (m13-d): empty persists as nil → the synthesized
        // `encodeIfPresent` omits the key and pre-m13-d saves stay
        // byte-identical (C5).
        self.masterEffects = masterEffects.isEmpty
            ? nil : masterEffects.map(EffectDocument.init(from:))
        // Master volume automation (m15-c): empty persists as nil → the
        // synthesized `encodeIfPresent` omits the key and pre-m15-c saves stay
        // byte-identical (the masterEffects rule).
        self.masterAutomation = masterAutomation.isEmpty ? nil : masterAutomation
        // Master modulation (m39-e, W7-MODP): empty persists as nil → the key is omitted (the masterAutomation
        // rule).
        self.masterModulationSources = masterModulationSources.isEmpty ? nil : masterModulationSources
        self.masterModulationRoutes = masterModulationRoutes.isEmpty ? nil : masterModulationRoutes
        // Copilot chats (chat-persist design): empty persists as nil → the
        // key is omitted and a pre-chat project stays byte-identical (the
        // grooveTemplates rule, no schemaVersion bump).
        self.copilotChats = copilotChats.isEmpty ? nil : copilotChats
        // Reference slot (m22-g): no slot persists as nil → the key is
        // omitted and a pre-reference project stays byte-identical. The
        // media ref comes from planMedia keyed by the slot id; a missing
        // source keeps the ABSOLUTE path (the slot must still name its file
        // so a later restore heals it — the missing-file-at-load contract).
        self.reference = reference.map { slot in
            ReferenceDocument(from: slot, media: (mediaRefs[slot.id] ?? nil) ?? slot.sourcePath)
        }
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
        // Additive optional (m12-d): a single-tempo project has no key → nil ⇒
        // the trivial map is synthesized from tempoBPM/timeSignature on
        // `runtimeState`. Structurally invalid segment/change arrays surface as
        // a decoding error via the element types' own Codable.
        tempoMap = try c.decodeIfPresent([TempoMap.Segment].self, forKey: .tempoMap)
        meterChanges = try c.decodeIfPresent([MeterMap.Change].self, forKey: .meterChanges)
        tempoMapRevision = try c.decodeIfPresent(UInt64.self, forKey: .tempoMapRevision)
        // Additive optional (m13-d): a pre-master-chain project has no key → nil.
        masterEffects = try c.decodeIfPresent([EffectDocument].self, forKey: .masterEffects)
        // Additive optional (m15-c): a pre-master-automation project has no
        // key → nil. Lane payloads heal through AutomationLane's own Codable
        // (canonical point order, clamped beats); v1 invariants sanitize in
        // `runtimeState`.
        masterAutomation = try c.decodeIfPresent([AutomationLane].self, forKey: .masterAutomation)
        // Additive optional (m39-e, W7-MODP): a project saved without master modulation has neither key.
        masterModulationSources = try c.decodeIfPresent([ModulationSource].self,
                                                        forKey: .masterModulationSources)
        masterModulationRoutes = try c.decodeIfPresent([ModulationRoute].self,
                                                       forKey: .masterModulationRoutes)
        // Additive optional (chat-persist design): a pre-chat project has no
        // key → nil. Decoded LOSSILY — a corrupt chat ELEMENT is skipped and
        // counted (one corrupt chat never fails a whole project open); the
        // count rides the transient (never-coded) `copilotChatsDroppedOnLoad`
        // so the open path can surface it as a warning (L6).
        let lossyChats = try c.decodeIfPresent(LossyArray<CopilotChatDocument>.self, forKey: .copilotChats)
        copilotChats = lossyChats?.elements
        copilotChatsDroppedOnLoad = lossyChats?.droppedCount ?? 0
        // Additive optional (m22-g): a pre-reference project has no key →
        // nil. TOLERANT: a present-but-corrupt value (wrong type, missing
        // id, hand-edited junk) decodes to nil + the dropped flag instead of
        // failing the whole open (the copilotChats lossy precedent).
        if c.contains(.reference) {
            if let decoded = try? c.decode(ReferenceDocument.self, forKey: .reference) {
                reference = decoded
            } else {
                reference = nil
                referenceDroppedOnLoad = true
            }
        }
        // Additive optional (m39-panlaw-new): a song saved before the setting
        // existed has no key → nil → the original rule. TOLERANT like
        // `reference`: a value this build cannot read keeps the original rule
        // and records the raw text for the open path's warning.
        if c.contains(.panLaw) {
            let raw = try? c.decode(String.self, forKey: .panLaw)
            if let raw, let law = PanLaw(rawValue: raw) {
                panLaw = law
            } else {
                panLaw = nil
                panLawUnreadOnLoad = raw ?? "(not text)"
            }
        }
    }

    /// The song's pan rule as the store restores it on open and on crash
    /// recovery (m39-panlaw-new): the stored rule, or the ORIGINAL rule when
    /// the file has none — every song made before the setting existed.
    public var runtimePanLaw: PanLaw { panLaw ?? PanLaw.savedSongDefault }

    /// Restores runtime state, resolving each clip's media reference against
    /// `bundleURL`. Relative refs must live under `media/` and never escape it
    /// (a `..` or non-`media/` ref is dropped with a warning); absolute refs
    /// are accepted verbatim (the recovery contract); a `media/` ref whose file
    /// is missing keeps the clip pointed at the (nonexistent) URL plus a
    /// warning. All runtime objects are rebuilt through their PUBLIC inits, so
    /// value clamps re-apply on load.
    public func runtimeState(
        bundleURL: URL
    ) -> (tracks: [Track], transport: TransportState, masterVolume: Double,
          masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
          reference: ReferenceSlot?, warnings: [String]) {
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
                    // Gain envelope (m13-e): absent reads as no envelope; the
                    // points re-clamp and re-canonicalize through `Clip.init`.
                    gainEnvelope: cd.gainEnvelope ?? [],
                    // Controller lanes (m16-b): absent reads as no lanes; the
                    // lanes re-canonicalize (and force [] on an audio clip)
                    // through `Clip.init`.
                    controllerLanes: cd.controllerLanes ?? [],
                    // Take-group marker (M5 iii-a): restores comp members as
                    // store-managed clips; nil for ordinary clips.
                    takeGroupID: cd.takeGroupId,
                    // Pitch edits (m23-ap): absent reads as no edits; the
                    // segments re-heal (sorted, non-overlapping, values
                    // re-clamped) through `PitchEditSet.init`, and an empty set
                    // normalises back to nil in `Clip.init`.
                    pitchEdits: cd.pitchEdits,
                    // Lyrics (p2-sing-d1b): absent reads as none; blank text
                    // and an audio clip's stray key normalise to nil in
                    // `Clip.init`.
                    lyrics: cd.lyrics,
                    // Singing style (p2-sing-x5): absent reads as none; an
                    // all-default style and an audio clip's stray key
                    // normalise to nil in `Clip.init`. Verbatim otherwise:
                    // nothing prunes per-note choices at load.
                    singStyle: cd.singStyle
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
                takeGroups: takeGroups,
                // m24-n: a fact about the past, restored verbatim. It is NOT
                // validated against the voice store on load — a voice that is
                // gone is a normal state, and blanking the record here would
                // destroy the only thing that can still say what the audio was
                // made from.
                voiceProvenance: td.voiceProvenance,
                // p2-sing-d2: the same fact-not-binding rule, verbatim.
                sungVocalProvenance: td.sungVocalProvenance,
                // m39-e (W7-MODP): restored verbatim; `Track.init` clamps the counts to `ModulationLimits`.
                // A route whose target no longer resolves is inert — the automation-lane rule above.
                modulationSources: td.modulationSources ?? [],
                modulationRoutes: td.modulationRoutes ?? []
            )
        }
        // Attach the non-trivial tempo/meter maps (m12-d) onto the runtime
        // transport. A stored map is reconstructed through its validating
        // initializer; a structurally bad (or hand-edited single-entry) array
        // collapses to nil so `tempoBPM`/`timeSignature` stay authoritative for
        // segment/change 0. The store's mutation only ever writes ≥2-entry maps,
        // so the collapse is the belt-and-suspenders path.
        var runtimeTransport = transport.transportState()
        if let tempoMap, let map = try? TempoMap(segments: tempoMap), map.segments.count > 1 {
            runtimeTransport.tempoMapOverride = map
        }
        if let meterChanges, let meter = try? MeterMap(changes: meterChanges), meter.changes.count > 1 {
            runtimeTransport.meterMapOverride = meter
        }
        // Master insert chain (m13-d): resolve like a track chain (unknown
        // kind → dropped with a warning), then SANITIZE the v1 invariants on
        // load (design §4): an `audioUnit`-kind entry is DROPPED (the master
        // hosts built-ins only — D4a), and a stray sidechain key is CLEARED
        // (a master effect can never be keyed) — each with a warning, so a
        // hand-edited file degrades readably instead of smuggling state the
        // store could never have produced.
        let runtimeMasterEffects: [EffectDescriptor] = (masterEffects ?? []).compactMap { ed in
            guard let effect = ed.effectDescriptor() else {
                warnings.append("unknown effect kind '\(ed.kind)' on the master chain — effect dropped")
                return nil
            }
            if effect.kind == .audioUnit {
                warnings.append("audioUnit effect on the master chain — dropped (the master chain hosts built-in effects only in v1)")
                return nil
            }
            var sanitized = effect
            if sanitized.sidechainSourceTrackID != nil {
                warnings.append("sidechain key on master \(ed.kind) effect — cleared (the master chain cannot host a sidechain-keyed effect)")
                sanitized.sidechainSourceTrackID = nil
            }
            return sanitized
        }
        // Master volume automation (m15-c): SANITIZE the v1 invariants on load
        // (the master-chain rule above) — only `.volume` lanes survive, and at
        // most ONE (the store enforces one lane per target; a hand-edited
        // duplicate would break `addMasterAutomationLane`'s idempotency).
        var runtimeMasterAutomation: [AutomationLane] = []
        for lane in masterAutomation ?? [] {
            guard lane.target == .volume else {
                warnings.append("non-volume master automation lane — dropped (master automation supports the volume target only in v1)")
                continue
            }
            guard runtimeMasterAutomation.isEmpty else {
                warnings.append("duplicate master volume automation lane — dropped (the master holds one volume lane)")
                continue
            }
            runtimeMasterAutomation.append(lane)
        }
        // Reference slot (m22-g): resolve its media ref like a clip's. A
        // missing FILE keeps the slot (and its persisted analysis) pointed
        // at the resolved path — reference.analyze / setMonitor refuse with
        // the referenceFileMissing teaching error, never a silent drop. A
        // slot with NO resolvable path (null/invalid ref) IS dropped with a
        // warning (a pathless slot names nothing). A hand-edited analysis
        // with the wrong band count SANITIZES to nil-analysis + a warning
        // (the m13-d hand-edited-load precedent).
        var runtimeReference: ReferenceSlot?
        if let rd = reference {
            let (url, warning) = Self.resolveMedia(
                rd.media, label: "reference '\(rd.name)'", bundleURL: bundleURL)
            if let warning { warnings.append(warning) }
            if let url {
                var analysis = rd.analysis
                if let a = analysis, a.bandsDb.count != MasterAnalysisSnapshot.bandCount {
                    warnings.append(
                        "reference '\(rd.name)' analysis has \(a.bandsDb.count) spectrum bands "
                        + "(expected \(MasterAnalysisSnapshot.bandCount)) — analysis dropped; "
                        + "re-run reference.analyze")
                    analysis = nil
                }
                runtimeReference = ReferenceSlot(
                    id: rd.id, name: rd.name, sourcePath: url.path,
                    offsetSeconds: rd.offsetSeconds, trimDb: rd.trimDb,
                    analysis: analysis)
            } else if rd.media == nil {
                warnings.append("reference '\(rd.name)' has no media reference — slot dropped")
            }
        }
        // m39-panlaw-new: a pan setting from a later build plays with the
        // original pan knobs, and says so.
        if let unread = panLawUnreadOnLoad {
            warnings.append("this song's pan setting '\(unread)' comes from a newer version of DAW Pro — "
                + "its pan knobs use the original setting instead")
        }
        return (runtimeTracks, runtimeTransport, masterVolume, runtimeMasterEffects,
                runtimeMasterAutomation, runtimeReference, warnings)
    }

    /// The master strip's modulation as the store restores it on open and on crash recovery (m39-e,
    /// W7-MODP): EMPTY when the file carries none — which is what replaces, rather than keeps, whatever the
    /// previous session's master strip held. Counts are clamped to `ModulationLimits`, exactly as `Track.init`
    /// clamps a track's (the render side preallocates to those caps); routes otherwise round-trip verbatim (an
    /// orphaned route is inert, the automation-lane rule).
    public var runtimeMasterModulation: (sources: [ModulationSource], routes: [ModulationRoute]) {
        (Array((masterModulationSources ?? []).prefix(ModulationLimits.maxSources)),
         Array((masterModulationRoutes ?? []).prefix(ModulationLimits.maxRoutes)))
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
        // ⭐⭐ m23-cy — THE DEFAULT CHANGE'S ONE INTERESTING EDGE, DECIDED AND
        // WRITTEN DOWN RATHER THAN INHERITED BY ACCIDENT.
        //
        // `d` is a fresh `TransportState()`, so the count-in default now
        // resolves to 1 here as well as for a new project. That means:
        //
        //   • A project file WITH the key keeps its stored value, always —
        //     including a stored 0. A user who set 0 on purpose is not
        //     overridden, and neither is one who merely saved under the old
        //     default. Both are indistinguishable from here and both are left
        //     alone; this is the conservative half and it is the important one.
        //   • A project file WITHOUT the key — only possible for a file saved
        //     before `countInBars` existed, since every save since writes every
        //     CodingKey — decodes to the NEW default, 1.
        //
        // The second case is deliberate, not an oversight. An absent key is the
        // one state that means "this user never had the setting to choose", and
        // giving them the current default is exactly what `decodeIfPresent ??
        // default` is for; the alternative (pinning a literal 0 here so old
        // files stay at the old default forever) would freeze a migration
        // decision into the decoder and quietly disagree with `newProject()`.
        // `CountInDefaultMigrationTests` (Tests/DAWCoreTests/PersistenceTests.swift)
        // pins BOTH cases.
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
    /// Voice-conversion provenance (m24-n). Additive and optional; nil (key
    /// omitted on encode) on every track that was not made by a conversion, so
    /// a pre-provenance project stays byte-identical — the `sends` rule.
    ///
    /// `VoiceProvenance` is reused directly rather than mirrored into a
    /// `…Document` type (the `automation` / `ClipDocument.notes` precedent): it
    /// carries no URLs and no media, so its `Codable` IS the disk shape. The
    /// voice FILES it implies are not referenced from here at all — they are
    /// found by id under the bundle's `voices/` folder, deliberately DERIVED
    /// rather than recorded, so no manifest can disagree with the directory.
    public var voiceProvenance: VoiceProvenance?
    /// Sung-vocal provenance (p2-sing-d2). Additive and optional, the
    /// `voiceProvenance` rule exactly: nil (key omitted) on every track no
    /// sing job made, and `SungVocalProvenance`'s Codable IS the disk shape.
    public var sungVocalProvenance: SungVocalProvenance?
    /// Modulation sources and routes on this strip (m39-e). Additive and optional, the `sends`/`automation`
    /// rule: an EMPTY array is stored as nil, so the key is omitted on encode and a project without modulation
    /// stays byte-identical (no schemaVersion bump). `ModulationSource`/`ModulationRoute` persist directly (the
    /// `automation` precedent: no media, no URLs, so their Codable IS the disk shape), under `Track`'s own key
    /// names, so the wire, the snapshot and the file agree.
    ///
    /// ⛔ m39-e shipped WITHOUT these two fields (W7-MODP, 2026-10-04; design §16). `Track` carried the arrays
    /// and encoded them in its OWN Codable, every §7.6 test exercised that Codable, and this DTO — the actual
    /// save format — never mentioned them, so every save dropped every LFO, step sequencer, follower and macro.
    /// `ProjectDocumentFidelityTests` now classifies every stored property of `Track` by `Mirror`, so the next
    /// field added to `Track` and not threaded here fails BY NAME instead of vanishing on save.
    public var modulationSources: [ModulationSource]? = nil
    public var modulationRoutes: [ModulationRoute]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, volume, pan, isMuted, isSoloed, isArmed, isAIGenerated, clips, instrument
        case outputBusId, sends, effects, automation, takeGroups
        case voiceProvenance
        case sungVocalProvenance
        case modulationSources, modulationRoutes
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
        // m24-n: rides verbatim; nil on a track no conversion produced, so the
        // synthesized encodeIfPresent omits the key entirely.
        voiceProvenance = track.voiceProvenance
        sungVocalProvenance = track.sungVocalProvenance
        // m39-e (W7-MODP): empty persists as nil (the `sends` rule) → the synthesized `encodeIfPresent` omits
        // the key, keeping a project without modulation byte-identical.
        modulationSources = track.modulationSources.isEmpty ? nil : track.modulationSources
        modulationRoutes = track.modulationRoutes.isEmpty ? nil : track.modulationRoutes
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
        // Additive optional (m24-n): a pre-provenance track has no key.
        voiceProvenance = try c.decodeIfPresent(VoiceProvenance.self, forKey: .voiceProvenance)
        // Additive optional (p2-sing-d2): a pre-sing track has no key.
        sungVocalProvenance = try c.decodeIfPresent(SungVocalProvenance.self, forKey: .sungVocalProvenance)
        // Additive optional (m39-e, W7-MODP): a track saved without modulation has neither key.
        modulationSources = try c.decodeIfPresent([ModulationSource].self, forKey: .modulationSources)
        modulationRoutes = try c.decodeIfPresent([ModulationRoute].self, forKey: .modulationRoutes)
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
    public var bassEnhancer: BassEnhancerParams?
    public var bitCrusher: BitCrusherParams?
    /// m39-i. ⚠️ THIS MIRROR IS HAND-MAINTAINED AND THE COMPILER DOES NOT
    /// FORCE IT: a new params optional added to `EffectDescriptor` but not to
    /// every one of the five sites below (field, CodingKeys, `init(from
    /// effect:)`, decode, encode, `effectDescriptor()`) renders and edits
    /// perfectly and is SILENTLY DROPPED on save. Pinned by a round-trip test.
    public var djFilter: DJFilterParams?
    /// m39-m — the same five sites, the same hazard.
    public var ringMod: RingModParams?
    /// m39-j — the same SIX sites, the same hazard. ✅ THE EXHAUSTIVE PIN
    /// LANDED AT m39-o: `EffectDocumentMirrorTests` round-trips a NON-DEFAULT
    /// descriptor for every kind, driven by `Kind.allCases`.
    /// `FlangerPersistenceTests` still covers this one by hand, by field.
    public var flanger: FlangerParams?
    /// m39-l — the same SIX sites, the same hazard, and this kind has FOURTEEN
    /// params riding on them: property, `CodingKeys`, `init(from effect:)`,
    /// `decodeIfPresent`, `encodeIfPresent`, `effectDescriptor()`. Miss one and
    /// the project saves, reports success, and reopens with the hall reset to
    /// defaults. ✅ THE EXHAUSTIVE PIN LANDED AT m39-o
    /// (`EffectDocumentMirrorTests`); `HallReverbPersistenceTests` still covers
    /// this one by hand, by field.
    public var hallReverb: HallReverbParams?
    /// m39-n — the same SIX sites, the same hazard. ✅ THE EXHAUSTIVE PIN
    /// LANDED AT m39-o (`EffectDocumentMirrorTests`, which adopted this
    /// comment's own rule: its fixtures are non-default IN EVERY FIELD, and a
    /// control asserts that mechanically). `TapeDelayPersistenceTests` still
    /// covers this one by hand, by field.
    public var tapeDelay: TapeDelayParams?
    /// m23-dj — the same SIX sites, the same hazard. ✅ THE EXHAUSTIVE PIN
    /// LANDED AT m39-o (`EffectDocumentMirrorTests`);
    /// `StereoWidthPersistenceTests` still covers this one by hand, by field.
    public var stereoWidth: StereoWidthParams?
    /// m39-o — the same SIX sites, the same hazard, and ⭐ THE ITEM THAT
    /// LANDED THE EXHAUSTIVE PIN THE FOUR COMMENTS ABOVE KEPT DEFERRING TO IT.
    /// `EffectDocumentMirrorTests` round-trips a NON-DEFAULT descriptor for
    /// EVERY `EffectDescriptor.Kind`, driven by `allCases`, so a kind added
    /// without all six sites now fails there instead of waiting for someone to
    /// hand-write a per-kind test — and it carries a plant control that STRIPS
    /// a params key and proves the comparison reddens. The per-kind tests stay:
    /// they name individual fields and go through the real save/open path.
    public var phaser: PhaserParams?
    public var transientShaper: TransientShaperParams?
    public var freqShifter: FreqShifterParams?
    public var clipper: ClipperParams?
    public var dynamicEQ: DynamicEQParams?
    /// Hosted Audio Unit selection + inlined state (stateData rides as base64
    /// through Codable's Data default) — the InstrumentDocument.audioUnit
    /// mirror. Additive optional: pre-M4 (v) files have no key and stay
    /// byte-identical across a round trip.
    public var audioUnit: AudioUnitConfig?
    /// Sidechain key source (m12-f). Additive optional, omitted when nil —
    /// pre-sidechain files stay byte-identical across a round trip.
    public var sidechainSourceTrackID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, kind, bypassed, gain, eq, compressor, limiter
        case reverb, delay, saturator, gate, chorus, bassEnhancer, bitCrusher
        case djFilter, ringMod, flanger, hallReverb, tapeDelay, stereoWidth, phaser
        case transientShaper
        case freqShifter
        case clipper
        case dynamicEQ
        case audioUnit
        case sidechainSourceTrackID
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
        bassEnhancer = effect.bassEnhancer
        bitCrusher = effect.bitCrusher
        djFilter = effect.djFilter
        ringMod = effect.ringMod
        flanger = effect.flanger
        hallReverb = effect.hallReverb
        tapeDelay = effect.tapeDelay
        stereoWidth = effect.stereoWidth
        phaser = effect.phaser
        transientShaper = effect.transientShaper
        freqShifter = effect.freqShifter
        clipper = effect.clipper
        dynamicEQ = effect.dynamicEQ
        audioUnit = effect.audioUnit
        sidechainSourceTrackID = effect.sidechainSourceTrackID
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
        bassEnhancer = try c.decodeIfPresent(BassEnhancerParams.self, forKey: .bassEnhancer)
        bitCrusher = try c.decodeIfPresent(BitCrusherParams.self, forKey: .bitCrusher)
        djFilter = try c.decodeIfPresent(DJFilterParams.self, forKey: .djFilter)
        ringMod = try c.decodeIfPresent(RingModParams.self, forKey: .ringMod)
        flanger = try c.decodeIfPresent(FlangerParams.self, forKey: .flanger)
        hallReverb = try c.decodeIfPresent(HallReverbParams.self, forKey: .hallReverb)
        tapeDelay = try c.decodeIfPresent(TapeDelayParams.self, forKey: .tapeDelay)
        stereoWidth = try c.decodeIfPresent(StereoWidthParams.self, forKey: .stereoWidth)
        phaser = try c.decodeIfPresent(PhaserParams.self, forKey: .phaser)
        transientShaper = try c.decodeIfPresent(
            TransientShaperParams.self, forKey: .transientShaper)
        freqShifter = try c.decodeIfPresent(FreqShifterParams.self, forKey: .freqShifter)
        clipper = try c.decodeIfPresent(ClipperParams.self, forKey: .clipper)
        dynamicEQ = try c.decodeIfPresent(DynamicEQParams.self, forKey: .dynamicEQ)
        audioUnit = try c.decodeIfPresent(AudioUnitConfig.self, forKey: .audioUnit)
        sidechainSourceTrackID = try c.decodeIfPresent(UUID.self, forKey: .sidechainSourceTrackID)
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
        try c.encodeIfPresent(bassEnhancer, forKey: .bassEnhancer)
        try c.encodeIfPresent(bitCrusher, forKey: .bitCrusher)
        try c.encodeIfPresent(djFilter, forKey: .djFilter)
        try c.encodeIfPresent(ringMod, forKey: .ringMod)
        try c.encodeIfPresent(flanger, forKey: .flanger)
        try c.encodeIfPresent(hallReverb, forKey: .hallReverb)
        try c.encodeIfPresent(tapeDelay, forKey: .tapeDelay)
        try c.encodeIfPresent(stereoWidth, forKey: .stereoWidth)
        try c.encodeIfPresent(phaser, forKey: .phaser)
        try c.encodeIfPresent(transientShaper, forKey: .transientShaper)
        try c.encodeIfPresent(freqShifter, forKey: .freqShifter)
        try c.encodeIfPresent(clipper, forKey: .clipper)
        try c.encodeIfPresent(dynamicEQ, forKey: .dynamicEQ)
        try c.encodeIfPresent(audioUnit, forKey: .audioUnit)
        try c.encodeIfPresent(sidechainSourceTrackID, forKey: .sidechainSourceTrackID)
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
                                gate: gate, chorus: chorus, bassEnhancer: bassEnhancer,
                                bitCrusher: bitCrusher,
                                djFilter: djFilter,
                                ringMod: ringMod,
                                flanger: flanger,
                                hallReverb: hallReverb,
                                tapeDelay: tapeDelay,
                                stereoWidth: stereoWidth,
                                phaser: phaser,
                                transientShaper: transientShaper,
                                freqShifter: freqShifter,
                                clipper: clipper,
                                dynamicEQ: dynamicEQ,
                                audioUnit: audioUnit,
                                sidechainSourceTrackID: sidechainSourceTrackID)
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
    /// Drum kit (m39-dm). Additive optional — a pre-drumSynth project has no
    /// key and stays byte-identical across a round trip.
    ///
    /// ⭐ It persists DIRECTLY as `DrumKitParams` rather than through a
    /// `DrumKitDocument` mirror, following `SoundBankConfig`/`AutomationLane`
    /// rather than `SamplerDocument`. The mirror exists for the sampler because
    /// a zone holds a live `URL` that must become a bundle-relative `media/…`
    /// ref; a drum kit is 77 numbers and eight optional ints with no file
    /// reference anywhere, so a mirror would be a second hand-maintained list
    /// of 77 names whose only function is to drift from the first.
    public var drumKit: DrumKitParams?

    // ⛔⛔ m39-dm — A KEY MISSING FROM THIS ENUM IS THE QUIETEST DEFECT IN THE
    // WHOLE PERSISTENCE PATH. `CodingKeys` is hand-written; omitting `drumKit`
    // produces NO compile error, NO runtime error and NO warning — the kit is
    // simply never written and never read, and every in-memory test passes.
    // `DrumKitPersistenceTests` round-trips all 77 names through a real bundle
    // for exactly this reason, and plant P12 deletes this key to prove it.
    private enum CodingKeys: String, CodingKey {
        case kind, polySynth, sampler, audioUnit, soundBank, drumKit
    }

    init(from d: InstrumentDescriptor, mediaRefs: [UUID: String?]) {
        kind = d.kind
        polySynth = d.polySynth
        // Persist sampler only when the descriptor carries one (even empty
        // zones), preserving "was a sampler configured" across a round trip.
        sampler = d.sampler.map { SamplerDocument(from: $0, mediaRefs: mediaRefs) }
        audioUnit = d.audioUnit
        soundBank = d.soundBank
        drumKit = d.drumKit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InstrumentDescriptor.default
        kind = try c.decodeIfPresent(InstrumentDescriptor.Kind.self, forKey: .kind) ?? d.kind
        polySynth = try c.decodeIfPresent(PolySynthParams.self, forKey: .polySynth) ?? d.polySynth
        sampler = try c.decodeIfPresent(SamplerDocument.self, forKey: .sampler)
        audioUnit = try c.decodeIfPresent(AudioUnitConfig.self, forKey: .audioUnit)
        soundBank = try c.decodeIfPresent(SoundBankConfig.self, forKey: .soundBank)
        // Absent (every pre-m39-dm project) → nil → `resolvedDrumKit` gives the
        // factory kit, which is exactly what a project that never carried the
        // key means.
        drumKit = try c.decodeIfPresent(DrumKitParams.self, forKey: .drumKit)
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
        // Omitted when absent, so a project that never touched the drum machine
        // stays byte-identical to a pre-m39-dm save.
        try c.encodeIfPresent(drumKit, forKey: .drumKit)
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
                    minPitch: zd.minPitch, maxPitch: zd.maxPitch, gain: zd.gain,
                    minVelocity: zd.minVelocity, maxVelocity: zd.maxVelocity,
                    group: zd.group, seqLength: zd.seqLength, seqPosition: zd.seqPosition,
                    randMin: zd.randMin, randMax: zd.randMax,
                    tuneCents: zd.tuneCents, pan: zd.pan, ampVelTrack: zd.ampVelTrack,
                    oneShot: zd.oneShot, startFrame: zd.startFrame, endFrame: zd.endFrame,
                    attack: zd.attack, decay: zd.decay, sustain: zd.sustain,
                    release: zd.release,
                    // m20-g: tolerant decode — an unknown loopMode rawValue
                    // resolves to nil (no loop) rather than failing the open.
                    loopMode: zd.loopMode.flatMap(SamplerLoopMode.init(rawValue:)),
                    loopStart: zd.loopStart, loopEnd: zd.loopEnd,
                    // m27 leg B: absent (every pre-m27 project) -> nil ->
                    // hard layer switching, exactly as before.
                    crossfade: zd.crossfade,
                    // m32-d: absent (every pre-m32-d project) -> nil -> forward.
                    reverse: zd.reverse,
                    // m32-f: absent -> nil -> no choke.
                    chokeGroup: zd.chokeGroup,
                    // m39-w4-6: absent, or a role this version does not
                    // know -> nil -> no drum row for that zone.
                    drumRole: zd.drumRole.flatMap(DrumVoice.init(rawValue:)))
            }
            return SamplerParams(zones: zones, oneShot: s.oneShot,
                                 attack: s.attack, release: s.release, gain: s.gain,
                                 // m26-h: provenance is a RECORD, so it decodes
                                 // verbatim — no resolution, no warning, no drop
                                 // if the .sfz has since moved. Absent (every
                                 // pre-m26-h project) → nil → today's behaviour.
                                 sourcePath: s.sourcePath, displayName: s.displayName,
                                 // m27: absent (every pre-m27 project) → nil →
                                 // depth 0 → the pre-m27 amplitude law exactly.
                                 expressionModDepth: s.expressionModDepth,
                                 expressionFilterDepth: s.expressionFilterDepth,
                                 expressionFilterCC: s.expressionFilterCC,
                                 // m34-s: absent (every pre-m34-s project) →
                                 // nil → the GM default 2.0, exactly what a
                                 // project that never carried the key means.
                                 bendRangeSemitones: s.bendRangeSemitones,
                                 // m34-s: tolerant decode — an unknown
                                 // voiceMode rawValue resolves to nil (poly)
                                 // rather than failing the open, the same rule
                                 // loopMode follows a few lines above.
                                 voiceMode: s.voiceMode
                                     .flatMap(SamplerVoiceMode.init(rawValue:)),
                                 // m34-s: absent → nil → the legacy pair
                                 // (decay 0, sustain 1), i.e. hold at peak.
                                 decay: s.decay, sustain: s.sustain,
                                 // m34-q: absent (every pre-m34-q project) →
                                 // nil → unlimited, the pre-m34-q behaviour.
                                 pedalHoldLimit: s.pedalHoldLimit,
                                 // m34-t: absent (every pre-m34-t project) →
                                 // nil → 0 → the pitch STEPS, exactly what a
                                 // project that never carried the key did.
                                 glideTime: s.glideTime,
                                 // m34-w: absent (every pre-m34-w project) →
                                 // nil → .constantTime → glideTime is a flat
                                 // duration, exactly what a project that never
                                 // carried the key meant. TOLERANT DECODE, the
                                 // voiceMode precedent four lines up: an
                                 // unknown rawValue written by a FUTURE build
                                 // resolves to nil rather than failing the
                                 // open, so a project round-trips through an
                                 // older build with a wrong SOUND rather than
                                 // an unopenable file.
                                 glideMode: s.glideMode
                                     .flatMap(SamplerGlideMode.init(rawValue:)),
                                 // PK-F2: absent (every un-chopped sampler, every
                                 // pre-PK-F2 project) → nil → not a slice kit.
                                 sliceKit: s.sliceKit)
        }
        // The AU config round-trips intact even when the component isn't
        // installed on this machine — the engine reports `.missing` and
        // renders the placeholder; the selection (and state) is never lost.
        // The sound-bank config likewise: a bank missing on THIS machine
        // surfaces as a `.failed` status at prepare time (LAW L5), never as a
        // dropped selection.
        // ⚠️ This is an EXPLICIT initialiser call with all-defaulted arguments,
        // so a payload omitted here does NOT inherit anything — it takes
        // `InstrumentDescriptor`'s own nil default and the user's setting is
        // dropped on every project open, with no error. The `setInstrument`
        // rebuild carries the same warning for the same reason.
        return InstrumentDescriptor(kind: kind, polySynth: polySynth,
                                    sampler: params, audioUnit: audioUnit,
                                    soundBank: soundBank, drumKit: drumKit)
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
    // m26-h provenance — nil never encodes (the synthesized encoder uses
    // encodeIfPresent for optionals), so a sampler that was never imported
    // from a library keeps a document shape byte-identical to pre-m26-h, and a
    // pre-m26-h project decodes both keys as nil. `sourcePath` is a plain
    // absolute path, NOT a `media/` reference: it names the .sfz/.dspreset the
    // zones came from, which the bundle deliberately does not copy (the SAMPLES
    // are what get copied, per zone). ReferenceDocument's `media`/`sourcePath`
    // pair is the sibling precedent for a path that may not resolve on the
    // machine that opens the project — and, like it, an unresolvable path here
    // is never an open-time failure: nothing reads it back.
    public var sourcePath: String?
    public var displayName: String?
    /// m27 continuous expression — nil never encodes (the optional
    /// encodeIfPresent rule above), so a sampler that never opted in keeps a
    /// document shape byte-identical to pre-m27, and every pre-m27 project
    /// decodes it as nil = off.
    public var expressionModDepth: Double?
    public var expressionFilterDepth: Double?
    public var expressionFilterCC: Int?
    /// m34-s — THE FOUR GLOBALS A SAVE USED TO THROW AWAY. `bendRangeSemitones`
    /// and `voiceMode` (the sax team's bend work) and `decay`/`sustain` (m34-o's
    /// global envelope) all shipped as settable, readable, engine-honoured
    /// fields on `SamplerParams` — and none of them was in these CodingKeys, so
    /// each was silently reset the next time the project opened.
    ///
    /// ⭐ THE USER-FACING COST, because it was worse than a missing field: nil
    /// `decay`/`sustain` resolve to the legacy pair (0, 1) — hold at peak
    /// forever — so losing them on save brought back the exact defect m34-o
    /// closed ("the note keeps playing") after any save and reopen.
    ///
    /// Same additive-optional contract as every field above: nil never encodes
    /// (the synthesized encoder's `encodeIfPresent`), so a sampler that set none
    /// of them keeps a document shape byte-identical to pre-m34-s, and every
    /// pre-m34-s project decodes all four as nil = the behaviour it has today.
    public var bendRangeSemitones: Double?
    /// ⛔ THE RAW STRING, NOT THE ENUM, RESOLVED WITH `flatMap(init(rawValue:))`
    /// — following `SamplerZoneDocument.loopMode` (m20-g) rather than the
    /// `pedalHoldLimit` precedent, because an enum is the one case where they
    /// differ. A strict `decodeIfPresent(SamplerVoiceMode.self)` THROWS on an
    /// unknown rawValue, and this decoder sits inside the project open: a third
    /// voice mode added by a later build would make every project that used it
    /// UNOPENABLE in this one — the whole document, not just the field.
    public var voiceMode: String?
    /// m34-o's instrument-wide envelope halves. Each inherits INDEPENDENTLY at
    /// the zone level, so they persist as two separate optionals rather than a
    /// pair — a document that carries one and not the other is meaningful.
    public var decay: Double?
    public var sustain: Double?

    /// m34-q pedal hold limit — nil never encodes (the optional
    /// encodeIfPresent rule above), so a sampler that never set a cap keeps a
    /// document shape byte-identical to pre-m34-q, and every pre-m34-q project
    /// decodes it as nil = unlimited.
    ///
    /// ⚠️ IT IS HERE BECAUSE A SETTING THAT DOES NOT SURVIVE A SAVE IS NOT A
    /// SETTING. `SamplerParams` does NOT persist through its own `Codable`:
    /// this document is the save format, and a global that is absent from these
    /// CodingKeys is silently reset the next time the project opens.
    public var pedalHoldLimit: Int?

    /// m34-t glide/portamento time in seconds — nil never encodes (the optional
    /// encodeIfPresent rule above), so a sampler that never set a glide keeps a
    /// document shape byte-identical to pre-m34-t, and every pre-m34-t project
    /// decodes it as nil = 0 = the pitch steps, which is what it did.
    ///
    /// ⚠️ IT IS HERE FOR THE m34-s REASON, restated because that item cost four
    /// silently-dropped globals: a setting that does not survive a save is not
    /// a setting. `SamplerParams` does NOT persist through its own `Codable` —
    /// this document is the save format.
    ///
    /// ⭐ `voiceMode` needed NOTHING for m34-t's new `.legato` case: it already
    /// persists as its RAW STRING and resolves with
    /// `flatMap(SamplerVoiceMode.init(rawValue:))`, so a third case rides the
    /// existing key, and an OLDER build opening a legato project resolves the
    /// unknown string to nil = poly rather than failing the open. That is the
    /// safe direction, and it is the whole reason the raw-string shape was
    /// chosen over `decodeIfPresent(SamplerVoiceMode.self)`.
    public var glideTime: Double?

    /// m34-w. The enum's RAW STRING, per the `voiceMode`/`loopMode` precedent
    /// directly above — that shape is what lets an older build open a project
    /// written by a newer one (unknown string → nil → `.constantTime`) instead
    /// of throwing. nil never encodes, so a sampler that never chose a mode
    /// keeps a document shape byte-identical to pre-m34-w.
    public var glideMode: String?

    /// PK-F2. `SamplerParams.sliceKit`, verbatim. nil never encodes (the
    /// synthesized encoder's `encodeIfPresent`), so an un-chopped sampler keeps
    /// a document shape byte-identical to pre-PK-F2. A kit saved by an OLDER
    /// build has no key and opens as "not a kit": a key change moves it, which
    /// is what that build did.
    public var sliceKit: Bool?

    private enum CodingKeys: String, CodingKey {
        case zones, oneShot, attack, release, gain, sourcePath, displayName
        case expressionModDepth, expressionFilterDepth, expressionFilterCC
        case pedalHoldLimit
        // m34-s — four globals that shipped BEFORE pedalHoldLimit and were
        // never added here. Order is cosmetic (the encoder sorts keys); the
        // grouping records which item each arrived with.
        case bendRangeSemitones, voiceMode, decay, sustain
        // m34-t.
        case glideTime
        // m34-w.
        case glideMode
        // PK-F2.
        case sliceKit
    }

    init(from s: SamplerParams, mediaRefs: [UUID: String?]) {
        zones = s.zones.map { SamplerZoneDocument(from: $0, media: mediaRefs[$0.id] ?? nil) }
        oneShot = s.oneShot
        attack = s.attack
        release = s.release
        gain = s.gain
        sourcePath = s.sourcePath
        displayName = s.displayName
        expressionModDepth = s.expressionModDepth
        expressionFilterDepth = s.expressionFilterDepth
        expressionFilterCC = s.expressionFilterCC
        pedalHoldLimit = s.pedalHoldLimit
        bendRangeSemitones = s.bendRangeSemitones
        // The enum's rawValue, per the loopMode precedent above.
        voiceMode = s.voiceMode?.rawValue
        decay = s.decay
        sustain = s.sustain
        glideTime = s.glideTime
        // The enum's rawValue, per the voiceMode precedent above.
        glideMode = s.glideMode?.rawValue
        sliceKit = s.sliceKit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplerParams()
        zones = try c.decodeIfPresent([SamplerZoneDocument].self, forKey: .zones) ?? []
        oneShot = try c.decodeIfPresent(Bool.self, forKey: .oneShot) ?? d.oneShot
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? d.attack
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? d.release
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? d.gain
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        expressionModDepth = try c.decodeIfPresent(Double.self, forKey: .expressionModDepth)
        expressionFilterDepth = try c.decodeIfPresent(Double.self, forKey: .expressionFilterDepth)
        expressionFilterCC = try c.decodeIfPresent(Int.self, forKey: .expressionFilterCC)
        pedalHoldLimit = try c.decodeIfPresent(Int.self, forKey: .pedalHoldLimit)
        bendRangeSemitones = try c.decodeIfPresent(Double.self, forKey: .bendRangeSemitones)
        voiceMode = try c.decodeIfPresent(String.self, forKey: .voiceMode)
        decay = try c.decodeIfPresent(Double.self, forKey: .decay)
        sustain = try c.decodeIfPresent(Double.self, forKey: .sustain)
        glideTime = try c.decodeIfPresent(Double.self, forKey: .glideTime)
        glideMode = try c.decodeIfPresent(String.self, forKey: .glideMode)
        sliceKit = try c.decodeIfPresent(Bool.self, forKey: .sliceKit)
    }
}

/// Persistable sampler-zone facts. `media` is a `media/<name>` reference
/// (self-contained bundle), an absolute path (recovery bundles only), or null
/// (source missing at save). `id` is required (identity); pitch/gain fields are
/// additive-optional with the model's defaults.
///
/// m19-a selection fields (minVelocity...randMax) and m19-b playback scalars
/// (tuneCents...release) persist as additive-optional keys that are OMITTED
/// when nil (the ClipDocument omit-when-default rule) — a pre-m19 zone's
/// document shape stays byte-identical across a round trip, and pre-m19
/// project files decode every new field as nil (= the legacy behavior).
public struct SamplerZoneDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var media: String?
    public var rootPitch: Int
    public var minPitch: Int
    public var maxPitch: Int
    public var gain: Double
    // m19-a selection dimension — nil never encodes.
    public var minVelocity: Int?
    public var maxVelocity: Int?
    public var group: Int?
    public var seqLength: Int?
    public var seqPosition: Int?
    public var randMin: Double?
    public var randMax: Double?
    // m19-b playback scalars — nil never encodes.
    public var tuneCents: Double?
    public var pan: Double?
    public var ampVelTrack: Double?
    public var oneShot: Bool?
    public var startFrame: Int?
    public var endFrame: Int?
    public var attack: Double?
    public var decay: Double?
    public var sustain: Double?
    public var release: Double?
    // m20-g loop fields — nil never encodes. loopMode is the enum's rawValue;
    // the document layer stays string-typed like `media`.
    public var loopMode: String?
    public var loopStart: Int?
    public var loopEnd: Int?
    // m27 leg B dynamic-layer crossfade -- nil never encodes.
    public var crossfade: SamplerCrossfade?
    // m32-d reverse playback -- nil never encodes.
    public var reverse: Bool?
    // m32-f per-zone choke group -- nil never encodes.
    public var chokeGroup: Int?
    // m39-w4-6 drum role (`DrumVoice` raw value) -- nil never encodes. String
    // typed like `loopMode`: a role from a newer version stays readable here
    // and resolves to nil at the converter instead of failing the open.
    public var drumRole: String?

    /// ⚠️ EVERY field of this struct is enumerated by hand THREE more times
    /// below — in `CodingKeys`, in `init(from decoder:)` and in `encode(to:)` —
    /// and once again in `instrumentDescriptor`'s converter. There is no
    /// synthesis to save you: a new field added to the struct and forgotten in
    /// this list PARSES, PLAYS, and then VANISHES on the next save/load, with
    /// nothing failing anywhere. That is why every new zone field ships with a
    /// full `zones` → save → open → describe round-trip test.
    private enum CodingKeys: String, CodingKey {
        case id, media, rootPitch, minPitch, maxPitch, gain
        case minVelocity, maxVelocity, group, seqLength, seqPosition, randMin, randMax
        case tuneCents, pan, ampVelTrack, oneShot, startFrame, endFrame
        case attack, decay, sustain, release
        case loopMode, loopStart, loopEnd
        case crossfade
        case reverse
        case chokeGroup
        case drumRole
    }

    init(from z: SamplerZone, media: String?) {
        id = z.id
        self.media = media
        rootPitch = z.rootPitch
        minPitch = z.minPitch
        maxPitch = z.maxPitch
        gain = z.gain
        minVelocity = z.minVelocity
        maxVelocity = z.maxVelocity
        group = z.group
        seqLength = z.seqLength
        seqPosition = z.seqPosition
        randMin = z.randMin
        randMax = z.randMax
        tuneCents = z.tuneCents
        pan = z.pan
        ampVelTrack = z.ampVelTrack
        oneShot = z.oneShot
        startFrame = z.startFrame
        endFrame = z.endFrame
        attack = z.attack
        decay = z.decay
        sustain = z.sustain
        release = z.release
        loopMode = z.loopMode?.rawValue
        loopStart = z.loopStart
        loopEnd = z.loopEnd
        crossfade = z.crossfade
        reverse = z.reverse
        chokeGroup = z.chokeGroup
        drumRole = z.drumRole?.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity is required — a missing id is a damaged file
        media = try c.decodeIfPresent(String.self, forKey: .media)
        rootPitch = try c.decodeIfPresent(Int.self, forKey: .rootPitch) ?? 60
        minPitch = try c.decodeIfPresent(Int.self, forKey: .minPitch) ?? 0
        maxPitch = try c.decodeIfPresent(Int.self, forKey: .maxPitch) ?? 127
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        minVelocity = try c.decodeIfPresent(Int.self, forKey: .minVelocity)
        maxVelocity = try c.decodeIfPresent(Int.self, forKey: .maxVelocity)
        group = try c.decodeIfPresent(Int.self, forKey: .group)
        seqLength = try c.decodeIfPresent(Int.self, forKey: .seqLength)
        seqPosition = try c.decodeIfPresent(Int.self, forKey: .seqPosition)
        randMin = try c.decodeIfPresent(Double.self, forKey: .randMin)
        randMax = try c.decodeIfPresent(Double.self, forKey: .randMax)
        tuneCents = try c.decodeIfPresent(Double.self, forKey: .tuneCents)
        pan = try c.decodeIfPresent(Double.self, forKey: .pan)
        ampVelTrack = try c.decodeIfPresent(Double.self, forKey: .ampVelTrack)
        oneShot = try c.decodeIfPresent(Bool.self, forKey: .oneShot)
        startFrame = try c.decodeIfPresent(Int.self, forKey: .startFrame)
        endFrame = try c.decodeIfPresent(Int.self, forKey: .endFrame)
        attack = try c.decodeIfPresent(Double.self, forKey: .attack)
        decay = try c.decodeIfPresent(Double.self, forKey: .decay)
        sustain = try c.decodeIfPresent(Double.self, forKey: .sustain)
        release = try c.decodeIfPresent(Double.self, forKey: .release)
        loopMode = try c.decodeIfPresent(String.self, forKey: .loopMode)
        loopStart = try c.decodeIfPresent(Int.self, forKey: .loopStart)
        loopEnd = try c.decodeIfPresent(Int.self, forKey: .loopEnd)
        crossfade = try c.decodeIfPresent(SamplerCrossfade.self, forKey: .crossfade)
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse)
        chokeGroup = try c.decodeIfPresent(Int.self, forKey: .chokeGroup)
        drumRole = try c.decodeIfPresent(String.self, forKey: .drumRole)
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
        try c.encodeIfPresent(minVelocity, forKey: .minVelocity)
        try c.encodeIfPresent(maxVelocity, forKey: .maxVelocity)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(seqLength, forKey: .seqLength)
        try c.encodeIfPresent(seqPosition, forKey: .seqPosition)
        try c.encodeIfPresent(randMin, forKey: .randMin)
        try c.encodeIfPresent(randMax, forKey: .randMax)
        try c.encodeIfPresent(tuneCents, forKey: .tuneCents)
        try c.encodeIfPresent(pan, forKey: .pan)
        try c.encodeIfPresent(ampVelTrack, forKey: .ampVelTrack)
        try c.encodeIfPresent(oneShot, forKey: .oneShot)
        try c.encodeIfPresent(startFrame, forKey: .startFrame)
        try c.encodeIfPresent(endFrame, forKey: .endFrame)
        try c.encodeIfPresent(attack, forKey: .attack)
        try c.encodeIfPresent(decay, forKey: .decay)
        try c.encodeIfPresent(sustain, forKey: .sustain)
        try c.encodeIfPresent(release, forKey: .release)
        try c.encodeIfPresent(loopMode, forKey: .loopMode)
        try c.encodeIfPresent(loopStart, forKey: .loopStart)
        try c.encodeIfPresent(loopEnd, forKey: .loopEnd)
        try c.encodeIfPresent(crossfade, forKey: .crossfade)
        try c.encodeIfPresent(reverse, forKey: .reverse)
        try c.encodeIfPresent(chokeGroup, forKey: .chokeGroup)
        try c.encodeIfPresent(drumRole, forKey: .drumRole)
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
    /// Breakpoint gain envelope (m13-e) — additive optional, same omit-when-empty
    /// rule: stored ONLY when the clip carries a non-empty envelope, so a
    /// pre-m13-e project stays byte-identical across a round trip. `nil`/absent
    /// reads as no envelope on load. NOTE (the m12-f mirror-DTO lesson): the disk
    /// path is THIS DTO, not `Clip`'s own Codable — this field must be threaded
    /// through `init(from clip:)`, encode, decode, AND `runtimeState`, or every
    /// envelope silently vanishes on reopen.
    public var gainEnvelope: [ClipGainPoint]?
    /// MIDI controller lanes (m16-b) — additive optional, same omit-when-empty
    /// rule as `gainEnvelope`: stored ONLY when the clip carries a non-empty lane
    /// set, so a pre-m16-b project stays byte-identical across a round trip.
    /// `nil`/absent reads as no lanes on load. Same m12-f mirror-DTO lesson: this
    /// field must be threaded through `init(from clip:)`, encode, decode, AND
    /// `runtimeState`, or every controller lane silently vanishes on reopen.
    public var controllerLanes: [MIDIControllerLane]?
    /// Note-level pitch correction (m23-ap, design §7.3) — additive optional,
    /// same omit-when-empty rule as `gainEnvelope`/`controllerLanes`: stored
    /// ONLY when the clip carries a non-empty edit set, so a pre-m23-ap project
    /// stays byte-identical across a round trip. `nil`/absent reads as no edits
    /// on load. A project WITH edits opened by an older build has the key
    /// ignored and the clip plays uncorrected — lossy but non-destructive,
    /// exactly how `gainEnvelope` and `controllerLanes` already behave.
    ///
    /// ⚠️⚠️ Same m12-f mirror-DTO lesson, and design §7.3 calls it the trap of
    /// its section: this field must be threaded through `init(from clip:)`,
    /// encode, decode, AND **BOTH** `ClipDocument`→`Clip` reconstructions —
    /// `ProjectDocument.runtimeState` for timeline clips and
    /// `TakeGroupDocument.takeGroup` for take lanes. §7.5 calls take lanes
    /// "free"; they are free in the DTO and NOT free in the reconstruction,
    /// which is precisely how `gainEnvelope` silently vanished from take lanes
    /// for three milestones until m16-b3 found it.
    public var pitchEdits: PitchEditSet?
    /// Typed lyrics (p2-sing-d1b) — additive optional, the omit-when-nil rule:
    /// stored ONLY when the clip has lyrics, so a project without any stays
    /// byte-identical across a round trip; absent reads as none. Same m12-f
    /// mirror-DTO lesson as `pitchEdits`: threaded through `init(from clip:)`,
    /// encode, decode AND both `ClipDocument`→`Clip` reconstructions.
    public var lyrics: ClipLyrics?
    /// Singing style (p2-sing-x5, design `2026-10-06-p2-sing-expansion.md`
    /// §5.3) — additive optional, the omit-when-nil rule: stored ONLY when the
    /// clip has a style, so a project without any stays byte-identical across
    /// a round trip (design §9 S2); absent reads as none. Same m12-f
    /// mirror-DTO lesson: threaded through `init(from clip:)`, encode, decode
    /// AND both `ClipDocument`→`Clip` reconstructions.
    public var singStyle: SingStyle?
    /// Take-group marker (M5 iii-a) — additive optional, same omit-when-nil rule.
    /// Set only on comp member clips; a pre-take clip has no key and stays
    /// byte-identical across a round trip.
    public var takeGroupId: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, name, startBeat, lengthBeats, media, notes, isAIGenerated
        case startOffsetSeconds, gainDb, fadeInBeats, fadeOutBeats, fadeInCurve, fadeOutCurve
        case stretchRatio, pitchShiftSemitones, formantPreserve, gainEnvelope, controllerLanes, takeGroupId
        case pitchEdits
        case lyrics
        case singStyle
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
        gainEnvelope = clip.gainEnvelope.isEmpty ? nil : clip.gainEnvelope
        controllerLanes = clip.controllerLanes.isEmpty ? nil : clip.controllerLanes
        // Pitch edits (m23-ap): `Clip.init` already normalised an empty set to
        // nil, so an unedited clip carries no key here either.
        pitchEdits = clip.pitchEdits
        // Lyrics (p2-sing-d1b): `Clip.init` already normalised blank text to
        // nil, so a clip without lyrics carries no key here either.
        lyrics = clip.lyrics
        // Singing style (p2-sing-x5): the one spelling `Clip.encode` writes
        // too (nil for an audio clip or an all-default style).
        singStyle = clip.singStyleToWrite
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
        gainEnvelope = try c.decodeIfPresent([ClipGainPoint].self, forKey: .gainEnvelope)
        controllerLanes = try c.decodeIfPresent([MIDIControllerLane].self, forKey: .controllerLanes)
        pitchEdits = try c.decodeIfPresent(PitchEditSet.self, forKey: .pitchEdits)
        lyrics = try c.decodeIfPresent(ClipLyrics.self, forKey: .lyrics)
        singStyle = try c.decodeIfPresent(SingStyle.self, forKey: .singStyle)
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
        // Gain envelope (m13-e): omitted when nil/absent (the clip had none), so
        // a pre-m13-e clip never grows a key.
        try c.encodeIfPresent(gainEnvelope, forKey: .gainEnvelope)
        // Controller lanes (m16-b): omitted when nil/absent (the clip had none),
        // so a pre-m16-b clip never grows a key.
        try c.encodeIfPresent(controllerLanes, forKey: .controllerLanes)
        // Pitch edits (m23-ap): omitted when nil/absent (the clip had none), so a
        // pre-m23-ap clip never grows a key.
        try c.encodeIfPresent(pitchEdits, forKey: .pitchEdits)
        // Lyrics (p2-sing-d1b): omitted when nil, so a clip without lyrics
        // never grows a key.
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        // Singing style (p2-sing-x5): omitted when nil, so a clip without one
        // never grows a key.
        try c.encodeIfPresent(singStyle, forKey: .singStyle)
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
                formantPreserve: cd.formantPreserve ?? false,
                // m16-b3 (design-m16b §14 amendment A1 / C13a): thread the
                // envelope AND the controller lanes — this reconstruction
                // silently dropped `gainEnvelope` since m13-e, and b2's lanes
                // inherited the same gap. The main `tracks` path (:196/:200)
                // always threaded both; take lanes now match it.
                gainEnvelope: cd.gainEnvelope ?? [],
                controllerLanes: cd.controllerLanes ?? [],
                // m23-ap: threaded HERE TOO. Design §7.5 calls take lanes
                // "free" because `TakeLaneDocument.clip` is a `ClipDocument` —
                // true of the DTO, FALSE of this reconstruction, which is a
                // second hand-maintained field list. That is exactly how
                // `gainEnvelope` went missing from take lanes from m13-e until
                // m16-b3 found it.
                pitchEdits: cd.pitchEdits,
                // p2-sing-d1b: the same second field list, so lyrics are
                // threaded here too.
                lyrics: cd.lyrics,
                // p2-sing-x5: and the singing style, verbatim (no pruning at
                // load).
                singStyle: cd.singStyle)
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

/// Persistable reference-slot facts (m22-g) — mirrors `ReferenceSlot`, but
/// `media` rides as a bundle-relative `media/<name>` ref (self-contained
/// bundle), an absolute path (recovery bundles / missing-at-save sources),
/// or null — the `ClipDocument.media` mechanism verbatim. `analysis` reuses
/// `ReferenceAnalysis` directly (no media, its Codable IS the disk shape —
/// the `automation`/`markers` rule). `id` is required (identity); the rest
/// are additive-optional with the model defaults.
public struct ReferenceDocument: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var media: String?
    public var offsetSeconds: Double
    public var trimDb: Double
    public var analysis: ReferenceAnalysis?

    private enum CodingKeys: String, CodingKey {
        case id, name, media, offsetSeconds, trimDb, analysis
    }

    init(from slot: ReferenceSlot, media: String?) {
        id = slot.id
        name = slot.name
        self.media = media
        offsetSeconds = slot.offsetSeconds
        trimDb = slot.trimDb
        analysis = slot.analysis
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)  // identity required — a missing id is a damaged file
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Reference"
        media = try c.decodeIfPresent(String.self, forKey: .media)
        offsetSeconds = try c.decodeIfPresent(Double.self, forKey: .offsetSeconds) ?? 0
        trimDb = try c.decodeIfPresent(Double.self, forKey: .trimDb) ?? 0
        analysis = try c.decodeIfPresent(ReferenceAnalysis.self, forKey: .analysis)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        // Explicit `null` when absent (schema shape), matching ClipDocument.
        try c.encode(media, forKey: .media)
        try c.encode(offsetSeconds, forKey: .offsetSeconds)
        try c.encode(trimDb, forKey: .trimDb)
        // Omitted when nil (not yet analyzed) — the EffectDocument param rule.
        try c.encodeIfPresent(analysis, forKey: .analysis)
    }
}
