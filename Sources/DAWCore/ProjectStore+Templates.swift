import Foundation

// m39-tpl-2 — `ProjectStore.applyTemplate(_:dryRun:)`: a whole sound setup in
// ONE undo step (docs/design/2026-09-27-multi-instrument-templates.md §5.4).
//
// Everything that can be judged without the live project is judged by the pure
// `TemplateBuilder`; this file adds ONLY what needs the live project: the
// file-backed resources on this Mac, the recording guard, the edit, and the
// engine. The order is the contract:
//
//   1. plan (a refusal records nothing);
//   2. resources, through the store's own validators (`validateSoundBank`,
//      `validateSamplerZones`) — a missing Audio Unit is a WARNING, never a
//      refusal: the track keeps the plug-in reference, the way a project with a
//      missing plug-in opens;
//   3. while recording, a template that connects its tracks (an output into a
//      bus, a send, a sidechain key) is refused through
//      `requireRoutingMutationAllowed`; a template of plain tracks is the
//      guard's own "attach-only" case and applies mid-take, like `track.add`;
//   4. `dryRun` stops HERE and replies `applied: false`, with no ids;
//   5. ONE `performEdit("Add Template '<name>'")` with NO coalescing key, so it
//      is exactly one undo step that never merges with a neighbour, and the
//      engine is told INSIDE it (the skeleton's pattern).
//
// ⭐ A REFUSAL CHANGES NOTHING AND RECORDS NO UNDO ENTRY: steps 1–3 run before
// the edit. Do not move a check into the edit body — `performEdit` journals
// nothing when its body throws, so a check placed after the tracks are
// appended would leave them in the song with no undo step to take them out.
//
// ⭐ ADDITIVE, NEVER IDEMPOTENT: applying twice adds the band twice (the
// skeleton's precedent). Names may repeat — they are labels, not identities —
// and the reply says so (`duplicateTrackNames`); nothing is renamed. The master
// chain, tempo, markers, the loop and every existing track are untouched.
//
// TODO(TPL-6): the wire verb `template.apply {template, dryRun?}` in
// `Sources/DAWControl/Commands.swift`, placed right after `playbox.generate`
// in `allCommands` (design §6.1, §6.3). This store function is its whole body.
// TODO(TPL-7): the MCP tool `template_apply` in `mcp-server/src/server.ts`, its
// `template` an opaque `z.union([z.string(), z.record(z.string(), z.unknown())])`
// so the app's codec, not a zod copy, refuses a misspelled key (design §6.5).

/// What `applyTemplate` did — or, on a dry run, would do (§6.1's reply).
public struct TemplateApplyResult: Sendable, Equatable {
    public struct TrackRef: Sendable, Equatable {
        /// The template's key for the track.
        public var key: String
        /// The new track's id; nil on a dry run, where nothing was created.
        public var id: UUID?
        public var name: String
        public var kind: TrackKind

        public init(key: String, id: UUID?, name: String, kind: TrackKind) {
            self.key = key
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    /// False on a dry run.
    public var applied: Bool
    /// The template's name.
    public var name: String
    /// Every track the template adds, in order.
    public var tracks: [TrackRef]
    /// The builder's warnings, then the store's (`audioUnitMissing`,
    /// `duplicateTrackNames`), each `{code, path, message}`.
    public var warnings: [TemplateWarning]
    /// Names that, after the apply, belong to more than one track in the song —
    /// so a UI can say "You now have two tracks called Drums." Nothing is
    /// renamed.
    public var duplicateTrackNames: [String]
    /// "Add Template '<name>'".
    public var undoLabel: String
    /// True when the template connects its tracks (an output into a bus, a
    /// send, or a sidechain key).
    public var hasRouting: Bool
    /// Per track key: the strip's effect-setting slots its modulation uses (of 64).
    public var slotsUsed: [String: Int]

    /// Every key → its new track's id. Empty on a dry run.
    public var keyToTrackID: [String: UUID] {
        var map: [String: UUID] = [:]
        for track in tracks { if let id = track.id { map[track.key] = id } }
        return map
    }

    public init(applied: Bool, name: String, tracks: [TrackRef], warnings: [TemplateWarning],
                duplicateTrackNames: [String], undoLabel: String, hasRouting: Bool,
                slotsUsed: [String: Int]) {
        self.applied = applied
        self.name = name
        self.tracks = tracks
        self.warnings = warnings
        self.duplicateTrackNames = duplicateTrackNames
        self.undoLabel = undoLabel
        self.hasRouting = hasRouting
        self.slotsUsed = slotsUsed
    }
}

extension ProjectStore {
    /// Adds `template`'s tracks to the song as ONE undoable edit ("Add
    /// Template '<name>'"), or — with `dryRun` — checks everything and reports
    /// what it would add, changing nothing. Throws `TemplateRefusal` for any
    /// builder or resource refusal and `ProjectError.transportBusy` for a
    /// connected template while recording; a refusal changes nothing and
    /// records no undo step.
    @discardableResult
    public func applyTemplate(_ template: TrackSetTemplate,
                              dryRun: Bool = false) throws -> TemplateApplyResult {
        // 1. The plan. A throw here records nothing.
        let plan = try TemplateBuilder.plan(template)

        // 2. File-backed resources, BEFORE the edit.
        var warnings = plan.warnings
        warnings += try checkTemplateResources(plan)

        // 3. The recording guard, for a template that connects its tracks.
        if plan.hasRouting {
            try requireRoutingMutationAllowed("add a template whose tracks play into each other")
        }

        let duplicates = Self.templateDuplicateNames(adding: plan.tracks, to: tracks)
        for name in duplicates {
            let count = tracks.filter { $0.name == name }.count
                + plan.tracks.filter { $0.name == name }.count
            let index = plan.tracks.firstIndex(where: { $0.name == name }) ?? 0
            warnings.append(TemplateWarning(
                code: .duplicateTrackNames, path: "\(TemplateBuilder.trackPath(index)).name",
                message: "After this, the song has \(count) tracks called '\(name)'. Nothing is "
                    + "renamed; rename one if that gets confusing."))
        }
        let label = "Add Template '\(template.name)'"

        func reply(applied: Bool) -> TemplateApplyResult {
            TemplateApplyResult(
                applied: applied, name: template.name,
                tracks: zip(template.tracks, plan.tracks).map { spec, track in
                    .init(key: spec.key, id: applied ? track.id : nil, name: track.name,
                          kind: track.kind)
                },
                warnings: warnings, duplicateTrackNames: duplicates, undoLabel: label,
                hasRouting: plan.hasRouting, slotsUsed: plan.slotsUsed)
        }

        // 4. A dry run stops here.
        if dryRun { return reply(applied: false) }

        // 5. ONE edit, no coalescing key, the engine told inside it.
        performEdit(label) {
            tracks.append(contentsOf: plan.tracks)
            engine?.tracksDidChange(tracks)
        }
        return reply(applied: true)
    }

    /// §5.4 step 2: every sound bank and sampler zone file through the store's
    /// own validators (a refusal names the path); every Audio Unit against the
    /// plug-ins this Mac has (missing = a warning). Module-internal since
    /// m39-tpl-3: `planSongSkeleton(template:)` checks a template's files
    /// through this SAME function (one home), before its edit.
    func checkTemplateResources(_ plan: TemplatePlan) throws -> [TemplateWarning] {
        var warnings: [TemplateWarning] = []
        var instruments: [AudioUnitComponentInfo]?
        var effects: [AudioUnitComponentInfo]?
        for resource in plan.resources {
            let trackName = plan.keyToTrackID[resource.trackKey]
                .flatMap { id in plan.tracks.first(where: { $0.id == id })?.name }
                ?? resource.trackKey
            switch resource.item {
            case .soundBank(let bank):
                do {
                    try validateSoundBank(bank)
                } catch {
                    throw TemplateRefusal(
                        code: .invalidValue, path: resource.path,
                        message: "this sound bank can't be used: \(Self.templateReason(error)).")
                }
            case .samplerZones(let zones):
                do {
                    try validateSamplerZones(zones)
                } catch {
                    throw TemplateRefusal(
                        code: .invalidValue, path: resource.path,
                        message: "a Sampler sound file can't be used: "
                            + "\(Self.templateReason(error)).")
                }
            case .audioUnitInstrument(let unit):
                if instruments == nil { instruments = availableAudioUnits() }
                if !(instruments ?? []).contains(where: { $0.component == unit.component }) {
                    warnings.append(Self.audioUnitMissing(unit, resource.path, trackName))
                }
            case .audioUnitEffect(let unit):
                if effects == nil { effects = availableAudioUnitEffects() }
                if !(effects ?? []).contains(where: { $0.component == unit.component }) {
                    warnings.append(Self.audioUnitMissing(unit, resource.path, trackName))
                }
            }
        }
        return warnings
    }

    private static func audioUnitMissing(_ unit: AudioUnitConfig, _ path: String,
                                         _ trackName: String) -> TemplateWarning {
        let component = unit.component
        let label = unit.name.isEmpty
            ? "\(component.type)/\(component.subType)/\(component.manufacturer)"
            : unit.name
        return TemplateWarning(
            code: .audioUnitMissing, path: path,
            message: "'\(trackName)' uses the plug-in \(label), which isn't installed on this "
                + "Mac. The track keeps it, and stays silent until the plug-in is installed.")
    }

    /// A validator's reason without its "Audio import failed:" frame.
    private static func templateReason(_ error: any Error) -> String {
        if case ProjectError.importFailed(let reason) = error { return reason }
        return error.localizedDescription
    }

    /// Names of the new tracks that, once added, belong to more than one track
    /// in the song, in the template's order, each once.
    static func templateDuplicateNames(adding new: [Track], to existing: [Track]) -> [String] {
        var counts: [String: Int] = [:]
        for track in existing + new { counts[track.name, default: 0] += 1 }
        var seen: Set<String> = []
        var names: [String] = []
        for track in new where counts[track.name, default: 0] > 1 {
            if seen.insert(track.name).inserted { names.append(track.name) }
        }
        return names
    }
}
