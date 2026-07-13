import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// The built-in sampler (M3 v): pitched multisample + one-shot playback.
/// 16 voices, oldest stolen when full; noteOff pairs by noteID (same policies
/// as `PolySynthInstrument`).
///
/// m16-b2 controllers (design-m16b §4.3): honors PITCH BEND (±2 st GM range,
/// playback-rate factor 2^(semitones/12) on every voice) and SUSTAIN (CC64 ≥
/// 64: noteOffs defer until pedal-up; one-shot mode is unaffected). All other
/// CCs and channel pressure are safely ignored (documented); `reset()`
/// re-centers bend and lifts the pedal.
///
/// Zone audio is loaded FULLY in init — reconcile time, never the render
/// thread — into immutable deinterleaved Float32 buffers at each file's
/// native rate. A voice triggers on the FIRST zone in array order whose span
/// contains the pitch (no zone → the note is silently ignored) and advances a
/// fractional playhead through the source at
///
///     2^((pitch − rootPitch)/12) × fileRate / graphRate
///
/// with linear interpolation, freeing itself at buffer end. Mono files play
/// on both output channels. Amplitude = velocity/127 × zone.gain × params.gain.
///
/// Envelope: `attack` is a linear anti-click ramp on trigger; noteOff starts a
/// linear release ramp that reaches EXACTLY 0 after `release` seconds and
/// frees the voice (true zeros from then on). `oneShot == true` ignores
/// noteOff entirely — every trigger plays to buffer end.
///
/// Parameter split: ZONES are structural — a zones change rebuilds the whole
/// instrument via `PlaybackGraph.InstrumentTrackKey` (fresh init reloads the
/// files). The SCALARS (oneShot/attack/release/gain) update in place:
/// `apply(params:)` publishes an immutable POD snapshot through a
/// heap-allocated `daw_atomic_ptr` with the same ≥ 1 s retire-bin pattern as
/// `PolySynthInstrument`; the render thread adopts it at the top of the next
/// quantum without cutting held voices.
///
/// Render-path contract: `render()`/`reset()` allocate nothing, take no
/// locks, log nothing, and touch no ObjC — voices and zone descriptors live
/// in fixed heap blocks allocated in init; sample memory is immutable after
/// init; the snapshot is borrowed via `takeUnretainedValue` (the retire bin
/// guarantees its lifetime).
final class SamplerInstrument: InstrumentRendering, @unchecked Sendable {
    // MARK: - Loaded zone data (immutable after init)

    /// POD descriptor of one successfully loaded zone. `left`/`right` point
    /// into buffers owned by `ownedChannelBuffers`; for mono files both point
    /// at the same buffer.
    private struct LoadedZone {
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var frameCount: Int
        var fileRate: Double
        var rootPitch: Int32
        var minPitch: Int32
        var maxPitch: Int32
        var gain: Float
    }

    // MARK: - Published scalar snapshot

    /// The in-place-updatable subset of `SamplerParams` (everything but
    /// zones). POD, so render-thread reads do no ARC or bridging work.
    private struct ScalarParams: Equatable {
        var oneShot: Bool
        var attack: Double
        var release: Double
        var gain: Double

        init(_ params: SamplerParams) {
            oneShot = params.oneShot
            attack = params.attack
            release = params.release
            gain = params.gain
        }
    }

    /// Immutable box crossing main actor → render thread through `paramsSlot`.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: ScalarParams

        init(generation: UInt64, params: ScalarParams) {
            self.generation = generation
            self.params = params
        }
    }

    // MARK: - Voice

    private struct Voice {
        var active = false
        var noteID: UInt64 = 0
        var serial: UInt64 = 0       // steal order: lowest serial = oldest voice
        var zoneIndex: Int32 = 0
        var releasing = false
        var sustained = false        // noteOff deferred by the pedal (m16-b2, CC64)
        var position = 0.0           // fractional playhead, source-file frames
        var increment = 0.0          // baseIncrement × bendFactor
        var baseIncrement = 0.0      // unbent source frames per output frame (m16-b2)
        var amp: Float = 0           // velocity/127 × zone.gain
        var level: Float = 0         // envelope, 0...1
        var releaseFrom: Float = 0   // level captured at noteOff (release anchor)
    }

    private static let voiceCount = 16

    private let voices: UnsafeMutablePointer<Voice>
    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// Zone descriptors — written once in init, immutable thereafter, read by
    /// the render thread with no Array machinery.
    private let zones: UnsafeMutablePointer<LoadedZone>
    private let zoneCount: Int
    /// Owned sample memory backing `zones` (freed in deinit).
    private var ownedChannelBuffers: [UnsafeMutableBufferPointer<Float>] = []

    /// Human-readable notes for zones skipped at load (missing/unreadable/
    /// empty files). Populated in init — reconcile time — and never touched
    /// by the render path.
    private(set) var zoneLoadNotes: [String] = []

    // Render-thread-only state.
    private var sampleRate: Double
    private var nextSerial: UInt64 = 0
    private var lastParamsGeneration = UInt64.max  // .max forces first-quantum adoption
    // Controller state (m16-b2, design-m16b §4.3): plain render-thread
    // scalars, mutated only by applied schedule events. Bend range is the GM
    // default ±2 semitones; `bendFactor` = 2^(semitones/12) multiplies every
    // voice's playback-rate increment (recomputed per applied bend event —
    // one exp2, no allocation).
    private var bendFactor = 1.0
    private var pedalDown = false
    private static let bendRangeSemitones = 2.0
    // Coefficients derived from the adopted snapshot — recomputed per
    // GENERATION change, never per sample.
    private var oneShot = false
    private var attackStep: Float = 0              // level units per sample
    private var releaseSlope: Float = 0            // fraction of releaseFrom per sample
    private var outputGain: Float = 0

    // Main-actor-only publish state (same retire-bin contract as
    // PolySynthInstrument / InstrumentRenderer).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedScalars: ScalarParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    /// Loads every zone's audio file synchronously. Construction happens at
    /// reconcile time on the main actor (PlaybackGraph's instrument factory) —
    /// NEVER on the render thread. `sampleRate` is a provisional graph rate;
    /// `prepare()` overrides it before the node ever renders.
    init(params: SamplerParams, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        lastAppliedScalars = ScalarParams(params)

        var loaded: [LoadedZone] = []
        for zone in params.zones {
            do {
                let file = try AVAudioFile(forReading: zone.audioFileURL)
                // processingFormat is deinterleaved Float32 at the file's
                // native rate, so floatChannelData below is always valid.
                guard file.length > 0,
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.length))
                else {
                    zoneLoadNotes.append(
                        "zone skipped (empty file): \(zone.audioFileURL.lastPathComponent)")
                    continue
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    zoneLoadNotes.append(
                        "zone skipped (no readable frames): \(zone.audioFileURL.lastPathComponent)")
                    continue
                }
                let frames = Int(buffer.frameLength)
                let left = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
                _ = left.initialize(from: UnsafeBufferPointer(start: channels[0], count: frames))
                ownedChannelBuffers.append(left)
                let rightBase: UnsafePointer<Float>
                if Int(buffer.format.channelCount) >= 2 {
                    let right = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
                    _ = right.initialize(
                        from: UnsafeBufferPointer(start: channels[1], count: frames))
                    ownedChannelBuffers.append(right)
                    rightBase = UnsafePointer(right.baseAddress!)
                } else {
                    rightBase = UnsafePointer(left.baseAddress!)  // mono → both channels
                }
                loaded.append(LoadedZone(
                    left: UnsafePointer(left.baseAddress!),
                    right: rightBase,
                    frameCount: frames,
                    fileRate: file.processingFormat.sampleRate,
                    rootPitch: Int32(zone.rootPitch),
                    minPitch: Int32(zone.minPitch),
                    maxPitch: Int32(zone.maxPitch),
                    gain: Float(zone.gain)))
            } catch {
                zoneLoadNotes.append(
                    "zone skipped (\(zone.audioFileURL.lastPathComponent)): "
                    + error.localizedDescription)
            }
        }
        zoneCount = loaded.count
        zones = .allocate(capacity: max(1, loaded.count))
        for (index, zone) in loaded.enumerated() {
            zones.advanced(by: index).initialize(to: zone)
        }
        // Init runs at reconcile time — stderr here is fine (same convention
        // as PlaybackGraph's unopenable-clip note), and never the render path.
        for note in zoneLoadNotes {
            FileHandle.standardError.write(Data("SamplerInstrument: \(note)\n".utf8))
        }

        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, params: lastAppliedScalars)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
        voices.deinitialize(count: Self.voiceCount)
        voices.deallocate()
        zones.deinitialize(count: zoneCount)
        zones.deallocate()
        for buffer in ownedChannelBuffers {
            buffer.deallocate()
        }
    }

    // MARK: - Main-actor surface

    /// Publishes new SCALAR parameters (oneShot/attack/release/gain) for
    /// pickup at the top of the next render quantum. Held voices are NOT
    /// interrupted. The zones array is deliberately ignored here — zone
    /// changes are structural and rebuild the instrument via
    /// `PlaybackGraph.InstrumentTrackKey`. No-op when nothing changed, so
    /// callers may invoke this on every parameter pass.
    @MainActor
    func apply(params: SamplerParams) {
        let scalars = ScalarParams(params)
        guard scalars != lastAppliedScalars else { return }
        lastAppliedScalars = scalars
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: scalars)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    // MARK: - InstrumentRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        lastParamsGeneration = .max  // ramp steps depend on the rate — readopt
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard let first = output.first, let firstData = first.mData else { return }
        let channel0 = firstData.assumingMemoryBound(to: Float.self)
        var channel1: UnsafeMutablePointer<Float>?
        if output.count > 1, let data = output[1].mData {
            channel1 = data.assumingMemoryBound(to: Float.self)
        }

        // Adopt a newly published scalar snapshot (borrowed — no
        // retain/release; the retire bin guarantees its lifetime).
        if let raw = daw_atomic_ptr_load(paramsSlot) {
            let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
            if snapshot.generation != lastParamsGeneration {
                lastParamsGeneration = snapshot.generation
                recomputeCoefficients(snapshot.params)
            }
        }

        var eventIndex = 0
        for frame in 0..<frameCount {
            // Same delivery rule as PolySynthInstrument: apply every event
            // whose clamped in-quantum offset is this frame BEFORE rendering.
            while eventIndex < events.count {
                let event = events[eventIndex]
                let offset = max(0, Int(event.sampleTime - renderStart))
                guard offset <= frame else { break }
                apply(event)
                eventIndex += 1
            }
            let (left, right) = renderFrame()
            channel0[frame] = left * outputGain
            channel1?[frame] = right * outputGain
        }

        // NaN/Inf guard, once per quantum: a blown-up voice is hard-killed.
        // (No recursive filter state here, so there is no denormal tail to
        // flush — the envelope frees voices at exact 0.)
        for index in 0..<Self.voiceCount where voices[index].active {
            if !(voices[index].level.isFinite && voices[index].position.isFinite) {
                voices[index] = Voice()
            }
        }

        // Channels beyond stereo mirror the right channel.
        if output.count > 2 {
            let byteCount = frameCount * MemoryLayout<Float>.stride
            let source = channel1.map { UnsafeRawPointer($0) } ?? UnsafeRawPointer(firstData)
            for buffer in output.dropFirst(2) {
                guard let data = buffer.mData else { continue }
                memcpy(data, source, min(Int(buffer.mDataByteSize), byteCount))
            }
        }
    }

    /// All-notes-off NOW (flush contract): immediate hard silence. Output is
    /// true zeros until the next noteOn.
    /// m16-b2: controller state neutralizes with the voice wipe — bend to
    /// center, pedal up (design-m16b §4.3).
    func reset() {
        for index in 0..<Self.voiceCount {
            voices[index] = Voice()
        }
        bendFactor = 1.0
        pedalDown = false
    }

    // MARK: - Per-sample playback (render thread)

    @inline(__always)
    private func renderFrame() -> (left: Float, right: Float) {
        var left: Float = 0
        var right: Float = 0
        for index in 0..<Self.voiceCount where voices[index].active {
            // 1. Envelope — linear segments. The release ramp subtracts a
            //    fixed fraction of the level captured at noteOff, so it
            //    reaches EXACTLY 0 after `release` seconds and frees the
            //    voice (true zeros from then on).
            if voices[index].releasing {
                voices[index].level -= voices[index].releaseFrom * releaseSlope
                if voices[index].level <= 0 {
                    voices[index] = Voice()  // freed — contributes nothing
                    continue
                }
            } else if voices[index].level < 1 {
                voices[index].level += attackStep
                if voices[index].level > 1 { voices[index].level = 1 }
            }

            // 2. Source read at the CURRENT playhead with linear
            //    interpolation (toward 0 past the last frame), then advance.
            //    The voice frees itself at buffer end.
            let zone = zones[Int(voices[index].zoneIndex)]
            let position = voices[index].position
            let idx = Int(position)
            if idx >= zone.frameCount {
                voices[index] = Voice()
                continue
            }
            let frac = Float(position - Double(idx))
            let next = idx + 1
            let l0 = zone.left[idx]
            let r0 = zone.right[idx]
            let l1 = next < zone.frameCount ? zone.left[next] : 0
            let r1 = next < zone.frameCount ? zone.right[next] : 0
            let gainNow = voices[index].level * voices[index].amp
            left += (l0 + (l1 - l0) * frac) * gainNow
            right += (r0 + (r1 - r0) * frac) * gainNow
            voices[index].position = position + voices[index].increment
        }
        return (left, right)
    }

    /// Render thread, once per adopted snapshot generation — pure float math,
    /// no allocation. `max(1, …)` makes attack = 0 a single-frame jump to
    /// full level rather than a divide-by-zero.
    private func recomputeCoefficients(_ params: ScalarParams) {
        oneShot = params.oneShot
        attackStep = Float(1.0 / max(1.0, params.attack * sampleRate))
        releaseSlope = Float(1.0 / max(1.0, params.release * sampleRate))
        outputGain = Float(params.gain)
    }

    // MARK: - Voice allocation (render thread)

    private func apply(_ event: ScheduledMIDIEvent) {
        if event.kind == ScheduledMIDIEvent.noteOn {
            // FIRST zone in array order whose span contains the pitch;
            // no matching zone → the note is silently ignored.
            let pitch = Int32(event.pitch)
            var zoneIndex = -1
            for index in 0..<zoneCount
            where pitch >= zones[index].minPitch && pitch <= zones[index].maxPitch {
                zoneIndex = index
                break
            }
            guard zoneIndex >= 0 else { return }
            let zone = zones[zoneIndex]

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

            var voice = Voice()
            voice.active = true
            voice.noteID = event.noteID
            voice.serial = nextSerial
            voice.zoneIndex = Int32(zoneIndex)
            voice.baseIncrement = exp2((Double(event.pitch) - Double(zone.rootPitch)) / 12.0)
                * zone.fileRate / sampleRate
            voice.increment = voice.baseIncrement * bendFactor  // bend applies now
            voice.amp = Float(event.velocity) / 127.0 * zone.gain
            voices[slot] = voice
            nextSerial &+= 1
        } else if event.kind == ScheduledMIDIEvent.noteOff {
            if oneShot { return }  // one-shot: every trigger plays to buffer end
            for index in 0..<Self.voiceCount
            where voices[index].active && voices[index].noteID == event.noteID {
                if pedalDown {
                    // Sustain (m16-b2): the pedal DEFERS the release — the
                    // voice keeps sounding, marked for the pedal-up sweep.
                    voices[index].sustained = true
                } else if voices[index].level <= 0 {
                    voices[index] = Voice()  // off before the first audible sample
                } else {
                    voices[index].releasing = true
                    voices[index].releaseFrom = voices[index].level
                }
            }
        } else if event.kind == ScheduledMIDIEvent.controlChange {
            // m16-b2 (design-m16b §4.3): the built-in honors CC64 (sustain)
            // only; every other CC is deliberately ignored here (documented —
            // hosted AUs receive them all). One-shot voices never mark
            // `sustained`, so the pedal-up sweep is a structural no-op there.
            if event.pitch == 64 {
                let down = event.velocity >= 64
                if pedalDown, !down {
                    // Pedal up: release every pedal-held voice — the deferred
                    // noteOffs, delivered now.
                    for index in 0..<Self.voiceCount
                    where voices[index].active && voices[index].sustained {
                        voices[index].sustained = false
                        if voices[index].level <= 0 {
                            voices[index] = Voice()
                        } else {
                            voices[index].releasing = true
                            voices[index].releaseFrom = voices[index].level
                        }
                    }
                }
                pedalDown = down
            }
        } else if event.kind == ScheduledMIDIEvent.pitchBend {
            // m16-b2: data1 = LSB, data2 = MSB (THE ONE DATA RULE); center
            // 8192 → factor 1. Playback-rate bend, applied to every sounding
            // voice in place — releasing tails bend too.
            let raw = Int(event.pitch & 0x7F) | (Int(event.velocity & 0x7F) << 7)
            bendFactor = exp2(Double(raw - 8_192) / 8_192.0
                              * Self.bendRangeSemitones / 12.0)
            for index in 0..<Self.voiceCount where voices[index].active {
                voices[index].increment = voices[index].baseIncrement * bendFactor
            }
        }
        // Channel pressure (kind 4) and any future kind fall through
        // silently — the C4 unknown-kind contract.
    }
}
