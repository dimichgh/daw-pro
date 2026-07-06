import AVFAudio
import Foundation

/// Trivial `InstrumentRendering` that writes exact zeros every quantum. Stands
/// in for a hosted Audio Unit whose preparation is `.pending`, `.missing`, or
/// `.failed` — and for a `.audioUnit` descriptor with no component selected —
/// so an instrument track always has a render-safe instrument.
final class SilentPlaceholderInstrument: InstrumentRendering {
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for buffer in output {
            guard let data = buffer.mData else { continue }
            memset(data, 0, min(Int(buffer.mDataByteSize), byteCount))
        }
    }

    func reset() {}
}
