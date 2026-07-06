import Foundation

/// One live MIDI note event as it crossed the wire — a 16-byte POD.
/// Deliberately NOT `ScheduledMIDIEvent`: at the wire there is no sampleTime
/// and no noteID yet (the render side mints live noteIDs at drain time; the
/// capture side pairs on/off by pitch).
struct LiveMIDIEvent: Equatable {
    var hostTime: UInt64   // mach ticks (packet.timeStamp, or "now" when 0)
    var source: Int32      // endpoint kMIDIPropertyUniqueID
    var kind: UInt8        // ScheduledMIDIEvent.noteOn / .noteOff
    var pitch: UInt8       // 0...127
    var velocity: UInt8    // on: 1...127 (vel-0 already mapped to off); off: 0
    var channel: UInt8     // captured, unused v0
}
