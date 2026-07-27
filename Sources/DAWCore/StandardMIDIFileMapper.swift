import Foundation

// Standard MIDI File → project mapping — m23-k3 (design:
// docs/research/m23-k3-midi-import-design.md, two architect passes).
//
// THE ONE HOME. Every decision about what an SMF means in DAW Pro's model lives
// in this file and nowhere else: the tick→beat conversion, the tempo/meter map
// construction, the part→track split, the controller-cap policy, and every
// hazard verdict. Pure and store-free — `ProjectStore+MIDIFile` consumes a
// `MIDIImportPlan` and cannot compute one, so no second mapping can exist.
//
// THE SPINE (design §0): for a metrical file, beats are AFFINE IN TICKS —
// `beat = tick / ticksPerQuarterNote`. No tempo value enters that expression,
// because DAW Pro's beat is a quarter note everywhere and SMF's metrical
// division is ticks per quarter note. Consequence: every tempo hazard is a
// PLAYBACK-SPEED hazard, never a NOTE-POSITION hazard — a tempo clamped from
// 60,000,000 BPM to 400 leaves every note on exactly the beat the file said.
// That is why the verdicts below are "accept-lossily + report" rather than
// "refuse". The one carve-out is SMPTE division (§2.2), where ticks are
// ABSOLUTE time and beats are derived through the project's tempo map.
//
// LAW L9: pure Foundation. No AudioToolbox, no CoreMIDI.

// MARK: - Options / context / policy

/// What to do with the file's tempo and meter maps (design D1).
///
/// `ask` is deliberately absent: a headless, agent-driven command must never
/// block on a human. A UI dialog chooses between `adopt` and `ignore` — it is
/// not a third policy.
public enum MIDITempoPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    /// Adopt iff the project has no clips yet — `importGeneration`'s exact
    /// empty-project predicate (`ProjectStore+Generation.swift:61`), so the two
    /// shipped importers can never disagree about the same question.
    case auto
    /// Replace the project's tempo (and meter) maps wholesale with the file's.
    case adopt
    /// Leave both maps untouched.
    case ignore
}

/// Whether to assign instruments from the file's program changes (design D3).
///
/// The default is `none` in k3 and that is a deliberate, evidence-based retreat:
/// nothing in the tree assigns sound-bank instruments in bulk, no per-prepare
/// cost is recorded anywhere, and AU preparation has historically cost minutes
/// on the main actor. k3 computes and REPORTS the whole GM mapping (all of the
/// value, none of the risk); k4 — which owns the UI and can show progress —
/// measures it and flips the default.
public enum MIDIImportInstruments: String, Sendable, Codable, Equatable, CaseIterable {
    case none
    case gm
}

/// Everything the caller chooses about an import.
public struct MIDIImportOptions: Sendable, Equatable {
    /// Timeline beat that file tick 0 lands on (`project.importMIDI`): it
    /// becomes every created clip's `startBeat` (R5) and NEVER enters a note's
    /// `startBeat`, which is clip-relative (R2). Applying it twice would put
    /// every note at `2 × atBeat` — design §10.10.
    public var atBeat: Double
    /// CLIP-RELATIVE shift applied to imported content (`clip.importMIDI`'s
    /// `atBeat`). Zero for the project path, where `atBeat` positions the clip
    /// instead. Kept here rather than at the store so that ALL beat placement —
    /// not just the tick conversion — has one home.
    public var contentOffsetBeats: Double
    public var tempoPolicy: MIDITempoPolicy
    public var instruments: MIDIImportInstruments
    /// Which parts to import, indexing the report's `parts` array (§3.1 — the
    /// FULL enumeration, including skipped parts). `nil` means all. An EXPLICIT
    /// empty array selects nothing, which is the plain reading of an explicit
    /// list and leaves the store's zero-effect refusal to say so.
    public var parts: [Int]?
    /// Overrides the `maxImportedTracks` refusal (§3.4).
    public var force: Bool

    public init(atBeat: Double = 0,
                contentOffsetBeats: Double = 0,
                tempoPolicy: MIDITempoPolicy = .auto,
                instruments: MIDIImportInstruments = .none,
                parts: [Int]? = nil,
                force: Bool = false) {
        self.atBeat = max(0, atBeat)
        self.contentOffsetBeats = max(0, contentOffsetBeats)
        self.tempoPolicy = tempoPolicy
        self.instruments = instruments
        self.parts = parts
        self.force = force
    }
}

/// What the mapper needs to know about the project, passed IN so the mapper
/// never reads a store (and every hazard stays unit-testable headless).
public struct MIDIImportContext: Sendable, Equatable {
    /// `tracks.contains { !$0.clips.isEmpty }` — D1's `auto` predicate.
    public var projectHasClips: Bool
    /// The project's current tempo map. Used as the SMPTE clock's beat source
    /// (§2.2) and as the tempo argument of a meter-only adoption (§2.5).
    public var currentTempoMap: TempoMap
    public var currentMeterMap: MeterMap
    /// Length of the clip being imported INTO (`clip.importMIDI`), or nil for
    /// the project path. Drives `notesPastClipEnd` — a clip import never
    /// changes `lengthBeats`, so content past the end is reported, not trimmed.
    public var targetClipLengthBeats: Double?

    public init(projectHasClips: Bool,
                currentTempoMap: TempoMap,
                currentMeterMap: MeterMap,
                targetClipLengthBeats: Double? = nil) {
        self.projectHasClips = projectHasClips
        self.currentTempoMap = currentTempoMap
        self.currentMeterMap = currentMeterMap
        self.targetClipLengthBeats = targetClipLengthBeats
    }
}

// MARK: - Errors

/// Structured MIDI-import refusals. Every message is a readable, actionable
/// sentence — the control protocol surfaces `errorDescription` verbatim (the
/// `SampleLibraryImportError` precedent).
public enum MIDIImportError: Error, LocalizedError, Equatable {
    /// Wrong extension entirely (not `.mid` / `.midi`).
    case notAMIDIFile(fileName: String)
    /// The file itself is missing or unreadable.
    case fileNotFound(path: String)
    /// `tempoPolicy: "adopt"` with a non-zero `atBeat` (D1′). Tempo and meter
    /// maps are ABSOLUTE, so there is no honest offset adoption.
    case tempoAdoptionRequiresBeatZero(atBeat: Double)
    /// The selected parts would create more tracks than `maxImportedTracks`
    /// and `force` was not passed (§3.4).
    case tooManyTracks(count: Int, limit: Int)
    /// The import would create no tracks AND adopt no map (§3.3b) — never a
    /// silent no-op that reads to the user as "this file was empty".
    case nothingToImport(fileName: String, contained: String)
    /// A `parts` entry that indexes nothing. Silently importing nothing would
    /// be indistinguishable from success.
    case partIndexOutOfRange(index: Int, partCount: Int)
    /// A map the mapper's own invariants say cannot fail to build, failed.
    /// Surfaced honestly rather than `try!`-crashed on a user's file (§2.3).
    case internalInconsistency(String)

    public var errorDescription: String? {
        switch self {
        case .notAMIDIFile(let fileName):
            return "\(fileName) is not a MIDI file — this imports .mid and .midi Standard MIDI Files"
        case .fileNotFound(let path):
            return "no MIDI file at \(path)"
        case .tempoAdoptionRequiresBeatZero(let atBeat):
            return "a MIDI file's tempo and time-signature maps start at beat 0 of the project, "
                + "so they cannot be adopted at beat \(formatBeat(atBeat)) — either import at "
                + "beat 0, or pass tempoPolicy: \"ignore\" to place the notes there and keep "
                + "the project's own tempo"
        case .tooManyTracks(let count, let limit):
            return "this MIDI file would create \(count) tracks, over the \(limit)-track import "
                + "limit — import a subset with parts: [...] (run with dryRun: true to see "
                + "them), or pass force: true to create them all"
        case .nothingToImport(let fileName, let contained):
            return "importing \(fileName) would do nothing — \(contained); nothing was changed "
                + "(run with dryRun: true to inspect the full report)"
        case .partIndexOutOfRange(let index, let partCount):
            return "this MIDI file has \(partCount) part(s), numbered 0…\(max(0, partCount - 1)), "
                + "so part \(index) does not exist"
        case .internalInconsistency(let detail):
            return "this MIDI file's \(detail) could not be built, which should be impossible — "
                + "please report the file"
        }
    }
}

/// Formats a beat for a message without a trailing `.0` on whole beats.
private func formatBeat(_ beat: Double) -> String {
    beat == beat.rounded() && abs(beat) < 1e15
        ? String(Int(beat.rounded()))
        : String(format: "%g", beat)
}

// MARK: - The tick clock — THE ONE producer of a beat from a tick

/// Converts the file's own ticks into project beats, and nothing else.
///
/// **Every tick→beat conversion in the program goes through this type.** No
/// caller divides by a division itself. This is the `ResolvedDropBeat` law
/// applied one level down: a `fileprivate` plan initializer stops the store
/// building a plan, but only a named conversion type stops a later surface
/// (k4's drag-drop especially) writing `Double(tick) / 480.0` inline.
public struct SMFTickClock: Sendable, Equatable {
    private enum Kind: Sendable, Equatable {
        /// Metrical: `t` ticks per quarter note, and a beat IS a quarter note.
        case metrical(ticksPerQuarterNote: Int)
        /// SMPTE: ticks are absolute time at a fixed rate; beats come from the
        /// project's tempo map.
        case absolute(ticksPerSecond: Double)
    }

    private let kind: Kind
    private let tempoMap: TempoMap
    /// The division this clock was built from, NORMALIZED exactly as `kind` is
    /// (a metrical `t` floored at 1), so `division` and `kind` can never
    /// disagree about the same file. Stored rather than reconstructed because
    /// the SMPTE branch collapses `(fps, ticksPerFrame)` into one rate and the
    /// pair is not recoverable from it — and m23-k4a's export needs the pair to
    /// write an `MThd` back out.
    private let sourceDivision: SMFDivision

    /// - Parameters:
    ///   - division: the file's `MThd` division, verbatim.
    ///   - tempoMap: the project's tempo map. UNUSED on the metrical path (the
    ///     spine: beats are affine in ticks, tempo is not in the loop); it is
    ///     the beat source on the SMPTE path only.
    public init(division: SMFDivision, tempoMap: TempoMap) {
        switch division {
        case .ticksPerQuarterNote(let t):
            // The reader throws `invalidDivision` on 0, so t >= 1 is guaranteed;
            // the max() is belt-and-braces against a hand-built IR.
            kind = .metrical(ticksPerQuarterNote: max(1, t))
            sourceDivision = .ticksPerQuarterNote(max(1, t))
        case .smpte(let framesPerSecond, let ticksPerFrame):
            // -29 in the spec's two's-complement byte means 30 drop-frame at
            // 29.97; 24/25/30 are exact. The reader guarantees both values > 0.
            let fps = framesPerSecond == 29 ? 30_000.0 / 1_001.0 : Double(framesPerSecond)
            kind = .absolute(ticksPerSecond: fps * Double(ticksPerFrame))    // R9
            sourceDivision = division
        }
        self.tempoMap = tempoMap
    }

    /// The division, for a caller BUILDING a file (m23-k4a). Exposed so the
    /// export mapper never holds a bare `Int` ticks-per-quarter of its own: the
    /// only way to multiply by hand is to destructure this enum for no reason,
    /// which is the D-ONEHOME mechanism (design-m23-k4a §2.4).
    public var division: SMFDivision { sourceDivision }

    /// True for a SMPTE file: note beats then depend on the project tempo,
    /// exactly like imported audio, and a later tempo change moves them
    /// relative to wall-clock. Inherent to absolute time, not a defect.
    public var isAbsoluteTime: Bool {
        if case .absolute = kind { return true }
        return false
    }

    /// Ticks per quarter note for a metrical file; nil for SMPTE.
    public var ticksPerQuarterNote: Int? {
        if case .metrical(let t) = kind { return t }
        return nil
    }

    /// R1 (metrical) / R10+R11 (SMPTE).
    ///
    /// R1 is a SINGLE DIVISION of two exactly-representable integers. It must
    /// NOT be written as `Double(tick) * reciprocal` with the reciprocal
    /// hoisted: the single division is the correctly-rounded answer BY
    /// DEFINITION, so `beats` has one right value and not two. (Measured: the
    /// two forms agree at every integer beat and on every musical grid at every
    /// division a MIDI file uses, and differ at 9.3 % of raw ticks at t = 480,
    /// first at tick 23. So this is a one-definition argument, not an audible
    /// fidelity claim — and the gate leg that catches a reciprocal is G1b, at
    /// tick 23, not the integer-beat identity.)
    public func beats(tick: Int) -> Double {
        switch kind {
        case .metrical(let t):
            return Double(tick) / Double(t)                                  // R1
        case .absolute(let ticksPerSecond):
            return tempoMap.beat(atSecondsFromZero: Double(tick) / ticksPerSecond) // R10/R11
        }
    }

    /// A note's length in beats: R3 on the metrical path, R12 on the SMPTE one,
    /// chosen by the clock rather than remembered by each call site.
    public func lengthBeats(tick: Int, lengthTicks: Int) -> Double {
        switch kind {
        case .metrical(let t):
            // `tick` IS NOT IN SCOPE inside the helper. Endpoint subtraction is
            // not "discouraged" on the metrical path, it is UNWRITEABLE — the
            // signature is load-bearing, not stylistic. Do not collapse it: a
            // single body that branched inline would leave `tick` visible and
            // dead on this path, which is exactly the shape a later reader
            // "cleans up" by using it. (Measured: endpoint subtraction of a
            // triplet-eighth length, 160 ticks at t = 480, diverges at 19,998
            // of 20,001 sixteenth-grid positions. G2 is that leg.)
            return Self.metricalLength(lengthTicks: lengthTicks, ticksPerQuarter: t)
        case .absolute:
            // R12 — there is no `t` to divide by, so endpoint subtraction is the
            // ONLY available form, and R3's prohibition does not apply. Under a
            // non-constant tempo map, equal `lengthTicks` at different positions
            // SHOULD give different `lengthBeats`: that is what absolute time
            // means, which is why G2 is scoped to metrical files.
            //
            // SATURATING, not wrapping. This is the ONE addition of two ticks in
            // the mapper, and m23-k2 already paid for this class once: a
            // hand-built `SMFNote(tick: .max, lengthTicks: 1)` SIGTRAPped inside
            // a pure-model type there, fixed with the same `addingReportingOverflow`
            // posture. A decoded file cannot reach it (ticks accumulate from
            // <=4-byte VLQs), but `map(_:options:context:)` is public API over a
            // caller-constructed `StandardMIDIFile`, so a hand-built IR can — and a
            // pure value-level API must refuse, never trap.
            let (endTick, overflowed) = tick.addingReportingOverflow(lengthTicks)
            return beats(tick: overflowed ? Int.max : endTick) - beats(tick: tick)
        }
    }

    private static func metricalLength(lengthTicks: Int, ticksPerQuarter t: Int) -> Double {
        Double(lengthTicks) / Double(t)                                      // R3
    }

    // MARK: - The INVERSE (m23-k4a) — beats back into ticks

    /// X1 (metrical) / §2.2 (SMPTE): the tick a beat lands on.
    ///
    /// `tick = round(beat · t)`, and the rounding rule is `round` — NOT `floor`,
    /// `trunc` or `ceil` — because it is the only one that bounds the error at
    /// half a tick instead of a whole one. `Double.rounded()` is
    /// half-away-from-zero; beats are non-negative everywhere in the model
    /// (`Clip.init` and `MIDINote.init` both floor at 0), so it is half-UP here
    /// and `floor` and `trunc` are provably indistinguishable — an honest limit
    /// of any gate leg over this function, not a gap in one.
    ///
    /// Import is TOTAL and export is not: every tick has a beat, but only the
    /// beats with `beat·t ∈ ℤ` survive the trip back. That loss is the export
    /// mapper's to MEASURE (through this function composed with `beats(tick:)`,
    /// never through a formula) and to report.
    ///
    /// SATURATING at the `Int` boundary, never trapping — the same posture
    /// `lengthBeats` already takes on its one addition. `Int(someDouble)` traps
    /// on an out-of-range value, and `beat` is a `Double` a caller controls
    /// (`Clip.startBeat` is floored at 0 but not ceilinged), so a hand-authored
    /// 1e300 would crash a pure value-level API. It saturates instead, and the
    /// export mapper's tick-ceiling pre-check turns the saturated value into a
    /// teaching refusal.
    public func ticks(beat: Double) -> Int {
        switch kind {
        case .metrical(let t):
            return Self.saturatingInt((beat * Double(t)).rounded())          // X1
        case .absolute(let ticksPerSecond):
            // The exact inverse of R10/R11: beats → seconds through the
            // project's tempo map, seconds → ticks at the file's fixed rate.
            // Live, tested code that the CONTROL WIRE CANNOT REACH — export
            // always builds a metrical division (`MIDIExportOptions` carries an
            // `SMFDivision` made from a validated 1…32767 Int), so there is no
            // `division: "smpte"` to ask for. It exists for totality, so that
            // "this clock converts both ways" has no asterisk.
            return Self.saturatingInt(
                (tempoMap.seconds(fromBeatZeroTo: beat) * ticksPerSecond).rounded())
        }
    }

    /// X2 — a note's onset tick AND its length in ticks, as ONE answer.
    ///
    /// The pair return is load-bearing, and it is the mirror image of
    /// `metricalLength`'s hidden `tick`. THE LENGTH RULE REVERSES BETWEEN
    /// IMPORT AND EXPORT: on the way in, R3 forbids endpoint subtraction and
    /// requires `lengthTicks / t`; on the way out, this REQUIRES endpoint
    /// subtraction — `ticks(startBeat + lengthBeats) − ticks(startBeat)` — and
    /// forbids `round(lengthBeats · t)`. Both rules exist for the same reason
    /// (one rounding, not two) and land on opposite forms because the direction
    /// flipped, which makes "let me make export consistent with import" the
    /// single most likely wrong edit to this file.
    ///
    /// It is not a style preference. Measured at t = 1200 over 200,000 random
    /// (start, length) pairs, the two forms disagree on 24.9 % of them; over
    /// 50,000 FLUSH-LEGATO pairs the endpoint form keeps the note-off tick equal
    /// to the next note-on tick in 50,000 of 50,000, while the independent form
    /// breaks that boundary in 12,420 (24.84 %). A note-off landing one tick
    /// past the next same-pitch onset turns a flush pair into an overlap, which
    /// a later export then truncates — a lossy edit minted by a rounding choice.
    ///
    /// `lengthBeats` is NOT IN SCOPE for any length-only entry point, because
    /// there is none: a caller who wants a length gets it with its onset or not
    /// at all, so `round(lengthBeats · t)` has no API to be written through.
    /// (Honest limit, stated so it is not over-trusted: `SMFDivision` is public
    /// and destructurable, so this is "the natural way is the only available
    /// way", not `ResolvedDropBeat`-grade unrepresentability. Gate leg G-M1 is
    /// the backstop.)
    ///
    /// The returned `lengthTicks` may be 0 or negative-turned-0 for a degenerate
    /// input; clamping it to a minimum is the MAPPER's musical policy and
    /// deliberately not the clock's arithmetic (k2 accepts `lengthTicks == 0` —
    /// it has a `zeroLengthNoteOff` rung for exactly that).
    public func noteTicks(startBeat: Double,
                          lengthBeats: Double) -> (tick: Int, lengthTicks: Int) {
        let tick = ticks(beat: startBeat)
        let endTick = ticks(beat: startBeat + lengthBeats)                   // X2
        let (length, overflowed) = endTick.subtractingReportingOverflow(tick)
        return (tick, overflowed ? Int.max : length)
    }

    /// `Int(_:)` on a `Double` TRAPS outside the integer range and on NaN. Every
    /// beat that reaches this type is caller-supplied, so it saturates instead:
    /// NaN has no tick at all and becomes 0, and an overflowing magnitude
    /// becomes the extreme the caller's own ceiling check will then refuse on.
    private static func saturatingInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= 9.2233720368547758e18 { return .max }
        if value <= -9.2233720368547758e18 { return .min }
        return Int(value)
    }

    /// Human description of the division, for the report.
    public var divisionDescription: String {
        switch kind {
        case .metrical(let t):
            return "\(t) ticks per quarter note"
        case .absolute(let ticksPerSecond):
            return String(format: "SMPTE absolute time, %g ticks per second", ticksPerSecond)
        }
    }
}

// MARK: - The report

/// Everything an import did and every fidelity loss it took, in machine-
/// readable fields plus human sentences (the `SampleLibraryImportReport`
/// idiom). Returned by dry runs AND applies; the wire emits it as JSON.
///
/// This is deliberately NOT `SMFWarning`. `SMFWarning` is about THE FILE — what
/// the bytes said, decided by the reader, identical for every consumer of the
/// IR. The fields below are about THE MAPPING ONTO OUR MODEL — decided here,
/// and entirely different against a different target model. Growing `SMFWarning`
/// with `tempoClampedToProjectRange` would drag the reader into knowing about
/// `TempoMap` and the store's lane caps, which is exactly the coupling the
/// tick-native IR exists to prevent. The two are reconciled by carrying the
/// file's own warnings inside this report (`fileWarnings`), so one object
/// answers "what was odd about this import" end to end.
public struct MIDIImportReport: Codable, Sendable, Equatable {

    /// One entry per `(sourceTrackIndex, channel)` pair in §3.1's FULL
    /// enumeration, INCLUDING parts that were skipped — so `parts: [0]` means
    /// the same thing in a dry run and a real one.
    public struct Part: Codable, Sendable, Equatable {
        public var index: Int
        public var name: String
        public var sourceTrackIndex: Int
        /// 0-based MIDI channel (the raw wire value, R1); nil for a part that
        /// speaks on no channel at all — a conductor/tempo-only chunk.
        public var channel: Int?
        public var noteCount: Int
        /// `wireKey`s of the lanes actually imported ("cc11", "pitchBend"…).
        public var controllerLanes: [String]
        /// The program this part asks for, 0-based (D3). Reported whether or
        /// not `instruments: "gm"` applied it.
        public var programChange: Int?
        /// The GM name of that program, or the drum kit for channel 10.
        public var programName: String?
        public var imported: Bool
        public var skipReason: String?
        /// nil on a dry run (nothing was created).
        public var trackID: UUID?
        public var clipID: UUID?

        /// `trackID`/`clipID` ride the wire as `trackId`/`clipId` — the same
        /// spelling every command's params use (`Track.outputBusID`'s precedent),
        /// so an agent can feed a reported id straight back into `clip.importMIDI`.
        private enum CodingKeys: String, CodingKey {
            case index, name, sourceTrackIndex, channel, noteCount, controllerLanes
            case programChange, programName, imported, skipReason
            case trackID = "trackId"
            case clipID = "clipId"
        }

        public init(index: Int, name: String, sourceTrackIndex: Int, channel: Int?,
                    noteCount: Int, controllerLanes: [String],
                    programChange: Int? = nil, programName: String? = nil,
                    imported: Bool, skipReason: String? = nil,
                    trackID: UUID? = nil, clipID: UUID? = nil) {
            self.index = index
            self.name = name
            self.sourceTrackIndex = sourceTrackIndex
            self.channel = channel
            self.noteCount = noteCount
            self.controllerLanes = controllerLanes
            self.programChange = programChange
            self.programName = programName
            self.imported = imported
            self.skipReason = skipReason
            self.trackID = trackID
            self.clipID = clipID
        }
    }

    // --- what the file was
    public var format: Int
    public var divisionDescription: String
    /// True for a SMPTE-division file (§2.2's carve-out).
    public var isAbsoluteTime: Bool

    // --- the per-part ledger
    public var parts: [Part]

    // --- what landed
    public var tracksCreated: Int
    public var notesImported: Int
    public var controllerPointsImported: Int
    public var instrumentsAssigned: String

    // --- tempo / meter
    /// Never "auto" — the report echoes what `auto` RESOLVED to.
    public var resolvedTempoPolicy: String
    public var tempoSegmentsAdopted: Int
    public var meterChangesAdopted: Int
    public var adoptedTempoBPM: Double?

    // --- the losses. Every one of these is empty/zero/false on a clean file
    //     (gate leg G9); if that stops being true the report becomes noise.
    /// H1 — a tempo the transport's 20…400 range clamped.
    public var clampedTempoEvents: [String]
    /// H2 (+ malformed, §1.3-1) — meter changes the model would not accept.
    public var droppedMeterChanges: [String]
    /// H3 — a second event at the same tick with a DIFFERENT value; the first
    /// won. Named rather than counted: the one file shape first-wins gets
    /// wrong needs tick, beat, winner and loser to be actionable.
    public var conflictingDuplicateTempoEvents: [String]
    public var conflictingDuplicateMeterEvents: [String]
    /// §2.3 step 3.5 — `µsPerQuarter <= 0`. Malformed, not merely extreme.
    public var droppedMalformedTempoEvents: [String]
    /// §2.2 — a SMPTE file was asked to hand over a tempo map it cannot have.
    public var tempoAdoptionDegradedToIgnore: Bool
    /// H4b — the file's first event was not at tick 0, so the SMF default was
    /// prepended at beat 0.
    public var synthesizedLeadingTempo: Bool
    public var synthesizedLeadingMeter: Bool
    /// H4c — ABSENCE, not a default. The file declared no map of this kind, so
    /// adopting it is a no-op and the project's own map is untouched. These two
    /// are INFORMATIONAL and sit outside the loss section: they must never push
    /// a line into `degradations` (the spine fixture sets
    /// `fileCarriedNoMeterMap` and G9 must need no exemption). FALSE when the
    /// events existed but were all dropped as malformed — that file asserted a
    /// map, it asserted an unusable one.
    public var fileCarriedNoTempoMap: Bool
    public var fileCarriedNoMeterMap: Bool
    /// H5b — `MIDINote` has no release-velocity field. 0 and 64 are the two
    /// conventional "no information" spellings and are NOT counted, or this
    /// would fire on every ordinary file.
    public var notesWithDroppedReleaseVelocity: Int
    /// H6c — notes shorter than `MIDINote.minLengthBeats` (a zero-tick note, or
    /// any note under `t/1000` ticks) stretched to it.
    public var notesStretchedToMinimumLength: Int
    public var shortestRequestedLengthBeats: Double?
    /// H7 — lane `wireKey` → canonical points dropped with it.
    public var droppedControllerLanes: [String: Int]
    /// H7 — lane `wireKey` → points kept after decimation.
    public var decimatedControllerLanes: [String: Int]
    /// D3 — program changes past the first on a part's channel, plus program
    /// changes for channels that produced no part at all.
    public var droppedProgramChanges: Int
    /// D3 — per-note aftertouch has no home in the model; the count is all that
    /// survives.
    public var polyAftertouchEventsDropped: Int
    /// `clip.importMIDI` only: content past the target clip's end. The clip is
    /// never resized — compose with `clip.fitToContent`.
    public var notesPastClipEnd: Int
    public var controllerPointsPastClipEnd: Int

    // --- the two prose channels
    /// `SMFWarning.description` verbatim, from the reader (k1).
    public var fileWarnings: [String]
    /// Human sentences: what an import gave up, in the words a user reads.
    public var degradations: [String]

    /// A `[String]` loss list never exceeds this many entries; the overflow
    /// folds into a trailing "… and N more". A pathological file with ten
    /// thousand off-barline meter changes must not mint a ten-thousand-element
    /// array that rides the wire into an agent's context. The typed COUNTS
    /// alongside stay exact.
    public static let maxReportedEntries = 32

    public init(format: Int = 1,
                divisionDescription: String = "",
                isAbsoluteTime: Bool = false,
                parts: [Part] = [],
                tracksCreated: Int = 0,
                notesImported: Int = 0,
                controllerPointsImported: Int = 0,
                instrumentsAssigned: String = MIDIImportInstruments.none.rawValue,
                resolvedTempoPolicy: String = MIDITempoPolicy.ignore.rawValue,
                tempoSegmentsAdopted: Int = 0,
                meterChangesAdopted: Int = 0,
                adoptedTempoBPM: Double? = nil,
                clampedTempoEvents: [String] = [],
                droppedMeterChanges: [String] = [],
                conflictingDuplicateTempoEvents: [String] = [],
                conflictingDuplicateMeterEvents: [String] = [],
                droppedMalformedTempoEvents: [String] = [],
                tempoAdoptionDegradedToIgnore: Bool = false,
                synthesizedLeadingTempo: Bool = false,
                synthesizedLeadingMeter: Bool = false,
                fileCarriedNoTempoMap: Bool = false,
                fileCarriedNoMeterMap: Bool = false,
                notesWithDroppedReleaseVelocity: Int = 0,
                notesStretchedToMinimumLength: Int = 0,
                shortestRequestedLengthBeats: Double? = nil,
                droppedControllerLanes: [String: Int] = [:],
                decimatedControllerLanes: [String: Int] = [:],
                droppedProgramChanges: Int = 0,
                polyAftertouchEventsDropped: Int = 0,
                notesPastClipEnd: Int = 0,
                controllerPointsPastClipEnd: Int = 0,
                fileWarnings: [String] = [],
                degradations: [String] = []) {
        self.format = format
        self.divisionDescription = divisionDescription
        self.isAbsoluteTime = isAbsoluteTime
        self.parts = parts
        self.tracksCreated = tracksCreated
        self.notesImported = notesImported
        self.controllerPointsImported = controllerPointsImported
        self.instrumentsAssigned = instrumentsAssigned
        self.resolvedTempoPolicy = resolvedTempoPolicy
        self.tempoSegmentsAdopted = tempoSegmentsAdopted
        self.meterChangesAdopted = meterChangesAdopted
        self.adoptedTempoBPM = adoptedTempoBPM
        self.clampedTempoEvents = clampedTempoEvents
        self.droppedMeterChanges = droppedMeterChanges
        self.conflictingDuplicateTempoEvents = conflictingDuplicateTempoEvents
        self.conflictingDuplicateMeterEvents = conflictingDuplicateMeterEvents
        self.droppedMalformedTempoEvents = droppedMalformedTempoEvents
        self.tempoAdoptionDegradedToIgnore = tempoAdoptionDegradedToIgnore
        self.synthesizedLeadingTempo = synthesizedLeadingTempo
        self.synthesizedLeadingMeter = synthesizedLeadingMeter
        self.fileCarriedNoTempoMap = fileCarriedNoTempoMap
        self.fileCarriedNoMeterMap = fileCarriedNoMeterMap
        self.notesWithDroppedReleaseVelocity = notesWithDroppedReleaseVelocity
        self.notesStretchedToMinimumLength = notesStretchedToMinimumLength
        self.shortestRequestedLengthBeats = shortestRequestedLengthBeats
        self.droppedControllerLanes = droppedControllerLanes
        self.decimatedControllerLanes = decimatedControllerLanes
        self.droppedProgramChanges = droppedProgramChanges
        self.polyAftertouchEventsDropped = polyAftertouchEventsDropped
        self.notesPastClipEnd = notesPastClipEnd
        self.controllerPointsPastClipEnd = controllerPointsPastClipEnd
        self.fileWarnings = fileWarnings
        self.degradations = degradations
    }

    /// True when nothing at all would happen (§3.3b). Measured off the REPORT,
    /// never off the requested policy — an `adopt` of a file that carries no
    /// tempo or meter events resolves to a no-op adoption (H4c) and would
    /// otherwise return success having done nothing.
    public var wouldChangeNothing: Bool {
        tracksCreated == 0 && tempoSegmentsAdopted == 0 && meterChangesAdopted == 0
    }

    /// One sentence naming what the file DID contain, for the `nothingToImport`
    /// refusal — so the message is about their file, not about our policy.
    public var contentSummary: String {
        var pieces: [String] = []
        let skipped = parts.filter { !$0.imported }.count
        if parts.isEmpty {
            pieces.append("it contains no parts")
        } else if skipped == parts.count {
            pieces.append("all \(parts.count) of its part(s) carry no notes or controller data")
        } else {
            pieces.append("\(parts.count - skipped) of its \(parts.count) part(s) hold content "
                          + "but none was selected for import")
        }
        if fileCarriedNoTempoMap { pieces.append("it declares no tempo map") }
        if fileCarriedNoMeterMap { pieces.append("it declares no time signature") }
        if resolvedTempoPolicy == MIDITempoPolicy.ignore.rawValue,
           !fileCarriedNoTempoMap {
            pieces.append("its tempo map was not adopted (tempoPolicy resolved to \"ignore\")")
        }
        return pieces.joined(separator: ", and ")
    }
}

// MARK: - The plan

/// A complete, ready-to-apply import: the tracks to append, the maps to adopt
/// (nil = do not adopt), and the report.
///
/// **`init` is `fileprivate`, so `SMFProjectMapper.map` is the only producer in
/// the program** and `ProjectStore`'s import is typed to consume one — the
/// store cannot compute a plan for itself, so no second mapping can exist. An
/// explicit `init` suppresses the synthesized memberwise initializer (which
/// would otherwise be `internal` and reachable from anywhere in DAWCore);
/// `Equatable` and `Sendable` synthesize no initializer.
///
/// **This type must NEVER conform to `Codable`.** A public `Codable` struct
/// synthesizes a public `init(from:)`, a second producer that no `fileprivate`
/// can stop. If a snapshot ever needs to show a plan, encode the `report`
/// (which IS `Codable`), not the plan.
public struct MIDIImportPlan: Sendable, Equatable {

    /// One track to create, with its single clip already built.
    public struct PlannedTrack: Sendable, Equatable {
        /// Index into `report.parts` (§3.1's full enumeration).
        public let partIndex: Int
        public let track: Track
        /// The track's one clip — `track.clips[0]`, surfaced so the clip-level
        /// import can harvest its notes and lanes without index arithmetic.
        public let clip: Clip

        fileprivate init(partIndex: Int, track: Track, clip: Clip) {
            self.partIndex = partIndex
            self.track = track
            self.clip = clip
        }
    }

    public let tracks: [PlannedTrack]
    /// Non-nil means ADOPT. `applyTempoMap` replaces wholesale, so a meter-only
    /// adoption carries the project's CURRENT tempo map here (§2.5) and the
    /// report's `tempoSegmentsAdopted` stays 0 — the map moved nothing.
    public let tempoMap: TempoMap?
    /// Non-nil means adopt the meter too; nil leaves the meter untouched
    /// (`applyTempoMap`'s own `meterMap: nil` contract).
    public let meterMap: MeterMap?
    public let report: MIDIImportReport

    fileprivate init(tracks: [PlannedTrack], tempoMap: TempoMap?,
                     meterMap: MeterMap?, report: MIDIImportReport) {
        self.tracks = tracks
        self.tempoMap = tempoMap
        self.meterMap = meterMap
        self.report = report
    }
}

// MARK: - The mapper

public enum SMFProjectMapper {

    /// A file whose selected parts would create more tracks than this is
    /// refused unless `force: true`. A POLICY number protecting the main actor
    /// (`tracksDidChange` drives an engine reconcile), not a physical limit —
    /// nothing in the model caps track count. One edit to move.
    public static let maxImportedTracks = 32

    /// The SMF 1.0 default tempo, used ONLY to complete a map the file started
    /// (H4b) — never to manufacture one it never began (H4c).
    static let defaultMicrosecondsPerQuarter = 500_000
    /// The SMF 1.0 default meter, same rule.
    static let defaultMeter = (numerator: 4, denominatorPower: 2)

    /// Lane priority when a clip carries more controller streams than the store
    /// allows (H7). The head is ENGINE-AWARE, not arbitrary: CC 64 is the ONLY
    /// CC DAW Pro's built-in instruments act on (`MIDIControllerType`: "built-in
    /// instruments honour CC 64 (sustain); every other CC is forwarded to
    /// hosted Audio Units"), so a pure "most points" rule would drop sustain in
    /// favour of dense controller spam.
    static let controllerPriority: [MIDIControllerType] = [
        .pitchBend, .channelPressure,
        .cc(controller: 64), .cc(controller: 1), .cc(controller: 11),
        .cc(controller: 7), .cc(controller: 10),
    ]

    /// Maps a decoded file onto a plan. Pure: no store, no engine, no clock —
    /// every hazard verdict in the design is unit-testable through this one
    /// call.
    public static func map(_ file: StandardMIDIFile,
                           options: MIDIImportOptions,
                           context: MIDIImportContext) throws -> MIDIImportPlan {
        var report = MIDIImportReport()
        var degradations = CappedStrings()

        // ---- 0. The clock. On the SMPTE path beats come from the project's
        //         tempo map, which is also the only map that can be in effect
        //         there (adoption is impossible), so there is no cycle.
        let clock = SMFTickClock(division: file.division, tempoMap: context.currentTempoMap)
        report.format = file.format.rawValue
        report.divisionDescription = clock.divisionDescription
        report.isAbsoluteTime = clock.isAbsoluteTime
        report.instrumentsAssigned = options.instruments.rawValue
        report.fileWarnings = file.warnings.map(\.description)
        if file.format == .independentSequences {
            degradations.append(
                "this file declares independent sequences (format 2); DAW Pro laid its parts "
                + "out simultaneously, all starting at the same beat")
        }
        if clock.isAbsoluteTime {
            degradations.append(
                "this file measures time in SMPTE frames, not musical ticks, so its notes were "
                + "placed through the project's tempo map — exactly like imported audio, a "
                + "later tempo change moves them relative to wall-clock time")
        }

        // ---- 1. Tempo policy (D1, D1′). Resolved BEFORE the maps are built so
        //         a refusal costs nothing.
        var resolved: MIDITempoPolicy
        switch options.tempoPolicy {
        case .adopt:
            guard options.atBeat == 0 else {
                // D1′: adoption is a wholesale REPLACE of maps that are
                // absolute; an offset adoption would be a MERGE, a different
                // operation with its own unanswered questions. Refusing a
                // self-contradictory explicit request beats silently performing
                // a third operation under the first one's name.
                throw MIDIImportError.tempoAdoptionRequiresBeatZero(atBeat: options.atBeat)
            }
            resolved = .adopt
        case .ignore:
            resolved = .ignore
        case .auto:
            // `importGeneration`'s exact predicate, passed in as
            // `projectHasClips`. `auto` at a non-zero beat simply resolves to
            // ignore rather than refusing — the user named no policy.
            resolved = (context.projectHasClips || options.atBeat != 0) ? .ignore : .adopt
        }

        // ---- 2. The file's tempo map (§2.3).
        let tempoBuild = buildTempoMap(file: file, clock: clock, report: &report)
        // ---- 3. The file's meter map (§2.4).
        let meterBuild = try buildMeterMap(file: file, clock: clock, report: &report)

        // A SMPTE file's `FF 51` events do not govern its tick rate, so adopting
        // a tempo map from it would be meaningless. Not a refusal — the user
        // asked for a policy, not for a contradiction.
        //
        // The degradation is TEMPO-ONLY, and deliberately so. `buildTempoMap`
        // already returns `map: nil` for an absolute-time clock, so the tempo
        // half is dead STRUCTURALLY and nothing here has to switch it off.
        // Flipping `resolved` to `.ignore` would therefore change exactly one
        // thing — it would silently discard the METER map too — and §2.2 is
        // explicit that meter survives: meter is a bar-grid/display concept, not
        // a clock, so `3/4` at tick 0 is a true statement about a SMPTE file in
        // a way that `120 BPM` is not. §2.5's `(nil, meter?)` case is precisely
        // the mechanism for adopting it: the project's CURRENT tempo map rides
        // through `applyTempoMap` unchanged so the meter change lands without
        // moving the tempo. (The report stays honest either way and says more
        // than one bit: `resolvedTempoPolicy` "adopt", `tempoSegmentsAdopted` 0,
        // `tempoAdoptionDegradedToIgnore` true, `meterChangesAdopted` N.)
        if resolved == .adopt, clock.isAbsoluteTime {
            report.tempoAdoptionDegradedToIgnore = true
            degradations.append(
                "this file's tempo events do not govern its own clock (SMPTE absolute time), so "
                + "there was no tempo map to adopt; the project's tempo is unchanged")
        }
        report.resolvedTempoPolicy = resolved.rawValue

        // ---- 4. Enumerate the parts (§3.1) — uniformly for EVERY format: the
        //         DAW track set is the set of (sourceTrackIndex, channel) pairs.
        //         Format 1 (and 2) can carry several channels in one `MTrk` and
        //         k1 does not split those; merging them would point one
        //         mono-timbral instrument at several parts AND destroy
        //         controller data, since a clip holds at most one lane per type.
        let parts = enumerateParts(file)
        if let requested = options.parts {
            for index in requested where index < 0 || index >= parts.count {
                throw MIDIImportError.partIndexOutOfRange(index: index, partCount: parts.count)
            }
        }
        let selection: Set<Int>? = options.parts.map(Set.init)

        // ---- 5. Build one track per importable part.
        var planned: [MIDIImportPlan.PlannedTrack] = []
        var reportParts: [MIDIImportReport.Part] = []
        var laneDrops: [String: Int] = [:]
        var laneDecimations: [String: Int] = [:]
        var totalNotes = 0
        var totalPoints = 0
        var droppedProgramChanges = 0
        var polyAftertouch = 0
        var releaseVelocityDrops = 0
        var stretchedNotes = 0
        var shortestRequested: Double?
        var notesPastEnd = 0
        var pointsPastEnd = 0

        for part in parts {
            polyAftertouch += part.polyAftertouchEventCount
            droppedProgramChanges += part.droppedProgramChangeCount
            let programName = part.programName

            // D4: the discriminator is CONTENT, not `channels.isEmpty`. They
            // coincide today, but a CC-only part IS content and IS imported —
            // `Clip` supports a CC-only MIDI clip as `notes: []` + lanes.
            guard !part.notes.isEmpty || !part.controllers.isEmpty else {
                reportParts.append(MIDIImportReport.Part(
                    index: part.index, name: part.name,
                    sourceTrackIndex: part.sourceTrackIndex, channel: part.channel,
                    noteCount: 0, controllerLanes: [],
                    programChange: part.programChange, programName: programName,
                    imported: false, skipReason: "no notes or controller data"))
                continue
            }
            guard selection?.contains(part.index) ?? true else {
                reportParts.append(MIDIImportReport.Part(
                    index: part.index, name: part.name,
                    sourceTrackIndex: part.sourceTrackIndex, channel: part.channel,
                    noteCount: part.notes.count, controllerLanes: [],
                    programChange: part.programChange, programName: programName,
                    imported: false, skipReason: "not selected for import"))
                continue
            }

            // Notes (R2, R3). `atBeat` NEVER enters a note's startBeat — it is
            // clip-relative; `contentOffsetBeats` is the clip-level import's own
            // in-clip shift and is 0 on the project path.
            var notes: [MIDINote] = []
            notes.reserveCapacity(part.notes.count)
            for smf in part.notes {
                let requestedLength = clock.lengthBeats(tick: smf.tick,
                                                        lengthTicks: smf.lengthTicks)
                if requestedLength < MIDINote.minLengthBeats {
                    // H6c. Two producers: a note-off at the note-on's own tick,
                    // and a dangling onset at/past end-of-track (k1 closes that
                    // one with length 0 and raises `danglingNoteOn`, so the two
                    // are distinguishable in `fileWarnings`).
                    stretchedNotes += 1
                    shortestRequested = min(shortestRequested ?? requestedLength, requestedLength)
                }
                // H5b: 0 and 64 are the two conventional "no information"
                // release velocities (0 is also what a `9n`-velocity-0 note-off
                // produces), so counting them would make the field noise on
                // every ordinary file.
                if smf.releaseVelocity != 0 && smf.releaseVelocity != 64 {
                    releaseVelocityDrops += 1
                }
                let startBeat = clock.beats(tick: smf.tick) + options.contentOffsetBeats
                notes.append(MIDINote(pitch: smf.note, velocity: smf.velocity,
                                      startBeat: startBeat, lengthBeats: requestedLength))
            }

            // Controller lanes (R4) + the H7 cap policy.
            let laneOutcome = buildControllerLanes(part.controllers, clock: clock,
                                                   offset: options.contentOffsetBeats)
            for (key, count) in laneOutcome.dropped { laneDrops[key, default: 0] += count }
            for (key, count) in laneOutcome.decimated { laneDecimations[key, default: 0] += count }

            // R6: `endTick` is authoritative for the part's length (it can sit
            // past the last note — trailing silence is meaningful — and never
            // before it), with the content end as a floor for the degenerate
            // case and 1 beat if even that is 0.
            let contentEnd = max(notes.map(\.endBeat).max() ?? 0,
                                 laneOutcome.lanes.flatMap(\.points).map(\.beat).max() ?? 0)
            var length = max(clock.beats(tick: part.endTick) + options.contentOffsetBeats,
                             contentEnd)
            if length <= 0 { length = 1 }

            if let clipLength = context.targetClipLengthBeats {
                // BOTH `>=`, not one of each. A clip spans the half-open beat
                // range [0, length): content sitting exactly ON the end is as
                // unreachable as content past it, and it is the same
                // unreachability for a note and for a controller point, so the
                // two legs must agree or the report contradicts itself at the
                // one beat where the answer is least obvious.
                notesPastEnd += notes.filter { $0.startBeat >= clipLength }.count
                pointsPastEnd += laneOutcome.lanes
                    .flatMap(\.points).filter { $0.beat >= clipLength }.count
            }

            let clip = Clip(name: part.name, startBeat: options.atBeat, lengthBeats: length,
                            notes: notes, controllerLanes: laneOutcome.lanes)
            var track = Track(name: part.name, kind: .instrument)
            // `kind: .instrument` is mandatory — MIDI clips live only on
            // instrument tracks. NOTE: this copies `importGeneration`'s
            // STRUCTURE but NOT its `isAIGenerated = true`: a MIDI file import
            // is not AI-generated, and "violet always means AI-generated" is a
            // design-language rule, so an imported file rendered violet would be
            // a lie about its provenance.
            if options.instruments == .gm {
                track.instrument = gmInstrument(channel: part.channel,
                                                program: part.programChange)
            }
            track.clips = [clip]

            totalNotes += notes.count
            totalPoints += laneOutcome.lanes.reduce(0) { $0 + $1.points.count }
            planned.append(MIDIImportPlan.PlannedTrack(partIndex: part.index,
                                                       track: track, clip: clip))
            reportParts.append(MIDIImportReport.Part(
                index: part.index, name: part.name,
                sourceTrackIndex: part.sourceTrackIndex, channel: part.channel,
                noteCount: notes.count,
                controllerLanes: laneOutcome.lanes.map(\.type.wireKey),
                programChange: part.programChange, programName: programName,
                imported: true, trackID: track.id, clipID: clip.id))
        }

        // ---- 6. The track-count guard (§3.4). A dry run still computes the
        //         full report, so the user can see exactly what they would get.
        guard planned.count <= maxImportedTracks || options.force else {
            throw MIDIImportError.tooManyTracks(count: planned.count, limit: maxImportedTracks)
        }

        // ---- 7. Resolve what is actually adopted (§2.5). `applyTempoMap`
        //         replaces wholesale and `meterMap: nil` leaves the meter alone,
        //         so a meter-only adoption carries the project's CURRENT tempo
        //         map through unchanged.
        var planTempo: TempoMap?
        var planMeter: MeterMap?
        if resolved == .adopt {
            switch (tempoBuild.map, meterBuild.map) {
            case (let t?, let m?):
                planTempo = t
                planMeter = m
            case (let t?, nil):
                planTempo = t
            case (nil, let m?):
                planTempo = context.currentTempoMap
                planMeter = m
            case (nil, nil):
                break
            }
            report.tempoSegmentsAdopted = tempoBuild.map?.segments.count ?? 0
            report.meterChangesAdopted = meterBuild.map?.changes.count ?? 0
            report.adoptedTempoBPM = tempoBuild.map?.segments.first?.bpm
        }

        // ---- 8. Fill in the report and roll the degradations up.
        report.parts = reportParts
        report.tracksCreated = planned.count
        report.notesImported = totalNotes
        report.controllerPointsImported = totalPoints
        report.notesWithDroppedReleaseVelocity = releaseVelocityDrops
        report.notesStretchedToMinimumLength = stretchedNotes
        report.shortestRequestedLengthBeats = shortestRequested
        report.droppedControllerLanes = laneDrops
        report.decimatedControllerLanes = laneDecimations
        report.droppedProgramChanges = droppedProgramChanges
        report.polyAftertouchEventsDropped = polyAftertouch
        report.notesPastClipEnd = notesPastEnd
        report.controllerPointsPastClipEnd = pointsPastEnd

        // Note what is deliberately NOT a degradation: a skipped conductor part
        // (it rides `parts[].skipReason`), and `fileCarriedNo…Map` (informational
        // facts about the file, §5). Both fire on a perfectly ordinary file, and
        // a report that says something about every file is noise nobody reads.
        if !report.clampedTempoEvents.isEmpty {
            degradations.append(
                "\(report.clampedTempoEvents.count) tempo change(s) asked for a speed outside "
                + "DAW Pro's \(Int(TransportState.tempoRange.lowerBound))–"
                + "\(Int(TransportState.tempoRange.upperBound)) BPM range and were clamped; the "
                + "notes are still on the beats the file gave them")
        }
        if !report.droppedMalformedTempoEvents.isEmpty {
            degradations.append(
                "\(report.droppedMalformedTempoEvents.count) tempo change(s) named an impossible "
                + "speed and were dropped")
        }
        if !report.droppedMeterChanges.isEmpty {
            degradations.append(
                "\(report.droppedMeterChanges.count) time-signature change(s) could not be "
                + "placed on DAW Pro's bar grid and were dropped; bar NUMBERING after them "
                + "differs from the file, but no note moved")
        }
        if !report.conflictingDuplicateTempoEvents.isEmpty {
            degradations.append(
                "\(report.conflictingDuplicateTempoEvents.count) place(s) in this file name two "
                + "different tempos at the same moment; the first one won")
        }
        if !report.conflictingDuplicateMeterEvents.isEmpty {
            degradations.append(
                "\(report.conflictingDuplicateMeterEvents.count) place(s) in this file name two "
                + "different time signatures at the same moment; the first one won")
        }
        if report.synthesizedLeadingTempo {
            degradations.append(
                "this file's first tempo change is not at its start, so the MIDI standard's "
                + "120 BPM default was used before it")
        }
        if report.synthesizedLeadingMeter {
            degradations.append(
                "this file's first time signature is not at its start, so the MIDI standard's "
                + "4/4 default was used before it")
        }
        if releaseVelocityDrops > 0 {
            degradations.append(
                "\(releaseVelocityDrops) note(s) carry a release velocity, which DAW Pro notes "
                + "do not store")
        }
        if stretchedNotes > 0 {
            let shortest = shortestRequested ?? 0
            degradations.append(String(
                format: "%d note(s) were shorter than DAW Pro's %g-beat minimum (the shortest "
                + "asked for %g beats) and were stretched to it",
                stretchedNotes, MIDINote.minLengthBeats, shortest))
        }
        if !laneDrops.isEmpty {
            let names = laneDrops.keys.sorted().joined(separator: ", ")
            degradations.append(
                "a clip holds at most \(ProjectStore.maxControllerLanesPerClip) controller "
                + "lanes, so these were dropped: \(names)")
        }
        if !laneDecimations.isEmpty {
            let names = laneDecimations.keys.sorted().joined(separator: ", ")
            degradations.append(
                "these controller lanes carried more than "
                + "\(ProjectStore.maxControllerPointsPerLane) points and were thinned: \(names)")
        }
        if droppedProgramChanges > 0 {
            degradations.append(
                "\(droppedProgramChanges) program change(s) beyond the first on a part were "
                + "dropped — a DAW Pro track holds one instrument for its whole length")
        }
        if polyAftertouch > 0 {
            degradations.append(
                "\(polyAftertouch) per-note aftertouch event(s) were dropped — DAW Pro v1 has no "
                + "per-note pressure lane")
        }
        if notesPastEnd > 0 || pointsPastEnd > 0 {
            degradations.append(
                "\(notesPastEnd) note(s) and \(pointsPastEnd) controller point(s) land past the "
                + "end of this clip; the clip was not resized — use clip.fitToContent to grow it")
        }
        report.degradations = degradations.materialized()

        return MIDIImportPlan(tracks: planned, tempoMap: planTempo,
                              meterMap: planMeter, report: report)
    }

    // MARK: - Parts (§3.1)

    /// One `(sourceTrackIndex, channel)` pair, with its events already carved
    /// out. Includes parts with no content at all — the index space is the FULL
    /// enumeration, so `parts: [0]` means the same thing in a dry run and a
    /// real one.
    struct Part {
        var index: Int
        var name: String
        var sourceTrackIndex: Int
        var channel: Int?
        var notes: [SMFNote]
        var controllers: [SMFControllerEvent]
        var endTick: Int
        var programChange: Int?
        var programName: String?
        var droppedProgramChangeCount: Int
        var polyAftertouchEventCount: Int
    }

    static func enumerateParts(_ file: StandardMIDIFile) -> [Part] {
        var parts: [Part] = []
        for source in file.tracks {
            let base = source.name ?? "MIDI Track \(source.sourceTrackIndex + 1)"
            if source.channels.isEmpty {
                // A chunk that speaks on no channel at all: the conductor track
                // in most format-1 files. Its tempo/meter payload was already
                // hoisted to file level by k1, so nothing is lost by skipping
                // it — but it still gets an entry, and every program change it
                // somehow carried is a drop.
                parts.append(Part(
                    index: parts.count, name: base,
                    sourceTrackIndex: source.sourceTrackIndex, channel: nil,
                    notes: [], controllers: [], endTick: source.endTick,
                    programChange: nil, programName: nil,
                    droppedProgramChangeCount: source.programChanges.count,
                    polyAftertouchEventCount: source.polyAftertouchEventCount))
                continue
            }
            let split = source.channels.count > 1
            // A poly-pressure count belongs to the whole chunk; hand it to the
            // FIRST split part so the file's total is reported exactly once.
            var pressureRemaining = source.polyAftertouchEventCount
            for channel in source.channels {
                let programs = source.programChanges.filter { $0.channel == channel }
                let program = programs.first?.program
                // Channel 10 (index 9) is GM percussion by convention, whatever
                // program it names.
                let isDrumChannel = channel == 9
                parts.append(Part(
                    index: parts.count,
                    // Channel shown 1-based (human convention); the stored value
                    // stays 0-based — the `GMProgramCatalog` R1 law.
                    name: split ? "\(base) (ch \(channel + 1))" : base,
                    sourceTrackIndex: source.sourceTrackIndex,
                    channel: channel,
                    notes: source.notes.filter { $0.channel == channel },
                    controllers: source.controllers.filter { $0.channel == channel },
                    endTick: source.endTick,
                    programChange: program,
                    programName: isDrumChannel
                        ? GMProgramCatalog.standardDrumKit.name
                        : program.map(GMProgramCatalog.name(forProgram:)),
                    droppedProgramChangeCount: max(0, programs.count - 1),
                    polyAftertouchEventCount: pressureRemaining))
                pressureRemaining = 0
            }
            // Program changes addressed to channels with no retained event have
            // no part to ride; they are drops, not phantom parts.
            let orphans = source.programChanges.filter { !source.channels.contains($0.channel) }
            if !orphans.isEmpty, let last = parts.indices.last {
                parts[last].droppedProgramChangeCount += orphans.count
            }
        }
        return parts
    }

    // MARK: - Tempo map (§2.3)

    struct TempoBuild {
        var map: TempoMap?
    }

    static func buildTempoMap(file: StandardMIDIFile, clock: SMFTickClock,
                              report: inout MIDIImportReport) -> TempoBuild {
        // A SMPTE file's tempo events do not govern its tick rate, so it has no
        // tempo map to hand over at all (§2.2). The events are still real, so
        // `fileCarriedNoTempoMap` reports the FILE's fact, not our verdict.
        report.fileCarriedNoTempoMap = file.tempoChanges.isEmpty
        guard !clock.isAbsoluteTime else { return TempoBuild(map: nil) }

        // Step 1/2: consume `file.tempoChanges` IN ARRIVAL ORDER. k1 already
        // returns it sorted by (tick, sourceTrackIndex) — and Swift's
        // `sorted(by:)` is NOT documented stable, so a "defensive" re-sort on
        // the same key would shuffle ties within one (tick, sourceTrackIndex)
        // and destroy the only tie-break H3 has left.
        var conflicts = CappedStrings()
        var winners: [SMFTempoEvent] = []
        for event in file.tempoChanges {
            guard let previous = winners.last, previous.tick == event.tick else {
                winners.append(event)
                continue
            }
            // Step 3 (H3): FIRST WINS. SMF 1.0 designates the first `MTrk` of a
            // format-1 file as the tempo-map track, so lowest `sourceTrackIndex`
            // is the SPEC's own tie-break. It is also what defeats the real
            // failure mode: exporters that stamp a default `FF 51 500000` into
            // EVERY chunk would, under last-wins, override a conductor track
            // that says 90 BPM. Identical duplicates are noise, not loss.
            if previous.microsecondsPerQuarterNote != event.microsecondsPerQuarterNote {
                conflicts.append(
                    "tick \(event.tick) (beat \(formatBeat(clock.beats(tick: event.tick)))): "
                    + "kept \(previous.microsecondsPerQuarterNote) µs per quarter note from "
                    + "track \(previous.sourceTrackIndex), discarded "
                    + "\(event.microsecondsPerQuarterNote) from track \(event.sourceTrackIndex)")
            }
        }
        report.conflictingDuplicateTempoEvents = conflicts.materialized()

        // Step 3.5: drop malformed events BEFORE any BPM is computed.
        // `FF 51 03 00 00 00` is a well-framed event k1 accepts, and
        // `60e6 / 0` is +infinity, which the Segment clamp silently turns into
        // 400 BPM — printing to the user as "requested BPM inf".
        var malformed = CappedStrings()
        var usable: [SMFTempoEvent] = []
        for event in winners {
            if event.microsecondsPerQuarterNote <= 0 {
                malformed.append(
                    "tick \(event.tick) (beat \(formatBeat(clock.beats(tick: event.tick)))): "
                    + "\(event.microsecondsPerQuarterNote) µs per quarter note is not a speed")
            } else {
                usable.append(event)
            }
        }
        report.droppedMalformedTempoEvents = malformed.materialized()

        // Step 4 (H4c): no events at all means the file has NO tempo map.
        // Synthesizing 120 BPM here and then "adopting" it would stomp a user's
        // 90 BPM project with a number the file never contained. Note the
        // fourth case is NOT this one: if every event was dropped as malformed,
        // the file DID assert a map — an unusable one — so
        // `fileCarriedNoTempoMap` stays false (set above from the raw array).
        guard !usable.isEmpty else { return TempoBuild(map: nil) }

        // Step 5 (H4b): complete a map the file STARTED. Here — and only here —
        // the spec default is legitimate: the user asked to adopt a map, and
        // 120-before-the-first-event is that map's spec-defined content.
        var events = usable
        if events[0].tick != 0 {
            events.insert(SMFTempoEvent(tick: 0,
                                        microsecondsPerQuarterNote: defaultMicrosecondsPerQuarter,
                                        sourceTrackIndex: events[0].sourceTrackIndex),
                          at: 0)
            report.synthesizedLeadingTempo = true
        }

        // Step 6 (D2 + H1). µs/quarter → BPM is the AUTHORITATIVE direction on
        // import: a single IEEE-754 division, no rounding and no snapping to
        // "nice" values, because that is what makes k4's export
        // (`round(60e6/bpm)`) exact. Measured: the round trip has ZERO failures
        // over all 2,850,001 µs values the 20…400 clamp permits, and the µ that
        // do NOT round-trip are exactly the set H1 reports.
        var clamped = CappedStrings()
        var segments: [TempoMap.Segment] = []
        segments.reserveCapacity(events.count)
        for event in events {
            let beat = clock.beats(tick: event.tick)                          // R7
            let bpm = 60_000_000.0 / Double(event.microsecondsPerQuarterNote) // D2
            if !TransportState.tempoRange.contains(bpm) {
                let effective = bpm.clamped(to: TransportState.tempoRange)
                clamped.append(String(
                    format: "tick %d (beat %@): asks for %g BPM, played at %g BPM",
                    event.tick, formatBeat(beat), bpm, effective))
            }
            segments.append(TempoMap.Segment(startBeat: beat, bpm: bpm))
        }
        report.clampedTempoEvents = clamped.materialized()

        // Step 7. This cannot throw — the dedupe guarantees strictly increasing
        // ticks, `beats` is strictly monotone in tick, step 5 guarantees the
        // first is at beat 0, and the array is non-empty. A `try!` here would
        // still be a crash on a user's file if any of that ever changed, so the
        // failure is surfaced as an empty map plus a report line instead.
        guard let map = try? TempoMap(segments: segments) else {
            report.droppedMalformedTempoEvents.append(
                "the file's tempo map could not be built and was left alone")
            return TempoBuild(map: nil)
        }
        return TempoBuild(map: map)
    }

    // MARK: - Meter map (§2.4)

    struct MeterBuild {
        var map: MeterMap?
    }

    static func buildMeterMap(file: StandardMIDIFile, clock: SMFTickClock,
                              report: inout MIDIImportReport) throws -> MeterBuild {
        report.fileCarriedNoMeterMap = file.timeSignatures.isEmpty

        // Steps 1/2: arrival order, first wins, NO re-sort (as for tempo).
        var conflicts = CappedStrings()
        var winners: [SMFTimeSignatureEvent] = []
        for event in file.timeSignatures {
            guard let previous = winners.last, previous.tick == event.tick else {
                winners.append(event)
                continue
            }
            if previous.numerator != event.numerator
                || previous.denominatorPower != event.denominatorPower {
                conflicts.append(
                    "tick \(event.tick) (beat \(formatBeat(clock.beats(tick: event.tick)))): "
                    + "kept \(meterText(previous)) from track \(previous.sourceTrackIndex), "
                    + "discarded \(meterText(event)) from track \(event.sourceTrackIndex)")
            }
        }
        report.conflictingDuplicateMeterEvents = conflicts.materialized()

        // Step 3: drop malformed. `dd = 255` would be 2^255 (unrepresentable),
        // and `Change.init`'s `max(1, …)` would silently turn `0/4` into `1/4` —
        // so both are dropped BEFORE any Change is constructed, not after.
        var dropped = CappedStrings()
        var usable: [SMFTimeSignatureEvent] = []
        for event in winners {
            if event.denominator == nil {
                dropped.append(
                    "tick \(event.tick): a denominator of 2^\(event.denominatorPower) is not a "
                    + "time signature any program can show")
            } else if event.numerator <= 0 {
                dropped.append(
                    "tick \(event.tick): \(event.numerator) beats per bar is not a time signature")
            } else {
                usable.append(event)
            }
        }

        // Step 4 (H4c): absence, not a default — the same trap as tempo, and
        // the worse one. Synthesizing 4/4 for a file with no `FF 58` and then
        // adopting it stomps a user's 3/4 project with a meter their file never
        // contained.
        guard !usable.isEmpty else {
            report.droppedMeterChanges = dropped.materialized()
            return MeterBuild(map: nil)
        }

        // Step 5 (H4b).
        var events = usable
        if events[0].tick != 0 {
            events.insert(SMFTimeSignatureEvent(
                tick: 0, numerator: defaultMeter.numerator,
                denominatorPower: defaultMeter.denominatorPower,
                clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                sourceTrackIndex: events[0].sourceTrackIndex), at: 0)
            report.synthesizedLeadingMeter = true
        }

        // Step 6. `beatsPerBar = numerator`, `beatUnit = denominator`, VERBATIM
        // (§1.3): the pair IS the time signature as written — it is what the
        // tempo lane's `meterEdited` and the wire's `parseMeterMap` produce, and
        // `Commands.swift` formats it back to the AI as "N/D". A translating
        // importer would put two incompatible encodings of one meter into the
        // model, and k4's export of a hand-entered 6/8 would emit numerator 12.
        var accepted: [MeterMap.Change] = []
        var map: MeterMap
        do {
            let first = events[0]
            accepted = [MeterMap.Change(startBeat: clock.beats(tick: first.tick),
                                        beatsPerBar: first.numerator,
                                        beatUnit: first.denominator ?? 4)]
            map = try MeterMap(changes: accepted)
        } catch {
            // The first change is at beat 0 with a positive numerator, so this
            // is unreachable — surfaced rather than `try!`-crashed.
            throw MIDIImportError.internalInconsistency("time-signature map")
        }
        var previous = events[0]
        for event in events.dropFirst() {
            let candidate = MeterMap.Change(startBeat: clock.beats(tick: event.tick), // R8
                                            beatsPerBar: event.numerator,
                                            beatUnit: event.denominator ?? 4)
            // The accept test is `MeterMap.init` ITSELF, never a re-implemented
            // barline formula: `MeterMap.barlineEpsilon` is private, so copying
            // it would mint a second home for a constant that can then drift.
            // Growing the map through its own throwing initializer makes this
            // test identical to the model's validation BY CONSTRUCTION — and the
            // last successful call has already built exactly the array returned
            // below, so there is no second construction and no `try!` left.
            if let grown = try? MeterMap(changes: accepted + [candidate]) {
                map = grown
                accepted.append(candidate)
                previous = event
            } else {
                dropped.append(dropReason(event: event, previous: previous,
                                          candidate: candidate, clock: clock))
            }
        }
        report.droppedMeterChanges = dropped.materialized()
        return MeterBuild(map: map)
    }

    /// FP tolerance used ONLY to choose which sentence a dropped meter change
    /// gets. It is NOT an accept test — `MeterMap.init` has already refused the
    /// change by the time this runs — so it cannot drift away from the model's
    /// own rule, because it never decides anything the model decides.
    private static let barlineDiagnosticEpsilon = 1e-9

    /// Names WHY a meter change was dropped, distinguishing the plain
    /// off-barline case from the v1-meter-model consequence — they mean very
    /// different things to a user, and the second must not read as a parse
    /// failure.
    private static func dropReason(event: SMFTimeSignatureEvent,
                                   previous: SMFTimeSignatureEvent,
                                   candidate: MeterMap.Change,
                                   clock: SMFTickClock) -> String {
        let previousBeat = clock.beats(tick: previous.tick)
        let span = candidate.startBeat - previousBeat
        let previousDenominator = previous.denominator ?? 4
        // The bar length the FILE means, in quarter notes: 6/8 is 3 quarter
        // notes, not 6.
        let trueBarQuarters = Double(previous.numerator) * 4.0 / Double(previousDenominator)
        let barsInFile = trueBarQuarters > 0 ? span / trueBarQuarters : .nan
        let onFileBarline = barsInFile.isFinite
            && abs(barsInFile - barsInFile.rounded()) <= barlineDiagnosticEpsilon
        if onFileBarline && previousDenominator != 4 {
            // §1.3-3 — the change IS on the file's own barline, and is off ours
            // only because `MeterMap.beatsPerBar` is the NUMERATOR while the bar
            // grid divides by it, so a non-4 denominator gives DAW Pro v1 a bar
            // of the wrong length. Named as the model limitation it is (see
            // docs/ARCHITECTURE.md §8), not as a problem with their file.
            return "tick \(event.tick) (beat \(formatBeat(candidate.startBeat))): "
                + "this file's \(meterText(previous)) bars are "
                + "\(formatBeat(trueBarQuarters)) quarter notes long, but DAW Pro v1 counts a "
                + "\(meterText(previous)) bar as \(previous.numerator) quarter notes, so the "
                + "change to \(meterText(event)) does not land on a barline of that grid and "
                + "was dropped"
        }
        return "tick \(event.tick) (beat \(formatBeat(candidate.startBeat))): the change to "
            + "\(meterText(event)) falls mid-bar (\(formatBeat(span)) beats after the "
            + "\(meterText(previous)) at beat \(formatBeat(previousBeat))), and DAW Pro's bar "
            + "grid only changes on a barline, so it was dropped"
    }

    private static func meterText(_ event: SMFTimeSignatureEvent) -> String {
        "\(event.numerator)/\(event.denominator.map(String.init) ?? "2^\(event.denominatorPower)")"
    }

    // MARK: - Controller lanes (R4 + H7)

    struct LaneOutcome {
        var lanes: [MIDIControllerLane]
        /// wireKey → canonical points dropped with the lane.
        var dropped: [String: Int]
        /// wireKey → points kept after decimation.
        var decimated: [String: Int]
    }

    static func buildControllerLanes(_ events: [SMFControllerEvent],
                                     clock: SMFTickClock,
                                     offset: Double) -> LaneOutcome {
        guard !events.isEmpty else { return LaneOutcome(lanes: [], dropped: [:], decimated: [:]) }
        var grouped: [MIDIControllerType: [MIDIControllerPoint]] = [:]
        for event in events {
            grouped[event.type, default: []].append(
                MIDIControllerPoint(beat: clock.beats(tick: event.tick) + offset,  // R4
                                    value: event.value))
        }
        // CANONICALIZE FIRST, then measure. `MIDIControllerLane.init`
        // canonicalizes on construction (equal-beat last-wins dedupe), so a raw
        // stream of 20,000 CC events that dedupes to 9,000 distinct beats needs
        // NO decimation at all — decimating the raw stream would discard data
        // the cap never objected to, and would make the post-condition
        // approximate instead of exact.
        var canonical = grouped.map { MIDIControllerLane(type: $0.key, points: $0.value) }

        // Lane ranking (H7): the fixed engine-aware priority head first, then
        // whatever is left by density.
        let priorityIndex = Dictionary(uniqueKeysWithValues:
            controllerPriority.enumerated().map { ($0.element, $0.offset) })
        canonical.sort { lhs, rhs in
            switch (priorityIndex[lhs.type], priorityIndex[rhs.type]) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                if lhs.points.count != rhs.points.count {
                    return lhs.points.count > rhs.points.count
                }
                return lhs.type.sortKey < rhs.type.sortKey
            }
        }

        var dropped: [String: Int] = [:]
        if canonical.count > ProjectStore.maxControllerLanesPerClip {
            for lane in canonical.dropFirst(ProjectStore.maxControllerLanesPerClip) {
                dropped[lane.type.wireKey] = lane.points.count
            }
            canonical = Array(canonical.prefix(ProjectStore.maxControllerLanesPerClip))
        }

        // Point decimation. Re-canonicalizing a decimated set is idempotent
        // (the beats stay distinct and ascending), so `points.count <= cap`
        // holds EXACTLY. This matters more than it looks: the mapper is the ONLY
        // enforcement of these caps in the program — they live in
        // `ProjectStore.setControllerLane`, which an import that builds `Clip`
        // values offline never touches.
        var decimated: [String: Int] = [:]
        let cap = ProjectStore.maxControllerPointsPerLane
        for index in canonical.indices where canonical[index].points.count > cap {
            let lane = canonical[index]
            let thinned = decimate(lane.points, cap: cap)
            canonical[index] = MIDIControllerLane(type: lane.type, points: thinned)
            decimated[lane.type.wireKey] = canonical[index].points.count
        }
        // Store in the model's canonical lane order.
        canonical = Clip.canonicalControllerLanes(canonical)
        return LaneOutcome(lanes: canonical, dropped: dropped, decimated: decimated)
    }

    /// Keeps every `ceil(n/cap)`-th point, ALWAYS including the first and the
    /// last. Lanes are stepwise, so decimation coarsens a ramp; truncating the
    /// tail instead would leave a stuck value that never resolves.
    ///
    /// POST-CONDITION, and it is the whole point of this function: for `cap >= 2`
    /// the result is NEVER longer than `cap`. (Below that the guard returns the
    /// input untouched — there is no meaningful thinning to a budget of one that
    /// still keeps both endpoints, and no caller asks for it; the real call site
    /// passes 16384.) The stride keeps `ceil(n/stride) <= cap`, so the
    /// grid alone is always in budget — but "always keep the last point" needs a
    /// slot, and when `n` is an exact multiple of `cap` the grid has already used
    /// every one. At `n = 32768, cap = 16384` the stride is 2, the grid keeps
    /// exactly 16384, and the file's last point sits at odd offset 32767: a plain
    /// append returns 16385 and silently breaks the cap. So when the grid is
    /// full the last point REPLACES the final grid point instead of extending
    /// past it — one interior point is coarsened, the endpoint is preserved, and
    /// the budget holds. This is the only enforcement of the cap on the import
    /// path (`ProjectStore.setControllerLane` is never called for offline-built
    /// `Clip` values), so an off-by-one here reaches the model unchallenged.
    static func decimate(_ points: [MIDIControllerPoint],
                         cap: Int) -> [MIDIControllerPoint] {
        guard points.count > cap, cap > 1 else { return points }
        let stride = Int((Double(points.count) / Double(cap)).rounded(.up))
        var kept = points.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        if let last = points.last, kept.last?.beat != last.beat {
            if kept.count >= cap {
                kept[kept.count - 1] = last
            } else {
                kept.append(last)
            }
        }
        return kept
    }

    // MARK: - Instruments (D3)

    /// The GM descriptor a part asks for. Channel 10 (index 9) is the GM
    /// percussion channel by convention and maps to the standard drum kit
    /// REGARDLESS of any program change it carries.
    static func gmInstrument(channel: Int?, program: Int?) -> InstrumentDescriptor {
        if channel == 9 {
            let kit = GMProgramCatalog.standardDrumKit
            return InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .generalMIDI, program: kit.program,
                                           bankMSB: kit.bankMSB, bankLSB: kit.bankLSB,
                                           displayName: kit.name))
        }
        let resolved = program ?? 0
        return InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: resolved,
                                       bankMSB: GMProgramCatalog.melodicBankMSB,
                                       bankLSB: GMProgramCatalog.bankLSB,
                                       displayName: GMProgramCatalog.name(forProgram: resolved)))
    }
}

// MARK: - Capped string lists

/// A `[String]` report list that stops growing at
/// `MIDIImportReport.maxReportedEntries` and folds the rest into a trailing
/// "… and N more". Bounded at APPEND time, not at materialization, so a
/// pathological file never allocates the huge array at all.
fileprivate struct CappedStrings {
    private var entries: [String] = []
    private var overflow = 0

    mutating func append(_ entry: String) {
        if entries.count < MIDIImportReport.maxReportedEntries {
            entries.append(entry)
        } else {
            overflow += 1
        }
    }

    func materialized() -> [String] {
        overflow == 0 ? entries : entries + ["… and \(overflow) more"]
    }
}
