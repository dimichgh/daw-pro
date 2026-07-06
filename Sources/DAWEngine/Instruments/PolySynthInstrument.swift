import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// The built-in subtractive polyphonic synth (M3 iv). 16 voices, oldest
/// stolen when full (same policy as `TestToneInstrument`); noteOff — paired
/// by noteID — enters the release stage instead of hard-stopping.
///
/// Per-voice signal path:
///
///     oscillator (polyBLEP saw/square · naive triangle/sine)
///       → 2-pole SVF low-pass (Simper TPT form; shared coefficients,
///         per-voice state)
///       → linear ADSR × velocity/127 × 0.25 headroom
///
/// then the voice sum is scaled by the `gain` parameter.
///
/// Parameter updates are RT-safe: `apply(params:)` publishes an immutable
/// snapshot through a heap-allocated `daw_atomic_ptr`, with the same ≥ 1 s
/// retire-bin pattern `InstrumentRenderer` uses for schedules (main-actor
/// publish, render-thread acquire-load, borrowed pointer). The render thread
/// adopts a new snapshot at the top of the next quantum and recomputes
/// filter/envelope coefficients ONLY on generation change — never per
/// sample, and never interrupting held notes.
///
/// Render-path contract: `render()`/`reset()` allocate nothing, take no
/// locks, log nothing, and touch no ObjC — voices live in a fixed heap block
/// allocated in init; the snapshot is borrowed via `takeUnretainedValue`
/// (the retire bin guarantees its lifetime).
final class PolySynthInstrument: InstrumentRendering, @unchecked Sendable {
    // MARK: - Published parameter snapshot

    /// Immutable box crossing main actor → render thread through
    /// `paramsSlot`. `PolySynthParams` is a POD value (Doubles + a payload-
    /// free enum tag), so render-thread reads do no ARC or bridging work.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: PolySynthParams

        init(generation: UInt64, params: PolySynthParams) {
            self.generation = generation
            self.params = params
        }
    }

    // MARK: - Voice

    private enum Stage {
        static let attack: UInt8 = 1
        static let decay: UInt8 = 2
        static let sustain: UInt8 = 3
        static let release: UInt8 = 4
    }

    private struct Voice {
        var active = false
        var noteID: UInt64 = 0
        var serial: UInt64 = 0       // steal order: lowest serial = oldest voice
        var phase = 0.0              // normalized [0, 1)
        var phaseIncrement = 0.0     // frequency / sampleRate
        var velocityAmp: Float = 0   // velocity / 127
        var stage: UInt8 = 0
        var level: Float = 0         // envelope level, 0...1
        var releaseFrom: Float = 0   // level captured at noteOff (release anchor)
        var ic1eq: Float = 0         // SVF integrator states
        var ic2eq: Float = 0
    }

    private static let voiceCount = 16
    /// Per-voice headroom scale (same convention as TestToneInstrument):
    /// full-velocity triads stay comfortably under clipping before `gain`.
    private static let voiceAmplitude: Float = 0.25

    private let voices: UnsafeMutablePointer<Voice>
    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var nextSerial: UInt64 = 0
    private var lastParamsGeneration = UInt64.max  // .max forces first-quantum adoption
    // Coefficients derived from the adopted snapshot — recomputed per
    // GENERATION change, never per sample.
    private var waveformCode: UInt8 = 0            // 0 saw · 1 square · 2 triangle · 3 sine
    private var attackStep: Float = 0              // level units per sample
    private var decayStep: Float = 0
    private var sustainLevel: Float = 0
    private var releaseSlope: Float = 0            // fraction of releaseFrom per sample
    private var outputGain: Float = 0
    private var svfA1: Float = 0
    private var svfA2: Float = 0
    private var svfA3: Float = 0

    // Main-actor-only publish state: retired snapshots stay alive ≥ 1 s after
    // unpublish so a render quantum still borrowing the old pointer can never
    // touch freed memory (same contract as InstrumentRenderer's schedules).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: PolySynthParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: PolySynthParams = PolySynthParams()) {
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, params: params)
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
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next render
    /// quantum. Held notes are NOT interrupted — sounding voices adopt the
    /// new waveform / filter / envelope coefficients in place. No-op when
    /// nothing changed, so callers may invoke this on every parameter pass.
    @MainActor
    func apply(params: PolySynthParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: params)
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
        lastParamsGeneration = .max  // coefficients depend on the rate — readopt
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard let first = output.first, let firstData = first.mData else { return }
        let channel0 = firstData.assumingMemoryBound(to: Float.self)

        // Adopt a newly published parameter snapshot (borrowed — no
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
            // Same delivery rule as TestToneInstrument: apply every event
            // whose clamped in-quantum offset is this frame BEFORE
            // synthesizing it.
            while eventIndex < events.count {
                let event = events[eventIndex]
                let offset = max(0, Int(event.sampleTime - renderStart))
                guard offset <= frame else { break }
                apply(event)
                eventIndex += 1
            }
            channel0[frame] = renderFrame() * outputGain
        }

        // Denormal / NaN guard, once per quantum: a blown-up voice
        // (non-finite state) is hard-killed; sub-denormal filter tails flush
        // to exact zero so decayed voices never grind denormals.
        for index in 0..<Self.voiceCount where voices[index].active {
            if !(voices[index].level.isFinite && voices[index].ic1eq.isFinite
                    && voices[index].ic2eq.isFinite) {
                voices[index] = Voice()
            } else {
                if abs(voices[index].ic1eq) < 1e-15 { voices[index].ic1eq = 0 }
                if abs(voices[index].ic2eq) < 1e-15 { voices[index].ic2eq = 0 }
            }
        }

        // Stereo-identical: copy channel 0 to every other channel buffer.
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for buffer in output.dropFirst() {
            guard let data = buffer.mData else { continue }
            memcpy(data, firstData, min(Int(buffer.mDataByteSize), byteCount))
        }
    }

    /// All-notes-off NOW (flush contract): hard silence, envelopes and filter
    /// state cleared. Output is true zeros until the next noteOn.
    func reset() {
        for index in 0..<Self.voiceCount {
            voices[index] = Voice()
        }
    }

    // MARK: - Per-sample synthesis (render thread)

    @inline(__always)
    private func renderFrame() -> Float {
        var sample: Float = 0
        for index in 0..<Self.voiceCount where voices[index].active {
            // 1. Envelope — linear segments. The release ramp subtracts a
            //    fixed fraction of the level captured at noteOff, so it
            //    reaches EXACTLY 0 after `release` seconds and frees the
            //    voice (true zeros from then on).
            switch voices[index].stage {
            case Stage.attack:
                voices[index].level += attackStep
                if voices[index].level >= 1 {
                    voices[index].level = 1
                    voices[index].stage = Stage.decay
                }
            case Stage.decay:
                voices[index].level -= decayStep
                if voices[index].level <= sustainLevel {
                    voices[index].level = sustainLevel
                    voices[index].stage = Stage.sustain
                }
            case Stage.sustain:
                voices[index].level = sustainLevel  // tracks live sustain edits
            default:  // Stage.release
                voices[index].level -= voices[index].releaseFrom * releaseSlope
                if voices[index].level <= 0 {
                    voices[index] = Voice()  // freed — contributes nothing
                    continue
                }
            }

            // 2. Oscillator at the CURRENT phase, then advance. Saw and
            //    square carry the standard 2-sample polyBLEP residual around
            //    each discontinuity; triangle (1/n² rolloff) and sine stay
            //    naive.
            let t = voices[index].phase
            let dt = voices[index].phaseIncrement
            let osc: Double
            switch waveformCode {
            case 0:  // saw: naive ramp minus the step residual at the wrap
                osc = 2.0 * t - 1.0 - Self.polyBLEP(t, dt)
            case 1:  // square: corrected edges at t = 0 (up) and t = 0.5 (down)
                var tDown = t + 0.5
                if tDown >= 1.0 { tDown -= 1.0 }
                osc = (t < 0.5 ? 1.0 : -1.0)
                    + Self.polyBLEP(t, dt) - Self.polyBLEP(tDown, dt)
            case 2:  // triangle
                osc = 4.0 * abs(t - 0.5) - 1.0
            default:  // sine
                osc = sin(2.0 * .pi * t)
            }
            voices[index].phase = t + dt
            if voices[index].phase >= 1.0 { voices[index].phase -= 1.0 }

            // 3. Low-pass: 2-pole SVF (Simper TPT), shared coefficients,
            //    per-voice state.
            let input = Float(osc)
            let v3 = input - voices[index].ic2eq
            let v1 = svfA1 * voices[index].ic1eq + svfA2 * v3
            let v2 = voices[index].ic2eq + svfA2 * voices[index].ic1eq + svfA3 * v3
            voices[index].ic1eq = 2 * v1 - voices[index].ic1eq
            voices[index].ic2eq = 2 * v2 - voices[index].ic2eq

            sample += v2 * voices[index].level * voices[index].velocityAmp * Self.voiceAmplitude
        }
        return sample
    }

    /// Render thread, once per adopted snapshot generation — pure float math,
    /// no allocation. Envelope steps are per-sample level deltas; the SVF
    /// coefficients follow Simper's TPT derivation with resonance 0...1
    /// mapped to Q 0.5 (fully damped) ... 10 (strong stable peak).
    private func recomputeCoefficients(_ params: PolySynthParams) {
        switch params.waveform {
        case .saw: waveformCode = 0
        case .square: waveformCode = 1
        case .triangle: waveformCode = 2
        case .sine: waveformCode = 3
        }
        attackStep = Float(1.0 / (params.attack * sampleRate))
        decayStep = Float((1.0 - params.sustain) / (params.decay * sampleRate))
        sustainLevel = Float(params.sustain)
        releaseSlope = Float(1.0 / (params.release * sampleRate))
        outputGain = Float(params.gain)
        let cutoff = min(params.cutoffHz, sampleRate * 0.45)  // tan() stability guard
        let g = Float(tan(.pi * cutoff / sampleRate))
        let q = 0.5 + params.resonance * 9.5
        let k = Float(1.0 / q)
        svfA1 = 1 / (1 + g * (g + k))
        svfA2 = g * svfA1
        svfA3 = g * svfA2
    }

    /// Standard 2-sample polyBLEP residual: the difference between an ideal
    /// step and its band-limited version, applied around each waveform
    /// discontinuity. `t` is the normalized phase, `dt` the per-sample
    /// increment (both in [0, 1)).
    @inline(__always)
    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1.0
        }
        if t > 1.0 - dt {
            let x = (t - 1.0) / dt
            return x * x + x + x + 1.0
        }
        return 0.0
    }

    // MARK: - Voice allocation (render thread)

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
            var voice = Voice()
            voice.active = true
            voice.noteID = event.noteID
            voice.serial = nextSerial
            voice.phaseIncrement = frequency / sampleRate
            voice.velocityAmp = Float(event.velocity) / 127.0
            voice.stage = Stage.attack
            voices[slot] = voice
            nextSerial &+= 1
        } else if event.kind == ScheduledMIDIEvent.noteOff {
            for index in 0..<Self.voiceCount
            where voices[index].active && voices[index].noteID == event.noteID {
                if voices[index].level <= 0 {
                    voices[index] = Voice()  // off before the first audible sample
                } else {
                    voices[index].stage = Stage.release
                    voices[index].releaseFrom = voices[index].level
                }
            }
        }
    }
}
