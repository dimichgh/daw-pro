import Foundation

// Standard MIDI File (SMF 1.0) encoder — m23-k2. The inverse of
// `StandardMIDIFileReader`: turns the tick-native `StandardMIDIFile` IR back
// into `.mid` bytes. Still tick-native, still project-free — mapping a file
// onto tracks/clips/tempo maps in either direction is m23-k3/k4's job, and it
// gets a `daw-architect` read first.
//
// LAW L9: pure Foundation `Data`, never AudioToolbox or CoreMIDI (the
// `SoundFontPresetReader` precedent). Apple's `MusicSequenceFileLoad` is used
// OUTSIDE the build, as the third-party witness that what this file writes is
// really a MIDI file — it appears nowhere here.
//
// WHY THIS FILE IS NOT GATED BY A ROUND TRIP, and why that matters more here
// than anywhere else in the codec: an encoder and a decoder that are wrong in
// MIRRORED ways round-trip perfectly. Writing pitch bend MSB-first and reading
// it MSB-first is a clean round trip and a broken file. So the load-bearing
// assertions live elsewhere — byte-exact `encode-*.mid` pins hand-authored from
// the spec BEFORE this encoder existed, plus Apple's loader reading what we
// wrote — and the round-trip test is kept only as a cheap regression net, said
// so in its own comment rather than presented as proof.
//
// THE TWELVE POLICIES this encoder commits to (each pinned by bytes, and most
// of them also confirmed by Apple's reading of those bytes):
//
//  P1  A tempo / time-signature event is emitted into the track its
//      `sourceTrackIndex` names.
//  P2  A note-off is spelled `8n`, NOT `9n` with velocity 0.
//  P3  That `8n`'s velocity slot carries `SMFNote.releaseVelocity` verbatim.
//      P2 and P3 are TWO decisions: `9n`-with-0 has no velocity slot to fill.
//  P4  Running status is OFF by default; every event carries its status byte.
//  P5  A track name is emitted at delta 0, before any channel event.
//  P6  End-of-track is emitted at `SMFTrack.endTick`, even when that sits past
//      the last note — trailing silence is meaningful and is part of the part's
//      length.
//  P7  Format 0 merges every part into ONE `MTrk`.
//  P8  At an equal tick the order is meta → note-off → controller → note-on,
//      and it holds ACROSS parts in a format-0 merge, not merely within one.
//  P9  A merged track's end-of-track is the MAXIMUM `endTick` across parts.
//  P10 Pitch bend is written 14-bit, LSB FIRST.
//  P11 Channel pressure is a TWO-byte message (`Dn vv`), not three.
//  P12 The channel nibble comes from the event's own `channel`, never a
//      hardcoded 0.
//
// `SMFTrack.channels` is DERIVED — the decoder fills it in from the events it
// saw — so the encoder ignores it entirely and takes every channel nibble from
// the event that needs one (P12). A hand-built or stale `channels` array
// therefore cannot corrupt the output; it is not an input to anything here.

/// How to write a `StandardMIDIFile`. The defaults are the pinned ones: the
/// IR's own format, and no running status.
public struct SMFWriteOptions: Sendable, Equatable, Hashable {
    /// The `MThd` format word to write, or nil to reuse the IR's own.
    ///
    /// Overriding it is a real conversion, not a header edit: format 0 merges
    /// every part into one chunk (P7/P8/P9) and format 1/2 writes one chunk per
    /// part. Format 2 is structurally identical to format 1 — one `MTrk` per
    /// part — and differs only in the header word and in what a reader is
    /// entitled to assume about whether the parts play together.
    public var format: SMFFormat?

    /// Elide a channel message's status byte when it repeats the previous one
    /// (P4). OFF by default.
    ///
    /// Running status makes files smaller and is legal everywhere, but it is
    /// also the single most common source of decoder desynchronisation, so the
    /// default output is the one that is easiest for any reader — including a
    /// naive one — to get right. When it IS enabled, correctness rests on one
    /// rule that is easy to forget: **a meta or SysEx event cancels running
    /// status** (SMF 1.0, "Sysex events and meta-events cancel any running
    /// status which was in effect"), so a tempo change between two identical
    /// control changes forces the second one to carry its status byte again.
    public var useRunningStatus: Bool

    public init(format: SMFFormat? = nil, useRunningStatus: Bool = false) {
        self.format = format
        self.useRunningStatus = useRunningStatus
    }
}

/// A refusal to encode, phrased so the message can be shown to a person.
///
/// The IR's fields are bare `Int`s with no range enforcement, so a hand-built
/// file — or one m23-k3 assembles from project data — can ask for something the
/// format cannot express. **An encoder that writes a corrupt file is worse than
/// one that refuses**: several of the cases below (a velocity-0 note-on, a
/// tempo above 2²⁴, a bend above 16383) would otherwise produce a file that
/// loads cleanly everywhere and is silently, musically wrong — which is far
/// harder to diagnose than a file that will not open at all.
///
/// Same posture as `SMFDecodeError`: every case names WHAT was wrong and WHERE,
/// and `errorDescription` is the same sentence as `description` so the message
/// a user sees never depends on which one a caller reached for.
public enum SMFEncodeError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {

    /// Which timed thing carried an impossible tick.
    public enum TickBearer: String, Sendable, Equatable, Hashable {
        case note
        case controller
        case tempoChange
        case timeSignature
        case endOfTrack

        var describedNoun: String {
            switch self {
            case .note: return "a note"
            case .controller: return "a controller event"
            case .tempoChange: return "a tempo change"
            case .timeSignature: return "a time signature"
            case .endOfTrack: return "the end-of-track marker"
            }
        }
    }

    /// Which byte of an `FF 58 04` time signature was out of range.
    public enum TimeSignatureField: String, Sendable, Equatable, Hashable {
        case numerator
        case denominatorPower
        case clocksPerMetronomeClick
        case thirtySecondNotesPerQuarter

        var describedName: String {
            switch self {
            case .numerator: return "numerator"
            case .denominatorPower: return "denominator power"
            case .clocksPerMetronomeClick: return "clocks per metronome click"
            case .thirtySecondNotesPerQuarter: return "32nd notes per quarter"
            }
        }
    }

    /// Which file-level event named a track that is not there.
    public enum GlobalEventKind: String, Sendable, Equatable, Hashable {
        case tempoChange
        case timeSignature

        var describedNoun: String {
            switch self {
            case .tempoChange: return "tempo change"
            case .timeSignature: return "time signature"
            }
        }
    }

    /// A file with no parts. Every valid SMF has at least one `MTrk`, and a
    /// header with nothing behind it is the "this file has no notes" lie the
    /// decoder refuses on the way in — refused here on the way out too.
    case noTracks
    /// Ticks per quarter note outside 1...32767. Bit 15 of the division word
    /// selects the SMPTE meaning, so 32768 and up are not large tick counts —
    /// they are a different unit entirely.
    case invalidTicksPerQuarterNote(Int)
    /// A SMPTE frame rate the format cannot name. Only 24, 25, 29 (drop-frame
    /// 29.97) and 30 have encodings.
    case invalidSMPTEFrameRate(Int)
    /// SMPTE ticks per frame outside 1...255 — it is one byte.
    case invalidSMPTETicksPerFrame(Int)
    /// A MIDI channel outside 0...15. The nibble has no room for more.
    case channelOutOfRange(trackIndex: Int, tick: Int, channel: Int)
    /// A note number outside 0...127.
    case noteNumberOutOfRange(trackIndex: Int, tick: Int, note: Int)
    /// A note-on velocity outside 1...127.
    ///
    /// Zero is the nastiest value in this whole enum and the reason this case
    /// is separate from `releaseVelocityOutOfRange`: written out as `9n nn 00`
    /// it is not an invalid file, it is a valid file in which the note has
    /// become a note-OFF and disappeared. The file still opens everywhere; the
    /// note is simply gone.
    case noteOnVelocityOutOfRange(trackIndex: Int, tick: Int, note: Int, velocity: Int)
    /// A note-off (release) velocity outside 0...127. Zero is legal here — it
    /// is the ordinary "no release information" value.
    case releaseVelocityOutOfRange(trackIndex: Int, tick: Int, note: Int, velocity: Int)
    /// A negative tick. Delta times are unsigned, so time cannot run backwards
    /// in an `MTrk` and there is no encoding for a negative one.
    case negativeTick(trackIndex: Int, tick: Int, bearer: TickBearer)
    /// A negative note length: the note-off would land before its note-on.
    case negativeNoteLength(trackIndex: Int, tick: Int, note: Int, lengthTicks: Int)
    /// `tick + lengthTicks` overflows `Int`, so the note-off has no tick to
    /// stand on.
    ///
    /// The IR's ticks are bare `Int`s that nothing range-enforces, so this is
    /// the one arithmetic in the encoder a hand-built (or future importer-built)
    /// IR can push past the machine word. It refuses rather than trapping,
    /// because this file's posture is "never a crash" and a trap in a pure-model
    /// type takes the whole app down. The check is an overflow check and not a
    /// tick ceiling on purpose: absolute ticks above 0x0FFFFFFF are legal SMF as
    /// long as no single GAP exceeds it, so a ceiling here would refuse files
    /// the format permits. Oversized gaps are `deltaTimeTooLarge`'s job.
    case noteEndTickOverflows(trackIndex: Int, tick: Int, note: Int, lengthTicks: Int)
    /// A CC number outside 0...127.
    case controllerNumberOutOfRange(trackIndex: Int, tick: Int, controller: Int)
    /// A controller value outside `MIDIControllerType.valueRange` — 0...127 for
    /// CC and channel pressure, 0...16383 for pitch bend. Read from the type
    /// rather than restated, so there is ONE home for each range.
    case controllerValueOutOfRange(trackIndex: Int, tick: Int,
                                   type: MIDIControllerType, value: Int)
    /// `endTick` before the track's own last event. The marker is the part's
    /// authoritative length, so a marker in the past would make the file
    /// disagree with itself about where the music stops.
    ///
    /// Checked per INPUT PART and independently of the requested format: an IR
    /// that is internally inconsistent is refused whether you ask for format 0
    /// or format 1, because which IRs are legal must not depend on which output
    /// you happen to want.
    case endTickBeforeLastEvent(trackIndex: Int, endTick: Int, lastEventTick: Int)
    /// Microseconds per quarter note outside 1...0xFFFFFF. The `FF 51 03`
    /// payload is THREE bytes: 2²⁴ and up truncate silently and produce a
    /// well-formed file playing at the wrong tempo. Zero is refused because it
    /// is a quarter note of no duration.
    case tempoOutOfRange(trackIndex: Int, tick: Int, microsecondsPerQuarterNote: Int)
    /// A time-signature byte outside 0...255. Each of the four is one byte.
    case timeSignatureByteOutOfRange(trackIndex: Int, tick: Int,
                                     field: TimeSignatureField, value: Int)
    /// A hoisted tempo / time-signature event whose `sourceTrackIndex` names a
    /// part that is not in the file (P1 has nowhere to put it).
    case sourceTrackIndexOutOfRange(kind: GlobalEventKind, tick: Int,
                                    sourceTrackIndex: Int, trackCount: Int)
    /// A delta time above 0x0FFFFFFF, which no 4-byte variable-length quantity
    /// can hold. At 480 ticks per quarter that is about 155 hours of 4/4 at
    /// 120 BPM between two adjacent events.
    case deltaTimeTooLarge(trackIndex: Int, delta: Int)
    /// More `MTrk` chunks than the header's 16-bit `ntrks` field can count.
    ///
    /// Same silent-corruption class as `tempoOutOfRange`: 65536 chunks would
    /// mask down to an `ntrks` of 0 and produce a header that lies about its own
    /// contents — a file every reader opens and no reader reads. Refusing is the
    /// only honest answer, and it is why this case exists even though nothing
    /// k1 or k3 can build comes near it.
    ///
    /// Deliberately checked on the OUTPUT chunk count, so unlike
    /// `endTickBeforeLastEvent` it IS format-dependent, and the difference is
    /// principled: that one is about an IR disagreeing with itself, which no
    /// choice of output can fix, while this one is about what the file being
    /// written can express. Format 0 merges every part into one chunk, so a
    /// 70000-part IR written as format 0 has one chunk and an `ntrks` of 1 —
    /// which is the truth about that file, not a loophole.
    case tooManyTracks(count: Int)
    /// A meta event payload above 0x0FFFFFFF bytes, which its variable-length
    /// length field cannot hold.
    ///
    /// DEFENSIVE, and said so rather than left looking like tested behaviour:
    /// the only payload this encoder writes from caller data is a track name,
    /// so reaching it needs roughly a quarter of a gigabyte of text. It is not
    /// strictly unreachable — the decoder's Latin-1 fallback can DOUBLE a
    /// payload's byte count on the way into a `String`, so a 200 MB Latin-1
    /// name would come back out over the limit — which is exactly why it
    /// refuses instead of truncating.
    case metaPayloadTooLong(trackIndex: Int, byteCount: Int)

    public var description: String {
        switch self {
        case .noTracks:
            return "This song has no tracks to write. A MIDI file must contain at least "
                + "one track."
        case .invalidTicksPerQuarterNote(let value):
            return "A MIDI file's time base must be between 1 and 32767 ticks per quarter "
                + "note; this one asks for \(value)."
        case .invalidSMPTEFrameRate(let fps):
            return "A MIDI file can only record SMPTE timing at 24, 25, 29 or 30 frames per "
                + "second; this one asks for \(fps)."
        case .invalidSMPTETicksPerFrame(let value):
            return "A MIDI file's SMPTE time base must be between 1 and 255 ticks per frame; "
                + "this one asks for \(value)."
        case .channelOutOfRange(let track, let tick, let channel):
            return "Track \(track) has an event at tick \(tick) on MIDI channel \(channel), "
                + "but MIDI has only channels 1-16 (stored as 0-15)."
        case .noteNumberOutOfRange(let track, let tick, let note):
            return "Track \(track) has a note numbered \(note) at tick \(tick); MIDI note "
                + "numbers run from 0 to 127."
        case .noteOnVelocityOutOfRange(let track, let tick, let note, let velocity):
            if velocity == 0 {
                return "Track \(track): note \(note) at tick \(tick) has velocity 0. In a MIDI "
                    + "file that is not a silent note — it is how a note is switched OFF, so "
                    + "the note would vanish from a file that still opened normally. "
                    + "Velocities run from 1 to 127."
            }
            return "Track \(track): note \(note) at tick \(tick) has velocity \(velocity); "
                + "MIDI velocities run from 1 to 127."
        case .releaseVelocityOutOfRange(let track, let tick, let note, let velocity):
            return "Track \(track): note \(note) at tick \(tick) has a release velocity of "
                + "\(velocity); release velocities run from 0 to 127."
        case .negativeTick(let track, let tick, let bearer):
            return "Track \(track) places \(bearer.describedNoun) at tick \(tick). A MIDI file "
                + "measures time forwards from zero and cannot record anything before the "
                + "start of the song."
        case .negativeNoteLength(let track, let tick, let note, let length):
            return "Track \(track): note \(note) at tick \(tick) has a length of \(length) "
                + "ticks, so it would end before it began."
        case .noteEndTickOverflows(let track, let tick, let note, let length):
            return "Track \(track): note \(note) starts at tick \(tick) and lasts \(length) "
                + "ticks, which counts past the largest position this program can measure. "
                + "Move the note earlier or shorten it."
        case .controllerNumberOutOfRange(let track, let tick, let controller):
            return "Track \(track) has control change #\(controller) at tick \(tick); MIDI "
                + "control change numbers run from 0 to 127."
        case .controllerValueOutOfRange(let track, let tick, let type, let value):
            let range = type.valueRange
            return "Track \(track): the \(type.wireKey) value \(value) at tick \(tick) is "
                + "outside the \(range.lowerBound)-\(range.upperBound) range MIDI allows for it."
        case .endTickBeforeLastEvent(let track, let endTick, let lastEventTick):
            return "Track \(track) is marked as ending at tick \(endTick), but it still has an "
                + "event at tick \(lastEventTick). The end of a track cannot come before its "
                + "last note."
        case .tempoOutOfRange(let track, let tick, let value):
            return "Track \(track) sets the tempo at tick \(tick) to \(value) microseconds per "
                + "quarter note. A MIDI file stores that in three bytes, so it must be between "
                + "1 and 16777215 (about 3.6 BPM at the slow end)."
        case .timeSignatureByteOutOfRange(let track, let tick, let field, let value):
            return "Track \(track) has a time signature at tick \(tick) whose "
                + "\(field.describedName) is \(value); each part of a MIDI time signature is a "
                + "single byte, 0 to 255."
        case .sourceTrackIndexOutOfRange(let kind, let tick, let index, let count):
            return "A \(kind.describedNoun) at tick \(tick) belongs to track \(index), but this "
                + "song has \(count) track(s). There is nowhere to write it."
        case .deltaTimeTooLarge(let track, let delta):
            return "Track \(track) has a gap of \(delta) ticks between two events. A MIDI file "
                + "can only record gaps up to 268435455 ticks."
        case .tooManyTracks(let count):
            return "This song has \(count) tracks to write. A MIDI file counts its tracks in "
                + "two bytes, so it can hold at most 65535 of them."
        case .metaPayloadTooLong(let track, let count):
            return "Track \(track) has a text event of \(count) bytes. A MIDI file can only "
                + "record up to 268435455 bytes in one event."
        }
    }

    /// Same string as `description` — see the type's doc comment.
    public var errorDescription: String? { description }
}

/// Writes a `StandardMIDIFile` back out as Standard MIDI File bytes.
public enum StandardMIDIFileWriter {

    // MARK: - Entry points

    /// Encodes to bytes in memory.
    ///
    /// Whole-file assembly is fine at this scale, for the same reason the reader
    /// reads whole files: SMF is an event list, and even a dense multi-track
    /// arrangement is tens of kilobytes. Control-plane work, never the render
    /// thread.
    public static func encode(_ file: StandardMIDIFile,
                              options: SMFWriteOptions = .init()) throws -> Data {
        let format = options.format ?? file.format

        // Order of refusal matters only in that it must be STABLE, so a caller
        // fixing one problem is not surprised by which one surfaces next: the
        // whole-file shape first (division, then emptiness), then per-part
        // content, then the chunk count — which is only knowable once the
        // requested format has decided whether the parts merge — then the deltas
        // that only exist once events are ordered.
        let division = try divisionWord(file.division)
        guard !file.tracks.isEmpty else { throw SMFEncodeError.noTracks }

        var parts = try file.tracks.indices.map { try buildPart(file.tracks[$0], index: $0) }

        // P1 — a hoisted tempo / time signature goes back into the part its
        // `sourceTrackIndex` names.
        //
        // `sourceTrackIndex` is read as an index into `file.tracks`. For
        // anything the decoder produced in format 1/2 that is exactly the chunk
        // it came from (part i has `sourceTrackIndex` i); for a decoded format 0
        // every part shares index 0 and the question is moot, because format 0
        // has only one chunk to write into anyway. Reading it as "the part at
        // this position" rather than "the first part whose own
        // `sourceTrackIndex` matches" also makes the bound check total: either
        // the position exists or the event has nowhere to go.
        for tempo in file.tempoChanges {
            guard parts.indices.contains(tempo.sourceTrackIndex) else {
                throw SMFEncodeError.sourceTrackIndexOutOfRange(
                    kind: .tempoChange, tick: tempo.tick,
                    sourceTrackIndex: tempo.sourceTrackIndex, trackCount: parts.count)
            }
            try parts[tempo.sourceTrackIndex].appendTempo(tempo)
        }
        for signature in file.timeSignatures {
            guard parts.indices.contains(signature.sourceTrackIndex) else {
                throw SMFEncodeError.sourceTrackIndexOutOfRange(
                    kind: .timeSignature, tick: signature.tick,
                    sourceTrackIndex: signature.sourceTrackIndex, trackCount: parts.count)
            }
            try parts[signature.sourceTrackIndex].appendTimeSignature(signature)
        }

        // P6 — the marker sits at `endTick`, which may be past the last note.
        // Checked per part and format-independently (see
        // `endTickBeforeLastEvent`).
        for part in parts {
            if let last = part.lastEventTick, part.endTick < last {
                throw SMFEncodeError.endTickBeforeLastEvent(
                    trackIndex: part.index, endTick: part.endTick, lastEventTick: last)
            }
            guard part.endTick >= 0 else {
                throw SMFEncodeError.negativeTick(trackIndex: part.index,
                                                  tick: part.endTick, bearer: .endOfTrack)
            }
        }

        let chunks: [Part]
        if format == .singleTrack {
            // P7 / P8 / P9 — one `MTrk`, ordered across parts, ending at the
            // latest of their ends.
            chunks = [Part.merged(parts)]
        } else {
            chunks = parts
        }

        // `ntrks` is two bytes and `uint16BE` MASKS, so without this an oversized
        // song writes a header claiming a track count it does not have — 65536
        // chunks would announce 0. See `tooManyTracks`.
        guard chunks.count <= 0xFFFF else {
            throw SMFEncodeError.tooManyTracks(count: chunks.count)
        }

        var bytes: [UInt8] = []
        bytes += Array("MThd".utf8)
        bytes += uint32BE(6)
        bytes += uint16BE(format.rawValue)
        bytes += uint16BE(chunks.count)
        bytes += uint16BE(division)
        for chunk in chunks {
            bytes += try trackChunk(chunk, useRunningStatus: options.useRunningStatus)
        }
        return Data(bytes)
    }

    /// Encodes and writes to disk atomically, so a failure part-way through
    /// cannot leave a half-written `.mid` where the user expects their export.
    public static func write(_ file: StandardMIDIFile, to url: URL,
                             options: SMFWriteOptions = .init()) throws {
        try encode(file, options: options).write(to: url, options: .atomic)
    }

    // MARK: - Division

    private static func divisionWord(_ division: SMFDivision) throws -> Int {
        switch division {
        case .ticksPerQuarterNote(let tpqn):
            // Bit 15 must stay CLEAR — it is what says "this is a tick count"
            // rather than "this is a negative frame rate".
            guard (1 ... 32767).contains(tpqn) else {
                throw SMFEncodeError.invalidTicksPerQuarterNote(tpqn)
            }
            return tpqn
        case .smpte(let framesPerSecond, let ticksPerFrame):
            guard [24, 25, 29, 30].contains(framesPerSecond) else {
                throw SMFEncodeError.invalidSMPTEFrameRate(framesPerSecond)
            }
            guard (1 ... 255).contains(ticksPerFrame) else {
                throw SMFEncodeError.invalidSMPTETicksPerFrame(ticksPerFrame)
            }
            // The high byte is the frame rate NEGATED, in two's complement —
            // which is also what sets bit 15 and switches the word's meaning.
            // 25 fps × 40 ticks/frame is 0xE728.
            let high = Int(UInt8(bitPattern: Int8(-framesPerSecond)))
            return (high << 8) | ticksPerFrame
        }
    }

    // MARK: - Event ordering

    /// The P8 ladder: at an equal tick, events come out in this order.
    ///
    /// Meta first so a tempo change takes effect before the notes it governs,
    /// note-off before note-on so a pitch released exactly where it is restruck
    /// pairs with the right onset (the whole hazard `encode-format0-merge.mid`
    /// exists to pin), and controllers between them so a CC that shapes a note
    /// is in place before the note starts.
    ///
    /// `zeroLengthNoteOff` is the one non-obvious rung, and it is load-bearing.
    /// A note of length 0 is legal in the IR ("nudging is a musical decision,
    /// and this layer makes none"), and its note-off shares a tick with its own
    /// note-on. Filed under `noteOff` it would be emitted BEFORE that note-on
    /// and the note would come back as an unmatched note-off plus a dangling
    /// onset — a silently wrong file. Filed after `noteOn` it closes correctly,
    /// and the note-on tiebreak below (shortest first) makes sure it closes its
    /// OWN onset rather than a longer note struck on the same pitch at the same
    /// tick.
    private enum Rank {
        static let meta = 0
        static let noteOff = 1
        static let controller = 2
        static let noteOn = 3
        static let zeroLengthNoteOff = 4
        static let endOfTrack = 5
    }

    /// The within-meta order at an equal tick: name, then tempo, then time
    /// signature. Arbitrary but DETERMINISTIC — the spec fixes no order among
    /// them, and the byte pins only exercise a name, so this is a choice made
    /// once here rather than left to sort instability.
    private enum MetaOrder {
        static let name = 0
        static let tempo = 1
        static let timeSignature = 2
    }

    /// One event, ready to be sorted and then serialised.
    ///
    /// The sort key is `(tick, rank, sortA, sortB, sortC, sequence)` and it is
    /// TOTAL: `sequence` is a monotonically increasing insertion counter, so the
    /// output never depends on `sort`'s stability (Swift's is not guaranteed) or
    /// on dictionary iteration order.
    private struct PendingEvent {
        var tick: Int
        var rank: Int
        var sortA: Int
        var sortB: Int
        var sortC: Int
        var sequence: Int
        /// The channel status byte (`8n`/`9n`/`Bn`/`Dn`/`En`), or nil for meta.
        /// Only channel messages may ride running status, and only meta events
        /// cancel it — this field is what tells the two apart.
        var status: UInt8?
        /// Everything after the status byte for a channel message; the complete
        /// `FF type length payload` for a meta event.
        var payload: [UInt8]

        var sortKey: (Int, Int, Int, Int, Int, Int) {
            (tick, rank, sortA, sortB, sortC, sequence)
        }
    }

    /// One output chunk's worth of material, before serialisation.
    private struct Part {
        /// Index into `StandardMIDIFile.tracks`, for error messages. After a
        /// format-0 merge this is the FIRST part's index — the merged chunk has
        /// no single source, and pointing at the first one is more useful than
        /// pointing at nothing.
        var index: Int
        var name: String?
        var events: [PendingEvent]
        var endTick: Int

        var lastEventTick: Int? { events.map(\.tick).max() }

        /// P7 / P9. The name is the FIRST non-nil part name: a merged chunk can
        /// carry only one `FF 03`, dropping all of them would throw away
        /// information the file had, and picking the first is the only choice
        /// that does not depend on the parts' contents.
        static func merged(_ parts: [Part]) -> Part {
            Part(index: parts.first?.index ?? 0,
                 name: parts.compactMap(\.name).first,
                 events: parts.flatMap(\.events),
                 endTick: parts.map(\.endTick).max() ?? 0)
        }

        /// P1 — a set-tempo event, back in the track its `sourceTrackIndex`
        /// named.
        mutating func appendTempo(_ tempo: SMFTempoEvent) throws {
            guard tempo.tick >= 0 else {
                throw SMFEncodeError.negativeTick(trackIndex: index, tick: tempo.tick,
                                                  bearer: .tempoChange)
            }
            // THREE bytes. 2²⁴ and up truncate to a well-formed file at the
            // wrong tempo — see `tempoOutOfRange`.
            let value = tempo.microsecondsPerQuarterNote
            guard (1 ... 0xFF_FFFF).contains(value) else {
                throw SMFEncodeError.tempoOutOfRange(trackIndex: index, tick: tempo.tick,
                                                     microsecondsPerQuarterNote: value)
            }
            let bytes = try StandardMIDIFileWriter.metaEvent(
                type: 0x51,
                payload: [UInt8((value >> 16) & 0xFF),
                          UInt8((value >> 8) & 0xFF),
                          UInt8(value & 0xFF)],
                trackIndex: index)
            events.append(PendingEvent(tick: tempo.tick, rank: Rank.meta,
                                       sortA: MetaOrder.tempo, sortB: 0, sortC: 0,
                                       sequence: events.count, status: nil, payload: bytes))
        }

        /// P1 — a time-signature event, likewise.
        mutating func appendTimeSignature(_ signature: SMFTimeSignatureEvent) throws {
            guard signature.tick >= 0 else {
                throw SMFEncodeError.negativeTick(trackIndex: index, tick: signature.tick,
                                                  bearer: .timeSignature)
            }
            // Each of the four is ONE byte, including `denominatorPower` —
            // which is stored raw precisely because the byte can name
            // denominators no `Int` holds, so it is range-checked as a byte and
            // not as a denominator.
            let fields: [(SMFEncodeError.TimeSignatureField, Int)] = [
                (.numerator, signature.numerator),
                (.denominatorPower, signature.denominatorPower),
                (.clocksPerMetronomeClick, signature.clocksPerMetronomeClick),
                (.thirtySecondNotesPerQuarter, signature.thirtySecondNotesPerQuarter),
            ]
            for (field, value) in fields {
                guard (0 ... 255).contains(value) else {
                    throw SMFEncodeError.timeSignatureByteOutOfRange(
                        trackIndex: index, tick: signature.tick, field: field, value: value)
                }
            }
            let bytes = try StandardMIDIFileWriter.metaEvent(
                type: 0x58, payload: fields.map { UInt8($0.1) }, trackIndex: index)
            events.append(PendingEvent(tick: signature.tick, rank: Rank.meta,
                                       sortA: MetaOrder.timeSignature, sortB: 0, sortC: 0,
                                       sequence: events.count, status: nil, payload: bytes))
        }
    }

    // MARK: - Part assembly

    /// Validates and converts one `SMFTrack` into orderable events.
    ///
    /// Every range check lives here, before a single byte is produced, so a
    /// refusal never leaves a partially built file behind.
    private static func buildPart(_ track: SMFTrack, index: Int) throws -> Part {
        var events: [PendingEvent] = []
        var sequence = 0

        for note in track.notes {
            guard note.tick >= 0 else {
                throw SMFEncodeError.negativeTick(trackIndex: index, tick: note.tick,
                                                  bearer: .note)
            }
            guard note.lengthTicks >= 0 else {
                throw SMFEncodeError.negativeNoteLength(trackIndex: index, tick: note.tick,
                                                        note: note.note,
                                                        lengthTicks: note.lengthTicks)
            }
            // The note-off's tick is the ONE addition in this encoder that a
            // caller controls both sides of, so it is checked rather than
            // assumed. See `noteEndTickOverflows`.
            let (endTick, overflowed) = note.tick.addingReportingOverflow(note.lengthTicks)
            guard !overflowed else {
                throw SMFEncodeError.noteEndTickOverflows(trackIndex: index, tick: note.tick,
                                                          note: note.note,
                                                          lengthTicks: note.lengthTicks)
            }
            guard (0 ... 15).contains(note.channel) else {
                throw SMFEncodeError.channelOutOfRange(trackIndex: index, tick: note.tick,
                                                       channel: note.channel)
            }
            guard (0 ... 127).contains(note.note) else {
                throw SMFEncodeError.noteNumberOutOfRange(trackIndex: index, tick: note.tick,
                                                          note: note.note)
            }
            // 1...127, not 0...127 — see `noteOnVelocityOutOfRange`.
            guard (1 ... 127).contains(note.velocity) else {
                throw SMFEncodeError.noteOnVelocityOutOfRange(
                    trackIndex: index, tick: note.tick, note: note.note,
                    velocity: note.velocity)
            }
            guard (0 ... 127).contains(note.releaseVelocity) else {
                throw SMFEncodeError.releaseVelocityOutOfRange(
                    trackIndex: index, tick: note.tick, note: note.note,
                    velocity: note.releaseVelocity)
            }

            let channel = UInt8(note.channel)
            // P12 — the nibble comes from the event.
            events.append(PendingEvent(
                tick: note.tick, rank: Rank.noteOn,
                sortA: note.channel, sortB: note.note,
                // SHORTEST FIRST among note-ons that share a tick, channel and
                // pitch. The decoder pairs re-struck pitches FIFO, so emitting
                // the shortest onset first is what makes the first note-off
                // close the note that really was shortest.
                sortC: note.lengthTicks, sequence: sequence,
                status: 0x90 | channel,
                payload: [UInt8(note.note), UInt8(note.velocity)]))
            sequence += 1

            // P2 — spelled `8n`. P3 — the velocity slot carries
            // `releaseVelocity` verbatim, which `9n`-with-0 has no room for.
            events.append(PendingEvent(
                tick: endTick,
                rank: note.lengthTicks == 0 ? Rank.zeroLengthNoteOff : Rank.noteOff,
                sortA: note.channel, sortB: note.note,
                sortC: note.releaseVelocity, sequence: sequence,
                status: 0x80 | channel,
                payload: [UInt8(note.note), UInt8(note.releaseVelocity)]))
            sequence += 1
        }

        for controller in track.controllers {
            guard controller.tick >= 0 else {
                throw SMFEncodeError.negativeTick(trackIndex: index, tick: controller.tick,
                                                  bearer: .controller)
            }
            guard (0 ... 15).contains(controller.channel) else {
                throw SMFEncodeError.channelOutOfRange(trackIndex: index, tick: controller.tick,
                                                       channel: controller.channel)
            }
            // The RANGE comes from the type — ONE home for "what values may a
            // pitch bend take", shared with the lane model that already clamps
            // to it. The CC NUMBER is a separate question from the CC value and
            // gets its own check.
            guard controller.type.valueRange.contains(controller.value) else {
                throw SMFEncodeError.controllerValueOutOfRange(
                    trackIndex: index, tick: controller.tick,
                    type: controller.type, value: controller.value)
            }
            let channel = UInt8(controller.channel)
            let status: UInt8
            let payload: [UInt8]
            switch controller.type {
            case .cc(let number):
                guard (0 ... 127).contains(number) else {
                    throw SMFEncodeError.controllerNumberOutOfRange(
                        trackIndex: index, tick: controller.tick, controller: number)
                }
                status = 0xB0 | channel
                payload = [UInt8(number), UInt8(controller.value)]
            case .pitchBend:
                // P10 — 14-bit, LSB FIRST. The low 7 bits go out ahead of the
                // high 7, the reverse of every other multi-byte field in the
                // format. Swapping them writes centre (8192) as 64, which every
                // reader accepts and plays as a stuck downward bend.
                status = 0xE0 | channel
                payload = [UInt8(controller.value & 0x7F), UInt8((controller.value >> 7) & 0x7F)]
            case .channelPressure:
                // P11 — TWO bytes total. A third would be read as the next
                // event's delta time and desynchronise the rest of the track.
                status = 0xD0 | channel
                payload = [UInt8(controller.value)]
            }
            events.append(PendingEvent(
                tick: controller.tick, rank: Rank.controller,
                sortA: controller.channel, sortB: controller.type.sortKey,
                sortC: controller.value, sequence: sequence,
                status: status, payload: payload))
            sequence += 1
        }

        return Part(index: index, name: track.name, events: events, endTick: track.endTick)
    }

    // MARK: - Meta events attached after the P1 hoist

    private static func metaEvent(type: UInt8, payload: [UInt8],
                                  trackIndex: Int) throws -> [UInt8] {
        guard let length = variableLengthQuantity(payload.count) else {
            throw SMFEncodeError.metaPayloadTooLong(trackIndex: trackIndex,
                                                    byteCount: payload.count)
        }
        return [0xFF, type] + length + payload
    }

    // MARK: - Serialisation

    private static func trackChunk(_ part: Part, useRunningStatus: Bool) throws -> [UInt8] {
        var events = part.events

        // P5 — the name rides at delta 0, ahead of any channel event. It is a
        // property of the track rather than a moment in it, so it is placed
        // rather than sorted: tick 0, the first meta rung.
        if let name = part.name {
            let bytes = try metaEvent(type: 0x03, payload: Array(name.utf8),
                                      trackIndex: part.index)
            events.append(PendingEvent(
                tick: 0, rank: Rank.meta, sortA: MetaOrder.name, sortB: 0, sortC: 0,
                sequence: -1, status: nil, payload: bytes))
        }
        // P6 — always last, at `endTick`.
        events.append(PendingEvent(
            tick: part.endTick, rank: Rank.endOfTrack, sortA: 0, sortB: 0, sortC: 0,
            sequence: Int.max,
            status: nil,
            payload: [0xFF, 0x2F, 0x00]))

        events.sort { $0.sortKey < $1.sortKey }

        var body: [UInt8] = []
        var tick = 0
        var runningStatus: UInt8?
        for event in events {
            let delta = event.tick - tick
            guard let deltaBytes = variableLengthQuantity(delta) else {
                throw SMFEncodeError.deltaTimeTooLarge(trackIndex: part.index, delta: delta)
            }
            tick = event.tick
            body += deltaBytes
            if let status = event.status {
                // P4 — the status byte is written unless running status is on
                // AND it repeats. Note this is the ONLY place `runningStatus`
                // is set: a meta event falls through to the `else` branch and
                // CLEARS it, which is the spec rule ("Sysex events and
                // meta-events cancel any running status which was in effect")
                // and the one an encoder most easily forgets, because forgetting
                // it produces byte-perfect output for every file that has no
                // meta event in the middle of a channel run.
                if useRunningStatus, runningStatus == status {
                    body += event.payload
                } else {
                    body.append(status)
                    body += event.payload
                    runningStatus = status
                }
            } else {
                body += event.payload
                runningStatus = nil
            }
        }

        return Array("MTrk".utf8) + uint32BE(body.count) + body
    }

    // MARK: - Primitives

    private static func uint16BE(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// NOTE — both of these MASK rather than trap, so every call site owes a
    /// bound. Audited: `uint32BE(6)` is a literal; `uint16BE(format.rawValue)`
    /// is an enum of 0/1/2; `uint16BE(division)` is validated by `divisionWord`;
    /// `uint16BE(chunks.count)` is guarded by `tooManyTracks`. The one left
    /// unguarded is `uint32BE(body.count)`, and deliberately: truncating it
    /// needs a single `MTrk` body over 4 GiB already resident in memory, so
    /// allocation fails long before the mask does — whereas 65536 empty tracks
    /// is a plausible loop bug in an importer, which is why THAT one refuses.
    private static func uint32BE(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// A variable-length quantity: 7 payload bits per byte, high bit set on
    /// every byte but the last, most significant group first.
    ///
    /// Returns nil above 0x0FFFFFFF rather than silently wrapping — the 4-byte
    /// cap is the spec's, and a 5-byte VLQ is not a large number, it is a file
    /// no conforming reader will parse. Zero encodes as a single `00`, which is
    /// what every delta of "at the same tick as the previous event" writes.
    static func variableLengthQuantity(_ value: Int) -> [UInt8]? {
        guard value >= 0, value <= 0x0FFF_FFFF else { return nil }
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var remainder = value >> 7
        while remainder > 0 {
            bytes.append(UInt8((remainder & 0x7F) | 0x80))
            remainder >>= 7
        }
        return bytes.reversed()
    }
}
