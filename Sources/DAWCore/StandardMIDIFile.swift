import Foundation

// Standard MIDI File (SMF 1.0) intermediate representation — m23-k1.
//
// TICK-NATIVE BY CONSTRUCTION, and that is the entire point of this type. SMF
// measures time in ticks against the file's own `division`; `MIDINote` measures
// it in beats relative to a clip. If this IR stored beats it would already have
// made the tempo-map mapping decision that m23-k3 exists to make (with a
// `daw-architect` read first), and k3 could then never be gated independently
// of the parser. So: ticks and the division, verbatim. No beats, no tempo
// applied, no project types touched. This is the `SoundFontPresetReader`
// posture — "stays a faithful readout of the bytes".
//
// LAW L9: DAWCore never imports AudioToolbox or CoreMIDI. The bytes are parsed
// with pure Foundation `Data` (see `StandardMIDIFileReader`). Apple's loader is
// used only OUTSIDE the build, to validate the checked-in test fixtures.
//
// "SMF" is the specification's own abbreviation, used here as the member prefix
// so nothing shadows DAWCore's project-level `Track` / `MIDINote`.

/// The `MThd` format word. The three formats differ in STRUCTURE, not just in
/// this header field, which is why the decoder branches on it:
/// - `.singleTrack` (0) carries every channel in ONE `MTrk`, so the decoder must
///   split it by channel to recover the parts.
/// - `.simultaneousTracks` (1) is one part per `MTrk`, played together, with the
///   tempo map by convention in the first chunk.
/// - `.independentSequences` (2) is a bag of unrelated sequences. Parsed
///   structurally like format 1 and recorded verbatim; whether the tracks are
///   simultaneous or independent is a mapping question, so it belongs to k3.
public enum SMFFormat: Int, Sendable, Equatable, Hashable {
    case singleTrack = 0
    case simultaneousTracks = 1
    case independentSequences = 2
}

/// The `MThd` division word, recorded verbatim in whichever of its two mutually
/// exclusive meanings the file declared.
public enum SMFDivision: Sendable, Equatable, Hashable {
    /// Metrical time (division bit 15 CLEAR): ticks per quarter note. A tick's
    /// wall-clock duration depends on the tempo map, which is exactly why
    /// converting to beats/seconds is k3's business and not this file's.
    case ticksPerQuarterNote(Int)

    /// SMPTE time-code time (division bit 15 SET): the high byte is a NEGATIVE
    /// frames-per-second count (−24/−25/−29/−30, two's complement) and the low
    /// byte is ticks per frame. This is ABSOLUTE time — 25 fps × 40 ticks/frame
    /// is 1000 ticks per second no matter what any set-tempo event says.
    ///
    /// Recorded verbatim rather than folded into a tpqn number because the two
    /// are not interchangeable: `0xE728` read as an unsigned tpqn is 59176,
    /// which would place every note about 123× too early. (Apple's own loader
    /// accepts such a file but reads it degenerately — its beat-native model
    /// cannot represent absolute time. That degeneracy is itself the argument
    /// for this IR being tick-native.)
    case smpte(framesPerSecond: Int, ticksPerFrame: Int)
}

/// One note, recovered by pairing a note-on with its note-off. Times are ticks
/// on the file's own clock; `lengthTicks` is the difference between the two,
/// so a note-on and note-off at the same tick legitimately yields length 0
/// (kept verbatim rather than nudged to a minimum — nudging is a musical
/// decision, and this layer makes none).
public struct SMFNote: Sendable, Equatable, Hashable {
    /// Absolute tick of the note-on.
    public let tick: Int
    /// Ticks from note-on to note-off. Never negative.
    public let lengthTicks: Int
    /// MIDI note number, 0...127.
    public let note: Int
    /// Note-on velocity, 1...127. Zero is impossible by construction: a note-on
    /// with velocity 0 IS a note-off (see `StandardMIDIFileReader`).
    public let velocity: Int
    /// Note-off velocity, 0...127. Zero both for a real `8n` release of zero and
    /// for the velocity-0 `9n` spelling — the two are indistinguishable in the
    /// recovered note, and nothing downstream can tell them apart either.
    public let releaseVelocity: Int
    /// MIDI channel, 0...15 (wire value, not the 1-16 humans see).
    public let channel: Int

    public init(tick: Int, lengthTicks: Int, note: Int,
                velocity: Int, releaseVelocity: Int, channel: Int) {
        self.tick = tick
        self.lengthTicks = lengthTicks
        self.note = note
        self.velocity = velocity
        self.releaseVelocity = releaseVelocity
        self.channel = channel
    }
}

/// One point on a controller stream. Reuses `MIDIControllerType` — the project
/// model's own controller vocabulary — because that enum is beat-free: it names
/// WHICH stream, never WHEN. Pairing it with a tick here keeps the IR
/// tick-native while sparing k3 a second controller taxonomy to translate.
public struct SMFControllerEvent: Sendable, Equatable, Hashable {
    /// Absolute tick.
    public let tick: Int
    /// MIDI channel, 0...15.
    public let channel: Int
    public let type: MIDIControllerType
    /// Raw MIDI value, in `type.valueRange` (0...127, or 0...16383 for bend).
    public let value: Int

    public init(tick: Int, channel: Int, type: MIDIControllerType, value: Int) {
        self.tick = tick
        self.channel = channel
        self.type = type
        self.value = value
    }
}

/// An `FF 51 03` set-tempo event, in the spec's own units.
///
/// Microseconds per quarter note is stored VERBATIM. BPM is a derived, lossy
/// reading of it (500000 µs/qn is exactly 120 BPM, but 666666 µs/qn is
/// 90.000090… BPM), and choosing how to round it is part of the tempo-map
/// mapping that k3 owns. `sourceTrackIndex` records which `MTrk` carried the
/// event, so hoisting it to file level below loses nothing.
public struct SMFTempoEvent: Sendable, Equatable, Hashable {
    public let tick: Int
    public let microsecondsPerQuarterNote: Int
    public let sourceTrackIndex: Int

    public init(tick: Int, microsecondsPerQuarterNote: Int, sourceTrackIndex: Int) {
        self.tick = tick
        self.microsecondsPerQuarterNote = microsecondsPerQuarterNote
        self.sourceTrackIndex = sourceTrackIndex
    }
}

/// An `FF 58 04` time-signature event.
///
/// The denominator is stored as the spec's raw NEGATIVE POWER OF TWO byte
/// (`dd`, where the denominator is 2^dd) rather than pre-expanded, because the
/// byte can name denominators no `Int` can hold: `dd = 255` would be 2^255.
/// `denominator` expands it and returns nil past the representable range, so a
/// hostile byte can't trap.
public struct SMFTimeSignatureEvent: Sendable, Equatable, Hashable {
    public let tick: Int
    /// The `nn` byte — beats per bar.
    public let numerator: Int
    /// The raw `dd` byte: the denominator is 2^dd (2 ⇒ 4, 3 ⇒ 8…).
    public let denominatorPower: Int
    /// The `cc` byte — MIDI clocks per metronome click.
    public let clocksPerMetronomeClick: Int
    /// The `bb` byte — 32nd notes per MIDI quarter note (normally 8).
    public let thirtySecondNotesPerQuarter: Int
    public let sourceTrackIndex: Int

    /// 2^`denominatorPower`, or nil when the power exceeds what an `Int` holds.
    public var denominator: Int? {
        guard denominatorPower >= 0, denominatorPower < Int.bitWidth - 1 else { return nil }
        return 1 << denominatorPower
    }

    public init(tick: Int, numerator: Int, denominatorPower: Int,
                clocksPerMetronomeClick: Int, thirtySecondNotesPerQuarter: Int,
                sourceTrackIndex: Int) {
        self.tick = tick
        self.numerator = numerator
        self.denominatorPower = denominatorPower
        self.clocksPerMetronomeClick = clocksPerMetronomeClick
        self.thirtySecondNotesPerQuarter = thirtySecondNotesPerQuarter
        self.sourceTrackIndex = sourceTrackIndex
    }
}

/// A `Cn` program-change event, recorded verbatim (m23-k3 Step 0).
///
/// k1 framed this message and discarded its payload, on the grounds that
/// "instrument selection is a mapping decision, so if k3 wants it, it is k3
/// that should say what it means". k3 says: a part's FIRST program change on
/// its channel is the instrument the file asks for, reported always and applied
/// only under `instruments: "gm"` (design §1.2 D3). Capturing the byte here is
/// purely additive — nothing in the IR's shape or equality changes for a file
/// that carries no `Cn`.
public struct SMFProgramChangeEvent: Sendable, Equatable, Hashable {
    /// Absolute tick.
    public let tick: Int
    /// MIDI channel, 0...15 (wire value, not the 1-16 humans see).
    public let channel: Int
    /// Program number, 0-BASED 0...127 — the raw MIDI byte (R1). Human GM
    /// charts are 1-based; this field is not.
    public let program: Int

    public init(tick: Int, channel: Int, program: Int) {
        self.tick = tick
        self.channel = channel
        self.program = program
    }
}

/// One recovered part. For format 1/2 this is one `MTrk`; for format 0 it is one
/// CHANNEL carved out of the single `MTrk` (see `StandardMIDIFileReader`).
public struct SMFTrack: Sendable, Equatable {
    /// The `FF 03` track-name meta event, if the file carried one.
    public let name: String?
    /// The `MTrk` index this part came from. Several format-0 parts share
    /// index 0 — that is how a caller can tell a split apart from real chunks.
    public let sourceTrackIndex: Int
    /// Distinct MIDI channels appearing in this part's events, ascending. Empty
    /// for a tempo-map-only track (Apple's format-1 output has exactly one).
    public let channels: [Int]
    /// Notes, ordered by (tick, channel, note). Note-off ORDER decides pairing
    /// but must not decide output order, or a re-struck chord would come back
    /// shuffled; sorting here makes the readout deterministic.
    public let notes: [SMFNote]
    /// Controller events in stream order, which is already tick-ascending.
    public let controllers: [SMFControllerEvent]
    /// Absolute tick of the `FF 2F 00` end-of-track marker. The authoritative
    /// length of the part — it can sit past the last note (trailing silence is
    /// meaningful) and never before it.
    public let endTick: Int
    /// Program-change events in stream order (m23-k3 Step 0). ADDITIVE: defaults
    /// to `[]`, so every pre-k3 construction site — and every equality
    /// comparison against one — is unchanged.
    ///
    /// A program change NEVER inserts its channel into `channels` (k1's rule for
    /// poly pressure, applied verbatim: it must not "conjure an empty part out
    /// of a format-0 split"). One consequence, stated rather than discovered: in
    /// a FORMAT 0 file, a program change addressed to a channel that carries no
    /// note/CC/bend/pressure event has no part to ride and is therefore absent
    /// from this IR entirely. It selects a sound for a channel that never
    /// sounds, so nothing is lost musically — but a future consumer must not
    /// read `programChanges` as "every `Cn` in the file".
    public let programChanges: [SMFProgramChangeEvent]
    /// How many `An` polyphonic-key-pressure events this part carried (m23-k3
    /// Step 0). ADDITIVE, defaults to 0.
    ///
    /// A COUNT, not the events: per-note aftertouch is a different model shape,
    /// deferred past v1 (`MIDIControllerType`'s own line), so there is nowhere
    /// for the values to go. The count exists only so the loss can be REPORTED
    /// instead of silent. It is unrecoverable by construction — a k4 export
    /// cannot reconstruct these events and owes the user nothing beyond saying
    /// so. For a format-0 split each part carries only ITS OWN channel's count,
    /// so summing the parts reproduces the file's total exactly once.
    public let polyAftertouchEventCount: Int

    /// The one channel this part speaks on, or nil if it is silent (tempo-only)
    /// or speaks on several. Derived from `channels` so there is ONE home for
    /// "which channel is this" and no way for the two to disagree.
    public var channel: Int? {
        channels.count == 1 ? channels[0] : nil
    }

    public init(name: String?, sourceTrackIndex: Int, channels: [Int],
                notes: [SMFNote], controllers: [SMFControllerEvent], endTick: Int,
                programChanges: [SMFProgramChangeEvent] = [],
                polyAftertouchEventCount: Int = 0) {
        self.name = name
        self.sourceTrackIndex = sourceTrackIndex
        self.channels = channels
        self.notes = notes
        self.controllers = controllers
        self.endTick = endTick
        self.programChanges = programChanges
        self.polyAftertouchEventCount = polyAftertouchEventCount
    }
}

/// Something recoverable the decoder had to decide for itself. Warnings never
/// fail a parse; they exist so k3 (and eventually the user) can be told that a
/// file was odd, instead of the oddity being swallowed silently.
public enum SMFWarning: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// A note-on was still sounding when the track ended. Closed at `endTick` —
    /// see `StandardMIDIFileReader`'s AMBIGUITY 2 for why closing beats dropping.
    case danglingNoteOn(trackIndex: Int, channel: Int, note: Int, tick: Int)
    /// A note-off arrived for a pitch that was not sounding. Discarded.
    case unmatchedNoteOff(trackIndex: Int, channel: Int, note: Int, tick: Int)
    /// The header's track count disagreed with the number of `MTrk` chunks
    /// actually present. The chunks win — they are the data.
    case trackCountMismatch(declared: Int, found: Int)
    /// Bytes after the last complete chunk, too few to be a chunk header.
    case trailingBytes(count: Int)

    public var description: String {
        switch self {
        case .danglingNoteOn(let track, let channel, let note, let tick):
            return "Track \(track): note \(note) on channel \(channel + 1) starts at tick "
                + "\(tick) but is never released; it was closed at the end of the track."
        case .unmatchedNoteOff(let track, let channel, let note, let tick):
            return "Track \(track): a note-off for note \(note) on channel \(channel + 1) "
                + "at tick \(tick) had no matching note-on, so it was ignored."
        case .trackCountMismatch(let declared, let found):
            return "The file header declares \(declared) track(s) but contains \(found); "
                + "the \(found) track(s) actually present were used."
        case .trailingBytes(let count):
            return "\(count) leftover byte(s) after the last complete chunk were ignored."
        }
    }
}

/// A refusal to parse, phrased so the message can be shown to a person.
///
/// Every case names WHAT was wrong and WHERE, because the alternative — a
/// plausible-looking empty parse — reads to a user as "this file has no notes",
/// which is a lie about their file and sends them looking in the wrong place.
public enum SMFDecodeError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The file has no bytes at all.
    case emptyFile
    /// `MThd` was found but the 14-byte header could not be completed.
    case truncatedHeader(availableBytes: Int)
    /// The file does not begin with `MThd`. Distinct from `truncatedHeader`
    /// because it means "not a MIDI file" rather than "a damaged MIDI file" —
    /// the same distinction Apple's loader draws with a separate status code.
    case missingHeaderChunk(foundTag: String)
    /// The header's format word is not 0, 1 or 2.
    case unsupportedFormat(Int)
    /// A division of zero ticks per quarter note — no time base exists.
    case invalidDivision(raw: Int)
    /// A chunk's declared length runs past the end of the file.
    case truncatedChunk(tag: String, declaredLength: Int, availableBytes: Int)
    /// An event's data bytes run past the end of its `MTrk`.
    case truncatedEvent(trackIndex: Int, byteOffsetInTrack: Int)
    /// A data byte appeared where a status byte was required and no running
    /// status was in effect (the very first event of a track, or after a
    /// SysEx/meta event cleared it).
    case runningStatusWithoutPrecedingStatus(trackIndex: Int, byteOffsetInTrack: Int)
    /// A system status byte (`F1`–`FE`, other than `F7`) that has no meaning
    /// inside an `MTrk`.
    case unexpectedStatusByte(UInt8, trackIndex: Int, byteOffsetInTrack: Int)
    /// A variable-length quantity ran past 4 bytes, which the spec forbids.
    case malformedVariableLengthQuantity(trackIndex: Int, byteOffsetInTrack: Int)
    /// The `MTrk` ended without an `FF 2F 00` marker. See DECISION 3 in
    /// `StandardMIDIFileReader` for why this is a refusal and not a warning.
    case missingEndOfTrack(trackIndex: Int)
    /// A well-formed header with no `MTrk` chunks behind it.
    case noTrackChunks

    public var description: String {
        switch self {
        case .emptyFile:
            return "This file is empty — there are no bytes to read. "
                + "A MIDI file is at least 14 bytes long."
        case .truncatedHeader(let available):
            return "This MIDI file's header is incomplete: it stops after \(available) byte(s), "
                + "and a MIDI header needs 14. The file was probably cut short in transfer."
        case .missingHeaderChunk(let tag):
            return "This is not a MIDI file: it begins with \"\(tag)\" where every MIDI file "
                + "begins with \"MThd\"."
        case .unsupportedFormat(let format):
            return "This MIDI file declares format \(format). Only formats 0, 1 and 2 exist "
                + "in the Standard MIDI File specification."
        case .invalidDivision(let raw):
            return "This MIDI file declares a time division of \(raw), which gives it no time "
                + "base at all. The file is corrupt."
        case .truncatedChunk(let tag, let declared, let available):
            return "The \"\(tag)\" section of this MIDI file says it is \(declared) bytes long, "
                + "but only \(available) byte(s) remain. The file was cut short."
        case .truncatedEvent(let track, let offset):
            return "Track \(track) of this MIDI file ends in the middle of an event "
                + "(\(offset) bytes in). The file was cut short."
        case .runningStatusWithoutPrecedingStatus(let track, let offset):
            return "Track \(track) of this MIDI file has an event at byte \(offset) that omits "
                + "its type, with no earlier event to inherit it from. The file is corrupt."
        case .unexpectedStatusByte(let byte, let track, let offset):
            return String(format: "Track %d of this MIDI file contains a 0x%02X message at "
                          + "byte %d, which is not valid inside a MIDI file.",
                          track, Int(byte), offset)
        case .malformedVariableLengthQuantity(let track, let offset):
            return "Track \(track) of this MIDI file has a timing value at byte \(offset) longer "
                + "than the 4 bytes the format allows. The file is corrupt."
        case .missingEndOfTrack(let track):
            return "Track \(track) of this MIDI file is missing its end-of-track marker, so "
                + "there is no way to know whether the track is complete."
        case .noTrackChunks:
            return "This MIDI file has a valid header but contains no tracks, so there is "
                + "nothing to import."
        }
    }

    /// Same string as `description`, so the message a user sees never depends on
    /// which of the two a caller happened to reach for.
    public var errorDescription: String? { description }
}

/// A parsed Standard MIDI File: the bytes, read faithfully, still in ticks.
public struct StandardMIDIFile: Sendable, Equatable {
    public let format: SMFFormat
    public let division: SMFDivision
    /// Recovered parts. For format 0 these are the channel splits of the single
    /// `MTrk`; for format 1/2, one per chunk (including tempo-only ones, which
    /// are kept rather than filtered — filtering is a mapping choice, so it is
    /// k3's to make).
    public let tracks: [SMFTrack]
    /// Every set-tempo event in the file, ascending by tick.
    ///
    /// Hoisted to FILE level because tempo is global in SMF: format 1 puts the
    /// tempo map in the first chunk by spec and format 0 has only one chunk, so
    /// "which of the channel-split parts owns the tempo?" is a question with no
    /// honest per-track answer. Each event keeps its `sourceTrackIndex`, so the
    /// hoist discards nothing.
    public let tempoChanges: [SMFTempoEvent]
    /// Every time-signature event in the file, ascending by tick. Hoisted for
    /// the same reason as `tempoChanges`.
    public let timeSignatures: [SMFTimeSignatureEvent]
    /// Recoverable oddities, in the order they were noticed.
    public let warnings: [SMFWarning]

    public init(format: SMFFormat, division: SMFDivision, tracks: [SMFTrack],
                tempoChanges: [SMFTempoEvent], timeSignatures: [SMFTimeSignatureEvent],
                warnings: [SMFWarning]) {
        self.format = format
        self.division = division
        self.tracks = tracks
        self.tempoChanges = tempoChanges
        self.timeSignatures = timeSignatures
        self.warnings = warnings
    }
}
