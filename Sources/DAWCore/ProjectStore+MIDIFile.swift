import Foundation

// Standard MIDI File import onto the project — m23-k3 Step 2 (design:
// docs/research/m23-k3-midi-import-design.md §6).
//
// This file is DELIBERATELY THIN. Every mapping decision — tick→beat, the
// tempo/meter maps, the part split, the controller caps, every hazard verdict —
// lives in `SMFProjectMapper` and is typed into a `MIDIImportPlan` whose
// initializer is `fileprivate` to that file, so the store CANNOT compute a plan
// for itself. What is left here is exactly the store's own business: the
// guards, the file checks, one journaled edit, and one engine reconcile.
@MainActor
extension ProjectStore {

    /// Extensions this importer accepts.
    public nonisolated static let midiFileExtensions: Set<String> = ["mid", "midi"]

    /// Imports a Standard MIDI File as new instrument tracks.
    ///
    /// - Parameters:
    ///   - path: absolute (or `~`-prefixed) path to a `.mid` / `.midi` file.
    ///   - atBeat: timeline beat that file tick 0 lands on. It becomes every
    ///     created clip's `startBeat`; notes stay CLIP-relative, so the parts
    ///     keep their alignment with each other and with the tempo map.
    ///   - tempoPolicy: `.auto` (default) adopts the file's tempo/meter maps
    ///     only when the project has no clips yet — `importGeneration`'s exact
    ///     predicate. `.adopt` always replaces them; `.ignore` never does.
    ///     Adoption is folded into the SAME edit as the tracks, so one undo
    ///     restores the tempo AND removes the tracks.
    ///   - instruments: `.none` (default) leaves the new tracks on the default
    ///     instrument; `.gm` assigns General MIDI sound-bank programs from the
    ///     file's program changes. The program a part asks for is REPORTED
    ///     either way.
    ///   - parts: which parts to import, indexing the report's `parts` array
    ///     (which lists every part, including skipped ones). nil = all.
    ///   - dryRun: computes the full report and touches NOTHING — no edit, no
    ///     undo entry, no engine reconcile.
    ///   - force: overrides the `maxImportedTracks` refusal.
    /// - Returns: the full `MIDIImportReport`, with real track/clip ids on an
    ///   apply and nil ids on a dry run.
    @discardableResult
    public func importMIDIFile(path: String,
                               atBeat: Double = 0,
                               tempoPolicy: MIDITempoPolicy = .auto,
                               instruments: MIDIImportInstruments = .none,
                               parts: [Int]? = nil,
                               dryRun: Bool = false,
                               force: Bool = false) throws -> MIDIImportReport {
        // D1″ — refuse while recording, uniformly, before any file work.
        // `setTempoMap` already refuses while recording, and this import folds
        // tempo adoption INSIDE its own `performEdit` (bypassing that guard,
        // exactly as `importGeneration` bypasses `setTempo`'s multi-segment
        // guard). Without an up-front check the behaviour would silently differ
        // by policy; refusing uniformly is one sentence to explain and has no
        // half-state.
        try requireTransportIdleForMIDIImport()

        let url = try Self.midiFileURL(path: path)
        let file = try StandardMIDIFileReader.decode(contentsOf: url)
        let options = MIDIImportOptions(atBeat: max(0, atBeat),
                                        tempoPolicy: tempoPolicy,
                                        instruments: instruments,
                                        parts: parts,
                                        force: force)
        let plan = try SMFProjectMapper.map(file, options: options,
                                            context: midiImportContext())

        // A dry run returns BEFORE the zero-effect refusal (the
        // `importSampleLibrary` order, `ProjectStore+SampleLibraries.swift:69`
        // vs `:70`): the whole point of a dry run is to find out.
        if dryRun { return Self.reportWithoutIDs(plan.report) }

        // §3.3b — a `project.importMIDI` that would create ZERO tracks AND adopt
        // NO map is a refusal, not an `ok: true` no-op. Measured off the REPORT,
        // never off the requested policy: an `adopt` of a file that carries no
        // tempo or meter events at all resolves to a no-op adoption (H4c) and
        // would otherwise return success having done nothing, which reads to the
        // user as "this file was empty" — a lie about their file. The condition
        // is deliberately the CONJUNCTION: zero tracks WITH an adopted map is a
        // legitimate tempo-map import and succeeds normally.
        guard !plan.report.wouldChangeNothing else {
            throw MIDIImportError.nothingToImport(fileName: url.lastPathComponent,
                                                  contained: plan.report.contentSummary)
        }

        let newTracks = plan.tracks.map(\.track)
        performEdit("Import MIDI File") {
            // Tempo/meter adoption folds into this SAME edit — the
            // `importGeneration` atomicity model — so ONE undo restores the
            // previous tempo along with removing every track. `applyTempoMap`
            // (not `setTempoMap`) is the entry point: the public one opens its
            // own `performEdit` and carries the recording guard we already ran.
            if let tempoMap = plan.tempoMap {
                applyTempoMap(tempoMap, meterMap: plan.meterMap)
            }
            tracks.append(contentsOf: newTracks)
            // MANDATORY. Notes AND controller lanes ride the `ClipKey` that
            // drives schedule rebuilds (`setControllerLane`'s own comment: "A
            // ClipKey-affecting edit … the engine must re-schedule"). Omit this
            // and the imported content is silent until some unrelated edit
            // happens to trigger a reschedule — a bug no model-level test can
            // catch.
            engine?.tracksDidChange(tracks)
        }
        return plan.report
    }

    /// Imports ONE part of a Standard MIDI File into an EXISTING MIDI clip,
    /// replacing its notes and controller lanes wholesale.
    ///
    /// Deliberately narrow: it NEVER touches the project's tempo or meter (that
    /// is `importMIDIFile`'s job — a clip-level import must not move the
    /// project grid) and NEVER changes the clip's `lengthBeats`. Content past
    /// the clip end is imported and REPORTED (`notesPastClipEnd`); grow the clip
    /// with the existing `clip.fitToContent` if you want it. Growing the clip
    /// here would make an import destructively trim a NEIGHBOURING clip through
    /// the overlap apparatus — composing with a shipped command is strictly
    /// better than a hidden side effect.
    ///
    /// - Parameters:
    ///   - clipID: an existing MIDI clip.
    ///   - path: absolute (or `~`-prefixed) path to a `.mid` / `.midi` file.
    ///   - part: which part of the file, indexing the report's `parts` array.
    ///     Default: the lowest-indexed part with notes; if none has notes, the
    ///     lowest with controller data.
    ///   - atBeat: CLIP-RELATIVE offset for the imported content (default 0).
    ///   - dryRun: computes the full report and touches nothing.
    @discardableResult
    public func importMIDIIntoClip(clipID: UUID,
                                   path: String,
                                   part: Int? = nil,
                                   atBeat: Double = 0,
                                   dryRun: Bool = false) throws -> MIDIImportReport {
        try requireTransportIdleForMIDIImport()

        // Clip guards FIRST (fail fast, before any file work) — the same order
        // and the same named guards every other clip content edit uses.
        guard let (t, c) = locateMIDIImportClip(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let target = tracks[t].clips[c]
        guard target.isMIDI else {
            throw ProjectError.notAMIDIClip(clipID, verb: "clip.importMIDI")
        }

        let url = try Self.midiFileURL(path: path)
        let file = try StandardMIDIFileReader.decode(contentsOf: url)

        // Default part selection: notes beat controllers, lowest index wins.
        let enumerated = SMFProjectMapper.enumerateParts(file)
        let selected: Int
        if let part {
            guard part >= 0, part < enumerated.count else {
                throw MIDIImportError.partIndexOutOfRange(index: part,
                                                          partCount: enumerated.count)
            }
            selected = part
        } else if let withNotes = enumerated.first(where: { !$0.notes.isEmpty }) {
            selected = withNotes.index
        } else if let withControllers = enumerated.first(where: { !$0.controllers.isEmpty }) {
            selected = withControllers.index
        } else {
            throw MIDIImportError.nothingToImport(
                fileName: url.lastPathComponent,
                contained: "none of its \(enumerated.count) part(s) carries notes or "
                    + "controller data")
        }

        let options = MIDIImportOptions(atBeat: 0,
                                        contentOffsetBeats: max(0, atBeat),
                                        // A clip import never moves the grid, so
                                        // there is no policy to resolve.
                                        tempoPolicy: .ignore,
                                        instruments: .none,
                                        parts: [selected])
        let plan = try SMFProjectMapper.map(
            file, options: options,
            context: midiImportContext(targetClipLengthBeats: target.lengthBeats))

        var report = plan.report
        guard let planned = plan.tracks.first else {
            if dryRun { return Self.reportWithoutIDs(report) }
            // Replacing the clip's content with nothing would silently CLEAR it.
            // `clip.setNotes` is the command for that; an import says what it
            // found instead.
            throw MIDIImportError.nothingToImport(fileName: url.lastPathComponent,
                                                  contained: report.contentSummary)
        }
        // The report's ids name the clip that actually receives the content, not
        // the track the mapper built to carry it.
        report = Self.reportWithoutIDs(report)
        // And NEITHER does the count. The mapper has one shape for building
        // content — it plans a `Track` carrying a `Clip` — so a clip import
        // necessarily produces one throwaway `PlannedTrack` whose `Track` is
        // discarded here. `tracksCreated` counts what the caller GOT, not what
        // the mapper allocated on the way, and on this verb the caller got zero
        // new tracks. Leaving the mapper's 1 here would make the report claim a
        // track appeared in the project when none did — and the report is the
        // honesty surface this whole verb is judged on.
        report.tracksCreated = 0
        if let index = report.parts.firstIndex(where: { $0.index == selected }) {
            report.parts[index].trackID = tracks[t].id
            report.parts[index].clipID = target.id
        }
        if dryRun { return report }

        let notes = planned.clip.notes ?? []
        let lanes = planned.clip.controllerLanes
        performEdit("Import MIDI into Clip") {
            tracks[t].clips[c].notes = notes
            tracks[t].clips[c].controllerLanes = lanes
            // The same `ClipKey` reschedule requirement as the project path —
            // both notes and lanes ride the schedule build.
            engine?.tracksDidChange(tracks)
        }
        return report
    }

    // MARK: - Export (m23-k4a)

    /// Writes the project out as a Standard MIDI File.
    ///
    /// EXPORT MUTATES NOTHING. There is no `performEdit`, no undo entry, no
    /// engine call — and, deliberately, no recording guard: `importMIDIFile`
    /// refuses while recording because it MUTATES and folds tempo adoption
    /// inside its own edit, so there is a half-state to protect. Reading the
    /// model has none, and a guard here would be one more rule to explain for no
    /// behaviour it changes.
    ///
    /// It also SERIALISES the model rather than RENDERING it, which is why it is
    /// `project.exportMIDI` and not `render.exportMIDI` (every `render.*`
    /// command runs the audio engine offline; this one never touches it). The
    /// visible consequences: muted and soloed tracks export like any other, and
    /// notes past a clip's end export at their authored positions. Both are
    /// REPORTED, neither is honoured. Pass `trackIDs` for the audible subset.
    ///
    /// - Parameters:
    ///   - path: destination. Omitted ⇒ a unique file under
    ///     `NSTemporaryDirectory()/DAWPro/` (the `renderBounce` policy); `~`
    ///     expands; `.mid` is appended unless the path already ends in `.mid` or
    ///     `.midi` (case-insensitive); parent directories are created; an
    ///     existing file is OVERWRITTEN, because the caller chose the path.
    ///   - trackIDs: which tracks, in PROJECT order whatever order they arrive
    ///     in. Omitted = every track. Non-instrument tracks in the selection are
    ///     SKIPPED and reported, never an error.
    ///   - ticksPerQuarterNote: the file's division, 1…32767. The default 9600
    ///     is derived, not conventional — see
    ///     `MIDIExportOptions.defaultTicksPerQuarterNote`.
    ///   - format: 1 (default, one chunk per track) or 0 (everything merged into
    ///     one chunk, which can carry only one track name).
    ///   - dryRun: computes the full report and writes NOTHING.
    /// - Returns: the full `MIDIExportReport`.
    @discardableResult
    public func exportMIDIFile(
        path: String? = nil,
        trackIDs: [UUID]? = nil,
        ticksPerQuarterNote: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
        format: Int = 1,
        dryRun: Bool = false
    ) throws -> MIDIExportReport {
        let options = try Self.midiExportOptions(ticksPerQuarterNote: ticksPerQuarterNote,
                                                 format: format, trackIDs: trackIDs)
        // Unknown ids fail fast and name themselves, rather than silently
        // exporting a smaller file than the caller asked for.
        for id in trackIDs ?? [] where !tracks.contains(where: { $0.id == id }) {
            throw ProjectError.trackNotFound(id)
        }
        return try writeMIDIExport(options: options, path: path, dryRun: dryRun)
    }

    /// Writes ONE track out as a Standard MIDI File.
    ///
    /// Identical file shape to `exportMIDIFile` with `trackIDs: [thatOne]` — a
    /// conductor chunk plus one track chunk — so the two verbs differ only in
    /// selection and one implementation serves both.
    ///
    /// Unlike the project verb, this one REFUSES a non-instrument track instead
    /// of skipping it: an explicit single-track request naming a track that
    /// cannot carry MIDI is a mistake worth naming (the `notAMIDIClip` posture),
    /// and the alternative is writing a file with no notes in it.
    @discardableResult
    public func exportTrackMIDIFile(
        trackID: UUID,
        path: String? = nil,
        ticksPerQuarterNote: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
        format: Int = 1,
        dryRun: Bool = false
    ) throws -> MIDIExportReport {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        // `Track.canExportMIDI` (m23-m3b), not a local `kind == .instrument`: the
        // track-header menu decides whether to OFFER this action from the SAME
        // property, so "the menu showed it and the store refused" cannot happen.
        guard track.canExportMIDI else {
            throw MIDIExportError.notAnInstrumentTrack(name: track.name,
                                                       kind: track.kind.rawValue)
        }
        let options = try Self.midiExportOptions(ticksPerQuarterNote: ticksPerQuarterNote,
                                                 format: format, trackIDs: [trackID])
        return try writeMIDIExport(options: options, path: path, dryRun: dryRun)
    }

    /// The one body both verbs run. DELIBERATELY THIN, like the import half:
    /// every mapping decision lives in `SMFProjectExporter` behind a
    /// `fileprivate` plan initializer, so the store cannot compute a plan for
    /// itself. What is left here is the store's own business — the guards, the
    /// destination, and the write.
    private func writeMIDIExport(options: MIDIExportOptions,
                                 path: String?,
                                 dryRun: Bool) throws -> MIDIExportReport {
        let plan = try SMFProjectExporter.map(tracks: tracks,
                                              projectName: projectName,
                                              tempoMap: transport.tempoMap,
                                              meterMap: transport.meterMap,
                                              options: options)
        let url = Self.midiExportDestination(from: path)
        var report = plan.report
        // Filled on a dry run too: "where would this go" is one of the two
        // questions a dry run exists to answer.
        report.path = url.path

        // ENCODED ON A DRY RUN AS WELL. A rehearsal that cannot fail is not a
        // rehearsal: encoding is the last step that can refuse, and running it
        // here means `dryRun: true` predicts both the outcome AND the file size
        // exactly. Nothing is written either way — `Data` in memory is not a
        // file. (The design lists `byteCount` among the fields a dry run may
        // differ on; this implementation makes it AGREE, which is strictly
        // stronger and costs one encode of a control-plane-sized buffer.)
        let bytes = try StandardMIDIFileWriter.encode(plan.file)
        report.byteCount = bytes.count

        // A dry run returns BEFORE the zero-effect refusal — the
        // `importMIDIFile` order (`:68-71`), for the same reason: the whole
        // point of a dry run is to find out.
        if dryRun { return report }

        guard report.tracksExported > 0 else {
            throw MIDIExportError.nothingToExport(contained: report.contentSummary)
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // ATOMIC, so a failure part-way through cannot leave a half-written
            // `.mid` where the user expects their export
            // (`StandardMIDIFileWriter.write`'s own guarantee, reproduced here
            // only because the bytes were already needed for `byteCount`).
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw MIDIExportError.writeFailed(path: url.path,
                                              reason: error.localizedDescription)
        }
        report.written = true
        return report
    }

    /// Contract-range validation, reading `MIDIExportOptions`' own constants so
    /// this guard and the control-plane's `ControlError` can never disagree
    /// about what is legal (the iv-d contract-range idiom).
    private nonisolated static func midiExportOptions(
        ticksPerQuarterNote: Int, format: Int, trackIDs: [UUID]?
    ) throws -> MIDIExportOptions {
        guard MIDIExportOptions.ticksPerQuarterNoteRange.contains(ticksPerQuarterNote) else {
            throw MIDIExportError.invalidTicksPerQuarterNote(ticksPerQuarterNote)
        }
        guard MIDIExportOptions.legalFormatValues.contains(format),
              let smfFormat = SMFFormat(rawValue: format) else {
            throw MIDIExportError.invalidFormat(format)
        }
        return MIDIExportOptions(division: .ticksPerQuarterNote(ticksPerQuarterNote),
                                 format: smfFormat, trackIDs: trackIDs)
    }

    /// Destination resolution — the `bounceDestination` policy with a `.mid`
    /// suffix (`ProjectStore+Render.swift:274-285`). A path that already ends in
    /// `.mid` OR `.midi` is left alone, so the extension set this file already
    /// accepts on the way IN is the same one it recognises on the way OUT.
    private nonisolated static func midiExportDestination(from path: String?) -> URL {
        guard let path else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("export-\(UUID().uuidString.prefix(8)).mid")
        }
        var expanded = (path as NSString).expandingTildeInPath
        if !midiFileExtensions.contains((expanded as NSString).pathExtension.lowercased()) {
            expanded += ".mid"
        }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - Shared plumbing

    /// The mapper's view of the project, built at the call boundary so the
    /// mapper itself never reads a store.
    private func midiImportContext(targetClipLengthBeats: Double? = nil) -> MIDIImportContext {
        MIDIImportContext(
            // D1's `auto` predicate, VERBATIM from `importGeneration`
            // (`ProjectStore+Generation.swift:61`) — one definition of "is this
            // project empty enough to adopt into", so two shipped importers can
            // never disagree about the same question.
            projectHasClips: tracks.contains { !$0.clips.isEmpty },
            currentTempoMap: transport.tempoMap,
            currentMeterMap: transport.meterMap,
            targetClipLengthBeats: targetClipLengthBeats)
    }

    private func requireTransportIdleForMIDIImport() throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy(
                "cannot import a MIDI file while recording — stop first")
        }
    }

    /// Extension check, then existence — the shipped importer's own order
    /// (`ProjectStore+SampleLibraries.swift:41-50`), which makes a non-existent
    /// `.txt` say "not a MIDI file" rather than "no file there". Both must
    /// precede the decode: `StandardMIDIFileReader.decode(contentsOf:)` wraps
    /// `Data(contentsOf:)` and would surface a raw Foundation error instead of a
    /// teaching one.
    private nonisolated static func midiFileURL(path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard midiFileExtensions.contains(url.pathExtension.lowercased()) else {
            throw MIDIImportError.notAMIDIFile(fileName: url.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MIDIImportError.fileNotFound(path: url.path)
        }
        return url
    }

    /// A dry run creates nothing, so it names nothing: the ids the mapper minted
    /// on its throwaway `Track`/`Clip` values must not ride out as though they
    /// were in the project. Everything else in the report is IDENTICAL to the
    /// real run's — that identity is a gate leg.
    private nonisolated static func reportWithoutIDs(_ report: MIDIImportReport)
        -> MIDIImportReport {
        var stripped = report
        for index in stripped.parts.indices {
            stripped.parts[index].trackID = nil
            stripped.parts[index].clipID = nil
        }
        return stripped
    }

    /// Locates a clip by id across every track (extension-local; the private
    /// `locateClip(_:)` in ProjectStore.swift is not visible cross-file).
    private func locateMIDIImportClip(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
