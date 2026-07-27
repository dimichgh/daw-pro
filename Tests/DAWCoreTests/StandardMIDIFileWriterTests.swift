import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// m23-k2 Standard MIDI File encoder.
///
/// **WHY THIS SUITE IS SHAPED THE WAY IT IS.** Round-tripping through our own
/// decoder is a VACUOUS gate for an encoder: a writer and a reader wrong in
/// mirrored ways round-trip perfectly (write pitch bend MSB-first, read it
/// MSB-first, and every note comes back exactly as it went in — from a file no
/// other program plays correctly). So the evidence here is deliberately
/// asymmetric, in three tiers:
///
/// 1. **The `encode-*.mid` byte pins.** Hand-authored from the SMF 1.0 spec
///    BEFORE this encoder existed, and validated through two independent
///    readers — Apple's `MusicSequenceFileLoad` and DAW Pro's own k1 decoder —
///    which agreed on every value. The encoder was made to match the table; the
///    table was not adjusted to match the encoder. `encodeFixtureBytesAreUnmodified`
///    pins their hashes, which also proves they actually bundle, so no fixture
///    leg below can pass green-by-absence.
///
/// 2. **Per-policy byte assertions** (P1…P12). A byte-pin failure says "these
///    63 bytes are not those 63 bytes"; these say WHICH policy broke. They also
///    reach cases the three pins do not exercise at all — a tempo event whose
///    `sourceTrackIndex` is 1 rather than 0, a named part in a format-0 merge,
///    a meta event in the middle of a running-status run.
///
/// 3. **Our own round trip, as a REGRESSION NET and nothing more** — see
///    `decodeEncodeDecodeIsStableForEveryValidFixture`, which states exactly
///    which direction is being claimed and why the other one is not claimable.
///
/// Everything is in the file's own ticks. Nothing here mentions beats: this
/// layer is tick-native by construction, and converting is m23-k3's job.
@Suite("Standard MIDI File encoder (m23-k2)")
struct StandardMIDIFileWriterTests {

    // MARK: - Fixture loading

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mid",
                              subdirectory: "Fixtures/SMF"),
            "fixture \(name).mid is not in the test bundle — check the resources: declaration on DAWCoreTests in Package.swift")
        return try Data(contentsOf: url)
    }

    // MARK: - Byte helpers

    /// The chunks of a file, in order, as (tag, body) — the shape every
    /// structural assertion below wants.
    private static func chunks(_ data: Data) -> [(tag: String, body: [UInt8])] {
        let bytes = [UInt8](data)
        var result: [(tag: String, body: [UInt8])] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
            let length = (Int(bytes[offset + 4]) << 24) | (Int(bytes[offset + 5]) << 16)
                | (Int(bytes[offset + 6]) << 8) | Int(bytes[offset + 7])
            let start = offset + 8
            guard start + length <= bytes.count else { break }
            result.append((tag, Array(bytes[start ..< start + length])))
            offset = start + length
        }
        return result
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0 ... (haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
            return start
        }
        return nil
    }

    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        for start in 0 ... (haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
            count += 1
        }
        return count
    }

    /// Encodes, returning the `SMFEncodeError` instead of throwing, so a test can
    /// assert the error's TYPE and its MESSAGE in one place. k1's suite made the
    /// point and it holds in this direction too: "it threw" is not evidence that
    /// a person would learn anything.
    private static func encodeError(_ file: StandardMIDIFile,
                                    options: SMFWriteOptions = .init()) -> SMFEncodeError? {
        do {
            _ = try StandardMIDIFileWriter.encode(file, options: options)
            return nil
        } catch let error as SMFEncodeError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - The three input IRs the fixture README specifies

    /// `encode-minimal.mid`: format 1, div 480; part 0 tempo-only (endTick 0);
    /// part 1 "Lead", ch 0, one note tick 0 len 480 n 60 vel 100 relVel 64,
    /// endTick 960; tempo 500000 @ tick 0 src 0.
    private static var minimalIR: StandardMIDIFile {
        StandardMIDIFile(
            format: .simultaneousTracks,
            division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: nil, sourceTrackIndex: 0, channels: [],
                         notes: [], controllers: [], endTick: 0),
                SMFTrack(name: "Lead", sourceTrackIndex: 1, channels: [0],
                         notes: [SMFNote(tick: 0, lengthTicks: 480, note: 60,
                                         velocity: 100, releaseVelocity: 64, channel: 0)],
                         controllers: [], endTick: 960),
            ],
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)],
            timeSignatures: [], warnings: [])
    }

    /// `encode-format0-merge.mid`: the same two-part shape with format 0
    /// requested; part A ch 0 n 60 vel 100 tick 0 len 480 endTick 480; part B
    /// ch 0 n 60 vel 90 tick 480 len 480 endTick 960.
    ///
    /// Deliberately the hardest case in the set: two parts, same channel, same
    /// pitch, one ending exactly where the next begins.
    private static var mergeIR: StandardMIDIFile {
        StandardMIDIFile(
            format: .simultaneousTracks,
            division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0],
                         notes: [SMFNote(tick: 0, lengthTicks: 480, note: 60,
                                         velocity: 100, releaseVelocity: 0, channel: 0)],
                         controllers: [], endTick: 480),
                SMFTrack(name: nil, sourceTrackIndex: 1, channels: [0],
                         notes: [SMFNote(tick: 480, lengthTicks: 480, note: 60,
                                         velocity: 90, releaseVelocity: 0, channel: 0)],
                         controllers: [], endTick: 960),
            ],
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)],
            timeSignatures: [], warnings: [])
    }

    /// `encode-controllers.mid`: format 1, div 480, one track "Ctrl" on channel
    /// 2: cc(11)=84 @0, note 64 vel 100 @0 len 480, pitchBend 2048 @240,
    /// channelPressure 64 @720, endTick 960.
    private static var controllersIR: StandardMIDIFile {
        StandardMIDIFile(
            format: .simultaneousTracks,
            division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: "Ctrl", sourceTrackIndex: 0, channels: [2],
                         notes: [SMFNote(tick: 0, lengthTicks: 480, note: 64,
                                         velocity: 100, releaseVelocity: 0, channel: 2)],
                         controllers: [
                            SMFControllerEvent(tick: 0, channel: 2,
                                               type: .cc(controller: 11), value: 84),
                            SMFControllerEvent(tick: 240, channel: 2,
                                               type: .pitchBend, value: 2048),
                            SMFControllerEvent(tick: 720, channel: 2,
                                               type: .channelPressure, value: 64),
                         ],
                         endTick: 960),
            ],
            tempoChanges: [], timeSignatures: [], warnings: [])
    }

    /// A one-note, one-part file, for the tests that only need something valid
    /// to perturb.
    private static func simpleIR(note: SMFNote, endTick: Int = 960,
                                 name: String? = nil,
                                 controllers: [SMFControllerEvent] = [],
                                 division: SMFDivision = .ticksPerQuarterNote(480),
                                 tempoChanges: [SMFTempoEvent] = [],
                                 timeSignatures: [SMFTimeSignatureEvent] = [])
    -> StandardMIDIFile {
        StandardMIDIFile(format: .simultaneousTracks, division: division,
                         tracks: [SMFTrack(name: name, sourceTrackIndex: 0, channels: [],
                                           notes: [note], controllers: controllers,
                                           endTick: endTick)],
                         tempoChanges: tempoChanges, timeSignatures: timeSignatures,
                         warnings: [])
    }

    private static let plainNote = SMFNote(tick: 0, lengthTicks: 480, note: 60,
                                           velocity: 100, releaseVelocity: 0, channel: 0)

    // MARK: - Fixture integrity

    /// The SHA-256 pins for the three EXPECTED-OUTPUT fixtures.
    ///
    /// Two jobs, and the second is the important one: it proves these bytes are
    /// the ones two independent readers validated, and it proves the resources
    /// actually bundle — a `Bundle.module.url` returning nil would otherwise
    /// make every byte-pin test below vacuous by absence. A changed hash means
    /// the fixture README's expectation table is no longer evidence of anything
    /// until it is re-validated against Apple's loader.
    ///
    /// Kept separate from k1's `fixtureBytesAreUnmodified` (which asserts
    /// `pins.count == 13`) on purpose: those are decoder INPUTS, these are
    /// encoder OUTPUTS, and mixing them would blur what each fixture is for.
    @Test("The 3 encode fixtures load from the bundle with their pinned SHA-256")
    func encodeFixtureBytesAreUnmodified() throws {
        let pins: [String: String] = [
            "encode-minimal":
                "d0e2ffa5372c1398c0402523cbca886bf7518934dfe16be223cc2c1dac6b3b45",
            "encode-format0-merge":
                "f3788d6039921b79d6fa91c90c9bb29c164b05fb924b5e9f8d1aa1edfdd88f38",
            "encode-controllers":
                "c34c5962e03d6c701f2e8341ae50b4642d647851bf737cdfdf5e4c03e21eb59b",
        ]
        #expect(pins.count == 3)
        for (name, expected) in pins.sorted(by: { $0.key < $1.key }) {
            let data = try Self.fixtureData(name)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "fixture \(name).mid has changed on disk")
        }
    }

    // MARK: - The byte pins (gate leg b)

    @Test("encode-minimal.mid — 63 bytes, exactly")
    func minimalMatchesItsBytePin() throws {
        let produced = try StandardMIDIFileWriter.encode(Self.minimalIR)
        #expect(produced.count == 63)
        #expect(produced == (try Self.fixtureData("encode-minimal")))
    }

    @Test("encode-format0-merge.mid — 51 bytes, exactly")
    func format0MergeMatchesItsBytePin() throws {
        let produced = try StandardMIDIFileWriter.encode(Self.mergeIR,
                                                         options: .init(format: .singleTrack))
        #expect(produced.count == 51)
        #expect(produced == (try Self.fixtureData("encode-format0-merge")))
    }

    @Test("encode-controllers.mid — 57 bytes, exactly")
    func controllersMatchesItsBytePin() throws {
        let produced = try StandardMIDIFileWriter.encode(Self.controllersIR)
        #expect(produced.count == 57)
        #expect(produced == (try Self.fixtureData("encode-controllers")))
    }

    // MARK: - P1: a global event lands in the track its sourceTrackIndex names

    /// The three pins all carry `src 0`, so "the track its index names" and
    /// "always the first chunk" both satisfy them. This test is what makes P1
    /// mean anything: a two-part file whose tempo belongs to part 1.
    @Test("P1 — a tempo change with sourceTrackIndex 1 is written into chunk 1, not chunk 0")
    func tempoLandsInTheTrackItsSourceIndexNames() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: "A", sourceTrackIndex: 0, channels: [], notes: [],
                         controllers: [], endTick: 480),
                SMFTrack(name: "B", sourceTrackIndex: 1, channels: [], notes: [],
                         controllers: [], endTick: 480),
            ],
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 400_000,
                                         sourceTrackIndex: 1)],
            timeSignatures: [], warnings: [])
        let chunks = Self.chunks(try StandardMIDIFileWriter.encode(file))
        #expect(chunks.count == 3)  // MThd + 2 MTrk
        #expect(Self.firstIndex(of: [0xFF, 0x51, 0x03], in: chunks[1].body) == nil)
        #expect(Self.firstIndex(of: [0xFF, 0x51, 0x03, 0x06, 0x1A, 0x80],
                                in: chunks[2].body) != nil)
    }

    @Test("P1 — a time signature with sourceTrackIndex 1 is written into chunk 1, not chunk 0")
    func timeSignatureLandsInTheTrackItsSourceIndexNames() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: "A", sourceTrackIndex: 0, channels: [], notes: [],
                         controllers: [], endTick: 480),
                SMFTrack(name: "B", sourceTrackIndex: 1, channels: [], notes: [],
                         controllers: [], endTick: 480),
            ],
            tempoChanges: [],
            timeSignatures: [SMFTimeSignatureEvent(tick: 0, numerator: 6,
                                                   denominatorPower: 3,
                                                   clocksPerMetronomeClick: 24,
                                                   thirtySecondNotesPerQuarter: 8,
                                                   sourceTrackIndex: 1)],
            warnings: [])
        let chunks = Self.chunks(try StandardMIDIFileWriter.encode(file))
        #expect(Self.firstIndex(of: [0xFF, 0x58], in: chunks[1].body) == nil)
        // 6/8, 24 clocks per click, 8 thirty-seconds per quarter.
        #expect(Self.firstIndex(of: [0xFF, 0x58, 0x04, 0x06, 0x03, 0x18, 0x08],
                                in: chunks[2].body) != nil)
    }

    // MARK: - P2 / P3: the note-off spelling and its velocity slot

    /// Two decisions, not one. P2 picks the spelling; P3 picks what goes in the
    /// slot the spelling provides — and `9n`-with-0 has no such slot, which is
    /// why they are separable at all.
    @Test("P2/P3 — a note-off is 8n carrying the release velocity, never 9n with velocity 0")
    func noteOffIsEightNWithTheReleaseVelocity() throws {
        let produced = [UInt8](try StandardMIDIFileWriter.encode(Self.minimalIR))
        // 8n note-off, note 60, release velocity 64 — verbatim from the IR.
        #expect(Self.firstIndex(of: [0x80, 0x3C, 0x40], in: produced) != nil)
        // And emphatically NOT the velocity-0 note-on spelling.
        #expect(Self.firstIndex(of: [0x90, 0x3C, 0x00], in: produced) == nil)
        #expect(Self.occurrences(of: [0x90], in: produced) == 1)
    }

    @Test("P3 — release velocity 0 and release velocity 64 produce different bytes")
    func releaseVelocityIsNotHardcoded() throws {
        let loud = try StandardMIDIFileWriter.encode(Self.simpleIR(
            note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                          releaseVelocity: 96, channel: 0)))
        let silent = try StandardMIDIFileWriter.encode(Self.simpleIR(note: Self.plainNote))
        #expect(Self.firstIndex(of: [0x80, 0x3C, 0x60], in: [UInt8](loud)) != nil)
        #expect(Self.firstIndex(of: [0x80, 0x3C, 0x00], in: [UInt8](silent)) != nil)
        #expect(loud != silent)
    }

    // MARK: - P4: running status is off by default

    @Test("P4 — by default every event carries its status byte, even repeats")
    func runningStatusIsOffByDefault() throws {
        let file = Self.simpleIR(note: Self.plainNote, controllers: [
            SMFControllerEvent(tick: 0, channel: 0, type: .cc(controller: 11), value: 20),
            SMFControllerEvent(tick: 120, channel: 0, type: .cc(controller: 11), value: 40),
            SMFControllerEvent(tick: 240, channel: 0, type: .cc(controller: 11), value: 60),
        ])
        let produced = [UInt8](try StandardMIDIFileWriter.encode(file))
        #expect(Self.occurrences(of: [0xB0, 0x0B], in: produced) == 3)
    }

    // MARK: - P5: the track name leads

    @Test("P5 — the track name is the first event in its chunk, at delta 0")
    func trackNameLeadsItsChunk() throws {
        let file = Self.simpleIR(note: Self.plainNote, name: "Lead")
        let chunks = Self.chunks(try StandardMIDIFileWriter.encode(file))
        let body = chunks[1].body
        #expect(Array(body.prefix(8)) == [0x00, 0xFF, 0x03, 0x04, 0x4C, 0x65, 0x61, 0x64])
        // ...and it really is ahead of the channel events, not merely present.
        let nameAt = try #require(Self.firstIndex(of: [0xFF, 0x03], in: body))
        let noteOnAt = try #require(Self.firstIndex(of: [0x90, 0x3C], in: body))
        #expect(nameAt < noteOnAt)
    }

    @Test("P5 — a nil name emits no FF 03 at all")
    func anUnnamedTrackGetsNoNameEvent() throws {
        let chunks = Self.chunks(try StandardMIDIFileWriter.encode(
            Self.simpleIR(note: Self.plainNote)))
        #expect(Self.firstIndex(of: [0xFF, 0x03], in: chunks[1].body) == nil)
    }

    // MARK: - P6: end-of-track sits at endTick

    /// Trailing silence is meaningful — a two-bar part whose last note stops in
    /// bar one is two bars long, and every other program shows it that way.
    @Test("P6 — end-of-track is written at endTick even when that is past the last note")
    func endOfTrackHonoursTrailingSilence() throws {
        for endTick in [480, 960, 1920] {
            let file = Self.simpleIR(note: Self.plainNote, endTick: endTick)
            let body = Self.chunks(try StandardMIDIFileWriter.encode(file))[1].body
            let markerAt = try #require(Self.firstIndex(of: [0xFF, 0x2F, 0x00], in: body))
            // The delta immediately preceding the marker is endTick − 480 (the
            // note-off's tick), variable-length encoded.
            let expectedDelta = try #require(
                StandardMIDIFileWriter.variableLengthQuantity(endTick - 480))
            #expect(Array(body[(markerAt - expectedDelta.count) ..< markerAt]) == expectedDelta,
                    "end-of-track delta wrong for endTick \(endTick)")
            #expect(markerAt + 3 == body.count, "end-of-track is not the last event")
        }
    }

    // MARK: - P7 / P8 / P9: the format-0 merge

    @Test("P7 — format 0 writes exactly one MTrk however many parts went in")
    func formatZeroMergesEveryPartIntoOneChunk() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: (0 ..< 3).map { channel in
                SMFTrack(name: nil, sourceTrackIndex: channel, channels: [channel],
                         notes: [SMFNote(tick: channel * 480, lengthTicks: 480,
                                         note: 60 + channel * 4, velocity: 100,
                                         releaseVelocity: 0, channel: channel)],
                         controllers: [], endTick: 1920)
            },
            tempoChanges: [], timeSignatures: [], warnings: [])
        let data = try StandardMIDIFileWriter.encode(file, options: .init(format: .singleTrack))
        let chunks = Self.chunks(data)
        #expect(chunks.count == 2)
        #expect(chunks[0].tag == "MThd")
        #expect(chunks[1].tag == "MTrk")
        // Header: format 0, one track.
        #expect(Array(chunks[0].body) == [0x00, 0x00, 0x00, 0x01, 0x01, 0xE0])
        // P12 — every channel nibble survived the merge.
        #expect(Self.firstIndex(of: [0x90, 0x3C], in: chunks[1].body) != nil)
        #expect(Self.firstIndex(of: [0x91, 0x40], in: chunks[1].body) != nil)
        #expect(Self.firstIndex(of: [0x92, 0x44], in: chunks[1].body) != nil)
        // And the round trip recovers three parts, one per channel.
        let reread = try StandardMIDIFileReader.decode(data)
        #expect(reread.tracks.map(\.channels) == [[0], [1], [2]])
    }

    /// The hazard `encode-format0-merge.mid` exists for. Both parts are on
    /// channel 0 and both play note 60; part A ends exactly where part B begins.
    /// Emit B's note-on before A's note-off and the file is STILL VALID SMF —
    /// but any reader pairs the wrong events and gets a zero-length note plus a
    /// dangling one. Apple's loader shows the same two notes we do.
    @Test("P8 — at an equal tick the note-off comes before the note-on, ACROSS merged parts")
    func mergedNoteOffPrecedesTheNoteOnAtTheSameTick() throws {
        let data = try StandardMIDIFileWriter.encode(Self.mergeIR,
                                                     options: .init(format: .singleTrack))
        let body = Self.chunks(data)[1].body
        let offAt = try #require(Self.firstIndex(of: [0x80, 0x3C, 0x00], in: body))
        let secondOnAt = try #require(Self.firstIndex(of: [0x90, 0x3C, 0x5A], in: body))
        #expect(offAt < secondOnAt)
        // The discriminator: two whole notes, not a zero-length one and a
        // dangling one.
        let reread = try StandardMIDIFileReader.decode(data)
        #expect(reread.tracks.count == 1)
        #expect(reread.tracks[0].notes == [
            SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                    releaseVelocity: 0, channel: 0),
            SMFNote(tick: 480, lengthTicks: 480, note: 60, velocity: 90,
                    releaseVelocity: 0, channel: 0),
        ])
        #expect(reread.warnings.isEmpty)
    }

    @Test("P8 — at an equal tick the order is meta, then controller, then note-on")
    func equalTickOrderIsMetaControllerNoteOn() throws {
        let body = Self.chunks(try StandardMIDIFileWriter.encode(Self.controllersIR))[1].body
        let nameAt = try #require(Self.firstIndex(of: [0xFF, 0x03], in: body))
        let ccAt = try #require(Self.firstIndex(of: [0xB2, 0x0B, 0x54], in: body))
        let noteOnAt = try #require(Self.firstIndex(of: [0x92, 0x40, 0x64], in: body))
        #expect(nameAt < ccAt)
        #expect(ccAt < noteOnAt)
    }

    @Test("P9 — a merged track ends at the LATEST part's endTick")
    func mergedEndOfTrackIsTheMaximumEndTick() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: [],
                         controllers: [], endTick: 240),
                SMFTrack(name: nil, sourceTrackIndex: 1, channels: [1], notes: [],
                         controllers: [], endTick: 7680),
                SMFTrack(name: nil, sourceTrackIndex: 2, channels: [2], notes: [],
                         controllers: [], endTick: 1920),
            ],
            tempoChanges: [], timeSignatures: [], warnings: [])
        let data = try StandardMIDIFileWriter.encode(file, options: .init(format: .singleTrack))
        let body = Self.chunks(data)[1].body
        // Delta 7680 (= 60 << 7, so `BC 00`) then the marker, and nothing else
        // in the chunk. Not 240, not 1920, and not the first part's end.
        #expect(body == [0xBC, 0x00, 0xFF, 0x2F, 0x00])
    }

    /// The three pins have no names in the merge case, so "first non-nil" and
    /// "drop every name" both satisfy them. This picks one and pins it.
    @Test("Format-0 merge keeps the FIRST non-nil part name")
    func formatZeroMergeKeepsTheFirstNonNilName() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: [],
                         controllers: [], endTick: 480),
                SMFTrack(name: "Bass", sourceTrackIndex: 1, channels: [1], notes: [],
                         controllers: [], endTick: 480),
                SMFTrack(name: "Pad", sourceTrackIndex: 2, channels: [2], notes: [],
                         controllers: [], endTick: 480),
            ],
            tempoChanges: [], timeSignatures: [], warnings: [])
        let data = try StandardMIDIFileWriter.encode(file, options: .init(format: .singleTrack))
        let body = Self.chunks(data)[1].body
        #expect(Self.occurrences(of: [0xFF, 0x03], in: body) == 1)
        #expect(Self.firstIndex(of: Array("Bass".utf8), in: body) != nil)
        #expect(Self.firstIndex(of: Array("Pad".utf8), in: body) == nil)
    }

    // MARK: - P10 / P11 / P12: the controller messages

    /// The most commonly reversed decode in the whole format, and the one that
    /// a round-trip gate cannot see at all: swap the bytes on both sides and
    /// every note comes back perfect from a file nothing else plays right.
    @Test("P10 — pitch bend is 14-bit, LSB first")
    func pitchBendIsLSBFirst() throws {
        // value, expected (lsb, msb)
        let cases: [(Int, UInt8, UInt8)] = [
            (0, 0x00, 0x00),
            (2048, 0x00, 0x10),      // the encode-controllers pin
            (8192, 0x00, 0x40),      // centre
            (8193, 0x01, 0x40),      // one above centre — asymmetric, so a swap shows
            (16383, 0x7F, 0x7F),
        ]
        for (value, lsb, msb) in cases {
            let file = Self.simpleIR(note: Self.plainNote, controllers: [
                SMFControllerEvent(tick: 0, channel: 0, type: .pitchBend, value: value),
            ])
            let produced = [UInt8](try StandardMIDIFileWriter.encode(file))
            #expect(Self.firstIndex(of: [0xE0, lsb, msb], in: produced) != nil,
                    "pitch bend \(value) should encode as E0 \(lsb) \(msb)")
        }
    }

    @Test("P11 — channel pressure is a two-byte message")
    func channelPressureIsTwoBytes() throws {
        let file = Self.simpleIR(note: Self.plainNote, controllers: [
            SMFControllerEvent(tick: 240, channel: 0, type: .channelPressure, value: 64),
        ])
        let body = Self.chunks(try StandardMIDIFileWriter.encode(file))[1].body
        let at = try #require(Self.firstIndex(of: [0xD0, 0x40], in: body))
        // The byte after the two-byte message is the NEXT event's delta time.
        // A stray third data byte here would be read as that delta and
        // desynchronise everything after it.
        #expect(body[at + 2] == 0x81)  // delta 240 from tick 240 to the note-off at 480
    }

    @Test("P12 — every message takes its channel nibble from the event")
    func channelNibbleComesFromTheEvent() throws {
        for channel in 0 ... 15 {
            let file = Self.simpleIR(
                note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                              releaseVelocity: 0, channel: channel),
                controllers: [
                    SMFControllerEvent(tick: 0, channel: channel,
                                       type: .cc(controller: 11), value: 20),
                    SMFControllerEvent(tick: 120, channel: channel,
                                       type: .pitchBend, value: 8192),
                    SMFControllerEvent(tick: 240, channel: channel,
                                       type: .channelPressure, value: 64),
                ])
            let produced = [UInt8](try StandardMIDIFileWriter.encode(file))
            let nibble = UInt8(channel)
            #expect(Self.firstIndex(of: [0x90 | nibble, 0x3C, 0x64], in: produced) != nil)
            #expect(Self.firstIndex(of: [0x80 | nibble, 0x3C, 0x00], in: produced) != nil)
            #expect(Self.firstIndex(of: [0xB0 | nibble, 0x0B, 0x14], in: produced) != nil)
            #expect(Self.firstIndex(of: [0xE0 | nibble, 0x00, 0x40], in: produced) != nil)
            #expect(Self.firstIndex(of: [0xD0 | nibble, 0x40], in: produced) != nil)
        }
    }

    // MARK: - Running status, when it IS asked for

    @Test("Running status ON elides a repeated status byte and keeps the data bytes")
    func runningStatusElidesRepeatedStatusBytes() throws {
        // No notes: three consecutive control changes on one channel, so all
        // three really are a run. (With a note in the middle the note-on's `90`
        // interrupts it and only one elision is available — which is the
        // encoder behaving correctly, not the test finding a bug.)
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: [],
                              controllers: [
                                SMFControllerEvent(tick: 0, channel: 0,
                                                   type: .cc(controller: 11), value: 20),
                                SMFControllerEvent(tick: 120, channel: 0,
                                                   type: .cc(controller: 11), value: 40),
                                SMFControllerEvent(tick: 240, channel: 0,
                                                   type: .cc(controller: 11), value: 60),
                              ],
                              endTick: 480)],
            tempoChanges: [], timeSignatures: [], warnings: [])
        let plain = try StandardMIDIFileWriter.encode(file)
        let terse = try StandardMIDIFileWriter.encode(file,
                                                      options: .init(useRunningStatus: true))
        // Two `B0` bytes saved: the first CC still carries its status.
        #expect(Self.occurrences(of: [0xB0, 0x0B], in: [UInt8](terse)) == 1)
        #expect(terse.count == plain.count - 2)
        // And it still says the same thing.
        #expect(try StandardMIDIFileReader.decode(terse)
                == (try StandardMIDIFileReader.decode(plain)))
    }

    /// The rule an encoder forgets silently, because forgetting it produces
    /// byte-perfect output for every file whose only meta event is a name at
    /// tick 0 — which is all three byte pins. SMF 1.0: "Sysex events and
    /// meta-events cancel any running status which was in effect."
    @Test("Running status ON — a meta event between two identical messages cancels it")
    func metaEventCancelsRunningStatus() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: [],
                              controllers: [
                                SMFControllerEvent(tick: 0, channel: 0,
                                                   type: .cc(controller: 11), value: 20),
                                SMFControllerEvent(tick: 480, channel: 0,
                                                   type: .cc(controller: 11), value: 40),
                              ],
                              endTick: 960)],
            tempoChanges: [SMFTempoEvent(tick: 240, microsecondsPerQuarterNote: 400_000,
                                         sourceTrackIndex: 0)],
            timeSignatures: [], warnings: [])
        let terse = try StandardMIDIFileWriter.encode(file,
                                                      options: .init(useRunningStatus: true))
        // BOTH control changes must carry `B0`: the tempo event in between
        // cancelled the running status the second one would otherwise inherit.
        #expect(Self.occurrences(of: [0xB0, 0x0B], in: [UInt8](terse)) == 2)
        // Belt and braces — a reader that DOES honour the cancellation gets the
        // same two events back.
        let reread = try StandardMIDIFileReader.decode(terse)
        #expect(reread.tracks[0].controllers.map(\.value) == [20, 40])
        #expect(reread.tempoChanges.map(\.microsecondsPerQuarterNote) == [400_000])
    }

    @Test("Running status ON does not elide across a change of status byte")
    func runningStatusDoesNotElideAcrossDifferentStatuses() throws {
        let file = Self.simpleIR(note: Self.plainNote, controllers: [
            SMFControllerEvent(tick: 120, channel: 0, type: .cc(controller: 11), value: 20),
            SMFControllerEvent(tick: 240, channel: 1, type: .cc(controller: 11), value: 20),
        ])
        let terse = [UInt8](try StandardMIDIFileWriter.encode(
            file, options: .init(useRunningStatus: true)))
        #expect(Self.firstIndex(of: [0xB0, 0x0B, 0x14], in: terse) != nil)
        #expect(Self.firstIndex(of: [0xB1, 0x0B, 0x14], in: terse) != nil)
    }

    // MARK: - Formats and division

    @Test("A nil options format reuses the IR's own")
    func nilFormatKeepsTheIRsFormat() throws {
        for format in [SMFFormat.singleTrack, .simultaneousTracks, .independentSequences] {
            let file = StandardMIDIFile(
                format: format, division: .ticksPerQuarterNote(480),
                tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0],
                                  notes: [Self.plainNote], controllers: [], endTick: 960)],
                tempoChanges: [], timeSignatures: [], warnings: [])
            let header = Self.chunks(try StandardMIDIFileWriter.encode(file))[0].body
            #expect(Array(header.prefix(2)) == [0x00, UInt8(format.rawValue)])
        }
    }

    @Test("Format 1 from a decoded format-0 file writes one chunk per channel part")
    func formatOneFromAFormatZeroIR() throws {
        let source = try StandardMIDIFileReader.decode(
            try Self.fixtureData("hazard-type0-multichannel"))
        #expect(source.format == .singleTrack)
        #expect(source.tracks.count == 3)
        let data = try StandardMIDIFileWriter.encode(
            source, options: .init(format: .simultaneousTracks))
        let chunks = Self.chunks(data)
        #expect(chunks.count == 4)  // MThd + 3 MTrk
        #expect(Array(chunks[0].body.prefix(4)) == [0x00, 0x01, 0x00, 0x03])
        let reread = try StandardMIDIFileReader.decode(data)
        #expect(reread.format == .simultaneousTracks)
        #expect(reread.tracks.map(\.notes) == source.tracks.map(\.notes))
        #expect(reread.tracks.map(\.channels) == [[0], [1], [2]])
    }

    /// Format 2 is structurally identical to format 1 — one `MTrk` per part —
    /// and differs only in the header word and in what a reader may assume about
    /// whether the parts play together. Both facts are asserted, because
    /// "supports format 2" would otherwise be satisfied by writing format 1
    /// bytes with a 2 in the header.
    @Test("Format 2 is format 1's structure with a different header word")
    func formatTwoIsStructurallyFormatOne() throws {
        let file = Self.minimalIR
        let asOne = try StandardMIDIFileWriter.encode(
            file, options: .init(format: .simultaneousTracks))
        let asTwo = try StandardMIDIFileWriter.encode(
            file, options: .init(format: .independentSequences))
        #expect(asOne.count == asTwo.count)
        #expect(Self.chunks(asTwo)[0].body == [0x00, 0x02, 0x00, 0x02, 0x01, 0xE0])
        #expect(Self.chunks(asTwo).map(\.body).dropFirst()
                == Self.chunks(asOne).map(\.body).dropFirst())
        let reread = try StandardMIDIFileReader.decode(asTwo)
        #expect(reread.format == .independentSequences)
        #expect(reread.tracks.count == 2)
        #expect(reread.tracks[1].notes == file.tracks[1].notes)
    }

    @Test("SMPTE division survives encoding, in the spec's two's-complement form")
    func smpteDivisionSurvivesEncoding() throws {
        let cases: [(Int, Int, [UInt8])] = [
            (24, 80, [0xE8, 0x50]),
            (25, 40, [0xE7, 0x28]),   // the k1 hazard fixture's division
            (29, 30, [0xE3, 0x1E]),
            (30, 4, [0xE2, 0x04]),
        ]
        for (fps, ticksPerFrame, expected) in cases {
            let file = Self.simpleIR(note: SMFNote(tick: 0, lengthTicks: 1000, note: 60,
                                                   velocity: 100, releaseVelocity: 0,
                                                   channel: 0),
                                     endTick: 1000,
                                     division: .smpte(framesPerSecond: fps,
                                                      ticksPerFrame: ticksPerFrame))
            let data = try StandardMIDIFileWriter.encode(file)
            #expect(Array(Self.chunks(data)[0].body.suffix(2)) == expected,
                    "\(fps) fps x \(ticksPerFrame) ticks/frame")
            #expect(try StandardMIDIFileReader.decode(data).division
                    == .smpte(framesPerSecond: fps, ticksPerFrame: ticksPerFrame))
        }
    }

    // MARK: - The zero-length note

    /// A note of length 0 is legal in the IR — the decoder keeps it verbatim
    /// because "nudging is a musical decision, and this layer makes none" — and
    /// it is the one case where P8's note-off-before-note-on rule would destroy
    /// the note it is meant to protect. No fixture covers it; k3 will produce it
    /// the first time a user drags a clip edge onto its own start.
    @Test("A zero-length note keeps its own note-off AFTER its own note-on")
    func zeroLengthNoteSurvivesTheOrderingRule() throws {
        let file = Self.simpleIR(note: SMFNote(tick: 240, lengthTicks: 0, note: 60,
                                               velocity: 100, releaseVelocity: 0, channel: 0))
        let data = try StandardMIDIFileWriter.encode(file)
        let body = Self.chunks(data)[1].body
        let onAt = try #require(Self.firstIndex(of: [0x90, 0x3C, 0x64], in: body))
        let offAt = try #require(Self.firstIndex(of: [0x80, 0x3C, 0x00], in: body))
        #expect(onAt < offAt)
        let reread = try StandardMIDIFileReader.decode(data)
        #expect(reread.tracks[0].notes == [file.tracks[0].notes[0]])
        #expect(reread.warnings.isEmpty)
    }

    /// The follow-on hazard: a zero-length note struck at the same tick, on the
    /// same pitch and channel, as a long one. The decoder pairs re-struck
    /// pitches FIFO, so the shortest note-on must be emitted FIRST or the
    /// zero-length note-off closes the wrong onset and both notes come back with
    /// the wrong lengths.
    @Test("A zero-length note beside a long one on the same pitch closes its own onset")
    func zeroLengthNoteBesideALongOneOnTheSamePitch() throws {
        let short = SMFNote(tick: 240, lengthTicks: 0, note: 60, velocity: 100,
                            releaseVelocity: 0, channel: 0)
        let long = SMFNote(tick: 240, lengthTicks: 480, note: 60, velocity: 80,
                           releaseVelocity: 0, channel: 0)
        for notes in [[short, long], [long, short]] {
            let file = StandardMIDIFile(
                format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
                tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0],
                                  notes: notes, controllers: [], endTick: 960)],
                tempoChanges: [], timeSignatures: [], warnings: [])
            let reread = try StandardMIDIFileReader.decode(
                try StandardMIDIFileWriter.encode(file))
            #expect(reread.tracks[0].notes.map(\.lengthTicks) == [0, 480])
            #expect(reread.warnings.isEmpty)
        }
    }

    /// Overlapping notes of DIFFERENT lengths on one pitch, in the order the
    /// note-offs must come back out.
    @Test("Overlapping same-pitch notes keep their lengths through a round trip")
    func overlappingSamePitchNotesKeepTheirLengths() throws {
        let notes = [
            SMFNote(tick: 0, lengthTicks: 240, note: 60, velocity: 100,
                    releaseVelocity: 0, channel: 0),
            SMFNote(tick: 0, lengthTicks: 720, note: 60, velocity: 90,
                    releaseVelocity: 0, channel: 0),
        ]
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: notes,
                              controllers: [], endTick: 960)],
            tempoChanges: [], timeSignatures: [], warnings: [])
        let reread = try StandardMIDIFileReader.decode(try StandardMIDIFileWriter.encode(file))
        #expect(reread.tracks[0].notes.map(\.lengthTicks) == [240, 720])
        #expect(reread.tracks[0].notes.map(\.velocity) == [100, 90])
    }

    // MARK: - The within-meta order

    /// Unpinned by the spec and unpinned by the three fixtures. Chosen once,
    /// here, so it cannot drift with `sort`'s (unguaranteed) stability.
    @Test("At an equal tick the meta order is name, then tempo, then time signature")
    func metaOrderAtAnEqualTickIsNameTempoTimeSignature() throws {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [SMFTrack(name: "Meta", sourceTrackIndex: 0, channels: [], notes: [],
                              controllers: [], endTick: 480)],
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)],
            timeSignatures: [SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                                   clocksPerMetronomeClick: 24,
                                                   thirtySecondNotesPerQuarter: 8,
                                                   sourceTrackIndex: 0)],
            warnings: [])
        let body = Self.chunks(try StandardMIDIFileWriter.encode(file))[1].body
        let nameAt = try #require(Self.firstIndex(of: [0xFF, 0x03], in: body))
        let tempoAt = try #require(Self.firstIndex(of: [0xFF, 0x51], in: body))
        let meterAt = try #require(Self.firstIndex(of: [0xFF, 0x58], in: body))
        #expect(nameAt < tempoAt)
        #expect(tempoAt < meterAt)
    }

    // MARK: - Variable-length quantities

    @Test("Variable-length quantities match the SMF 1.0 table")
    func variableLengthQuantitiesMatchTheSpec() {
        // The spec's own worked examples, plus the deltas the pins use.
        let table: [(Int, [UInt8])] = [
            (0x00000000, [0x00]),
            (0x00000040, [0x40]),
            (0x0000007F, [0x7F]),
            (0x00000080, [0x81, 0x00]),
            (0x000000F0, [0x81, 0x70]),        // 240 — the encode-controllers delta
            (0x000001E0, [0x83, 0x60]),        // 480 — the encode-minimal delta
            (0x00002000, [0xC0, 0x00]),
            (0x00003FFF, [0xFF, 0x7F]),
            (0x00004000, [0x81, 0x80, 0x00]),
            (0x00100000, [0xC0, 0x80, 0x00]),
            (0x001FFFFF, [0xFF, 0xFF, 0x7F]),
            (0x00200000, [0x81, 0x80, 0x80, 0x00]),
            (0x08000000, [0xC0, 0x80, 0x80, 0x00]),
            (0x0FFFFFFF, [0xFF, 0xFF, 0xFF, 0x7F]),
        ]
        for (value, expected) in table {
            #expect(StandardMIDIFileWriter.variableLengthQuantity(value) == expected,
                    "VLQ of \(value)")
        }
        // Past the spec's 4-byte cap there is no encoding — nil, not a wrap.
        #expect(StandardMIDIFileWriter.variableLengthQuantity(0x1000_0000) == nil)
        #expect(StandardMIDIFileWriter.variableLengthQuantity(-1) == nil)
    }

    // MARK: - The round trip, as a REGRESSION NET and not as proof

    /// **THIS IS NOT THE GATE.** It is a cheap net that catches a later edit
    /// breaking one side, and it is worth exactly that much: a writer and a
    /// reader wrong in mirrored ways pass it every time. The load-bearing
    /// evidence is the byte pins above and Apple's loader outside the build.
    ///
    /// The direction claimed is `decode → encode → decode` IR-STABILITY. The
    /// other direction, `encode → decode → encode` byte-stability, is NOT
    /// claimable in general and is not asserted anywhere:
    ///
    /// - k1 parses program change and polyphonic aftertouch for framing and
    ///   then DISCARDS them, so they cannot be written back;
    /// - unknown chunks are skipped by length and not retained, so
    ///   `hazard-unknown-chunk.mid` loses its `XFIR` chunk;
    /// - `8n`-with-velocity-0 and `9n`-with-velocity-0 decode identically, so a
    ///   file spelled the second way comes back spelled the first;
    /// - `encode-format0-merge.mid` decodes to ONE part, not the two encoded,
    ///   because format 0 splits by CHANNEL and both parts are on channel 0.
    ///
    /// Even the direction claimed has a limit worth naming: notes NESTED inside
    /// another note of the same pitch on the same channel are not representable
    /// in note-on/note-off at all, so FIFO re-pairing changes them. None of the
    /// fixtures contains that case, and no encoder can fix it.
    @Test("Regression net — decode, encode, decode is stable for every valid fixture")
    func decodeEncodeDecodeIsStableForEveryValidFixture() throws {
        let names = ["apple-type1", "hazard-controllers", "hazard-note-on-vel0",
                     "hazard-running-status", "hazard-smpte-division",
                     "hazard-type0-multichannel", "hazard-unknown-chunk",
                     "hazard-vlq-multibyte"]
        #expect(names.count == 8)
        for name in names {
            let first = try StandardMIDIFileReader.decode(try Self.fixtureData(name))
            for useRunningStatus in [false, true] {
                let second = try StandardMIDIFileReader.decode(
                    try StandardMIDIFileWriter.encode(
                        first, options: .init(useRunningStatus: useRunningStatus)))
                #expect(second.format == first.format, "\(name) format")
                #expect(second.division == first.division, "\(name) division")
                #expect(second.tracks == first.tracks, "\(name) tracks")
                #expect(second.tempoChanges == first.tempoChanges, "\(name) tempo")
                #expect(second.timeSignatures == first.timeSignatures, "\(name) meter")
                #expect(second.warnings.isEmpty, "\(name) re-decode warnings")
            }
        }
    }

    /// Pins the asymmetry the fixture README names, so nobody later "fixes" it.
    @Test("Decoding the format-0 merge pin gives ONE part, not the two encoded")
    func formatZeroMergeDecodesToOnePart() throws {
        let reread = try StandardMIDIFileReader.decode(try Self.fixtureData("encode-format0-merge"))
        #expect(Self.mergeIR.tracks.count == 2)
        #expect(reread.tracks.count == 1)
        #expect(reread.tracks[0].channels == [0])
        #expect(reread.tracks[0].notes.count == 2)
    }

    // MARK: - Refusals

    // The IR's fields are bare `Int`s with no range enforcement, so a hand-built
    // file — or one k3 assembles from project data — can ask for something the
    // format cannot express. Each test below asserts the error CASE and that the
    // MESSAGE names what and where, because a refusal a person cannot act on is
    // only marginally better than a corrupt file.

    @Test("Refusal — a file with no tracks")
    func refusesAFileWithNoTracks() {
        let file = StandardMIDIFile(format: .simultaneousTracks,
                                    division: .ticksPerQuarterNote(480), tracks: [],
                                    tempoChanges: [], timeSignatures: [], warnings: [])
        let error = Self.encodeError(file)
        #expect(error == .noTracks)
        #expect(error?.description.contains("at least one track") == true)
    }

    @Test("Refusal — a note number outside 0...127")
    func refusesAnOutOfRangeNoteNumber() {
        for note in [-1, 128, 255] {
            let error = Self.encodeError(Self.simpleIR(
                note: SMFNote(tick: 120, lengthTicks: 480, note: note, velocity: 100,
                              releaseVelocity: 0, channel: 0)))
            #expect(error == .noteNumberOutOfRange(trackIndex: 0, tick: 120, note: note))
            #expect(error?.description.contains("tick 120") == true)
            #expect(error?.description.contains("0 to 127") == true)
        }
    }

    /// The nastiest value in the whole refusal set. `9n nn 00` is not an invalid
    /// file — it is a valid file in which the note has become a note-OFF and
    /// vanished, and every reader on earth opens it without complaint.
    @Test("Refusal — a note-on velocity of 0, which would silently delete the note")
    func refusesVelocityZero() {
        let error = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 0,
                          releaseVelocity: 0, channel: 0)))
        #expect(error == .noteOnVelocityOutOfRange(trackIndex: 0, tick: 0, note: 60,
                                                   velocity: 0))
        #expect(error?.description.contains("switched OFF") == true)
        #expect(error?.description.contains("1 to 127") == true)
    }

    @Test("Refusal — a note-on velocity above 127")
    func refusesVelocityAbove127() {
        let error = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 128,
                          releaseVelocity: 0, channel: 0)))
        #expect(error == .noteOnVelocityOutOfRange(trackIndex: 0, tick: 0, note: 60,
                                                   velocity: 128))
        #expect(error?.description.contains("128") == true)
    }

    @Test("Refusal — a release velocity outside 0...127 (but 0 itself is fine)")
    func refusesAnOutOfRangeReleaseVelocity() throws {
        for velocity in [-1, 128] {
            let error = Self.encodeError(Self.simpleIR(
                note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                              releaseVelocity: velocity, channel: 0)))
            #expect(error == .releaseVelocityOutOfRange(trackIndex: 0, tick: 0, note: 60,
                                                        velocity: velocity))
            #expect(error?.description.contains("release velocity") == true)
        }
        // 0 is the ordinary "no release information" value, not an error.
        #expect(throws: Never.self) {
            try StandardMIDIFileWriter.encode(Self.simpleIR(note: Self.plainNote))
        }
    }

    @Test("Refusal — a MIDI channel outside 0...15")
    func refusesAnOutOfRangeChannel() {
        let noteError = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 16)))
        #expect(noteError == .channelOutOfRange(trackIndex: 0, tick: 0, channel: 16))
        #expect(noteError?.description.contains("channels 1-16") == true)

        let controllerError = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            controllers: [SMFControllerEvent(tick: 60, channel: -1,
                                             type: .cc(controller: 11), value: 20)]))
        #expect(controllerError == .channelOutOfRange(trackIndex: 0, tick: 60, channel: -1))
    }

    @Test("Refusal — a negative tick, on whichever kind of event carries it")
    func refusesANegativeTick() {
        let note = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: -1, lengthTicks: 480, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0)))
        #expect(note == .negativeTick(trackIndex: 0, tick: -1, bearer: .note))
        #expect(note?.description.contains("a note") == true)

        let controller = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            controllers: [SMFControllerEvent(tick: -8, channel: 0,
                                             type: .pitchBend, value: 8192)]))
        #expect(controller == .negativeTick(trackIndex: 0, tick: -8, bearer: .controller))

        let tempo = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            tempoChanges: [SMFTempoEvent(tick: -2, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)]))
        #expect(tempo == .negativeTick(trackIndex: 0, tick: -2, bearer: .tempoChange))

        let meter = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            timeSignatures: [SMFTimeSignatureEvent(tick: -3, numerator: 4,
                                                   denominatorPower: 2,
                                                   clocksPerMetronomeClick: 24,
                                                   thirtySecondNotesPerQuarter: 8,
                                                   sourceTrackIndex: 0)]))
        #expect(meter == .negativeTick(trackIndex: 0, tick: -3, bearer: .timeSignature))

        let end = Self.encodeError(StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [SMFTrack(name: nil, sourceTrackIndex: 0, channels: [], notes: [],
                              controllers: [], endTick: -5)],
            tempoChanges: [], timeSignatures: [], warnings: []))
        #expect(end == .negativeTick(trackIndex: 0, tick: -5, bearer: .endOfTrack))
        #expect(end?.description.contains("end-of-track marker") == true)
    }

    @Test("Refusal — a negative note length")
    func refusesANegativeNoteLength() {
        let error = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 480, lengthTicks: -240, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0)))
        #expect(error == .negativeNoteLength(trackIndex: 0, tick: 480, note: 60,
                                             lengthTicks: -240))
        #expect(error?.description.contains("end before it began") == true)
    }

    @Test("Refusal — more tracks than the header's 16-bit ntrks can count")
    func refusesMoreThan65535Tracks() throws {
        func file(trackCount: Int, format: SMFFormat) -> StandardMIDIFile {
            StandardMIDIFile(
                format: format, division: .ticksPerQuarterNote(480),
                tracks: (0 ..< trackCount).map {
                    SMFTrack(name: nil, sourceTrackIndex: $0, channels: [], notes: [],
                             controllers: [], endTick: 0)
                },
                tempoChanges: [], timeSignatures: [], warnings: [])
        }

        // 65535 is the largest honest header, and the count really is written
        // as 0xFFFF rather than masked from something larger.
        let atLimit = try StandardMIDIFileWriter.encode(file(trackCount: 0xFFFF,
                                                             format: .simultaneousTracks))
        #expect(Array(atLimit[10 ... 11]) == [0xFF, 0xFF])
        #expect(Self.chunks(atLimit).filter { $0.tag == "MTrk" }.count == 0xFFFF)

        // One more masks to an ntrks of 0 — a header that lies about its own
        // contents, which is the whole reason this refuses instead of writing.
        let error = Self.encodeError(file(trackCount: 0x1_0000, format: .simultaneousTracks))
        #expect(error == .tooManyTracks(count: 0x1_0000))
        #expect(error?.description.contains("at most 65535") == true)

        // FORMAT-DEPENDENT ON PURPOSE, and pinned so it is not mistaken for a
        // leak: format 0 merges every part into ONE chunk, so the same oversized
        // IR encodes fine and its ntrks of 1 is the truth about that file.
        // Contrast `endTickBeforeLastEvent`, which is about an IR disagreeing
        // with itself and so is refused under every format.
        let merged = try StandardMIDIFileWriter.encode(file(trackCount: 0x1_0000,
                                                            format: .singleTrack))
        #expect(Array(merged[10 ... 11]) == [0x00, 0x01])
    }

    @Test("Refusal — a note whose end tick overflows Int")
    func refusesANoteEndTickThatOverflows() {
        // Not a hypothetical: before this guard existed, BOTH of these inputs
        // trapped (SIGTRAP on the `tick + lengthTicks` addition) instead of
        // refusing. The IR's ticks are bare `Int`s with nothing enforcing a
        // range, so a hand-built or importer-built IR can reach here — and a
        // trap inside a pure-model type kills the app rather than showing a
        // message. Every OTHER refusal test probes a boundary at ±1; this one
        // probes where `Int` itself gives out.
        let atMax = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: Int.max, lengthTicks: 1, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0),
            endTick: Int.max))
        #expect(atMax == .noteEndTickOverflows(trackIndex: 0, tick: Int.max, note: 60,
                                               lengthTicks: 1))
        #expect(atMax?.description.contains("past the largest position") == true)

        // Symmetrical: a long note starting late enough to wrap.
        let longNote = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 1, lengthTicks: Int.max, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0),
            endTick: Int.max))
        #expect(longNote == .noteEndTickOverflows(trackIndex: 0, tick: 1, note: 60,
                                                  lengthTicks: Int.max))

        // The neighbouring case that does NOT overflow must still be refused,
        // by the OTHER error — `Int.max` ticks is representable arithmetic and
        // an unwritable gap. Distinguishing the two is the point of a separate
        // case: an overflow check that swallowed this one would be a ceiling.
        let representable = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: 0, lengthTicks: Int.max, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0),
            endTick: Int.max))
        #expect(representable == .deltaTimeTooLarge(trackIndex: 0, delta: Int.max))
    }

    @Test("Refusal — endTick before the track's last event")
    func refusesAnEndTickBeforeTheLastEvent() {
        // The note-off lands at 480; the marker claims the track stopped at 240.
        let error = Self.encodeError(Self.simpleIR(note: Self.plainNote, endTick: 240))
        #expect(error == .endTickBeforeLastEvent(trackIndex: 0, endTick: 240,
                                                 lastEventTick: 480))
        #expect(error?.description.contains("cannot come before its last note") == true)

        // And it fires for a hoisted tempo event past the marker too — P1 puts
        // that event INTO the track, so it counts as one of the track's events.
        let tempo = Self.encodeError(Self.simpleIR(
            note: Self.plainNote, endTick: 960,
            tempoChanges: [SMFTempoEvent(tick: 5000, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)]))
        #expect(tempo == .endTickBeforeLastEvent(trackIndex: 0, endTick: 960,
                                                 lastEventTick: 5000))
    }

    /// Checked per INPUT PART and independently of the requested format: which
    /// IRs are legal must not depend on which output you happen to want.
    @Test("Refusal — endTick before the last event fires under format 0 as well")
    func refusesAnEndTickBeforeTheLastEventUnderFormatZero() {
        let file = StandardMIDIFile(
            format: .simultaneousTracks, division: .ticksPerQuarterNote(480),
            tracks: [
                SMFTrack(name: nil, sourceTrackIndex: 0, channels: [0], notes: [],
                         controllers: [], endTick: 100_000),
                SMFTrack(name: nil, sourceTrackIndex: 1, channels: [1],
                         notes: [Self.plainNote], controllers: [], endTick: 240),
            ],
            tempoChanges: [], timeSignatures: [], warnings: [])
        #expect(Self.encodeError(file, options: .init(format: .singleTrack))
                == .endTickBeforeLastEvent(trackIndex: 1, endTick: 240, lastEventTick: 480))
    }

    @Test("Refusal — a CC number outside 0...127")
    func refusesAnOutOfRangeControllerNumber() {
        let error = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            controllers: [SMFControllerEvent(tick: 0, channel: 0,
                                             type: .cc(controller: 200), value: 20)]))
        #expect(error == .controllerNumberOutOfRange(trackIndex: 0, tick: 0, controller: 200))
        #expect(error?.description.contains("control change #200") == true)
    }

    /// The ranges come from `MIDIControllerType.valueRange` — ONE home, shared
    /// with the lane model that already clamps to it — so this test walks every
    /// controller type rather than restating numbers.
    @Test("Refusal — a controller value outside its own type's valueRange")
    func refusesAnOutOfRangeControllerValue() {
        let types: [MIDIControllerType] = [.cc(controller: 11), .pitchBend, .channelPressure]
        for type in types {
            let range = type.valueRange
            for value in [range.lowerBound - 1, range.upperBound + 1] {
                let error = Self.encodeError(Self.simpleIR(
                    note: Self.plainNote,
                    controllers: [SMFControllerEvent(tick: 96, channel: 0,
                                                     type: type, value: value)]))
                #expect(error == .controllerValueOutOfRange(trackIndex: 0, tick: 96,
                                                            type: type, value: value))
                #expect(error?.description.contains(type.wireKey) == true)
                #expect(error?.description
                    .contains("\(range.lowerBound)-\(range.upperBound)") == true)
            }
            // The extremes themselves must still encode.
            #expect(throws: Never.self) {
                try StandardMIDIFileWriter.encode(Self.simpleIR(
                    note: Self.plainNote,
                    controllers: [SMFControllerEvent(tick: 96, channel: 0, type: type,
                                                     value: range.upperBound)]))
            }
        }
    }

    /// `FF 51 03` is a THREE-byte payload. 2²⁴ and up do not fail to write —
    /// they truncate, and produce a well-formed file playing at a tempo nobody
    /// asked for.
    @Test("Refusal — microseconds per quarter note outside 1...0xFFFFFF")
    func refusesAnUnrepresentableTempo() throws {
        for value in [0, -1, 0x100_0000, 0x100_0001] {
            let error = Self.encodeError(Self.simpleIR(
                note: Self.plainNote,
                tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: value,
                                             sourceTrackIndex: 0)]))
            #expect(error == .tempoOutOfRange(trackIndex: 0, tick: 0,
                                              microsecondsPerQuarterNote: value))
            #expect(error?.description.contains("three bytes") == true)
        }
        // The boundary itself writes, as `FF FF FF`.
        let edge = try StandardMIDIFileWriter.encode(Self.simpleIR(
            note: Self.plainNote,
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 0xFF_FFFF,
                                         sourceTrackIndex: 0)]))
        #expect(Self.firstIndex(of: [0xFF, 0x51, 0x03, 0xFF, 0xFF, 0xFF],
                                in: [UInt8](edge)) != nil)
    }

    @Test("Refusal — a time-signature byte outside 0...255")
    func refusesAnOutOfRangeTimeSignatureByte() {
        let cases: [(SMFEncodeError.TimeSignatureField, SMFTimeSignatureEvent, Int)] = [
            (.numerator,
             SMFTimeSignatureEvent(tick: 0, numerator: 256, denominatorPower: 2,
                                   clocksPerMetronomeClick: 24,
                                   thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0), 256),
            (.denominatorPower,
             SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: -1,
                                   clocksPerMetronomeClick: 24,
                                   thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0), -1),
            (.clocksPerMetronomeClick,
             SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                   clocksPerMetronomeClick: 999,
                                   thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0), 999),
            (.thirtySecondNotesPerQuarter,
             SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                   clocksPerMetronomeClick: 24,
                                   thirtySecondNotesPerQuarter: 300, sourceTrackIndex: 0), 300),
        ]
        for (field, signature, value) in cases {
            let error = Self.encodeError(Self.simpleIR(note: Self.plainNote,
                                                       timeSignatures: [signature]))
            #expect(error == .timeSignatureByteOutOfRange(trackIndex: 0, tick: 0,
                                                          field: field, value: value))
            #expect(error?.description.contains("single byte") == true)
        }
        // `denominatorPower: 255` is a byte, so it writes — 2^255 is not an
        // `Int`, which is exactly why the IR stores the raw power.
        #expect(throws: Never.self) {
            try StandardMIDIFileWriter.encode(Self.simpleIR(
                note: Self.plainNote,
                timeSignatures: [SMFTimeSignatureEvent(
                    tick: 0, numerator: 4, denominatorPower: 255,
                    clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                    sourceTrackIndex: 0)]))
        }
    }

    @Test("Refusal — a global event naming a track that does not exist")
    func refusesAnOutOfRangeSourceTrackIndex() {
        let tempo = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 3)]))
        #expect(tempo == .sourceTrackIndexOutOfRange(kind: .tempoChange, tick: 0,
                                                     sourceTrackIndex: 3, trackCount: 1))
        #expect(tempo?.description.contains("nowhere to write it") == true)

        let meter = Self.encodeError(Self.simpleIR(
            note: Self.plainNote,
            timeSignatures: [SMFTimeSignatureEvent(tick: 96, numerator: 4,
                                                   denominatorPower: 2,
                                                   clocksPerMetronomeClick: 24,
                                                   thirtySecondNotesPerQuarter: 8,
                                                   sourceTrackIndex: -1)]))
        #expect(meter == .sourceTrackIndexOutOfRange(kind: .timeSignature, tick: 96,
                                                     sourceTrackIndex: -1, trackCount: 1))
    }

    @Test("Refusal — a delta that will not fit a 4-byte variable-length quantity")
    func refusesAnUnrepresentableDelta() throws {
        let tick = 0x1000_0000  // one past the 4-byte VLQ ceiling
        let error = Self.encodeError(Self.simpleIR(
            note: SMFNote(tick: tick, lengthTicks: 0, note: 60, velocity: 100,
                          releaseVelocity: 0, channel: 0),
            endTick: tick))
        #expect(error == .deltaTimeTooLarge(trackIndex: 0, delta: tick))
        #expect(error?.description.contains("268435455") == true)
        // One tick below the ceiling still writes.
        #expect(throws: Never.self) {
            try StandardMIDIFileWriter.encode(Self.simpleIR(
                note: SMFNote(tick: 0x0FFF_FFFF, lengthTicks: 0, note: 60, velocity: 100,
                              releaseVelocity: 0, channel: 0),
                endTick: 0x0FFF_FFFF))
        }
    }

    @Test("Refusal — a division no MThd word can hold")
    func refusesAnUnrepresentableDivision() {
        for tpqn in [0, -1, 32768, 65535] {
            let error = Self.encodeError(Self.simpleIR(
                note: Self.plainNote, division: .ticksPerQuarterNote(tpqn)))
            #expect(error == .invalidTicksPerQuarterNote(tpqn))
            #expect(error?.description.contains("1 and 32767") == true)
        }
        for fps in [0, 23, 26, 60, -25] {
            let error = Self.encodeError(Self.simpleIR(
                note: Self.plainNote,
                division: .smpte(framesPerSecond: fps, ticksPerFrame: 40)))
            #expect(error == .invalidSMPTEFrameRate(fps))
            #expect(error?.description.contains("24, 25, 29 or 30") == true)
        }
        for ticks in [0, -1, 256] {
            let error = Self.encodeError(Self.simpleIR(
                note: Self.plainNote,
                division: .smpte(framesPerSecond: 25, ticksPerFrame: ticks)))
            #expect(error == .invalidSMPTETicksPerFrame(ticks))
            #expect(error?.description.contains("1 and 255") == true)
        }
        // 32767 is the last legal tick count — bit 15 must stay clear.
        #expect(throws: Never.self) {
            try StandardMIDIFileWriter.encode(Self.simpleIR(
                note: Self.plainNote, division: .ticksPerQuarterNote(32767)))
        }
    }

    // MARK: - Round-out

    @Test("write(_:to:) puts the same bytes on disk that encode(_:) returns")
    func writeToDiskMatchesEncode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23k2-\(UUID().uuidString).mid")
        defer { try? FileManager.default.removeItem(at: url) }
        try StandardMIDIFileWriter.write(Self.minimalIR, to: url)
        #expect(try Data(contentsOf: url) == (try Self.fixtureData("encode-minimal")))
    }

    @Test("Encoding is deterministic — the same IR twice gives the same bytes")
    func encodingIsDeterministic() throws {
        for _ in 0 ..< 8 {
            #expect(try StandardMIDIFileWriter.encode(Self.controllersIR)
                    == (try Self.fixtureData("encode-controllers")))
        }
    }
}
