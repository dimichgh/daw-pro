import Foundation

/// One live MIDI event as it crossed the wire — a 16-byte POD.
/// Deliberately NOT `ScheduledMIDIEvent`: at the wire there is no sampleTime
/// and no noteID yet (the render side mints live noteIDs at drain time; the
/// capture side pairs on/off by pitch). Since m16-b3 it also carries CC /
/// pitch bend / channel pressure under the §4.1 one-data-rule (design-m16b):
/// `pitch` ≡ MIDI data1, `velocity` ≡ MIDI data2 for every kind.
struct LiveMIDIEvent: Equatable {
    var hostTime: UInt64   // mach ticks (packet.timeStamp, or "now" when 0)
    var source: Int32      // endpoint kMIDIPropertyUniqueID
    var kind: UInt8        // ScheduledMIDIEvent kind (0/1 notes, 2/3/4 controllers)
    var pitch: UInt8       // MIDI data1: key / controller# / bend LSB / pressure value
    var velocity: UInt8    // MIDI data2: velocity (vel-0 on already mapped to off) / CC value / bend MSB; 0 when absent
    var channel: UInt8     // captured, unused v0
}
