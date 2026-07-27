import Foundation

// Standard MIDI File EXPORT from the project — m23-k4a Step 2 (design:
// docs/research/m23-k4a-midi-export-design.md §1–§5).
//
// The inverse of `SMFProjectMapper`, and deliberately its mirror image: a pure,
// headless, store-free mapper that turns project values into a `StandardMIDIFile`
// IR plus a `MIDIExportReport`, typed into a `MIDIExportPlan` whose initializer
// is `fileprivate` so the store cannot compute a plan for itself.
//
// LAW L9: DAWCore never imports AudioToolbox or CoreMIDI. Bytes are produced by
// `StandardMIDIFileWriter` from pure Foundation `Data`.
//
// THE SPINE, INVERTED: `tick = round(beat · division)`, with NO tempo term. Every
// tempo hazard in this file is a playback-SPEED hazard, never a note-POSITION
// hazard — exactly as in m23-k3, and for the same reason. The one asymmetry
// worth carrying in your head while reading: import is TOTAL (every tick has a
// beat) and export is LOSSY (only beats with `beat·t ∈ ℤ` survive), which is why
// this side has a quantization section the import report does not need.

// MARK: - Options

/// What an export was asked for. `division` is an `SMFDivision`, not an `Int`,
/// so the mapper never holds a bare ticks-per-quarter it could multiply by hand
/// (design §2.4, D-ONEHOME).
public struct MIDIExportOptions: Sendable, Equatable {
    /// ALWAYS metrical in practice: the wire builds this from a validated
    /// `1...32767` Int, so `division: "smpte"` is unaskable. The type admits
    /// SMPTE only because `SMFDivision` does, and `SMFTickClock` inverts that
    /// branch for totality (design §2.2).
    public var division: SMFDivision
    public var format: SMFFormat
    /// Which project tracks to export, in PROJECT order regardless of the order
    /// given here. nil = every track.
    public var trackIDs: [UUID]?

    /// 9600 = 2⁷·3·5², DERIVED and not conventional (design D-DIVISION): the
    /// unique smallest division ≤ 32767 that is exact for every dyadic
    /// subdivision to 1/128 of a beat, every triplet/sextuplet/quintuplet, every
    /// MPC swing preset `Groove.builtin(named:)` produces (the offsets are
    /// `P/100` and `P/200`, so 5² is required — this is what 480, 960 and 15360
    /// lack), and content native to 24/48/96/120/128/192/240/384/480/960 tpqn
    /// source files, so a file m23-k3 just imported re-exports bit-exactly. It
    /// is divisible by 24, so MIDI-clock alignment survives. It is NOT divisible
    /// by 7 or 9: septuplets and nonuplets quantize, and are reported like any
    /// other off-grid content. The cost is headroom — 0x0FFFFFFF/9600 = 27962
    /// beats ≈ 3.9 hours at 120 BPM before a delta overflows the 4-byte VLQ —
    /// which `MIDIExportError.contentTooFarFromStart` turns into a teaching
    /// refusal naming a lower division.
    public static let defaultTicksPerQuarterNote = 9600

    /// The legal `division` window, and THE ONE HOME for it: the wire's
    /// `ControlError` range check and the store's own guard both read this
    /// constant, so the two can never disagree about what is legal. Bit 15 of
    /// the `MThd` division word is what says "this is a tick count" rather than
    /// "this is a negative frame rate", which is where 32767 comes from.
    public static let ticksPerQuarterNoteRange: ClosedRange<Int> = 1 ... 32767

    /// Format 2 is a bag of unrelated sequences, which a project is not.
    public static let legalFormatValues: [Int] = [0, 1]

    public init(division: SMFDivision =
                    .ticksPerQuarterNote(MIDIExportOptions.defaultTicksPerQuarterNote),
                format: SMFFormat = .simultaneousTracks,
                trackIDs: [UUID]? = nil) {
        self.division = division
        self.format = format
        self.trackIDs = trackIDs
    }
}

// MARK: - Errors

/// A refusal to export, phrased so the message can be shown to a person — the
/// `SMFDecodeError` / `MIDIImportError` posture, including naming the escape.
public enum MIDIExportError: Error, Equatable, Sendable,
                             CustomStringConvertible, LocalizedError {
    /// `track.exportMIDI` on a track that cannot carry MIDI. `project.exportMIDI`
    /// SKIPS such a track and reports it instead — an explicit single-track
    /// request naming a track with no notes is a mistake worth naming.
    case notAnInstrumentTrack(name: String, kind: String)
    /// No instrument track in the project (or in the requested selection).
    case nothingToExport(contained: String)
    /// Content past the 4-byte VLQ ceiling at this division.
    case contentTooFarFromStart(beat: Double, limitBeats: Double, division: Int)
    /// The file could not be written.
    case writeFailed(path: String, reason: String)
    /// `division` outside `MIDIExportOptions.ticksPerQuarterNoteRange`.
    case invalidTicksPerQuarterNote(Int)
    /// `format` other than 0 or 1.
    case invalidFormat(Int)

    public var description: String {
        switch self {
        case .notAnInstrumentTrack(let name, let kind):
            return "\"\(name)\" is a \(kind) track, and a MIDI file can only carry notes — "
                + "export an instrument track, or use project.exportMIDI, which skips "
                + "tracks like this one and says so in its report"
        case .nothingToExport(let contained):
            return "there is nothing to export as MIDI — \(contained); nothing was written "
                + "(run with dryRun: true to see the full per-track report)"
        case .contentTooFarFromStart(let beat, let limitBeats, let division):
            return "there is content at beat \(formatExportBeat(beat)), past the beat "
                + "\(formatExportBeat(limitBeats)) limit a MIDI file can address at "
                + "\(division) ticks per quarter note — export with a smaller division "
                + "(480 is the industry default and reaches "
                + "\(formatExportBeat(Double(0x0FFF_FFFF) / 480.0))), or move the content "
                + "closer to the start"
        case .writeFailed(let path, let reason):
            return "the MIDI file could not be written to \(path): \(reason)"
        case .invalidTicksPerQuarterNote(let value):
            let range = MIDIExportOptions.ticksPerQuarterNoteRange
            return "'division' must be between \(range.lowerBound) and \(range.upperBound) "
                + "ticks per quarter note — got \(value)"
        case .invalidFormat(let value):
            return "'format' must be 0 (one merged track) or 1 (one track per part) — "
                + "got \(value)"
        }
    }

    public var errorDescription: String? { description }
}

/// Formats a beat without a trailing `.0` on whole beats (the mapper's own
/// `formatBeat`, which is `private` to `StandardMIDIFileMapper.swift` — a
/// private helper is copied rather than reached for, exactly as k3 refused to
/// copy `MeterMap.barlineEpsilon`).
private func formatExportBeat(_ beat: Double) -> String {
    beat == beat.rounded() && abs(beat) < 1e15
        ? String(Int(beat.rounded()))
        : String(format: "%g", beat)
}

// MARK: - The report

/// Everything an export wrote and every fidelity loss it took — the structural
/// mirror of `MIDIImportReport`, with the same two channels: typed counts an
/// agent or a test asserts on, and prose `degradations` a person reads.
///
/// NO LOSS IN THIS DESIGN IS SILENT, and the converse is gate leg G9: a clean
/// project must produce an all-zero/empty loss section and `degradations == []`,
/// with no exemption. A report that says something about every project is noise
/// nobody reads.
public struct MIDIExportReport: Codable, Sendable, Equatable {

    /// One row per SELECTED track, including the ones that were skipped.
    public struct Track: Codable, Sendable, Equatable {
        /// Index in the PROJECT's track order — not in the selection, and not in
        /// the file. A reported index means the same thing whatever `trackIds`
        /// was.
        public var index: Int
        public var name: String
        public var trackID: UUID
        public var kind: String
        /// 0-based MIDI channel (the raw wire value); nil when skipped.
        public var channel: Int?
        /// `MTrk` index in the file; nil when skipped. Always 0 in a format-0
        /// export, where every part merges into the single chunk.
        public var chunkIndex: Int?
        public var noteCount: Int
        /// `wireKey`s of the lanes actually written ("cc11", "pitchBend"…).
        public var controllerLanes: [String]
        /// THIS TRACK'S General MIDI program, 0-based; nil when the track is not
        /// on a GM sound bank.
        ///
        /// NOT "what the file says": in m23-k4a the exported bytes contain no
        /// `Cn` at all (the k2 writer is byte-frozen and does not read
        /// `SMFTrack.programChanges`). Every non-nil `program` here is also
        /// counted in `programChangesNotWritten`.
        public var program: Int?
        /// `GMProgramCatalog.name(forProgram:)`, same caveat.
        public var programName: String?
        public var isMuted: Bool
        public var exported: Bool
        public var skipReason: String?

        /// `trackID` rides the wire as `trackId` — the spelling every command's
        /// params use, so an agent can feed a reported id straight back into
        /// `track.exportMIDI`.
        private enum CodingKeys: String, CodingKey {
            case index, name, kind, channel, chunkIndex, noteCount, controllerLanes
            case program, programName, isMuted, exported, skipReason
            case trackID = "trackId"
        }

        public init(index: Int, name: String, trackID: UUID, kind: String,
                    channel: Int? = nil, chunkIndex: Int? = nil,
                    noteCount: Int = 0, controllerLanes: [String] = [],
                    program: Int? = nil, programName: String? = nil,
                    isMuted: Bool = false, exported: Bool = false,
                    skipReason: String? = nil) {
            self.index = index
            self.name = name
            self.trackID = trackID
            self.kind = kind
            self.channel = channel
            self.chunkIndex = chunkIndex
            self.noteCount = noteCount
            self.controllerLanes = controllerLanes
            self.program = program
            self.programName = programName
            self.isMuted = isMuted
            self.exported = exported
            self.skipReason = skipReason
        }
    }

    // --- what was written
    /// The path written — or the path that WOULD be written, on a dry run.
    public var path: String
    /// False on a dry run.
    public var written: Bool
    public var byteCount: Int
    public var format: Int
    public var ticksPerQuarterNote: Int
    public var divisionDescription: String

    // --- the per-track ledger
    public var tracks: [Track]

    // --- what landed
    public var tracksExported: Int
    public var notesExported: Int
    public var controllerPointsExported: Int
    public var tempoSegmentsWritten: Int
    public var meterChangesWritten: Int
    public var endTick: Int
    public var endBeat: Double

    // --- the losses. Every one of these is zero/empty/false on a clean project
    //     (gate leg G9); if that stops being true the report becomes noise.
    /// Notes whose onset moved by more than `SMFProjectExporter.beatEpsilon`,
    /// MEASURED through the clock's own round trip and never through a formula.
    public var notesQuantized: Int
    public var controllerPointsQuantized: Int
    public var maxQuantizationErrorBeats: Double
    /// The same error in milliseconds, at the tempo in force at the worst item.
    public var maxQuantizationErrorMs: Double
    /// `bpm → µs/qn → bpm` is NOT exact (m23-k3's D2 verified the OTHER
    /// direction). It moves ZERO notes — per the spine, note positions are
    /// tick-affine — so this is a playback-SPEED error: ≈ 0.2 ms of drift per
    /// minute of music at the worst case in the 20…400 BPM clamp window.
    public var maxTempoRoundTripErrorBPM: Double
    /// Notes whose length rounded to 0 ticks and were widened to 1.
    public var notesWidenedToOneTick: Int
    /// SMF cannot express nested same-pitch note-ons, so the earlier note is
    /// truncated to end exactly at the later one's onset.
    public var overlappingSamePitchNotesTruncated: Int
    /// …and dropped when truncation would leave it no length at all.
    public var overlappingSamePitchNotesDropped: Int
    /// Content whose extent leaves its clip's half-open `[0, lengthBeats)` span.
    /// Exported AT ITS AUTHORED POSITION — this is a FACT about the project, not
    /// a loss taken, and it does not push a `degradations` line.
    public var notesPastClipEnd: Int
    public var controllerPointsPastClipEnd: Int
    /// Clip gain / gain envelope / fades are not folded into velocity.
    public var clipsWithGainNotExported: Int
    /// Clip stretch / pitch shift are not folded into timing.
    public var clipsWithStretchNotExported: Int
    /// Audio clips parked on an instrument track contribute nothing.
    public var audioClipsSkipped: Int
    public var droppedMeterChanges: [String]
    public var tempoSegmentsCollidingAtSameTick: [String]
    /// The file must carry a meter at tick 0; when the project's own change 0
    /// was unwritable, the SMF default 4/4 was substituted.
    public var substitutedDefaultMeterAtZero: Bool
    /// The k2 gap: the IR carries these program changes, the bytes do not.
    public var programChangesNotWritten: Int
    public var channelsWrapped: Int
    public var trackNamesLostToFormat0: Int
    /// Names of muted tracks that were exported anyway (D-MIX: export
    /// SERIALISES the model, it does not RENDER it). Informational.
    public var mutedTracksExported: [String]
    /// Informational.
    public var soloedTracksPresent: Bool

    // --- the one prose channel
    public var degradations: [String]

    /// A `[String]` loss list never exceeds this many entries; the overflow
    /// folds into a trailing "… and N more". The typed COUNTS stay exact.
    /// (`MIDIImportReport.maxReportedEntries`'s reason, verbatim: a pathological
    /// project must not mint an unbounded array that rides the wire into an
    /// agent's context.)
    public static let maxReportedEntries = 32

    public init(path: String = "",
                written: Bool = false,
                byteCount: Int = 0,
                format: Int = SMFFormat.simultaneousTracks.rawValue,
                ticksPerQuarterNote: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
                divisionDescription: String = "",
                tracks: [Track] = [],
                tracksExported: Int = 0,
                notesExported: Int = 0,
                controllerPointsExported: Int = 0,
                tempoSegmentsWritten: Int = 0,
                meterChangesWritten: Int = 0,
                endTick: Int = 0,
                endBeat: Double = 0,
                notesQuantized: Int = 0,
                controllerPointsQuantized: Int = 0,
                maxQuantizationErrorBeats: Double = 0,
                maxQuantizationErrorMs: Double = 0,
                maxTempoRoundTripErrorBPM: Double = 0,
                notesWidenedToOneTick: Int = 0,
                overlappingSamePitchNotesTruncated: Int = 0,
                overlappingSamePitchNotesDropped: Int = 0,
                notesPastClipEnd: Int = 0,
                controllerPointsPastClipEnd: Int = 0,
                clipsWithGainNotExported: Int = 0,
                clipsWithStretchNotExported: Int = 0,
                audioClipsSkipped: Int = 0,
                droppedMeterChanges: [String] = [],
                tempoSegmentsCollidingAtSameTick: [String] = [],
                substitutedDefaultMeterAtZero: Bool = false,
                programChangesNotWritten: Int = 0,
                channelsWrapped: Int = 0,
                trackNamesLostToFormat0: Int = 0,
                mutedTracksExported: [String] = [],
                soloedTracksPresent: Bool = false,
                degradations: [String] = []) {
        self.path = path
        self.written = written
        self.byteCount = byteCount
        self.format = format
        self.ticksPerQuarterNote = ticksPerQuarterNote
        self.divisionDescription = divisionDescription
        self.tracks = tracks
        self.tracksExported = tracksExported
        self.notesExported = notesExported
        self.controllerPointsExported = controllerPointsExported
        self.tempoSegmentsWritten = tempoSegmentsWritten
        self.meterChangesWritten = meterChangesWritten
        self.endTick = endTick
        self.endBeat = endBeat
        self.notesQuantized = notesQuantized
        self.controllerPointsQuantized = controllerPointsQuantized
        self.maxQuantizationErrorBeats = maxQuantizationErrorBeats
        self.maxQuantizationErrorMs = maxQuantizationErrorMs
        self.maxTempoRoundTripErrorBPM = maxTempoRoundTripErrorBPM
        self.notesWidenedToOneTick = notesWidenedToOneTick
        self.overlappingSamePitchNotesTruncated = overlappingSamePitchNotesTruncated
        self.overlappingSamePitchNotesDropped = overlappingSamePitchNotesDropped
        self.notesPastClipEnd = notesPastClipEnd
        self.controllerPointsPastClipEnd = controllerPointsPastClipEnd
        self.clipsWithGainNotExported = clipsWithGainNotExported
        self.clipsWithStretchNotExported = clipsWithStretchNotExported
        self.audioClipsSkipped = audioClipsSkipped
        self.droppedMeterChanges = droppedMeterChanges
        self.tempoSegmentsCollidingAtSameTick = tempoSegmentsCollidingAtSameTick
        self.substitutedDefaultMeterAtZero = substitutedDefaultMeterAtZero
        self.programChangesNotWritten = programChangesNotWritten
        self.channelsWrapped = channelsWrapped
        self.trackNamesLostToFormat0 = trackNamesLostToFormat0
        self.mutedTracksExported = mutedTracksExported
        self.soloedTracksPresent = soloedTracksPresent
        self.degradations = degradations
    }

    /// What the project DID contain, for the `nothingToExport` refusal — the
    /// `MIDIImportReport.contentSummary` idiom: a refusal that names what it
    /// found is actionable, one that says "nothing" reads as a lie about the
    /// user's project.
    public var contentSummary: String {
        guard !tracks.isEmpty else { return "no tracks were selected" }
        var counts: [String: Int] = [:]
        for track in tracks { counts[track.kind, default: 0] += 1 }
        let phrases = counts.keys.sorted().map { "\(counts[$0] ?? 0) \($0) track(s)" }
        return "it has " + phrases.joined(separator: " and ")
            + ", and a MIDI file can only carry notes"
    }
}

// MARK: - The plan

/// A complete export, ready to encode: the IR and the report that describes it.
///
/// `init` is `fileprivate`, so `SMFProjectExporter.map` is the ONLY producer in
/// the program and the store is typed to consume one — the `MIDIImportPlan`
/// mechanism verbatim.
///
/// **This type must NEVER conform to `Codable`.** A public `Codable` struct
/// synthesizes a public `init(from:)`, which is a second producer no
/// `fileprivate` can stop (the m23-k3 V.4.4 lesson). If a snapshot ever needs to
/// show a plan, encode the `report`, which IS `Codable`.
public struct MIDIExportPlan: Sendable, Equatable {
    public let file: StandardMIDIFile
    public let report: MIDIExportReport

    fileprivate init(file: StandardMIDIFile, report: MIDIExportReport) {
        self.file = file
        self.report = report
    }
}

// MARK: - The mapper

/// Project values → a `StandardMIDIFile` IR + a `MIDIExportReport`. Pure,
/// headless, store-free, engine-free: every verdict below is unit-testable with
/// no `ProjectStore` anywhere in sight.
public enum SMFProjectExporter {

    /// A beat moved by less than this did not move. DELIBERATELY AND SEPARATELY
    /// the same magnitude as `MeterMap.barlineEpsilon`: that constant is
    /// `private` and means "tolerance for a barline test", a different question
    /// about a different quantity. Two concepts that share a value are not one
    /// constant with two homes — and copying a private constant across a file
    /// boundary is exactly what m23-k3 §2.4 refused to do.
    ///
    /// It must be an epsilon and not `!= 0`: DAW Pro's own swing offsets are
    /// exactly representable at 2400 and 4800 ticks, yet leave one ULP of
    /// `Double` residue (2.2e-16), which `!= 0` would report as quantization on
    /// content that did not move.
    public static let beatEpsilon = 1e-9

    /// The largest tick any delta may address: a variable-length quantity is at
    /// most 4 bytes of 7 bits. Pre-checked against the LARGEST tick in the file,
    /// which is conservative-and-correct — every delta is a difference of two
    /// ticks in `[0, maxTick]`.
    public static let maxAddressableTick = 0x0FFF_FFFF

    /// The GM drum channel. Channel 9 (the 10th) IS the drum channel in every GM
    /// player REGARDLESS of any program change, which is what settles the drum
    /// rule independently of the k2 program-change gap: a drum track exported on
    /// 9 sounds like drums and one exported on 0 does not.
    public static let drumChannel = 9

    /// Channels handed to melodic tracks, in order, skipping the drum channel.
    static let melodicChannels: [Int] = Array(0 ... 8) + Array(10 ... 15)

    // MARK: Entry point

    /// - Parameters:
    ///   - tracks: the project's tracks, in project order.
    ///   - projectName: becomes the conductor chunk's `FF 03`. Empty ⇒ no name
    ///     event.
    ///   - tempoMap / meterMap: the project's maps, written VERBATIM onto the
    ///     conductor (6/8 stays `numerator = 6`, `denominatorPower = 3` — the
    ///     exact identity of m23-k3's import, which is what makes the two mutual
    ///     inverses).
    ///   - options: division, format, and the track selection.
    public static func map(tracks: [Track],
                           projectName: String,
                           tempoMap: TempoMap,
                           meterMap: MeterMap,
                           options: MIDIExportOptions) throws -> MIDIExportPlan {
        let clock = SMFTickClock(division: options.division, tempoMap: tempoMap)
        var report = MIDIExportReport(
            format: options.format.rawValue,
            ticksPerQuarterNote: clock.ticksPerQuarterNote ?? 0,
            divisionDescription: clock.divisionDescription)

        // The largest tick and the beat that produced it, for the VLQ ceiling
        // refusal. Tracked as we go so the message can name a BEAT (which the
        // user can find) rather than a tick (which they cannot).
        var maxTick = 0
        var maxTickBeat = 0.0
        func note(tick: Int, beat: Double) {
            if tick > maxTick { maxTick = tick; maxTickBeat = beat }
        }

        // ---- 1. Selection, in PROJECT order whatever order the ids arrived in.
        let selected: [(index: Int, track: Track)]
        if let ids = options.trackIDs {
            let wanted = Set(ids)
            selected = tracks.enumerated()
                .filter { wanted.contains($0.element.id) }
                .map { (index: $0.offset, track: $0.element) }
        } else {
            selected = tracks.enumerated().map { (index: $0.offset, track: $0.element) }
        }

        // ---- 2. Channels. One per EXPORTED track, drum kits on 9, allocated
        // before any content is walked so a track's channel does not depend on
        // whether it happens to have notes.
        var melodicCursor = 0
        var channelsWrapped = 0
        func allocateChannel(for track: Track) -> Int {
            if isDrumKit(track) { return drumChannel }
            let channel = melodicChannels[melodicCursor % melodicChannels.count]
            if melodicCursor >= melodicChannels.count { channelsWrapped += 1 }
            melodicCursor += 1
            return channel
        }

        // ---- 3. Per-track flattening.
        var smfTracks: [SMFTrack] = []
        var ledger: [MIDIExportReport.Track] = []
        var totals = Totals()
        var mutedExported: [String] = []
        var soloedPresent = false

        for entry in selected {
            let track = entry.track
            if track.isSoloed { soloedPresent = true }

            // The THIRD reader of the m23-m3b eligibility rule (`Track
            // .canExportMIDI`), after the single-track verb's refusal and the
            // track-header menu's offer. Only the RESPONSE differs per caller —
            // skip here, refuse there, hide in the menu; the question does not.
            guard track.canExportMIDI else {
                // D-AUDIO: skip + report. Emitting an empty chunk would CLAIM
                // the file contains that part; omitting it silently reads as
                // "my drums disappeared".
                ledger.append(MIDIExportReport.Track(
                    index: entry.index, name: track.name, trackID: track.id,
                    kind: track.kind.rawValue, isMuted: track.isMuted, exported: false,
                    skipReason: skipReason(for: track.kind)))
                continue
            }

            let channel = allocateChannel(for: track)
            // The chunk index the part will occupy. Chunk 0 is ALWAYS the
            // conductor in format 1; a format-0 export merges everything into
            // the single chunk 0.
            let chunkIndex = options.format == .singleTrack ? 0 : smfTracks.count + 1

            let flattened = flatten(track: track, channel: channel, clock: clock,
                                    totals: &totals, noteTick: note)
            if track.isMuted { mutedExported.append(track.name) }

            let program = gmProgram(of: track)
            if program != nil { totals.programChangesNotWritten += 1 }

            smfTracks.append(SMFTrack(
                name: track.name.isEmpty ? nil : track.name,
                sourceTrackIndex: smfTracks.count + 1,
                // The IR's own contract: "distinct MIDI channels appearing in
                // this part's EVENTS". A program change never inserts its
                // channel (k1's rule), and an empty instrument track speaks on
                // none — so this is [] there even though the report names the
                // channel the part WOULD have used.
                channels: flattened.notes.isEmpty && flattened.controllers.isEmpty
                    ? [] : [channel],
                notes: flattened.notes,
                controllers: flattened.controllers,
                endTick: flattened.endTick,
                // Populated so the IR is COMPLETE and the report is truthful.
                // The byte-frozen k2 writer does not read this field, so none of
                // these reach the file — `programChangesNotWritten` says so.
                programChanges: program.map {
                    [SMFProgramChangeEvent(tick: 0, channel: channel, program: $0)]
                } ?? []))

            ledger.append(MIDIExportReport.Track(
                index: entry.index, name: track.name, trackID: track.id,
                kind: track.kind.rawValue, channel: channel, chunkIndex: chunkIndex,
                noteCount: flattened.notes.count,
                controllerLanes: flattened.laneKeys,
                program: program,
                programName: program.map { GMProgramCatalog.name(forProgram: $0) },
                isMuted: track.isMuted, exported: true))

            note(tick: flattened.endTick, beat: clock.beats(tick: flattened.endTick))
        }

        // ---- 4. The conductor: the project name, the whole tempo map, the
        // whole meter map, and nothing else. Emitted UNCONDITIONALLY, including
        // for a default 120 BPM / 4/4 project, so the chunk count is a function
        // of the project's TRACK STRUCTURE only and never of its content.
        let tempo = buildTempoEvents(tempoMap: tempoMap, clock: clock, noteTick: note)
        let meter = buildMeterEvents(meterMap: meterMap, clock: clock, noteTick: note)

        let conductorLastEvent = max(tempo.events.map(\.tick).max() ?? 0,
                                     meter.events.map(\.tick).max() ?? 0)
        // P6 is checked per part AFTER the P1 hoist, so the conductor's endTick
        // must cover its OWN tempo/meter events as well as the song end, or a
        // tempo change past the last note throws `endTickBeforeLastEvent`.
        let songEnd = max(smfTracks.map(\.endTick).max() ?? 0, conductorLastEvent)
        let conductor = SMFTrack(
            name: projectName.isEmpty ? nil : projectName,
            sourceTrackIndex: 0, channels: [], notes: [], controllers: [],
            endTick: songEnd)

        note(tick: songEnd, beat: clock.beats(tick: songEnd))

        // ---- 5. The VLQ ceiling, checked ONCE over everything.
        guard maxTick <= maxAddressableTick else {
            throw MIDIExportError.contentTooFarFromStart(
                beat: maxTickBeat,
                limitBeats: clock.beats(tick: maxAddressableTick),
                division: clock.ticksPerQuarterNote ?? 0)
        }

        let file = StandardMIDIFile(
            format: options.format,
            division: clock.division,
            tracks: [conductor] + smfTracks,
            tempoChanges: tempo.events,
            timeSignatures: meter.events,
            warnings: [])

        // ---- 6. Fill the report in and roll the degradations up.
        report.tracks = ledger
        report.tracksExported = smfTracks.count
        report.notesExported = smfTracks.reduce(0) { $0 + $1.notes.count }
        report.controllerPointsExported = smfTracks.reduce(0) { $0 + $1.controllers.count }
        report.tempoSegmentsWritten = tempo.events.count
        report.meterChangesWritten = meter.events.count
        report.endTick = songEnd
        report.endBeat = clock.beats(tick: songEnd)
        report.notesQuantized = totals.notesQuantized
        report.controllerPointsQuantized = totals.pointsQuantized
        report.maxQuantizationErrorBeats = totals.maxQuantizationErrorBeats
        report.maxQuantizationErrorMs = totals.maxQuantizationErrorBeats
            * tempoMap.secondsPerBeat(atBeat: totals.maxQuantizationErrorAtBeat) * 1000
        report.maxTempoRoundTripErrorBPM = tempo.maxRoundTripErrorBPM
        report.notesWidenedToOneTick = totals.notesWidenedToOneTick
        report.overlappingSamePitchNotesTruncated = totals.overlapTruncated
        report.overlappingSamePitchNotesDropped = totals.overlapDropped
        report.notesPastClipEnd = totals.notesPastClipEnd
        report.controllerPointsPastClipEnd = totals.pointsPastClipEnd
        report.clipsWithGainNotExported = totals.clipsWithGain
        report.clipsWithStretchNotExported = totals.clipsWithStretch
        report.audioClipsSkipped = totals.audioClipsSkipped
        report.droppedMeterChanges = capped(meter.dropped)
        report.tempoSegmentsCollidingAtSameTick = capped(tempo.collisions)
        report.substitutedDefaultMeterAtZero = meter.substitutedDefaultAtZero
        report.programChangesNotWritten = totals.programChangesNotWritten
        report.channelsWrapped = channelsWrapped
        report.trackNamesLostToFormat0 = namesLostToFormat0(
            format: options.format, projectName: projectName, tracks: smfTracks)
        report.mutedTracksExported = capped(mutedExported)
        report.soloedTracksPresent = soloedPresent
        report.degradations = degradations(for: report)

        return MIDIExportPlan(file: file, report: report)
    }

    // MARK: Track flattening

    /// Everything the walk over one track accumulates that the report needs.
    private struct Totals {
        var notesQuantized = 0
        var pointsQuantized = 0
        var maxQuantizationErrorBeats = 0.0
        var maxQuantizationErrorAtBeat = 0.0
        var notesWidenedToOneTick = 0
        var overlapTruncated = 0
        var overlapDropped = 0
        var notesPastClipEnd = 0
        var pointsPastClipEnd = 0
        var clipsWithGain = 0
        var clipsWithStretch = 0
        var audioClipsSkipped = 0
        var programChangesNotWritten = 0

        mutating func observeQuantization(errorBeats: Double, atBeat beat: Double) {
            if errorBeats > maxQuantizationErrorBeats {
                maxQuantizationErrorBeats = errorBeats
                maxQuantizationErrorAtBeat = beat
            }
        }
    }

    private struct Flattened {
        var notes: [SMFNote] = []
        var controllers: [SMFControllerEvent] = []
        var laneKeys: [String] = []
        var endTick = 0
    }

    /// A note on its way to the IR, before same-pitch overlaps are resolved.
    private struct PendingNote {
        var tick: Int
        var lengthTicks: Int
        var pitch: Int
        var velocity: Int
        /// Flatten order, so every sort in here is TOTAL and the bytes never
        /// depend on `sort`'s stability.
        var order: Int
    }

    private static func flatten(track: Track, channel: Int, clock: SMFTickClock,
                                totals: inout Totals,
                                noteTick: (Int, Double) -> Void) -> Flattened {
        var pending: [PendingNote] = []
        var controllers: [SMFControllerEvent] = []
        var laneKeys: Set<String> = []
        var contentEndTick = 0
        var order = 0

        // Sorted by (startBeat, id) — a TOTAL order, because clips may share a
        // startBeat and a `Dictionary`-shaped or unstable grouping is the one
        // bug no functional leg catches (gate leg G10, byte determinism).
        let clips = track.clips.sorted {
            $0.startBeat != $1.startBeat
                ? $0.startBeat < $1.startBeat
                : $0.id.uuidString < $1.id.uuidString
        }

        for clip in clips {
            guard clip.isMIDI else {
                totals.audioClipsSkipped += 1
                continue
            }
            // NOT baked in, and reported instead: baking gain into velocity is a
            // musical judgement with no inverse (a re-import could never
            // separate authored velocity from applied gain) and it would make
            // export non-idempotent.
            if clip.gainDb != 0 || !clip.gainEnvelope.isEmpty
                || clip.fadeInBeats > 0 || clip.fadeOutBeats > 0 {
                totals.clipsWithGain += 1
            }
            if !clip.isStretchIdentity { totals.clipsWithStretch += 1 }

            for midiNote in clip.notes ?? [] {
                let absoluteStart = clip.startBeat + midiNote.startBeat
                // X2 — the PAIR. There is no length-only entry point, so an
                // independently-rounded length cannot be written here.
                var (tick, lengthTicks) = clock.noteTicks(startBeat: absoluteStart,
                                                          lengthBeats: midiNote.lengthBeats)
                if lengthTicks < 1 {
                    // MAPPER policy, not an encoder requirement: k2 accepts
                    // `lengthTicks == 0` (it has a `zeroLengthNoteOff` rung).
                    // The floor exists so a re-import does not mint an
                    // H6c degradation on a file we wrote.
                    lengthTicks = 1
                    totals.notesWidenedToOneTick += 1
                }
                // MEASURED THROUGH THE ROUND TRIP, never through a formula
                // (`0.5/t` would report loss on a project whose notes are all
                // on-grid). Both directions of the same clock, so the number
                // printed is definitionally what a re-import will see.
                let landed = clock.beats(tick: tick)
                let error = abs(absoluteStart - landed)
                if error > beatEpsilon { totals.notesQuantized += 1 }
                totals.observeQuantization(errorBeats: error, atBeat: absoluteStart)

                // A clip spans the half-open beat range [0, lengthBeats): a note
                // ending exactly AT the end is entirely inside it, and a note
                // whose extent leaves it is past it. AUTHORED POSITIONS SURVIVE
                // — `MIDISchedule`'s playback window is deliberately not
                // mirrored (§3.4), because `clip.importMIDI` deliberately
                // creates exactly this content and windowing would break the
                // round trip on clips DAW Pro itself produces.
                if midiNote.endBeat > clip.lengthBeats + beatEpsilon {
                    totals.notesPastClipEnd += 1
                }

                pending.append(PendingNote(tick: tick, lengthTicks: lengthTicks,
                                           pitch: midiNote.pitch,
                                           velocity: midiNote.velocity, order: order))
                order += 1
                noteTick(tick, absoluteStart)
                noteTick(tick + lengthTicks, absoluteStart + midiNote.lengthBeats)
                contentEndTick = max(contentEndTick, tick + lengthTicks)
            }

            for lane in clip.controllerLanes {
                var wrote = false
                for point in lane.points {
                    let absoluteBeat = clip.startBeat + point.beat
                    let tick = clock.ticks(beat: absoluteBeat)
                    let landed = clock.beats(tick: tick)
                    let error = abs(absoluteBeat - landed)
                    if error > beatEpsilon { totals.pointsQuantized += 1 }
                    totals.observeQuantization(errorBeats: error, atBeat: absoluteBeat)
                    // A point occupies a single instant, so it leaves
                    // [0, lengthBeats) as soon as it reaches the end — the note
                    // rule and this one are the SAME rule about a half-open
                    // span, applied to items of different extent.
                    if point.beat >= clip.lengthBeats - beatEpsilon {
                        totals.pointsPastClipEnd += 1
                    }
                    controllers.append(SMFControllerEvent(tick: tick, channel: channel,
                                                          type: lane.type,
                                                          value: point.value))
                    wrote = true
                    noteTick(tick, absoluteBeat)
                    contentEndTick = max(contentEndTick, tick)
                }
                if wrote { laneKeys.insert(lane.type.wireKey) }
            }
        }

        // D-FLATTEN's one FORMAT-forced change.
        let resolved = resolveSamePitchOverlaps(pending, totals: &totals)

        // The IR's stated contract: notes ordered by (tick, channel, note). One
        // channel per track here, so the third key is the tiebreak that matters;
        // `order` keeps the sort total.
        let notes = resolved
            .sorted {
                if $0.tick != $1.tick { return $0.tick < $1.tick }
                if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
                return $0.order < $1.order
            }
            .map {
                SMFNote(tick: $0.tick, lengthTicks: $0.lengthTicks, note: $0.pitch,
                        velocity: $0.velocity,
                        // The one value INVENTED rather than read: `MIDINote`
                        // has no release-velocity field, and 64 is the
                        // conventional "no information" spelling that m23-k3's
                        // H5b exemption treats as carrying none — so a note we
                        // write round-trips without minting a
                        // `notesWithDroppedReleaseVelocity` entry on the way
                        // back. Not reported: it would fire on every file.
                        releaseVelocity: 64, channel: channel)
            }
        let sortedControllers = controllers.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.type.sortKey != $1.type.sortKey { return $0.type.sortKey < $1.type.sortKey }
            return $0.value < $1.value
        }

        // Trailing silence is MEANINGFUL: m23-k3's R6 reads a clip's length back
        // OUT of `part.endTick`, so a clip's full span must be written IN or the
        // round trip loses it.
        var endTick = contentEndTick
        for clip in clips where clip.isMIDI {
            endTick = max(endTick, clock.ticks(beat: clip.startBeat + clip.lengthBeats))
        }

        return Flattened(notes: notes, controllers: sortedControllers,
                         laneKeys: laneKeys.sorted(), endTick: endTick)
    }

    /// SMF cannot express two note-ons on one pitch/channel with no intervening
    /// note-off: the pairing is ambiguous, and every FIFO reader (m23-k1's
    /// included) brings a nested pair back with the two LENGTHS SWAPPED — silent
    /// musical corruption in a file that opens everywhere.
    ///
    /// So the earlier note is truncated to end exactly at the later one's onset.
    /// That is the only resolution that ROUND-TRIPS: k2's `Rank` ladder emits
    /// note-off (rank 1) before note-on (rank 3) at an equal tick, so the
    /// truncated pair re-imports as the same two notes.
    private static func resolveSamePitchOverlaps(_ notes: [PendingNote],
                                                 totals: inout Totals) -> [PendingNote] {
        var byPitch: [Int: [PendingNote]] = [:]
        for note in notes { byPitch[note.pitch, default: []].append(note) }

        var kept: [PendingNote] = []
        // Sorted keys, not `Dictionary` order — G10 (byte determinism) is the
        // only leg that catches an unsorted grouping, and it catches it here.
        for pitch in byPitch.keys.sorted() {
            // Ascending by tick, then SHORTEST FIRST at an equal tick, so when
            // two onsets collide the shorter one is the one dropped and the
            // longer survives.
            let group = byPitch[pitch]!.sorted {
                if $0.tick != $1.tick { return $0.tick < $1.tick }
                if $0.lengthTicks != $1.lengthTicks { return $0.lengthTicks < $1.lengthTicks }
                return $0.order < $1.order
            }
            var current: PendingNote?
            for next in group {
                guard var sounding = current else { current = next; continue }
                if next.tick < sounding.tick + sounding.lengthTicks {
                    // Strictly inside. An onset exactly AT the current note's
                    // end is FLUSH, not overlapping, and is left alone.
                    let truncated = next.tick - sounding.tick
                    if truncated <= 0 {
                        totals.overlapDropped += 1
                    } else {
                        sounding.lengthTicks = truncated
                        totals.overlapTruncated += 1
                        kept.append(sounding)
                    }
                } else {
                    kept.append(sounding)
                }
                current = next
            }
            if let last = current { kept.append(last) }
        }
        return kept
    }

    // MARK: Conductor

    private struct TempoBuild {
        var events: [SMFTempoEvent] = []
        var collisions: [String] = []
        var maxRoundTripErrorBPM = 0.0
    }

    private static func buildTempoEvents(tempoMap: TempoMap, clock: SMFTickClock,
                                         noteTick: (Int, Double) -> Void) -> TempoBuild {
        var build = TempoBuild()
        var usedTicks: [Int: Double] = [:]
        for segment in tempoMap.segments {
            let tick = clock.ticks(beat: segment.startBeat)
            // REACHABLE: `TempoMap.init` requires strictly increasing start
            // beats with NO MINIMUM GAP, so two segments 1e-6 beats apart both
            // land on tick 0. m23-k3's H3 keeps the FIRST on the way back, so
            // the first wins here too and the loser is NAMED.
            if let winner = usedTicks[tick] {
                build.collisions.append(
                    "the tempo change at beat \(formatExportBeat(segment.startBeat)) "
                    + "(\(formatExportBeat(segment.bpm)) BPM) lands on tick \(tick), already "
                    + "taken by \(formatExportBeat(winner)) BPM; the first one was kept")
                continue
            }
            usedTicks[tick] = segment.bpm
            // D2, inherited as SETTLED: µs per quarter note is authoritative and
            // `round` is the rule. `TempoMap.Segment.init` clamps bpm into
            // 20…400, so µ ∈ [150000, 3000000] ⊂ k2's legal [1, 0xFFFFFF] and
            // the out-of-range guard is UNREACHABLE — stated rather than coded,
            // and given no report field, because a field that can never fire is
            // worse than none.
            let microseconds = Int((60_000_000.0 / segment.bpm).rounded())
            build.events.append(SMFTempoEvent(tick: tick,
                                              microsecondsPerQuarterNote: microseconds,
                                              sourceTrackIndex: 0))
            // The direction m23-k3's D2 did NOT verify. It moves ZERO notes.
            let readBack = 60_000_000.0 / Double(microseconds)
            build.maxRoundTripErrorBPM = max(build.maxRoundTripErrorBPM,
                                             abs(readBack - segment.bpm))
            noteTick(tick, segment.startBeat)
        }
        return build
    }

    private struct MeterBuild {
        var events: [SMFTimeSignatureEvent] = []
        var dropped: [String] = []
        var substitutedDefaultAtZero = false
    }

    private static func buildMeterEvents(meterMap: MeterMap, clock: SMFTickClock,
                                         noteTick: (Int, Double) -> Void) -> MeterBuild {
        var build = MeterBuild()
        for change in meterMap.changes {
            let tick = clock.ticks(beat: change.startBeat)
            // REACHABLE over the control port: `MeterMap.Change.init` applies
            // only `max(1, …)`, and `tempo.setMap` takes the wire's pair
            // verbatim — so `beatUnit: 5` and `beatsPerBar: 300` both arrive
            // here. Coercing them silently would produce a file naming a meter
            // the project never held.
            guard let power = denominatorPower(of: change.beatUnit) else {
                build.dropped.append(
                    "the time signature at beat \(formatExportBeat(change.startBeat)) is "
                    + "\(change.beatsPerBar)/\(change.beatUnit), and a MIDI file can only "
                    + "write a denominator that is a power of two")
                continue
            }
            guard (0 ... 255).contains(power) else {
                build.dropped.append(
                    "the time signature at beat \(formatExportBeat(change.startBeat)) has a "
                    + "denominator of \(change.beatUnit), too large for the one byte a MIDI "
                    + "file gives it")
                continue
            }
            guard (1 ... 255).contains(change.beatsPerBar) else {
                build.dropped.append(
                    "the time signature at beat \(formatExportBeat(change.startBeat)) has "
                    + "\(change.beatsPerBar) beats per bar, and a MIDI file can only write "
                    + "1…255")
                continue
            }
            build.events.append(SMFTimeSignatureEvent(
                tick: tick,
                // VERBATIM, both fields (m23-k3 §1.3): 6/8 exports as
                // numerator 6, denominatorPower 3. Translating it (say
                // `beatsPerBar · 4 / beatUnit`) brings 6/8 back as 3/8 or 12/8,
                // and export would stop being the identity of import.
                numerator: change.beatsPerBar,
                denominatorPower: power,
                // The universal defaults, and what DAW Pro has to say: the model
                // carries no metronome-subdivision quantity to source anything
                // else from.
                clocksPerMetronomeClick: 24,
                thirtySecondNotesPerQuarter: 8,
                sourceTrackIndex: 0))
            noteTick(tick, change.startBeat)
        }
        // A MIDI file must carry a meter at tick 0. If the project's own change
        // 0 was unwritable, the SMF default is the only honest substitute — and
        // it is reported (the mirror of m23-k3's H4b).
        if build.events.first?.tick != 0 {
            build.events.insert(SMFTimeSignatureEvent(
                tick: 0, numerator: 4, denominatorPower: 2,
                clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                sourceTrackIndex: 0), at: 0)
            build.substitutedDefaultAtZero = true
        }
        return build
    }

    /// `log2` of a power of two, or nil when the value is not one. Integer-only,
    /// so no `Double` rounding decides whether 6/8 is writable.
    static func denominatorPower(of denominator: Int) -> Int? {
        guard denominator > 0, denominator & (denominator - 1) == 0 else { return nil }
        return denominator.trailingZeroBitCount
    }

    // MARK: Instruments

    /// A drum kit takes channel 9. Gated on `kind == .soundBank` and NOT on the
    /// `soundBank` field alone: `InstrumentDescriptor` carries every kind's
    /// parameters at once so switching kinds round-trips a user's settings, so a
    /// `.polySynth` track can be holding a stale percussion `SoundBankConfig`
    /// that it does not play. (The design's §4.3 pseudocode omits the `kind`
    /// test; adding it is this implementation's one deliberate deviation, and it
    /// is recorded in the item's report.)
    ///
    /// Deliberately NOT gated on `source == .generalMIDI`: a `.file(path:)` SF2
    /// on bank 120 IS a percussion bank, and channel 9 is the right channel for
    /// it in any GM player. That is a different question from which program
    /// NUMBER means what, which is what the `source` test below is for.
    static func isDrumKit(_ track: Track) -> Bool {
        guard let instrument = track.instrument, instrument.kind == .soundBank,
              let bank = instrument.soundBank else { return false }
        return bank.bankMSB == GMProgramCatalog.percussionBankMSB
    }

    /// The GM program this track asks for, or nil.
    ///
    /// Gated on `source == .generalMIDI` and not merely on `kind == .soundBank`,
    /// and that is load-bearing: a `.file(path:)` SF2's program number addresses
    /// THAT FILE'S bank, so writing it as a GM program would name a different
    /// instrument in every other program that opens the file.
    ///
    /// NO BANK-SELECT CC IS EVER EMITTED. DAW Pro's `bankMSB` 121/120 are
    /// AUSampler conventions (`kAUSampler_DefaultMelodicBankMSB`), not GM file
    /// conventions, and emitting them as CC 0 would mean something else to every
    /// reader.
    static func gmProgram(of track: Track) -> Int? {
        guard let instrument = track.instrument, instrument.kind == .soundBank,
              let bank = instrument.soundBank, bank.source == .generalMIDI else { return nil }
        return bank.program
    }

    // MARK: Report assembly

    private static func skipReason(for kind: TrackKind) -> String {
        switch kind {
        case .audio: return "audio track — a MIDI file has nowhere to put recorded audio"
        case .bus: return "bus track — carries no notes"
        case .instrument: return ""
        }
    }

    /// k2's `Part.merged` keeps "the FIRST non-nil part name", so a format-0
    /// export loses every other one. The conductor is chunk 0, so when the
    /// project has a name it is the conductor's name that survives and EVERY
    /// track name is lost; with no project name the first named track's survives.
    private static func namesLostToFormat0(format: SMFFormat, projectName: String,
                                           tracks: [SMFTrack]) -> Int {
        guard format == .singleTrack else { return 0 }
        let named = tracks.filter { $0.name != nil }.count
        return projectName.isEmpty ? max(0, named - 1) : named
    }

    private static func capped(_ entries: [String]) -> [String] {
        let limit = MIDIExportReport.maxReportedEntries
        guard entries.count > limit else { return entries }
        return Array(entries.prefix(limit)) + ["… and \(entries.count - limit) more"]
    }

    /// The human roll-up. What is deliberately NOT here: `mutedTracksExported`,
    /// `soloedTracksPresent`, `notesPastClipEnd` and `controllerPointsPastClipEnd`
    /// — those state FACTS about the project rather than losses taken, and they
    /// fire on perfectly ordinary input. A report that says something about every
    /// project is noise nobody reads, and the next agent "fixes" a permanently
    /// noisy field by exempting it — which is what gate leg G9 exists to prevent.
    private static func degradations(for report: MIDIExportReport) -> [String] {
        var lines: [String] = []
        if report.notesQuantized > 0 || report.controllerPointsQuantized > 0 {
            lines.append(
                "\(report.notesQuantized) note(s) and \(report.controllerPointsQuantized) "
                + "controller point(s) were not exactly on the file's tick grid and moved to "
                + "the nearest tick; the largest move was "
                + String(format: "%.4f", report.maxQuantizationErrorMs)
                + " ms. Export at a division that divides your grid to avoid this.")
        }
        if report.notesWidenedToOneTick > 0 {
            lines.append(
                "\(report.notesWidenedToOneTick) note(s) were shorter than one tick at "
                + "\(report.ticksPerQuarterNote) ticks per quarter note and were widened to "
                + "one tick, so they are not lost.")
        }
        if report.overlappingSamePitchNotesTruncated > 0
            || report.overlappingSamePitchNotesDropped > 0 {
            lines.append(
                "\(report.overlappingSamePitchNotesTruncated) note(s) were shortened and "
                + "\(report.overlappingSamePitchNotesDropped) dropped where two notes of the "
                + "same pitch overlapped: a MIDI file has no way to say that one note starts "
                + "before another on the same pitch has finished.")
        }
        if report.clipsWithGainNotExported > 0 {
            lines.append(
                "\(report.clipsWithGainNotExported) clip(s) have a gain, envelope or fade "
                + "that a MIDI file cannot carry; their notes were exported at the velocities "
                + "you wrote, not the levels you hear.")
        }
        if report.clipsWithStretchNotExported > 0 {
            lines.append(
                "\(report.clipsWithStretchNotExported) clip(s) are time-stretched or "
                + "pitch-shifted, which applies to audio and cannot be written into a MIDI "
                + "file; their notes were exported unchanged.")
        }
        if report.audioClipsSkipped > 0 {
            lines.append(
                "\(report.audioClipsSkipped) audio clip(s) sitting on an instrument track "
                + "were skipped — a MIDI file has nowhere to put recorded audio.")
        }
        if !report.droppedMeterChanges.isEmpty {
            lines.append(
                "\(report.droppedMeterChanges.count) time signature(s) could not be written: "
                + report.droppedMeterChanges.joined(separator: "; ") + ".")
        }
        if report.substitutedDefaultMeterAtZero {
            lines.append(
                "the project's time signature at the start could not be written, so the file "
                + "says 4/4 there — every MIDI file must declare one.")
        }
        if !report.tempoSegmentsCollidingAtSameTick.isEmpty {
            lines.append(
                "\(report.tempoSegmentsCollidingAtSameTick.count) tempo change(s) were too "
                + "close together to be told apart at this division: "
                + report.tempoSegmentsCollidingAtSameTick.joined(separator: "; ") + ".")
        }
        if report.programChangesNotWritten > 0 {
            lines.append(
                "\(report.programChangesNotWritten) track(s) name a General MIDI instrument, "
                + "but this version does not write program-change events into the file — the "
                + "receiving program will use its own default sound for each part. The "
                + "instrument each track asks for is listed per track in this report.")
        }
        if report.channelsWrapped > 0 {
            lines.append(
                "\(report.channelsWrapped) track(s) had to reuse a MIDI channel — a MIDI file "
                + "has 16 and this export needed more. Each part is still its own track, so "
                + "this matters only in a player that puts one sound on each channel.")
        }
        if report.trackNamesLostToFormat0 > 0 {
            lines.append(
                "\(report.trackNamesLostToFormat0) track name(s) were lost because format 0 "
                + "merges everything into one track, which can carry only one name. Export as "
                + "format 1 to keep them.")
        }
        if report.maxTempoRoundTripErrorBPM > 0 {
            lines.append(
                "the file stores tempo as microseconds per quarter note, which cannot express "
                + "every BPM exactly; the largest difference is "
                + String(format: "%.6f", report.maxTempoRoundTripErrorBPM)
                + " BPM. No note moves — this is a playback speed difference of well under a "
                + "millisecond per minute.")
        }
        return lines
    }
}
