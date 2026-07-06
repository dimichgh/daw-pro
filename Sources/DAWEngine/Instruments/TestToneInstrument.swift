import AVFAudio
import Foundation

/// Deliberately crude sine-blip instrument that makes MIDI audible this cycle
/// (the real poly synth is M3 (iv)). 16 fixed voices, oldest-stolen when
/// full; noteOn starts a phase-0 sine at the equal-tempered pitch frequency,
/// noteOff (matched by noteID) hard-stops the voice at its exact frame —
/// clicky by design. Stereo-identical channels; true zeros when idle.
///
/// Render-path contract: `render()`/`reset()` allocate nothing, take no
/// locks, and touch no ObjC — voices live in a fixed heap block allocated in
/// init and are indexed by raw pointer.
final class TestToneInstrument: InstrumentRendering, @unchecked Sendable {
    private struct Voice {
        var active = false
        var noteID: UInt64 = 0
        var phase = 0.0
        var phaseIncrement = 0.0
        var amplitude: Float = 0
        var serial: UInt64 = 0    // steal order: lowest serial = oldest voice
    }

    private static let voiceCount = 16

    private let voices: UnsafeMutablePointer<Voice>
    private var sampleRate: Double = 48_000
    private var nextSerial: UInt64 = 0

    init() {
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
    }

    deinit {
        voices.deinitialize(count: Self.voiceCount)
        voices.deallocate()
    }

    // MARK: - InstrumentRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard let first = output.first, let firstData = first.mData else { return }
        let channel0 = firstData.assumingMemoryBound(to: Float.self)

        var eventIndex = 0
        for frame in 0..<frameCount {
            // Apply every event whose (clamped) in-quantum offset is this
            // frame BEFORE synthesizing it: a noteOff at offset k silences its
            // voice from frame k; a noteOn at offset k sounds from frame k
            // (sin(0) = 0, so the first nonzero sample is one frame later).
            while eventIndex < events.count {
                let event = events[eventIndex]
                let offset = max(0, Int(event.sampleTime - renderStart))
                guard offset <= frame else { break }
                apply(event)
                eventIndex += 1
            }

            var sample: Float = 0
            for index in 0..<Self.voiceCount where voices[index].active {
                sample += voices[index].amplitude * Float(sin(voices[index].phase))
                voices[index].phase += voices[index].phaseIncrement
                if voices[index].phase > 2.0 * .pi {
                    voices[index].phase -= 2.0 * .pi
                }
            }
            channel0[frame] = sample
        }

        // Stereo-identical: copy channel 0 to every other channel buffer.
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for buffer in output.dropFirst() {
            guard let data = buffer.mData else { continue }
            memcpy(data, firstData, min(Int(buffer.mDataByteSize), byteCount))
        }
    }

    func reset() {
        for index in 0..<Self.voiceCount {
            voices[index].active = false
        }
    }

    // MARK: - Voice logic (render thread)

    private func apply(_ event: ScheduledMIDIEvent) {
        if event.kind == ScheduledMIDIEvent.noteOn {
            var slot = -1
            var oldestSerial = UInt64.max
            var oldestIndex = 0
            for index in 0..<Self.voiceCount {
                if !voices[index].active {
                    slot = index
                    break
                }
                if voices[index].serial < oldestSerial {
                    oldestSerial = voices[index].serial
                    oldestIndex = index
                }
            }
            if slot < 0 { slot = oldestIndex }  // steal the oldest voice
            let frequency = 440.0 * exp2((Double(event.pitch) - 69.0) / 12.0)
            voices[slot] = Voice(
                active: true,
                noteID: event.noteID,
                phase: 0,
                phaseIncrement: 2.0 * .pi * frequency / sampleRate,
                amplitude: Float(event.velocity) / 127.0 * 0.25,
                serial: nextSerial
            )
            nextSerial &+= 1
        } else if event.kind == ScheduledMIDIEvent.noteOff {
            for index in 0..<Self.voiceCount
            where voices[index].active && voices[index].noteID == event.noteID {
                voices[index].active = false  // hard stop at this frame
            }
        }
    }
}
