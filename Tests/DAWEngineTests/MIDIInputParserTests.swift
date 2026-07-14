import Foundation
import Testing
@testable import DAWEngine

/// Pure UMP-word parser: MT 2 note-on/off only, vel-0 → off, everything else
/// dropped. Word layout under test (MIDI 1.0 channel voice in UMP):
/// [MT:4][group:4][status:8][data1:8][data2:8].
@Suite("MIDI input — UMP parser")
struct MIDIInputParserTests {
    @Test("note-on word parses: MT2 0x9n → noteOn with pitch/velocity/channel")
    func noteOnWordParses() {
        // MT 2, group 0, status 0x91 (note-on ch 1), pitch 60, velocity 100.
        let note = MIDIUMPParser.parse(word: 0x2091_3C64)
        #expect(note == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100, channel: 1))
    }

    @Test("note-on with velocity 0 maps to note-off (MIDI 1.0 rule)")
    func noteOnVelocityZeroMapsToNoteOff() {
        let note = MIDIUMPParser.parse(word: 0x2090_3C00)
        #expect(note == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0, channel: 0))
    }

    @Test("note-off word parses with velocity normalized to 0")
    func noteOffWordParses() {
        // Off velocity 0x40 on the wire is normalized away (unused v0).
        let note = MIDIUMPParser.parse(word: 0x2080_3C40)
        #expect(note == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0, channel: 0))
    }

    // m16-b3: CC (0xB) / bend (0xE) / pressure (0xD) moved OUT of this list —
    // they now parse (C10 vectors below). Poly aftertouch, program change and
    // non-MT-2 words stay dropped.
    @Test("poly aftertouch, program change, and non-MT-2 words are dropped")
    func nonChannelVoiceAndNonNoteWordsAreDropped() {
        #expect(MIDIUMPParser.parse(word: 0x20A0_3C40) == nil)  // poly aftertouch
        #expect(MIDIUMPParser.parse(word: 0x20C0_0500) == nil)  // program change
        #expect(MIDIUMPParser.parse(word: 0x1090_3C64) == nil)  // MT 1 (system RT)
        #expect(MIDIUMPParser.parse(word: 0x4090_3C64) == nil)  // MT 4 (MIDI 2.0 CV)
        #expect(MIDIUMPParser.parse(word: 0x0000_0000) == nil)  // MT 0 (utility/NOOP)
        #expect(MIDIUMPParser.parse(word: 0x3016_F07E) == nil)  // MT 3 (SysEx7)
    }

    // MARK: - m16-b3 controller vectors (design-m16b §8.1, C10)

    @Test("C10 CC word parses: MT2 0xBn → kind 2, data1 = controller, data2 = value")
    func ccWordParses() {
        // MT 2, group 0, status 0xB3 (CC ch 3), controller 87, value 42.
        let event = MIDIUMPParser.parse(word: 0x20B3_572A)
        #expect(event == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.controlChange, pitch: 87, velocity: 42, channel: 3))
    }

    @Test("C10 pitch-bend word parses: data1 = LSB, data2 = MSB; 14-bit reassembly is (MSB << 7) | LSB")
    func pitchBendWordParsesWithLSBMSBWireOrder() throws {
        // MT 2, status 0xE0, LSB 0x12 (18), MSB 0x34 (52).
        let event = try #require(MIDIUMPParser.parse(word: 0x20E0_1234))
        #expect(event.kind == ScheduledMIDIEvent.pitchBend)
        #expect(event.pitch == 18)      // data1 = LSB (wire order)
        #expect(event.velocity == 52)   // data2 = MSB
        #expect((Int(event.velocity) << 7) | Int(event.pitch) == 6674)  // the §4.1 reassembly
        // Center: LSB 0, MSB 0x40 → 8192.
        let center = try #require(MIDIUMPParser.parse(word: 0x20E0_0040))
        #expect((Int(center.velocity) << 7) | Int(center.pitch) == 8192)
    }

    @Test("C10 channel-pressure word parses: TWO-byte message — data1 = value, data2 forced 0")
    func channelPressureWordParses() {
        // MT 2, status 0xD1 (pressure ch 1), value 99, trailing byte 0.
        let event = MIDIUMPParser.parse(word: 0x20D1_6300)
        #expect(event == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.channelPressure, pitch: 99, velocity: 0, channel: 1))
        // Defensive: junk in the unused trailing byte never leaks into data2.
        let junk = MIDIUMPParser.parse(word: 0x20D1_6377)
        #expect(junk?.velocity == 0)
    }

    @Test("C10 era: note vectors parse byte-identical to the pre-controller parser")
    func noteVectorsByteIdentical() {
        // The exact pre-m16-b3 outputs, re-pinned A/B (kind, pitch, velocity,
        // channel — every byte).
        #expect(MIDIUMPParser.parse(word: 0x2091_3C64) == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100, channel: 1))
        #expect(MIDIUMPParser.parse(word: 0x2090_3C00) == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0, channel: 0))
        #expect(MIDIUMPParser.parse(word: 0x2080_3C40) == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0, channel: 0))
        #expect(MIDIUMPParser.parse(word: 0x2F9F_7F01) == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOn, pitch: 127, velocity: 1, channel: 15))
    }

    @Test("group and channel bits never corrupt pitch or velocity")
    func channelAndGroupBitsDoNotCorruptPitch() {
        // MT 2, group 0xF, note-on ch 15, pitch 127, velocity 1.
        let note = MIDIUMPParser.parse(word: 0x2F9F_7F01)
        #expect(note == MIDIUMPParser.LiveNote(
            kind: ScheduledMIDIEvent.noteOn, pitch: 127, velocity: 1, channel: 15))
        // Data bytes keep their top bit masked off (7-bit fields).
        let masked = MIDIUMPParser.parse(word: 0x2090_BCE4)  // 0xBC & 0x7F = 60, 0xE4 & 0x7F = 100
        #expect(masked?.pitch == 60)
        #expect(masked?.velocity == 100)
    }

    @Test("message word counts advance the walker past multi-word messages")
    func wordCountsSkipWholeMessages() {
        #expect(MIDIUMPParser.wordCount(messageType: 0x2) == 1)
        #expect(MIDIUMPParser.wordCount(messageType: 0x3) == 2)  // SysEx7
        #expect(MIDIUMPParser.wordCount(messageType: 0x4) == 2)  // MIDI 2.0 CV
        #expect(MIDIUMPParser.wordCount(messageType: 0x5) == 4)  // Data 128
        #expect(MIDIUMPParser.wordCount(messageType: 0xF) == 4)  // Stream
    }
}
