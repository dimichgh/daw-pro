import Foundation

// Standard MIDI File (SMF 1.0) decoder — m23-k1. Reads `.mid` bytes into the
// tick-native `StandardMIDIFile` IR and nothing else: no beats, no tempo
// applied, no project types touched (that mapping is m23-k3, and it gets a
// `daw-architect` read first).
//
// LAW L9: pure Foundation `Data`, never AudioToolbox or CoreMIDI — the
// `SoundFontPresetReader` precedent. Apple's `MusicSequenceFileLoad` was used
// OUTSIDE the build to validate the checked-in fixtures; it appears nowhere
// here, and correctness is established against those fixtures' recorded bytes.
//
// Every read is bounds-checked through `SMFCursor`, whose accessors return nil
// rather than trapping, so a truncated or hostile file produces a teaching
// `SMFDecodeError` — never a crash, and never a plausible-looking empty parse
// that would read to a user as "this file has no notes".
public enum StandardMIDIFileReader {

    // MARK: - Entry points

    /// Decodes a Standard MIDI File from disk.
    ///
    /// Unlike `SoundFontPresetReader.presets(at:)`, which returns [] because its
    /// caller has a legitimate generic fallback, this THROWS: there is no
    /// sensible fallback for "the user asked to import this specific file", and
    /// silence would be indistinguishable from an empty song.
    public static func decode(contentsOf url: URL) throws -> StandardMIDIFile {
        try decode(Data(contentsOf: url))
    }

    /// Decodes a Standard MIDI File from bytes already in memory.
    ///
    /// Whole-file read is fine at this scale — SMF is an event list, and even a
    /// dense multi-track arrangement is tens of kilobytes. This is control-plane
    /// work, never on the render thread.
    public static func decode(_ data: Data) throws -> StandardMIDIFile {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { throw SMFDecodeError.emptyFile }

        var cursor = SMFCursor(bytes: bytes, start: 0, end: bytes.count)
        let header = try parseHeader(&cursor, totalBytes: bytes.count)

        var rawTracks: [RawTrack] = []
        var warnings: [SMFWarning] = []

        // Chunk walk. A chunk is a 4-byte tag plus a 4-byte big-endian length;
        // fewer than 8 bytes left cannot be a chunk header, so the walk stops.
        while cursor.remaining >= 8 {
            guard let tag = cursor.fourCC(), let length = cursor.uint32BE() else { break }
            guard cursor.remaining >= length else {
                throw SMFDecodeError.truncatedChunk(tag: tag, declaredLength: length,
                                                    availableBytes: cursor.remaining)
            }
            let chunkStart = cursor.offset
            if tag == "MTrk" {
                let raw = try parseTrack(bytes: bytes,
                                         start: chunkStart,
                                         end: chunkStart + length,
                                         trackIndex: rawTracks.count)
                warnings.append(contentsOf: raw.warnings)
                rawTracks.append(raw)
            }
            // UNKNOWN CHUNKS ARE SKIPPED BY THEIR LENGTH, not rejected. The spec
            // requires this ("programs which read MIDI files should skip over
            // any chunk types they do not know about"), and real DAWs emit
            // proprietary chunks freely — a reader that errors here refuses
            // files every other program opens without complaint.
            cursor.offset = chunkStart + length
        }
        if cursor.remaining > 0 {
            warnings.append(.trailingBytes(count: cursor.remaining))
        }

        // A valid header with no tracks behind it is exactly the case that would
        // otherwise become the "this file has no notes" lie, so it is a refusal.
        guard !rawTracks.isEmpty else { throw SMFDecodeError.noTrackChunks }
        if header.declaredTrackCount != rawTracks.count {
            warnings.append(.trackCountMismatch(declared: header.declaredTrackCount,
                                                found: rawTracks.count))
        }

        // Tempo and meter are hoisted to file level (see `StandardMIDIFile`);
        // sorting is by tick, then by source chunk so two events on the same
        // tick in different chunks still land in a deterministic order.
        let tempoChanges = rawTracks.flatMap(\.tempoChanges)
            .sorted { ($0.tick, $0.sourceTrackIndex) < ($1.tick, $1.sourceTrackIndex) }
        let timeSignatures = rawTracks.flatMap(\.timeSignatures)
            .sorted { ($0.tick, $0.sourceTrackIndex) < ($1.tick, $1.sourceTrackIndex) }

        let tracks = header.format == .singleTrack
            ? rawTracks.flatMap(splitByChannel)
            : rawTracks.map(wholeTrack)

        return StandardMIDIFile(format: header.format,
                                division: header.division,
                                tracks: tracks,
                                tempoChanges: tempoChanges,
                                timeSignatures: timeSignatures,
                                warnings: warnings)
    }

    // MARK: - Header

    private struct Header {
        let format: SMFFormat
        let declaredTrackCount: Int
        let division: SMFDivision
    }

    private static func parseHeader(_ cursor: inout SMFCursor,
                                    totalBytes: Int) throws -> Header {
        guard let tag = cursor.fourCC() else {
            throw SMFDecodeError.truncatedHeader(availableBytes: totalBytes)
        }
        // The header chunk must come FIRST. Skipping a non-`MThd` leading chunk
        // as if it were an unknown chunk would turn "this is a ZIP file" into
        // "this MIDI file has no tracks" — a worse message about a different
        // problem. Apple's loader draws the same line, reporting a distinct
        // status for a bad magic versus a damaged-but-real MIDI file.
        guard tag == "MThd" else {
            throw SMFDecodeError.missingHeaderChunk(foundTag: tag)
        }
        guard let declaredLength = cursor.uint32BE(),
              declaredLength >= 6,
              cursor.remaining >= declaredLength else {
            throw SMFDecodeError.truncatedHeader(availableBytes: totalBytes)
        }
        let headerEnd = cursor.offset + declaredLength
        guard let rawFormat = cursor.uint16BE(),
              let declaredTrackCount = cursor.uint16BE(),
              let rawDivision = cursor.uint16BE() else {
            throw SMFDecodeError.truncatedHeader(availableBytes: totalBytes)
        }
        guard let format = SMFFormat(rawValue: rawFormat) else {
            throw SMFDecodeError.unsupportedFormat(rawFormat)
        }
        // Trust the DECLARED length, not the constant 6: the spec reserves the
        // right to extend the header, and future bytes must be skipped, not
        // mistaken for the first chunk.
        cursor.offset = headerEnd
        return Header(format: format,
                      declaredTrackCount: declaredTrackCount,
                      division: try division(raw: rawDivision))
    }

    private static func division(raw: Int) throws -> SMFDivision {
        // Bit 15 selects between the division word's two INCOMPATIBLE meanings,
        // and the high byte of the SMPTE form is a two's-complement NEGATIVE
        // frame rate. Reading the word as an unsigned tick count is the classic
        // silent misparse: 0xE728 is 25 fps × 40 ticks/frame (1000 ticks per
        // second, absolute), but read unsigned it is 59176 ticks per quarter
        // note, which places every note roughly 123× too early — with no error
        // anywhere to say so.
        if raw & 0x8000 != 0 {
            let framesPerSecond = -Int(Int8(bitPattern: UInt8((raw >> 8) & 0xFF)))
            let ticksPerFrame = raw & 0xFF
            guard framesPerSecond > 0, ticksPerFrame > 0 else {
                throw SMFDecodeError.invalidDivision(raw: raw)
            }
            return .smpte(framesPerSecond: framesPerSecond, ticksPerFrame: ticksPerFrame)
        }
        guard raw > 0 else { throw SMFDecodeError.invalidDivision(raw: raw) }
        return .ticksPerQuarterNote(raw)
    }

    // MARK: - Track chunk

    /// One `MTrk` as parsed, before the format-0 channel split.
    private struct RawTrack {
        var index: Int
        var name: String?
        var notes: [SMFNote]
        var controllers: [SMFControllerEvent]
        var channels: [Int]
        var endTick: Int
        var tempoChanges: [SMFTempoEvent]
        var timeSignatures: [SMFTimeSignatureEvent]
        var programChanges: [SMFProgramChangeEvent]
        /// Poly-pressure events counted PER CHANNEL (m23-k3 Step 0). Per-channel
        /// and not a single total because the format-0 split fans one `MTrk`
        /// into N parts: a shared total would be copied N times and the report
        /// would over-count by exactly the factor the split exists to create.
        var polyAftertouchCountsByChannel: [Int: Int]
        var warnings: [SMFWarning]
    }

    /// A note-on waiting for its note-off.
    private struct PendingNote {
        let tick: Int
        let velocity: Int
    }

    private static func parseTrack(bytes: [UInt8], start: Int, end: Int,
                                   trackIndex: Int) throws -> RawTrack {
        var cursor = SMFCursor(bytes: bytes, start: start, end: end)
        var tick = 0
        // Running status survives only across CHANNEL messages; SysEx and meta
        // events clear it (SMF 1.0: "Sysex events and meta-events cancel any
        // running status which was in effect").
        var runningStatus: UInt8?
        // Keyed by channel<<8 | note. The VALUE IS A QUEUE, which is what makes
        // AMBIGUITY 1 below expressible at all.
        var open: [Int: [PendingNote]] = [:]
        var notes: [SMFNote] = []
        var controllers: [SMFControllerEvent] = []
        var channels: Set<Int> = []
        var tempoChanges: [SMFTempoEvent] = []
        var timeSignatures: [SMFTimeSignatureEvent] = []
        var programChanges: [SMFProgramChangeEvent] = []
        var polyAftertouchCounts: [Int: Int] = [:]
        var warnings: [SMFWarning] = []
        var name: String?
        var endTick: Int?

        // AMBIGUITY 1 — RE-STRUCK PITCHES PAIR FIFO.
        // The spec does not say what a note-off means when the same pitch on the
        // same channel is already sounding twice. We close the OLDEST open
        // note-on. FIFO over LIFO because it cannot starve: with LIFO, a pitch
        // held down while a trill runs over it keeps having its own note-off
        // stolen by the newer strikes and can be left dangling forever, whereas
        // FIFO retires strikes in the order they arrived and always drains.
        // (The two agree whenever a pitch is struck at most once at a time,
        // which is every fixture here and the overwhelming majority of files.)
        func closeNote(channel: Int, note: Int, releaseVelocity: Int) {
            let key = channel << 8 | note
            guard var queue = open[key], !queue.isEmpty else {
                warnings.append(.unmatchedNoteOff(trackIndex: trackIndex, channel: channel,
                                                  note: note, tick: tick))
                return
            }
            let pending = queue.removeFirst()
            open[key] = queue.isEmpty ? nil : queue
            // Deltas are unsigned, so ticks only ever advance and this cannot go
            // negative; the clamp is belt-and-braces against a future edit.
            notes.append(SMFNote(tick: pending.tick,
                                 lengthTicks: max(0, tick - pending.tick),
                                 note: note,
                                 velocity: pending.velocity,
                                 releaseVelocity: releaseVelocity,
                                 channel: channel))
        }

        while !cursor.isAtEnd {
            let deltaOffset = cursor.offsetInChunk
            switch cursor.variableLengthQuantity() {
            case .value(let delta):
                tick += delta
            case .truncated:
                throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                    byteOffsetInTrack: deltaOffset)
            case .tooLong:
                throw SMFDecodeError.malformedVariableLengthQuantity(
                    trackIndex: trackIndex, byteOffsetInTrack: deltaOffset)
            }

            let eventOffset = cursor.offsetInChunk
            guard let lead = cursor.peek() else {
                throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                    byteOffsetInTrack: eventOffset)
            }
            let status: UInt8
            if lead & 0x80 != 0 {
                status = lead
                cursor.advance(1)
                runningStatus = lead < 0xF0 ? lead : nil
            } else {
                // RUNNING STATUS: the event omits its status byte and inherits
                // the previous channel message's. A reader that assumes every
                // event carries one reads this first DATA byte as a status and
                // desynchronises for the rest of the track.
                guard let inherited = runningStatus else {
                    throw SMFDecodeError.runningStatusWithoutPrecedingStatus(
                        trackIndex: trackIndex, byteOffsetInTrack: eventOffset)
                }
                status = inherited
            }

            if status == 0xFF {
                guard let metaType = cursor.byte() else {
                    throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                        byteOffsetInTrack: eventOffset)
                }
                let length: Int
                switch cursor.variableLengthQuantity() {
                case .value(let value): length = value
                case .truncated:
                    throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                        byteOffsetInTrack: eventOffset)
                case .tooLong:
                    throw SMFDecodeError.malformedVariableLengthQuantity(
                        trackIndex: trackIndex, byteOffsetInTrack: eventOffset)
                }
                guard let payload = cursor.take(length) else {
                    throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                        byteOffsetInTrack: eventOffset)
                }
                switch metaType {
                case 0x2F:  // End of track.
                    endTick = tick
                case 0x51 where length == 3:  // Set tempo, 24-bit big-endian.
                    // VERBATIM microseconds per quarter note. BPM is a lossy
                    // reading of this (666666 µs/qn is 90.000090… BPM), and how
                    // to round it is part of the tempo-map mapping k3 owns.
                    let value = (Int(payload[payload.startIndex]) << 16)
                        | (Int(payload[payload.startIndex + 1]) << 8)
                        | Int(payload[payload.startIndex + 2])
                    tempoChanges.append(SMFTempoEvent(tick: tick,
                                                      microsecondsPerQuarterNote: value,
                                                      sourceTrackIndex: trackIndex))
                case 0x58 where length >= 4:  // Time signature: nn dd cc bb.
                    timeSignatures.append(SMFTimeSignatureEvent(
                        tick: tick,
                        numerator: Int(payload[payload.startIndex]),
                        denominatorPower: Int(payload[payload.startIndex + 1]),
                        clocksPerMetronomeClick: Int(payload[payload.startIndex + 2]),
                        thirtySecondNotesPerQuarter: Int(payload[payload.startIndex + 3]),
                        sourceTrackIndex: trackIndex))
                case 0x03 where name == nil:  // Track name.
                    // FIRST one wins. Later `FF 03`s in the same chunk are the
                    // writer disagreeing with itself; the one at tick 0 is the
                    // name every other program shows.
                    name = decodeText(payload)
                default:
                    // Every other meta event (copyright, lyric, key signature,
                    // SMPTE offset, sequencer-specific…) is skipped BY ITS
                    // LENGTH. It still had to be framed correctly, or the byte
                    // after it would be read as a delta time.
                    break
                }
                if endTick != nil {
                    // Bytes after `FF 2F 00` inside the chunk are padding; the
                    // marker, not the chunk length, ends the track.
                    break
                }
            } else if status == 0xF0 || status == 0xF7 {
                // SysEx (and the "escape" form). Length-prefixed, and skipped —
                // but the length must be read correctly or the stream desyncs.
                let length: Int
                switch cursor.variableLengthQuantity() {
                case .value(let value): length = value
                case .truncated:
                    throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                        byteOffsetInTrack: eventOffset)
                case .tooLong:
                    throw SMFDecodeError.malformedVariableLengthQuantity(
                        trackIndex: trackIndex, byteOffsetInTrack: eventOffset)
                }
                guard cursor.take(length) != nil else {
                    throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                        byteOffsetInTrack: eventOffset)
                }
            } else if status >= 0xF1 {
                // System common / real-time bytes have no meaning inside an
                // `MTrk`; there is no safe length to skip, so the stream is lost.
                throw SMFDecodeError.unexpectedStatusByte(status, trackIndex: trackIndex,
                                                          byteOffsetInTrack: eventOffset)
            } else {
                let channel = Int(status & 0x0F)
                switch status & 0xF0 {
                case 0x80:  // Note off.
                    guard let note = cursor.byte(), let velocity = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    channels.insert(channel)
                    closeNote(channel: channel, note: Int(note),
                              releaseVelocity: Int(velocity))

                case 0x90:  // Note on — or note OFF, if the velocity is zero.
                    guard let note = cursor.byte(), let velocity = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    channels.insert(channel)
                    if velocity == 0 {
                        // NOTE-ON WITH VELOCITY 0 IS A NOTE-OFF. This spelling
                        // exists so a whole passage can ride running status on
                        // one `9n` byte, and it is extremely common. A reader
                        // that treats it as a note-on ends with every onset
                        // dangling and — depending on how it handles that —
                        // zero notes or notes of nonsense length.
                        closeNote(channel: channel, note: Int(note), releaseVelocity: 0)
                    } else {
                        open[channel << 8 | Int(note), default: []]
                            .append(PendingNote(tick: tick, velocity: Int(velocity)))
                    }

                case 0xA0:  // Polyphonic key pressure: 2 data bytes.
                    // Consumed for framing and COUNTED, never kept — per-note
                    // aftertouch is a different model shape, deferred past v1
                    // (the same line `MIDIControllerType` already draws). m23-k3
                    // Step 0 added the count so the loss can be reported instead
                    // of being silent; the VALUES still have nowhere to go. It
                    // does NOT mark the channel as present, so it cannot conjure
                    // an empty part out of a format-0 split.
                    guard cursor.take(2) != nil else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    polyAftertouchCounts[channel, default: 0] += 1

                case 0xB0:  // Control change.
                    guard let controller = cursor.byte(), let value = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    channels.insert(channel)
                    controllers.append(SMFControllerEvent(
                        tick: tick, channel: channel,
                        type: .cc(controller: Int(controller)), value: Int(value)))

                case 0xC0:  // Program change: ONE data byte, not two.
                    // RECORDED since m23-k3 Step 0 — instrument selection is a
                    // mapping decision, and k3 has now said what it means by it
                    // (design §1.2 D3: the part's first program change is the
                    // instrument the file asks for, reported always, applied
                    // only under `instruments: "gm"`). Framing still matters:
                    // reading two bytes here would desynchronise the track.
                    //
                    // It does NOT `channels.insert(channel)` — a bank/program
                    // stamp on an otherwise-silent channel must not conjure an
                    // empty part out of a format-0 split, exactly as poly
                    // pressure must not (pinned by
                    // `discardedOnlyChannelYieldsNoPart`).
                    guard let program = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    programChanges.append(SMFProgramChangeEvent(
                        tick: tick, channel: channel, program: Int(program)))

                case 0xD0:  // Channel pressure: ONE data byte.
                    guard let value = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    channels.insert(channel)
                    controllers.append(SMFControllerEvent(tick: tick, channel: channel,
                                                          type: .channelPressure,
                                                          value: Int(value)))

                default:  // 0xE0 — pitch bend.
                    guard let lsb = cursor.byte(), let msb = cursor.byte() else {
                        throw SMFDecodeError.truncatedEvent(trackIndex: trackIndex,
                                                            byteOffsetInTrack: eventOffset)
                    }
                    channels.insert(channel)
                    // 14-BIT, LSB FIRST. The low 7 bits come first on the wire —
                    // the reverse of almost every other multi-byte field in the
                    // format, and the most commonly reversed decode in it.
                    // Swapping the two turns centre (8192) into 64 and makes
                    // every bend gesture look like a stuck downward one.
                    controllers.append(SMFControllerEvent(tick: tick, channel: channel,
                                                          type: .pitchBend,
                                                          value: (Int(msb) << 7) | Int(lsb)))
                }
            }
        }

        // DECISION 3 — A MISSING END-OF-TRACK MARKER IS A REFUSAL, NOT A WARNING.
        // `FF 2F 00` is mandatory in SMF 1.0, and Apple's loader rejects files
        // without it. Tolerant recovery is defensible in the abstract — some
        // real files omit the marker — but it cannot be done honestly here: the
        // marker is the only thing that distinguishes "the writer forgot it"
        // from "the file was cut off mid-phrase", and in the second case the
        // notes recovered are a fragment presented as a whole song. Refusing
        // says something true; recovering says something that might be false.
        // A lenient mode is deliberately NOT offered rather than offered and
        // untested; adding one later is additive.
        guard let resolvedEndTick = endTick else {
            throw SMFDecodeError.missingEndOfTrack(trackIndex: trackIndex)
        }

        // AMBIGUITY 2 — NOTE-ONS STILL OPEN AT END OF TRACK ARE CLOSED THERE,
        // not dropped, and each one warns. Dropping is the tidier implementation
        // but the worse behaviour: a note the user can see in every other
        // program would silently vanish from ours, which is the same "plausible
        // empty parse" failure this decoder exists to avoid, just smaller. A
        // note closed at `endTick` is visible, is obviously odd, and carries a
        // warning that says exactly what happened. Iteration is over sorted keys
        // so the recovered set does not depend on dictionary order.
        for key in open.keys.sorted() {
            let channel = key >> 8
            let note = key & 0xFF
            for pending in open[key] ?? [] {
                notes.append(SMFNote(tick: pending.tick,
                                     lengthTicks: max(0, resolvedEndTick - pending.tick),
                                     note: note,
                                     velocity: pending.velocity,
                                     releaseVelocity: 0,
                                     channel: channel))
                warnings.append(.danglingNoteOn(trackIndex: trackIndex, channel: channel,
                                                note: note, tick: pending.tick))
            }
        }

        // Pairing order is note-OFF order, which would come back shuffled for
        // any overlapping passage. Sort to a total order so the readout is
        // deterministic; `lengthTicks` breaks the last tie so two simultaneous
        // strikes of one pitch still order stably.
        notes.sort {
            ($0.tick, $0.channel, $0.note, $0.lengthTicks)
                < ($1.tick, $1.channel, $1.note, $1.lengthTicks)
        }

        return RawTrack(index: trackIndex, name: name, notes: notes,
                        controllers: controllers, channels: channels.sorted(),
                        endTick: resolvedEndTick, tempoChanges: tempoChanges,
                        timeSignatures: timeSignatures,
                        programChanges: programChanges,
                        polyAftertouchCountsByChannel: polyAftertouchCounts,
                        warnings: warnings)
    }

    // MARK: - Format 0 / format 1 track shaping

    /// Format 1 and 2: one `MTrk` is one part, however many channels it uses.
    private static func wholeTrack(_ raw: RawTrack) -> SMFTrack {
        SMFTrack(name: raw.name, sourceTrackIndex: raw.index, channels: raw.channels,
                 notes: raw.notes, controllers: raw.controllers, endTick: raw.endTick,
                 programChanges: raw.programChanges,
                 // The whole chunk is one part, so the whole chunk's count rides.
                 polyAftertouchEventCount: raw.polyAftertouchCountsByChannel.values.reduce(0, +))
    }

    /// Format 0: ONE chunk carries all 16 channels, so the parts have to be
    /// carved out of it by channel. This is why format 0 and format 1 differ in
    /// STRUCTURE and not merely in a header field — a decoder that ignores the
    /// channel nibble here returns one track holding every part at once.
    ///
    /// The split keys on channels that carried a RETAINED event (notes, CC,
    /// pitch bend, channel pressure), so a channel-0-only controller file still
    /// yields its one part even with no notes in it, while a stray program
    /// change cannot conjure an empty part. Ascending channel order.
    private static func splitByChannel(_ raw: RawTrack) -> [SMFTrack] {
        raw.channels.map { channel in
            SMFTrack(name: raw.name,
                     sourceTrackIndex: raw.index,
                     channels: [channel],
                     notes: raw.notes.filter { $0.channel == channel },
                     controllers: raw.controllers.filter { $0.channel == channel },
                     endTick: raw.endTick,
                     // Program changes and poly-pressure counts split by channel
                     // exactly like notes and controllers, so summing the parts
                     // never double-counts. A program change addressed to a
                     // channel with NO retained event has no part to land on and
                     // is dropped here — see `SMFTrack.programChanges`.
                     programChanges: raw.programChanges.filter { $0.channel == channel },
                     polyAftertouchEventCount: raw.polyAftertouchCountsByChannel[channel] ?? 0)
        }
    }

    // MARK: - Text

    /// Decodes a meta event's text payload.
    ///
    /// SMF nominally specifies ASCII, but real files carry Latin-1 and UTF-8
    /// alike. UTF-8 is tried first (it is a superset of ASCII and what modern
    /// writers emit); Latin-1 is the fallback because it cannot fail on any byte
    /// sequence, so a name never comes back nil. Bytes are otherwise verbatim —
    /// no trimming, because trimming is the caller's taste, not the file's.
    private static func decodeText(_ payload: ArraySlice<UInt8>) -> String {
        let data = Data(payload)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - Bounds-checked cursor

/// A read cursor over a byte range. Every accessor returns nil (or `.truncated`)
/// at the boundary instead of trapping, which is what lets the decoder answer a
/// malformed file with a sentence rather than a crash.
private struct SMFCursor {
    private let bytes: [UInt8]
    private let chunkStart: Int
    private let end: Int
    var offset: Int

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.chunkStart = start
        self.end = end
        self.offset = start
    }

    var remaining: Int { max(0, end - offset) }
    var isAtEnd: Bool { offset >= end }
    /// Offset from the start of this cursor's range — what an error message
    /// should quote, since "byte 12 of track 2" locates a defect and an absolute
    /// file offset does not.
    var offsetInChunk: Int { offset - chunkStart }

    func peek() -> UInt8? {
        guard offset < end else { return nil }
        return bytes[offset]
    }

    mutating func advance(_ count: Int) {
        offset = min(end, offset + count)
    }

    mutating func byte() -> UInt8? {
        guard offset < end else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return bytes[offset ..< offset + count]
    }

    /// A 4-byte chunk tag. Decoded lossily on purpose: the tag of a chunk that
    /// is not a MIDI chunk may be arbitrary bytes, and the point of reading it
    /// is to QUOTE it back in an error message, so replacement characters beat
    /// a nil that would have to be reported as something vaguer.
    mutating func fourCC() -> String? {
        guard let raw = take(4) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }

    mutating func uint16BE() -> Int? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    mutating func uint32BE() -> Int? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    enum VLQResult {
        case value(Int)
        case truncated
        case tooLong
    }

    /// A variable-length quantity: 7 payload bits per byte, high bit set on
    /// every byte but the last.
    ///
    /// The 4-byte cap is the spec's, not an implementation limit — it is what
    /// makes the encoding self-terminating on hostile input. Deltas really do
    /// use the long forms (a 4-byte VLQ reaches 2^28−1 ticks), so a reader that
    /// gives up after one or two bytes does not merely misread a rare file: it
    /// reads the CONTINUATION byte as the next event's status and loses the rest
    /// of the track.
    mutating func variableLengthQuantity() -> VLQResult {
        var value = 0
        for _ in 0 ..< 4 {
            guard let next = byte() else { return .truncated }
            value = (value << 7) | Int(next & 0x7F)
            if next & 0x80 == 0 { return .value(value) }
        }
        return .tooLong
    }
}
