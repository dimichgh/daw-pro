import Foundation

/// Pure Universal MIDI Packet word parser — headless-testable, no CoreMIDI
/// types anywhere. The input port is created at UMP protocol 1.0, so every
/// channel-voice message arrives as ONE 32-bit word with message type 2
/// (CoreMIDI downconverts MIDI 2.0 devices for free).
enum MIDIUMPParser {
    /// What one accepted UMP word says — pre-timestamp, pre-source (the packet
    /// walker adds those when it builds the `LiveMIDIEvent`). Field naming is
    /// historical; the CONTENTS follow the §4.1 one-data-rule (design-m16b):
    /// `pitch` ≡ MIDI data1, `velocity` ≡ MIDI data2 for EVERY kind — notes
    /// (key, velocity), CC (controller, value), bend (LSB, MSB in wire order;
    /// the consumer reassembles `(MSB << 7) | LSB`), channel pressure
    /// (value, 0 — a TWO-byte message).
    struct LiveNote: Equatable {
        var kind: UInt8       // ScheduledMIDIEvent.noteOn/.noteOff/.controlChange/.pitchBend/.channelPressure
        var pitch: UInt8      // MIDI data1 (0...127)
        var velocity: UInt8   // MIDI data2 (0...127); 0 where the message has none
        var channel: UInt8    // 0...15
    }

    /// Parses ONE 32-bit UMP word. Scope: message type 2 (MIDI 1.0 channel
    /// voice) note-on / note-off (**note-on velocity 0 maps to note-off** per
    /// the MIDI 1.0 rule) plus, since m16-b3, CC (0xB → kind 2), channel
    /// pressure (0xD → kind 4) and pitch bend (0xE → kind 3) under the §4.1
    /// one-data-rule above. Everything else (poly aftertouch, program change,
    /// non-MT-2 words) returns nil and is dropped.
    ///
    /// RT-safe by construction: pure integer math, called from the CoreMIDI
    /// receive thread.
    static func parse(word: UInt32) -> LiveNote? {
        guard (word >> 28) & 0xF == 0x2 else { return nil }  // MT 2 only
        let status = UInt8((word >> 16) & 0xFF)
        let channel = status & 0x0F
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        switch status >> 4 {
        case 0x9 where data2 > 0:
            return LiveNote(kind: ScheduledMIDIEvent.noteOn, pitch: data1,
                            velocity: data2, channel: channel)
        case 0x9, 0x8:  // note-on vel 0 ≡ note-off; 0x8 is note-off proper
            return LiveNote(kind: ScheduledMIDIEvent.noteOff, pitch: data1,
                            velocity: 0, channel: channel)
        case 0xB:  // control change: data1 = controller#, data2 = value
            return LiveNote(kind: ScheduledMIDIEvent.controlChange, pitch: data1,
                            velocity: data2, channel: channel)
        case 0xE:  // pitch bend: data1 = LSB, data2 = MSB (wire order)
            return LiveNote(kind: ScheduledMIDIEvent.pitchBend, pitch: data1,
                            velocity: data2, channel: channel)
        case 0xD:  // channel pressure: TWO-byte message, data1 = value
            return LiveNote(kind: ScheduledMIDIEvent.channelPressure, pitch: data1,
                            velocity: 0, channel: channel)
        default:
            return nil
        }
    }

    /// UMP words per message, keyed by the message-type nibble (MIDI 2.0 spec
    /// table). The packet walker advances by WHOLE messages so a data word of
    /// a multi-word message (e.g. the second word of a SysEx7) can never be
    /// misread as a channel-voice word.
    static func wordCount(messageType: UInt32) -> Int {
        switch messageType & 0xF {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4  // 0x5, 0xD, 0xE, 0xF
        }
    }
}
