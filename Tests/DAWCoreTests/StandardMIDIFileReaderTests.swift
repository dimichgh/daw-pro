import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// m23-k1 Standard MIDI File decoder.
///
/// TWO KINDS OF EVIDENCE, deliberately not mixed:
///
/// 1. **Checked-in byte fixtures** under `Fixtures/SMF/`. `apple-type1.mid` came
///    out of Apple's `MusicSequenceFileCreate`; every `hazard-*`/`malformed-*`
///    file was hand-authored from the SMF 1.0 spec and then read back with
///    `MusicSequenceFileLoad` to confirm Apple sees what the bytes intend. That
///    third-party confirmation is the whole value of the directory, so these are
///    never regenerated with our own writer (the vacuity trap the fixture
///    README exists to name) and `fixtureBytesAreUnmodified` pins their hashes.
///
/// 2. **Inline byte literals**, in the AMBIGUITIES and STRUCTURE sections. These
///    pin decisions the spec leaves open and framing rules no fixture covers.
///    They are NOT fixtures and carry no third-party backing — they say "we
///    chose this", not "Apple agrees". The `SoundFontPresetReaderTests`
///    precedent for synthesizing bytes in-test.
///
/// The decoder is tick-native: every expectation below is in the file's own
/// ticks. Nothing here mentions beats, because converting is m23-k3's job.
@Suite("Standard MIDI File decoder (m23-k1)")
struct StandardMIDIFileReaderTests {

    // MARK: - Fixture loading

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mid",
                              subdirectory: "Fixtures/SMF"),
            "fixture \(name).mid is not in the test bundle — check the resources: declaration on DAWCoreTests in Package.swift")
        return try Data(contentsOf: url)
    }

    private static func decodeFixture(_ name: String) throws -> StandardMIDIFile {
        try StandardMIDIFileReader.decode(fixtureData(name))
    }

    /// Decodes, returning the `SMFDecodeError` instead of throwing, so a test can
    /// assert the error's TYPE and its MESSAGE in one place. Leg (d) asks for
    /// both: "it threw" is not evidence that a person would learn anything.
    private static func decodeError(_ data: Data) -> SMFDecodeError? {
        do {
            _ = try StandardMIDIFileReader.decode(data)
            return nil
        } catch let error as SMFDecodeError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Fixture integrity

    /// The SHA-256 pins from the fixture README's Integrity section.
    ///
    /// This test does two jobs at once, and the second is the important one:
    /// it proves the resources are actually BUNDLED (a `Bundle.module.url`
    /// returning nil would otherwise make every fixture test below vacuous by
    /// absence), and it proves the bytes are the ones Apple's loader validated.
    /// A changed hash means the expectation table is no longer evidence of
    /// anything until it is re-validated.
    @Test("All 13 fixtures load from the bundle with their pinned SHA-256")
    func fixtureBytesAreUnmodified() throws {
        let pins: [String: String] = [
            "apple-type1": "019c62ea7df93baa5bc676db48d5483fd18983fb13f8b31e55cdfbc9b88463ee",
            "hazard-controllers": "100ef2212bf09cd56868bdadcdc690a52b75d1be038601705d1de65f5c25d640",
            "hazard-note-on-vel0": "465397bdaab21c1b190585eb265cda43f7156e766a953428fe256b0bbc2c9c14",
            "hazard-running-status": "0575b50e18cbd78fd9b58124b0453af5d9725a68ea870025d6a249e627016f69",
            "hazard-smpte-division": "979ac37dda586cf7536c5a406a81db11cf99b10d140064b61f72187d50762e6a",
            "hazard-type0-multichannel": "e24511e09a32ee8a2acde06fee670c0850bbb7a13e3b738d379dd42011ad8abe",
            "hazard-unknown-chunk": "689d38f9237cec1a4a1ed15fc22d39053bd0326bc05edfec338e20d722f27a11",
            "hazard-vlq-multibyte": "cf0205f58ef01e8d7ffdcf64ee1287129516ac09b0de6e1e6c827e00ec25e091",
            "malformed-bad-magic": "cb21e94fb5a6840dd47a1bf047864c1112266e81a15845f4189fd78bb0495b53",
            "malformed-empty": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "malformed-no-end-of-track": "fc1c3183d4fde5b72e1576e0a05b573f45f27872b5d271573b441ccc08584b5c",
            "malformed-truncated-header": "7ed5302ab537819c49fb41c3670d2080240a3c05af841b51bb04ced49d11f4a1",
            "malformed-truncated-track": "3a5e40b676b670408fc772925656dbe82d3ff4a86065413fc34afeaa361b535c",
        ]
        #expect(pins.count == 13)
        for (name, expected) in pins.sorted(by: { $0.key < $1.key }) {
            let data = try Self.fixtureData(name)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "fixture \(name).mid has changed on disk")
        }
    }

    // MARK: - Leg (a): Apple's own encoder

    /// `apple-type1.mid`, straight out of `MusicSequenceFileCreate`.
    ///
    /// NOTE ON EVIDENCE: the fixture README's expectation table has rows only for
    /// the hand-authored `hazard-*` files; there is no Apple row. The numbers
    /// below were therefore DERIVED FROM THE BYTES (which are Apple's), not read
    /// off a third-party-confirmed table. What Apple's authorship buys here is
    /// that the SHAPE is a real encoder's, not ours.
    ///
    /// Also the reason this expects THREE tracks: Apple's chunk 0 is the tempo
    /// map and carries no channel events at all. It is kept as a track with no
    /// channels rather than filtered away, because filtering is a mapping choice
    /// and mapping is k3's.
    @Test("(a) Apple's type-1 file: 3 chunks, 8 notes, 6 CC points, 2 tempo changes")
    func appleType1() throws {
        let file = try Self.decodeFixture("apple-type1")

        #expect(file.format == .simultaneousTracks)
        #expect(file.division == .ticksPerQuarterNote(480))
        #expect(file.warnings.isEmpty)
        #expect(file.timeSignatures.isEmpty)

        // Microseconds per quarter note, VERBATIM: 0x07A120 = 500000 (120 BPM)
        // and 0x0A2C2A = 666666. Deliberately not 90 BPM — 666666 µs/qn is
        // 90.000090… BPM, and that rounding is k3's to decide, not ours.
        #expect(file.tempoChanges == [
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500000, sourceTrackIndex: 0),
            SMFTempoEvent(tick: 1920, microsecondsPerQuarterNote: 666666, sourceTrackIndex: 0),
        ])

        #expect(file.tracks.count == 3)

        let tempoMap = file.tracks[0]
        #expect(tempoMap.channels.isEmpty)
        #expect(tempoMap.channel == nil)
        #expect(tempoMap.notes.isEmpty)
        #expect(tempoMap.controllers.isEmpty)
        #expect(tempoMap.endTick == 1920)

        // Both musical chunks are the same figure a fifth apart: four notes on a
        // 480-tick grid, each 240 ticks long, with expression (CC 11) stepping
        // 20 → 60 → 100 under the first three.
        for (index, channel, firstPitch) in [(1, 0, 60), (2, 1, 48)] {
            let track = file.tracks[index]
            #expect(track.sourceTrackIndex == index)
            #expect(track.channels == [channel])
            #expect(track.channel == channel)
            #expect(track.endTick == 1680)
            #expect(track.notes == [
                SMFNote(tick: 0, lengthTicks: 240, note: firstPitch,
                        velocity: 70, releaseVelocity: 0, channel: channel),
                SMFNote(tick: 480, lengthTicks: 240, note: firstPitch + 2,
                        velocity: 80, releaseVelocity: 0, channel: channel),
                SMFNote(tick: 960, lengthTicks: 240, note: firstPitch + 4,
                        velocity: 90, releaseVelocity: 0, channel: channel),
                SMFNote(tick: 1440, lengthTicks: 240, note: firstPitch + 6,
                        velocity: 100, releaseVelocity: 0, channel: channel),
            ])
            #expect(track.controllers == [
                SMFControllerEvent(tick: 0, channel: channel,
                                   type: .cc(controller: 11), value: 20),
                SMFControllerEvent(tick: 240, channel: channel,
                                   type: .cc(controller: 11), value: 60),
                SMFControllerEvent(tick: 480, channel: channel,
                                   type: .cc(controller: 11), value: 100),
            ])
        }
    }

    // MARK: - Leg (b): one hazard per fixture

    /// HAZARD: events after the first omit their status byte. A reader that
    /// assumes every event carries one reads the `3E` of `83 60 3E 64` as a
    /// status byte and desynchronises for the rest of the track.
    @Test("(b) running status: three overlapping notes, all inheriting one 0x90")
    func hazardRunningStatus() throws {
        let file = try Self.decodeFixture("hazard-running-status")

        #expect(file.format == .singleTrack)
        #expect(file.division == .ticksPerQuarterNote(480))
        #expect(file.warnings.isEmpty)
        #expect(file.tempoChanges == [
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500000, sourceTrackIndex: 0)
        ])
        // 4/4: `dd` is a NEGATIVE POWER OF TWO, so the raw byte 2 means 4.
        #expect(file.timeSignatures == [
            SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24,
                                  thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0)
        ])
        #expect(file.timeSignatures[0].denominator == 4)

        let track = try #require(file.tracks.first)
        #expect(file.tracks.count == 1)
        // The three note-offs also ride running status (`00 3E 40`, `00 40 40`),
        // so their release velocity of 64 is itself proof the inheritance held
        // through the second half of the track.
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 1440, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0),
            SMFNote(tick: 480, lengthTicks: 960, note: 62,
                    velocity: 100, releaseVelocity: 64, channel: 0),
            SMFNote(tick: 960, lengthTicks: 480, note: 64,
                    velocity: 100, releaseVelocity: 64, channel: 0),
        ])
        #expect(track.endTick == 1440)
    }

    /// HAZARD: note-off written as note-on with velocity 0. A reader that treats
    /// it as a note-on ends with four dangling onsets and no releases at all.
    @Test("(b) note-on velocity 0 is a note-off: two notes, not four onsets")
    func hazardNoteOnVelocityZero() throws {
        let file = try Self.decodeFixture("hazard-note-on-vel0")

        let track = try #require(file.tracks.first)
        #expect(file.tracks.count == 1)
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 240, note: 60,
                    velocity: 100, releaseVelocity: 0, channel: 0),
            SMFNote(tick: 240, lengthTicks: 480, note: 64,
                    velocity: 80, releaseVelocity: 0, channel: 0),
        ])
        #expect(track.endTick == 720)
        // The discriminating half: a reader that mistook these for note-ons
        // would leave every one of them open, so a clean parse means NO dangling
        // warnings, not merely two notes.
        #expect(file.warnings.isEmpty)
    }

    /// HAZARD: format 0 puts every channel in ONE chunk. Type 0 and type 1 differ
    /// in structure, not just in a header field — a reader that ignores the
    /// channel nibble returns one track holding all three parts at once.
    @Test("(b) type 0 splits by channel: one chunk becomes three parts")
    func hazardType0MultiChannel() throws {
        let file = try Self.decodeFixture("hazard-type0-multichannel")

        #expect(file.format == .singleTrack)
        #expect(file.tracks.count == 3)
        // All three parts came out of chunk 0 — that shared source index is how
        // a caller tells a split apart from three real chunks.
        #expect(file.tracks.allSatisfy { $0.sourceTrackIndex == 0 })
        #expect(file.tracks.map(\.channel) == [0, 1, 2])

        let expected = [(0, 60, 100), (1, 64, 80), (2, 67, 96)]
        for (track, spec) in zip(file.tracks, expected) {
            let (channel, pitch, velocity) = spec
            #expect(track.channels == [channel])
            #expect(track.endTick == 480)
            #expect(track.notes == [
                SMFNote(tick: 0, lengthTicks: 480, note: pitch,
                        velocity: velocity, releaseVelocity: 64, channel: channel)
            ])
        }
    }

    /// HAZARD: deltas needing 2-, 3- and 4-byte VLQs. Apple's own encoder never
    /// exceeds 2 bytes, so this is precisely the shape its fixture cannot gate.
    @Test("(b) multi-byte VLQ: deltas of 128, 16384 and 2097152 ticks")
    func hazardMultiByteVLQ() throws {
        let file = try Self.decodeFixture("hazard-vlq-multibyte")

        let track = try #require(file.tracks.first)
        // 16512 = 128 + 16384 (a 3-byte VLQ) and 2113792 = 16640 + 2097152 (a
        // 4-byte one). Both are stored as TICKS; at 480 tpqn they are beats
        // 34.4 and 4403.7334, but that division is k3's to apply, not ours.
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 128, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0),
            SMFNote(tick: 16512, lengthTicks: 128, note: 62,
                    velocity: 100, releaseVelocity: 64, channel: 0),
            SMFNote(tick: 2113792, lengthTicks: 128, note: 64,
                    velocity: 100, releaseVelocity: 64, channel: 0),
        ])
        #expect(track.endTick == 2113920)
        #expect(file.warnings.isEmpty)
    }

    /// HAZARD: pitch bend is 14-bit LSB FIRST — the reverse of nearly every other
    /// multi-byte field in the format, and the most commonly reversed decode in
    /// it. Swapping the bytes turns centre (8192) into 64.
    @Test("(b) controllers: CC, pitch bend LSB-first, and channel pressure")
    func hazardControllers() throws {
        let file = try Self.decodeFixture("hazard-controllers")

        #expect(file.tracks.count == 1)
        let track = try #require(file.tracks.first)
        // A format-0 file with ZERO notes still yields its part: the split keys
        // on any retained channel event, not on notes.
        #expect(track.notes.isEmpty)
        #expect(track.channels == [0])
        #expect(track.controllers == [
            SMFControllerEvent(tick: 0, channel: 0, type: .cc(controller: 11), value: 20),
            SMFControllerEvent(tick: 240, channel: 0, type: .cc(controller: 11), value: 84),
            // `E0 00 40` — LSB 0, MSB 64 ⇒ (64 << 7) | 0 = 8192, dead centre.
            // Byte-swapped it would read (0 << 7) | 64 = 64, hard down.
            SMFControllerEvent(tick: 480, channel: 0, type: .pitchBend, value: 8192),
            // `E0 7F 7F` ⇒ 16383, full up. Symmetric in both bytes ON PURPOSE:
            // it pins the RANGE while the 8192 case pins the ORDER.
            SMFControllerEvent(tick: 720, channel: 0, type: .pitchBend, value: 16383),
            SMFControllerEvent(tick: 960, channel: 0, type: .channelPressure, value: 64),
        ])
        #expect(track.endTick == 960)
        // Values land inside the vocabulary the project model already uses.
        for event in track.controllers {
            #expect(event.type.valueRange.contains(event.value))
        }
    }

    /// HAZARD: the spec REQUIRES unknown chunks be skipped by their length. A
    /// reader that errors here rejects files other DAWs write happily.
    @Test("(b) unknown chunk: XFIR is stepped over, the MTrk behind it is read")
    func hazardUnknownChunk() throws {
        let file = try Self.decodeFixture("hazard-unknown-chunk")

        #expect(file.tracks.count == 1)
        let track = try #require(file.tracks.first)
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 480, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0)
        ])
        // Skipping is normal, not an anomaly — no warning is raised for it.
        #expect(file.warnings.isEmpty)
    }

    /// HAZARD: SMPTE division. `0xE728` is a NEGATIVE frame rate in the high
    /// byte (−25 fps) and ticks-per-frame in the low byte (40) — 1000 ticks per
    /// second of ABSOLUTE time. Read as an unsigned tpqn it is 59176.
    ///
    /// This is the one row the fixture README marks NOT third-party-confirmed:
    /// Apple accepts the file but reads it degenerately (beat −0.0000), because
    /// its beat-native model cannot represent absolute time. That degeneracy is
    /// itself the argument for this IR being tick-native, so the assertion is
    /// against the spec.
    @Test("(b) SMPTE division recorded verbatim, not mistaken for a large tpqn")
    func hazardSMPTEDivision() throws {
        let file = try Self.decodeFixture("hazard-smpte-division")

        #expect(file.division == .smpte(framesPerSecond: 25, ticksPerFrame: 40))
        // Explicitly NOT the unsigned misread, which is the whole hazard.
        #expect(file.division != .ticksPerQuarterNote(59176))
        // No set-tempo event anywhere: under SMPTE division, tempo is irrelevant
        // to timing. Ticks stay ticks.
        #expect(file.tempoChanges.isEmpty)

        let track = try #require(file.tracks.first)
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 1000, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0)
        ])
        #expect(track.endTick == 1000)
    }

    // MARK: - Leg (d): malformed files give teaching errors

    @Test("(d) empty file")
    func malformedEmpty() throws {
        let error = Self.decodeError(try Self.fixtureData("malformed-empty"))
        #expect(error == .emptyFile)
        #expect(error?.description.contains("empty") == true)
        // The message must say what a MIDI file looks like, or the user learns
        // nothing they can act on.
        #expect(error?.description.contains("14 bytes") == true)
    }

    @Test("(d) truncated header: MThd with a 3-byte length field")
    func malformedTruncatedHeader() throws {
        let error = Self.decodeError(try Self.fixtureData("malformed-truncated-header"))
        #expect(error == .truncatedHeader(availableBytes: 7))
        #expect(error?.description.contains("header is incomplete") == true)
        #expect(error?.description.contains("7 byte") == true)
    }

    /// Apple reports a DIFFERENT status for this one (−10870) than for the rest
    /// (−10871), and the reason is worth preserving: this file is not a damaged
    /// MIDI file, it is not a MIDI file. Our error draws the same line.
    @Test("(d) bad magic: MThX is 'not a MIDI file', a distinct error from damage")
    func malformedBadMagic() throws {
        let error = Self.decodeError(try Self.fixtureData("malformed-bad-magic"))
        #expect(error == .missingHeaderChunk(foundTag: "MThX"))
        #expect(error?.description.contains("not a MIDI file") == true)
        #expect(error?.description.contains("MThX") == true)
        #expect(error != .truncatedHeader(availableBytes: 14))
    }

    @Test("(d) truncated track: MTrk claims 100 bytes, 3 remain")
    func malformedTruncatedTrack() throws {
        let error = Self.decodeError(try Self.fixtureData("malformed-truncated-track"))
        #expect(error == .truncatedChunk(tag: "MTrk", declaredLength: 100, availableBytes: 3))
        #expect(error?.description.contains("100 bytes") == true)
        #expect(error?.description.contains("cut short") == true)
    }

    /// DECISION 3, pinned: a missing `FF 2F 00` is a REFUSAL.
    ///
    /// The fixture README flags this as a judgement call — tolerant
    /// recovery-with-warning would also be defensible, and some real files do
    /// omit the marker. Strict rejection is chosen because the marker is the
    /// only thing distinguishing "the writer forgot it" from "the file was cut
    /// off mid-phrase", and in the second case the recovered notes are a
    /// fragment presented as a whole song. It also matches Apple, and matches
    /// this file's placement in the malformed set.
    ///
    /// The unacceptable outcome — silently returning the notes as though the
    /// file were fine — is asserted against directly below.
    @Test("(d) missing end-of-track is refused, NOT silently recovered")
    func malformedNoEndOfTrack() throws {
        let data = try Self.fixtureData("malformed-no-end-of-track")
        let error = Self.decodeError(data)
        #expect(error == .missingEndOfTrack(trackIndex: 0))
        #expect(error?.description.contains("end-of-track marker") == true)

        // The file DOES contain a complete, parseable note (60 at tick 0, off at
        // 480). Returning it would look entirely plausible, which is exactly why
        // the refusal has to be asserted as a refusal.
        var decoded: StandardMIDIFile?
        decoded = try? StandardMIDIFileReader.decode(data)
        #expect(decoded == nil)
    }

    // MARK: - Structure: bytes no fixture covers
    //
    // Inline literals from here down. These pin framing rules and our own
    // decisions; they carry no third-party backing and are not fixtures.

    private static func fourCC(_ tag: String) -> [UInt8] { Array(tag.utf8) }

    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func u32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Assembles a syntactically well-formed SMF around the given `MTrk` bodies.
    private static func midiFile(format: Int = 0, declaredTracks: Int? = nil,
                                 division: Int = 480, trackBodies: [[UInt8]],
                                 trailing: [UInt8] = []) -> Data {
        var bytes = fourCC("MThd") + u32(6) + u16(format)
            + u16(declaredTracks ?? trackBodies.count) + u16(division)
        for body in trackBodies {
            bytes += fourCC("MTrk") + u32(body.count) + body
        }
        return Data(bytes + trailing)
    }

    private static let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

    // MARK: AMBIGUITY 1 — re-struck pitches pair FIFO

    /// The spec does not say what a note-off means when the same pitch on the
    /// same channel is already sounding twice. We close the OLDEST open note-on.
    ///
    /// FIFO over LIFO because FIFO cannot starve: with LIFO, a pitch held under
    /// a trill keeps having its own note-off stolen by newer strikes and can be
    /// left dangling forever. The two agree whenever a pitch sounds at most once
    /// at a time, which is every fixture here and nearly every real file.
    ///
    /// This test DISCRIMINATES: under LIFO the same bytes give lengths 720/240
    /// with the velocities swapped onto the wrong onsets.
    @Test("AMBIGUITY 1: a re-struck pitch pairs FIFO — oldest onset closes first")
    func reStruckPitchPairsFIFO() throws {
        let body: [UInt8] = [
            0x00, 0x90, 0x3C, 0x40,        // tick 0:   on 60, velocity 64
            0x81, 0x70, 0x90, 0x3C, 0x50,  // tick 240: on 60 AGAIN, velocity 80
            0x81, 0x70, 0x80, 0x3C, 0x00,  // tick 480: off 60
            0x81, 0x70, 0x80, 0x3C, 0x00,  // tick 720: off 60
        ] + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        let track = try #require(file.tracks.first)

        #expect(track.notes == [
            // The tick-0 strike (velocity 64) takes the tick-480 release.
            SMFNote(tick: 0, lengthTicks: 480, note: 60,
                    velocity: 64, releaseVelocity: 0, channel: 0),
            // The tick-240 strike (velocity 80) takes the tick-720 release.
            SMFNote(tick: 240, lengthTicks: 480, note: 60,
                    velocity: 80, releaseVelocity: 0, channel: 0),
        ])
        // LIFO would produce these instead — asserted against so the choice is
        // pinned rather than merely described.
        #expect(track.notes.map(\.lengthTicks) != [720, 240])
        #expect(file.warnings.isEmpty)
    }

    // MARK: AMBIGUITY 2 — note-ons open at end of track

    /// Closed at `endTick` and warned about, NOT dropped.
    ///
    /// Dropping is the tidier implementation and the worse behaviour: a note the
    /// user can see in every other program would silently vanish from ours,
    /// which is the same "plausible empty parse" failure this decoder exists to
    /// avoid, just smaller. Closing leaves the note visible, obviously odd, and
    /// accompanied by a sentence saying exactly what happened.
    @Test("AMBIGUITY 2: a note still held at end-of-track is closed there, and warns")
    func danglingNoteOnIsClosedAtEndOfTrack() throws {
        let body: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,        // tick 0: on 60 — never released
            0x83, 0x60, 0xFF, 0x2F, 0x00,  // tick 480: end of track
        ]

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        let track = try #require(file.tracks.first)

        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 480, note: 60,
                    velocity: 100, releaseVelocity: 0, channel: 0)
        ])
        #expect(file.warnings == [
            .danglingNoteOn(trackIndex: 0, channel: 0, note: 60, tick: 0)
        ])
        #expect(file.warnings[0].description.contains("never released"))
    }

    @Test("A note-off with nothing sounding is dropped, and warns")
    func unmatchedNoteOffWarns() throws {
        let body: [UInt8] = [0x00, 0x80, 0x3C, 0x40] + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        #expect(try #require(file.tracks.first).notes.isEmpty)
        #expect(file.warnings == [
            .unmatchedNoteOff(trackIndex: 0, channel: 0, note: 60, tick: 0)
        ])
    }

    // MARK: Meta events

    /// Format 1 throughout this section: a name belongs to a CHUNK, and under
    /// format 0 a chunk carrying nothing but a name has no channel to be split
    /// onto, so it correctly yields no parts at all.
    @Test("Track name (FF 03) is read; the FIRST one wins")
    func trackNameIsRead() throws {
        let body: [UInt8] = [0x00, 0xFF, 0x03, 0x05] + Array("Drums".utf8)
            + [0x00, 0xFF, 0x03, 0x04] + Array("Nope".utf8)
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 1, trackBodies: [body]))
        #expect(try #require(file.tracks.first).name == "Drums")
    }

    /// A format-0 chunk's name belongs to every part carved out of it — the
    /// channels are splits of one named chunk, not separately named tracks.
    @Test("A format-0 split copies the chunk's name onto every channel part")
    func formatZeroSplitCarriesTheChunkName() throws {
        let body: [UInt8] = [0x00, 0xFF, 0x03, 0x04] + Array("Band".utf8)
            + [0x00, 0x90, 0x3C, 0x64, 0x00, 0x91, 0x40, 0x50,
               0x81, 0x70, 0x80, 0x3C, 0x40, 0x00, 0x81, 0x40, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        #expect(file.tracks.count == 2)
        #expect(file.tracks.map(\.name) == ["Band", "Band"])
    }

    /// SMF nominally specifies ASCII; real files carry UTF-8 and Latin-1 alike.
    /// UTF-8 first, Latin-1 as a fallback that cannot fail on any byte sequence —
    /// so a name never comes back nil and a stray high byte never loses the name.
    @Test("Track name decodes UTF-8, falling back to Latin-1 for non-UTF-8 bytes")
    func trackNameTextEncodings() throws {
        let utf8Body: [UInt8] = [0x00, 0xFF, 0x03, 0x05, 0x43, 0x61, 0x66, 0xC3, 0xA9]
            + Self.endOfTrack
        let utf8File = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 1, trackBodies: [utf8Body]))
        #expect(try #require(utf8File.tracks.first).name == "Café")

        // The same word in Latin-1: 0xE9 is not valid UTF-8 on its own.
        let latin1Body: [UInt8] = [0x00, 0xFF, 0x03, 0x04, 0x43, 0x61, 0x66, 0xE9]
            + Self.endOfTrack
        let latin1File = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 1, trackBodies: [latin1Body]))
        #expect(try #require(latin1File.tracks.first).name == "Café")
    }

    /// Unknown meta events must be skipped BY THEIR LENGTH. If the length were
    /// ignored, the byte after the payload would be read as the next delta time
    /// and the rest of the track would be garbage.
    @Test("An unrecognised meta event is skipped by its length, not by guesswork")
    func unknownMetaEventIsSkippedByLength() throws {
        let body: [UInt8] = [0x00, 0xFF, 0x7F, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]  // sequencer-specific
            + [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        #expect(try #require(file.tracks.first).notes == [
            SMFNote(tick: 0, lengthTicks: 240, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0)
        ])
    }

    /// SMF 1.0: "Sysex events and meta-events cancel any running status which was
    /// in effect." A decoder that keeps running status across them silently
    /// mis-reads the first event after any meta event.
    @Test("A meta event cancels running status")
    func metaEventCancelsRunningStatus() throws {
        let body: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,                    // offset 0:  on 60, sets running status
            0x00, 0xFF, 0x01, 0x03, 0x41, 0x42, 0x43,  // offset 4:  text meta — cancels it
            0x00, 0x3E, 0x64,                          // offset 11: bare data byte ⇒ refusal
        ] + Self.endOfTrack

        let error = Self.decodeError(Self.midiFile(trackBodies: [body]))
        #expect(error == .runningStatusWithoutPrecedingStatus(trackIndex: 0,
                                                              byteOffsetInTrack: 12))
    }

    // MARK: Event framing

    /// SysEx is length-prefixed and skipped, but the length must be read right or
    /// the stream desynchronises.
    @Test("SysEx is skipped by its length; the event after it still decodes")
    func sysExIsSkippedByLength() throws {
        let body: [UInt8] = [0x00, 0xF0, 0x03, 0x41, 0x42, 0xF7]
            + [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        #expect(try #require(file.tracks.first).notes == [
            SMFNote(tick: 0, lengthTicks: 240, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0)
        ])
    }

    /// Program change and channel pressure take ONE data byte; every other
    /// channel message takes two. Reading two here would swallow the next
    /// event's delta time.
    @Test("Program change consumes one data byte, not two")
    func programChangeIsOneDataByte() throws {
        let body: [UInt8] = [0x00, 0xC0, 0x05]
            + [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        let track = try #require(file.tracks.first)
        #expect(track.notes == [
            SMFNote(tick: 0, lengthTicks: 240, note: 60,
                    velocity: 100, releaseVelocity: 64, channel: 0)
        ])
        #expect(track.channels == [0])
    }

    @Test("Polyphonic key pressure consumes two data bytes and is discarded")
    func polyKeyPressureIsFramedAndDropped() throws {
        let body: [UInt8] = [0x00, 0xA0, 0x3C, 0x40]
            + [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        let track = try #require(file.tracks.first)
        #expect(track.notes.count == 1)
        // Per-note aftertouch is a different model shape, deferred past v1 — the
        // same line MIDIControllerType already draws. It is framed, not kept.
        #expect(track.controllers.isEmpty)
    }

    /// A channel that carries only discarded events must NOT conjure an empty
    /// part out of a format-0 split. (`hazard-controllers.mid` pins the other
    /// side of this line: a channel with only CC DOES yield a part.)
    @Test("A format-0 channel with only a program change yields no part")
    func discardedOnlyChannelYieldsNoPart() throws {
        let body: [UInt8] = [0x00, 0xC5, 0x20] + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(Self.midiFile(trackBodies: [body]))
        #expect(file.tracks.isEmpty)
    }

    // MARK: Format 0 versus format 1

    /// The same bytes, read under each format header. Format 0 splits by channel;
    /// format 1 does not, because there each chunk is already one part.
    @Test("Identical bytes split under format 0 and stay whole under format 1")
    func formatDecidesWhetherToSplit() throws {
        let body: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,        // ch 0
            0x00, 0x91, 0x40, 0x50,        // ch 1
            0x81, 0x70, 0x80, 0x3C, 0x40,
            0x00, 0x81, 0x40, 0x40,
        ] + Self.endOfTrack

        let type0 = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 0, trackBodies: [body]))
        #expect(type0.tracks.count == 2)
        #expect(type0.tracks.map(\.channel) == [0, 1])
        #expect(type0.tracks.map { $0.notes.count } == [1, 1])

        let type1 = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 1, trackBodies: [body]))
        #expect(type1.tracks.count == 1)
        let whole = try #require(type1.tracks.first)
        #expect(whole.channels == [0, 1])
        // Two channels ⇒ no single channel to name.
        #expect(whole.channel == nil)
        #expect(whole.notes.count == 2)
    }

    @Test("Format 2 is accepted and recorded verbatim, parsed chunk-per-part")
    func formatTwoIsRecordedNotRejected() throws {
        let body: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 2, trackBodies: [body, body]))
        // Whether these sequences are simultaneous or independent is a mapping
        // question, so the format is recorded and the answer left to k3.
        #expect(file.format == .independentSequences)
        #expect(file.tracks.count == 2)
    }

    // MARK: Header edge cases

    @Test("A header longer than 6 bytes is skipped by its declared length")
    func longHeaderIsSkippedByDeclaredLength() throws {
        let body: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack
        // Declared length 8: the six standard bytes plus two the spec reserves
        // the right to add. Trusting the constant 6 instead would read `0xABCD`
        // as the start of the next chunk tag.
        var bytes = Self.fourCC("MThd") + Self.u32(8) + Self.u16(1) + Self.u16(1)
            + Self.u16(480) + [0xAB, 0xCD]
        bytes += Self.fourCC("MTrk") + Self.u32(body.count) + body

        let file = try StandardMIDIFileReader.decode(Data(bytes))
        #expect(file.format == .simultaneousTracks)
        #expect(file.tracks.count == 1)
    }

    @Test("An out-of-range format word is refused")
    func unsupportedFormatIsRefused() throws {
        let body: [UInt8] = Self.endOfTrack
        let error = Self.decodeError(Self.midiFile(format: 3, trackBodies: [body]))
        #expect(error == .unsupportedFormat(3))
        #expect(error?.description.contains("formats 0, 1 and 2") == true)
    }

    @Test("A zero division is refused — the file has no time base at all")
    func zeroDivisionIsRefused() throws {
        let body: [UInt8] = Self.endOfTrack
        let error = Self.decodeError(Self.midiFile(division: 0, trackBodies: [body]))
        #expect(error == .invalidDivision(raw: 0))
        #expect(error?.description.contains("no time base") == true)
    }

    /// A valid header with nothing behind it is exactly the "this file has no
    /// notes" lie the decoder must never tell, so it is a refusal.
    @Test("A header with no MTrk chunks is refused, not returned empty")
    func noTrackChunksIsRefused() throws {
        let error = Self.decodeError(Self.midiFile(declaredTracks: 0, trackBodies: []))
        #expect(error == .noTrackChunks)
        #expect(error?.description.contains("no tracks") == true)
    }

    /// The chunks win over the header's count — they are the data. This is a
    /// warning rather than a refusal because the file is still fully readable.
    @Test("A header track count that disagrees with the chunks warns; chunks win")
    func trackCountMismatchWarns() throws {
        let body: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(
            Self.midiFile(format: 1, declaredTracks: 2, trackBodies: [body]))
        #expect(file.tracks.count == 1)
        #expect(file.warnings == [.trackCountMismatch(declared: 2, found: 1)])
    }

    @Test("Leftover bytes after the last chunk are ignored, and warn")
    func trailingBytesWarn() throws {
        let body: [UInt8] = [0x00, 0x90, 0x3C, 0x64, 0x81, 0x70, 0x80, 0x3C, 0x40]
            + Self.endOfTrack

        let file = try StandardMIDIFileReader.decode(
            Self.midiFile(trackBodies: [body], trailing: [0x01, 0x02, 0x03]))
        #expect(file.tracks.count == 1)
        #expect(file.warnings == [.trailingBytes(count: 3)])
    }

    // MARK: Bounds checking inside a track

    @Test("An event cut off mid-way gives a teaching error, not a crash")
    func truncatedEventIsRefused() throws {
        // An honest MTrk length of 3, but a note-on needs two data bytes and
        // only one is there.
        let error = Self.decodeError(Self.midiFile(trackBodies: [[0x00, 0x90, 0x3C]]))
        #expect(error == .truncatedEvent(trackIndex: 0, byteOffsetInTrack: 1))
        #expect(error?.description.contains("middle of an event") == true)
    }

    @Test("A VLQ longer than the spec's 4 bytes is refused")
    func overlongVLQIsRefused() throws {
        let body: [UInt8] = [0x81, 0x81, 0x81, 0x81, 0x00] + [0xFF, 0x2F, 0x00]
        let error = Self.decodeError(Self.midiFile(trackBodies: [body]))
        #expect(error == .malformedVariableLengthQuantity(trackIndex: 0,
                                                          byteOffsetInTrack: 0))
        #expect(error?.description.contains("4 bytes") == true)
    }

    /// System common / real-time bytes have no meaning inside an `MTrk`, and
    /// there is no safe length to skip past one, so the stream is lost.
    @Test("A system real-time byte inside a track is refused")
    func unexpectedStatusByteIsRefused() throws {
        let body: [UInt8] = [0x00, 0xF1, 0x00] + Self.endOfTrack
        let error = Self.decodeError(Self.midiFile(trackBodies: [body]))
        #expect(error == .unexpectedStatusByte(0xF1, trackIndex: 0, byteOffsetInTrack: 1))
        #expect(error?.description.contains("0xF1") == true)
    }

    @Test("A bare data byte as the first event of a track is refused")
    func runningStatusWithNoPrecedingStatusIsRefused() throws {
        let body: [UInt8] = [0x00, 0x3C, 0x64] + Self.endOfTrack
        let error = Self.decodeError(Self.midiFile(trackBodies: [body]))
        #expect(error == .runningStatusWithoutPrecedingStatus(trackIndex: 0,
                                                              byteOffsetInTrack: 1))
        #expect(error?.description.contains("omits") == true)
    }

    /// Fuzz-ish smoke test: every truncation of a known-good file must either
    /// decode or throw an `SMFDecodeError`. Never trap, never hang.
    @Test("Every prefix of a valid file either decodes or throws — none crash")
    func everyPrefixIsSafe() throws {
        let full = [UInt8](try Self.fixtureData("apple-type1"))
        for length in 0 ..< full.count {
            let prefix = Data(full[0 ..< length])
            do {
                _ = try StandardMIDIFileReader.decode(prefix)
            } catch is SMFDecodeError {
                continue
            } catch {
                Issue.record("prefix of \(length) bytes threw a non-SMF error: \(error)")
            }
        }
    }
}
