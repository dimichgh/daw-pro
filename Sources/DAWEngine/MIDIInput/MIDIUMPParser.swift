import Foundation

/// Pure Universal MIDI Packet word parser — headless-testable, no CoreMIDI
/// types anywhere. The input port is created at UMP protocol 1.0, so every
/// channel-voice message arrives as ONE 32-bit word with message type 2
/// (CoreMIDI downconverts MIDI 2.0 devices for free).
enum MIDIUMPParser {
    /// What one accepted UMP word says — pre-timestamp, pre-source (the packet
    /// walker adds those when it builds the `LiveMIDIEvent`).
    struct LiveNote: Equatable {
        var kind: UInt8       // ScheduledMIDIEvent.noteOn / .noteOff
        var pitch: UInt8      // 0...127
        var velocity: UInt8   // on: 1...127; off: 0
        var channel: UInt8    // 0...15
    }

    /// Parses ONE 32-bit UMP word. v0 scope: message type 2 (MIDI 1.0 channel
    /// voice) note-on / note-off only; **note-on velocity 0 maps to note-off**
    /// per the MIDI 1.0 rule. Everything else (CC, pitch bend, aftertouch,
    /// program change, non-MT-2 words) returns nil and is dropped.
    ///
    /// RT-safe by construction: pure integer math, called from the CoreMIDI
    /// receive thread.
    static func parse(word: UInt32) -> LiveNote? {
        guard (word >> 28) & 0xF == 0x2 else { return nil }  // MT 2 only
        let status = UInt8((word >> 16) & 0xFF)
        let channel = status & 0x0F
        let pitch = UInt8((word >> 8) & 0x7F)
        let velocity = UInt8(word & 0x7F)
        switch status >> 4 {
        case 0x9 where velocity > 0:
            return LiveNote(kind: ScheduledMIDIEvent.noteOn, pitch: pitch,
                            velocity: velocity, channel: channel)
        case 0x9, 0x8:  // note-on vel 0 ≡ note-off; 0x8 is note-off proper
            return LiveNote(kind: ScheduledMIDIEvent.noteOff, pitch: pitch,
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
