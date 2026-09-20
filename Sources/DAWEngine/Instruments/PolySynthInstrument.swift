import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// The built-in subtractive polyphonic synth (M3 iv). 16 voices, oldest
/// stolen when full (same policy as `TestToneInstrument`); noteOff — paired
/// by noteID — enters the release stage instead of hard-stopping.
///
/// m16-b2 controllers (design-m16b §4.3): honors PITCH BEND (±2 st GM range,
/// frequency factor 2^(semitones/12) on every voice) and SUSTAIN (CC64 ≥ 64:
/// noteOffs defer until pedal-up). All other CCs and channel pressure are
/// safely ignored (documented); `reset()` re-centers bend and lifts the pedal.
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
        var phaseIncrement = 0.0     // baseIncrement × bendFactor
        var baseIncrement = 0.0      // unbent frequency / sampleRate (m16-b2)
        var sustained = false        // noteOff deferred by the pedal (m16-b2, CC64)
        var velocityAmp: Float = 0   // velocity / 127
        var stage: UInt8 = 0
        var level: Float = 0         // envelope level, 0...1
        var releaseFrom: Float = 0   // level captured at noteOff (release anchor)
        var ic1eq: Float = 0         // SVF integrator states
        var ic2eq: Float = 0

        // MARK: m39-g per-voice state
        //
        // ⭐ EVERY ONE OF THESE INITIALISES TO ITS OWN NEUTRAL, and the neutral
        // is chosen so the pre-m39-g arithmetic survives unchanged: the scale
        // factors are exactly 1.0 (and `x * 1.0 == x` is exact in IEEE 754, so
        // multiplying by them cannot move a bit), and the state variables are
        // exactly 0 and are only ever READ inside a branch their feature gates.

        /// Right-channel SVF state. Untouched — and therefore permanently zero
        /// — unless the patch actually spreads across the stereo field.
        var ic1eqR: Float = 0
        var ic2eqR: Float = 0
        /// Sub-oscillator phase and its own increment (a fixed octave below).
        var subPhase = 0.0
        var subIncrement = 0.0
        /// One-pole state for the noise layer's colour tilt.
        var noiseLP: Float = 0
        /// Slow random walk for oscillator drift, and the pitch factor it
        /// resolves to. ⚠️ `driftFactor` is stepped ONCE PER RENDER BLOCK.
        var driftWalk = 0.0
        var driftFactor = 1.0
        /// Composite per-note cutoff multiplier (velocity × key × jitter),
        /// frozen at note-on so a parameter edit can re-derive coefficients
        /// without re-rolling the random part.
        var cutoffScale = 1.0
        /// Per-note detune multiplier from `voiceJitter`.
        var detuneScale = 1.0
        /// Per-note pan from `voiceJitter`, applied AFTER the filter.
        var panL: Float = 1
        var panR: Float = 1
        /// Per-voice filter coefficients — used ONLY when something makes this
        /// voice's cutoff differ from the patch's (`perVoiceCutoff`). Otherwise
        /// the shared coefficients are read, exactly as before m39-g.
        var svfA1: Float = 0
        var svfA2: Float = 0
        var svfA3: Float = 0
        /// Curved-envelope release anchors: the AMPLITUDE at note-off (so a
        /// curved release starts where the note actually was, with no click)
        /// and 1/`releaseFrom` (so the per-sample progress needs no division).
        var releaseAmp: Float = 0
        var releaseFromInv: Float = 0
        /// Antiderivative-antialiased waveshaper memory: the previous scaled
        /// input and its antiderivative.
        ///
        /// ⚠️ ONE PAIR PER CHANNEL. The ADAA quotient is a function of the
        /// PREVIOUS sample of the signal it is shaping; feeding the left
        /// channel's history into the right one produces a wrong (and, at a
        /// stereo-spread patch's channel difference, audibly wrong) quotient.
        /// Sharing one pair here was a real bug caught before it shipped.
        var driveX1 = 0.0
        var driveF1 = 0.0
        var driveX1R = 0.0
        var driveF1R = 0.0
    }

    private static let voiceCount = 16
    /// ⛔ NOT A LOCAL 8. `PolySynthParams.maxUnisonVoices` is the ONE home for
    /// this number — it bounds the model's range AND this allocation, and the
    /// two must never be able to disagree, because the render thread indexes
    /// the allocation with a number the model clamped.
    private static let maxUnison = PolySynthParams.maxUnisonVoices
    /// Sub-voices stored OUTSIDE `Voice`: sub-voice 0 is the voice's own
    /// `phase`/`phaseIncrement` (so a unison-free patch runs the pre-m39-g code
    /// unchanged), and only the EXTRA 1..<n live in the parallel block.
    private static let extraUnison = maxUnison - 1
    /// Per-voice headroom scale (same convention as TestToneInstrument):
    /// full-velocity triads stay comfortably under clipping before `gain`.
    private static let voiceAmplitude: Float = 0.25

    private let voices: UnsafeMutablePointer<Voice>
    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>
    /// m39-g — phase and increment for unison sub-voices 1..<n, one fixed heap
    /// block allocated in `init` (never resized, never reallocated). Indexed
    /// `voiceIndex * extraUnison + (k - 1)`.
    private let extraPhase: UnsafeMutablePointer<Double>
    private let extraIncrement: UnsafeMutablePointer<Double>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var nextSerial: UInt64 = 0
    private var lastParamsGeneration = UInt64.max  // .max forces first-quantum adoption
    // Controller state (m16-b2, design-m16b §4.3): plain render-thread
    // scalars, mutated only by applied schedule events. Bend range is the GM
    // default ±2 semitones; `bendFactor` = 2^(semitones/12) multiplies every
    // voice's phase increment (recomputed per applied bend event — one exp2,
    // no allocation).
    private var bendFactor = 1.0
    private var pedalDown = false
    private static let bendRangeSemitones = 2.0
    /// m34-q: how many notes the CC 64 pedal may keep ringing. `Int.max` is the
    /// resolved form of the model's nil — "unlimited" — and it is deliberately
    /// a value the note-on guard below can never satisfy, so an instrument
    /// without a cap executes no extra work at all.
    private var pedalHoldLimit = Int.max
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

    // MARK: m39-g coefficients — derived per GENERATION, never per sample
    //
    // Every `…Active` flag below exists so the neutral path executes the
    // pre-m39-g instructions and no others. They are deliberately branches
    // rather than multiply-by-one: a multiply by a neutral factor would be
    // bit-exact but would still cost the work, and — more importantly — would
    // put arithmetic in a path this suite's goldens say must not change.
    private var unisonCount = 1
    private var unisonActive = false
    private var unisonNorm: Float = 1
    /// Frequency ratio and equal-power pan per unison sub-voice, sized
    /// `maxUnison`. Fixed blocks, filled per generation.
    private let unisonRatio: UnsafeMutablePointer<Double>
    private let unisonPanL: UnsafeMutablePointer<Float>
    private let unisonPanR: UnsafeMutablePointer<Float>
    private var stereoActive = false
    private var subActive = false
    private var subLevel: Float = 0
    private var subRatio = 0.5                 // 2^subOctave
    private var subWaveformCode: UInt8 = 3
    private var noiseActive = false
    private var noiseLevel: Float = 0
    private var noiseLPCoeff: Float = 0
    private var noiseMixLP: Float = 0          // out = mixLP·lp + mixWhite·white
    private var noiseMixWhite: Float = 0
    private var driftActive = false
    private var driftDepth = 0.0               // walk units → pitch, in octaves
    private var driveActive = false
    private var driveGain = 0.0
    private var driveNorm = 1.0
    private var perVoiceCutoff = false
    private var velToCutoffOctaves = 0.0
    private var keyToCutoffOctaves = 0.0
    private var jitterActive = false
    private var jitterAmount = 0.0
    private var envCurveActive = false
    private var envCurve: Float = 0
    private var invOneMinusSustain: Float = 0
    /// Base cutoff of the adopted snapshot, kept so a per-voice cutoff can be
    /// re-derived at note-on without re-reading the snapshot.
    private var baseCutoffHz = 8_000.0
    private var filterQ = 0.5
    /// Render-thread PRNG (xorshift64*). Seeded deterministically in `init` and
    /// re-seeded by `reset()`, so an offline render of the same project is
    /// reproducible sample-for-sample even with jitter, noise and drift on —
    /// which is what makes those features testable at all.
    private var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let rngSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    // Main-actor-only publish state: retired snapshots stay alive ≥ 1 s after
    // unpublish so a render quantum still borrowing the old pointer can never
    // touch freed memory (same contract as InstrumentRenderer's schedules).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: PolySynthParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    // MARK: - m39-e P1 — modulation delivery
    //
    // ⭐ THE DELIVERY MECHANISM IS THE LOOP THAT ALREADY EXISTS. `render`
    // walks per frame with sample-offset event dispatch, so a modulated value
    // is simply READ at `renderStart + frame` — there is no schedule, no event
    // kind, no widened POD. What m39-e adds here is a re-derivation of the
    // coefficients `recomputeCoefficients` freezes, at a 32-frame stride.
    //
    // ⚠️ THIS IS A BOUNDED, DECLARED EXCEPTION to this file's "frozen for the
    // life of the snapshot" contract, and it is bounded in exactly one way:
    // `modulationActive` is false unless an ENABLED ROUTE addresses an
    // instrument param on this strip. A patch with no modulation re-derives
    // nothing, branches once per frame on a Bool, and renders bit-identically
    // — which the m39-g golden digests assert, not assume.
    private let modulationSlot: UnsafeMutablePointer<daw_atomic_ptr>
    private var retiredModulation:
        [(snapshot: ModulationSnapshot, retiredAt: ContinuousClock.Instant)] = []
    private var lastModulationGeneration = UInt64.max
    /// Resolved once per snapshot generation — the render loop never searches.
    private var modTargetCutoff: Int32 = -1
    private var modTargetResonance: Int32 = -1
    private var modTargetGain: Int32 = -1
    private var modTargetAttack: Int32 = -1
    private var modTargetDecay: Int32 = -1
    private var modTargetSustain: Int32 = -1
    private var modTargetRelease: Int32 = -1
    private var modulationActive = false
    private var modulationTouchesFilter = false
    private var modulationTouchesEnvelope = false
    /// The base params the depth law offsets — the values in force before any
    /// modulation, captured when a parameter snapshot is adopted.
    private var modulationBaseParams = PolySynthParams()

    init(params: PolySynthParams = PolySynthParams()) {
        modulationSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(modulationSlot)
        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        // m39-g — every render-thread buffer is allocated ONCE, here, at its
        // maximum size. `unisonVoices` changes how much of these blocks is
        // READ; it can never change how much is allocated.
        let extraSlots = Self.voiceCount * Self.extraUnison
        extraPhase = .allocate(capacity: extraSlots)
        extraPhase.initialize(repeating: 0, count: extraSlots)
        extraIncrement = .allocate(capacity: extraSlots)
        extraIncrement.initialize(repeating: 0, count: extraSlots)
        unisonRatio = .allocate(capacity: Self.maxUnison)
        unisonRatio.initialize(repeating: 1, count: Self.maxUnison)
        unisonPanL = .allocate(capacity: Self.maxUnison)
        unisonPanL.initialize(repeating: 1, count: Self.maxUnison)
        unisonPanR = .allocate(capacity: Self.maxUnison)
        unisonPanR.initialize(repeating: 1, count: Self.maxUnison)
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
        if let raw = daw_atomic_ptr_exchange(modulationSlot, nil) {
            Unmanaged<ModulationSnapshot>.fromOpaque(raw).release()
        }
        modulationSlot.deallocate()
        voices.deinitialize(count: Self.voiceCount)
        voices.deallocate()
        let extraSlots = Self.voiceCount * Self.extraUnison
        extraPhase.deinitialize(count: extraSlots)
        extraPhase.deallocate()
        extraIncrement.deinitialize(count: extraSlots)
        extraIncrement.deallocate()
        unisonRatio.deinitialize(count: Self.maxUnison)
        unisonRatio.deallocate()
        unisonPanL.deinitialize(count: Self.maxUnison)
        unisonPanL.deallocate()
        unisonPanR.deinitialize(count: Self.maxUnison)
        unisonPanR.deallocate()
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

    /// m39-e P1: publishes the strip's modulation snapshot. Same discipline as
    /// `apply(params:)` — the slot holds a +1 retain, displaced snapshots go to
    /// a retire bin and survive ≥ 1 s so an in-flight quantum's borrow is safe.
    @MainActor
    func publishModulation(_ snapshot: ModulationSnapshot?) {
        let now = ContinuousClock.now
        let raw = snapshot.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let old = daw_atomic_ptr_exchange(modulationSlot, raw) {
            retiredModulation.append(
                (Unmanaged<ModulationSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retiredModulation.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
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

        // m39-e P1 — adopt the modulation snapshot and RESOLVE its targets
        // once per generation, so the per-frame path never searches.
        var modulation: ModulationSnapshot?
        var modulationPosition: Int64 = 0
        if let raw = daw_atomic_ptr_load(modulationSlot) {
            let snapshot = Unmanaged<ModulationSnapshot>.fromOpaque(raw).takeUnretainedValue()
            if snapshot.generation != lastModulationGeneration {
                lastModulationGeneration = snapshot.generation
                adoptModulationTargets(snapshot)
            }
            if modulationActive {
                modulation = snapshot
                modulationPosition = snapshot.originSample &+ renderStart
            }
        } else if modulationActive {
            // Unpublished: fall straight back to the frozen coefficients.
            modulationActive = false
            lastModulationGeneration = UInt64.max
            recomputeCoefficients(modulationBaseParams)
        }

        // m39-g — OSCILLATOR DRIFT, STEPPED ONCE PER BLOCK. This is the whole
        // reason drift is in this item and an LFO is not: the random walk
        // advances at the `render()` boundary, so a sounding voice's pitch
        // moves without any coefficient being recomputed per sample. Skipped
        // entirely — not stepped by zero — when the patch has no drift.
        if driftActive {
            for index in 0..<Self.voiceCount where voices[index].active {
                // One-pole-smoothed white walk: slow, bounded, uncorrelated
                // between voices because they draw from one stream in turn.
                let step = nextRandomBipolar()
                voices[index].driftWalk = voices[index].driftWalk * 0.995 + step * 0.005
                voices[index].driftWalk = min(1, max(-1, voices[index].driftWalk))
                voices[index].driftFactor = exp2(voices[index].driftWalk * driftDepth)
                refreshIncrements(at: index)
            }
        }

        // m39-g — the ONE place the instrument may write a second channel.
        // `stereoActive` is false for every patch that has not opted into
        // spread or per-voice pan jitter, and the false path below is the
        // pre-m39-g path verbatim: render channel 0, memcpy it everywhere.
        let channel1: UnsafeMutablePointer<Float>? =
            (stereoActive && output.count >= 2)
                ? output[1].mData?.assumingMemoryBound(to: Float.self)
                : nil

        var eventIndex = 0
        for frame in 0..<frameCount {
            // m39-e P1 — the modulation stride. One Bool test per frame when
            // nothing is modulated (and the m39-g goldens prove that test
            // cannot move a bit); a coefficient re-derivation every 32 frames
            // when something is. 32 frames is 1 500 Hz at 48 kHz, whose
            // 0.25-image-ratio ceiling is 300 Hz — six times above the top of
            // the musical modulation band, so nothing authorable aliases.
            if let modulation, frame % ModulationDepth.evaluationStrideFrames == 0 {
                applyModulation(modulation, atSample: modulationPosition &+ Int64(frame))
            }
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
            let (left, right) = renderFrame()
            if let channel1 {
                channel0[frame] = left * outputGain
                channel1[frame] = right * outputGain
            } else if stereoActive {
                // A spread patch asked to render into ONE channel. Fold down
                // at equal power, so a centred voice keeps exactly its mono
                // level (0.7071 + 0.7071) × 0.7071 = 1.
                channel0[frame] = (left + right) * 0.707_106_78 * outputGain
            } else {
                channel0[frame] = left * outputGain
            }
        }

        // Denormal / NaN guard, once per quantum: a blown-up voice
        // (non-finite state) is hard-killed; sub-denormal filter tails flush
        // to exact zero so decayed voices never grind denormals.
        //
        // ⚠️ m39-g EXTENDED THIS DELIBERATELY. Every state variable the
        // richness pass added is a feedback path or an accumulator that can
        // blow up or grind: the right-channel SVF is a second filter, the noise
        // one-pole is a third, and the waveshaper's ADAA memory divides by a
        // difference of its own inputs. A guard that covered only the original
        // three would let a stereo patch grind denormals in the right channel
        // forever while the left one read perfectly clean.
        for index in 0..<Self.voiceCount where voices[index].active {
            if !(voices[index].level.isFinite && voices[index].ic1eq.isFinite
                    && voices[index].ic2eq.isFinite && voices[index].ic1eqR.isFinite
                    && voices[index].ic2eqR.isFinite && voices[index].noiseLP.isFinite
                    && voices[index].driveX1.isFinite && voices[index].driveF1.isFinite
                    && voices[index].driveX1R.isFinite && voices[index].driveF1R.isFinite
                    && voices[index].driftFactor.isFinite) {
                voices[index] = Voice()
            } else {
                if abs(voices[index].ic1eq) < 1e-15 { voices[index].ic1eq = 0 }
                if abs(voices[index].ic2eq) < 1e-15 { voices[index].ic2eq = 0 }
                if abs(voices[index].ic1eqR) < 1e-15 { voices[index].ic1eqR = 0 }
                if abs(voices[index].ic2eqR) < 1e-15 { voices[index].ic2eqR = 0 }
                if abs(voices[index].noiseLP) < 1e-15 { voices[index].noiseLP = 0 }
                if abs(voices[index].driveX1) < 1e-15 { voices[index].driveX1 = 0 }
                if abs(voices[index].driveX1R) < 1e-15 { voices[index].driveX1R = 0 }
            }
        }

        let byteCount = frameCount * MemoryLayout<Float>.stride
        if let channel1 {
            // Channels 2+ alternate L/R. (Nothing in the app renders an
            // instrument into more than two channels today; this is here so
            // that if anything ever does, it gets a sane image rather than a
            // mono copy of the left side.)
            for (index, buffer) in output.enumerated() where index >= 2 {
                guard let data = buffer.mData else { continue }
                let source = index % 2 == 0
                    ? UnsafeRawPointer(channel0) : UnsafeRawPointer(channel1)
                memcpy(data, source, min(Int(buffer.mDataByteSize), byteCount))
            }
        } else {
            // Stereo-identical: copy channel 0 to every other channel buffer.
            for buffer in output.dropFirst() {
                guard let data = buffer.mData else { continue }
                memcpy(data, firstData, min(Int(buffer.mDataByteSize), byteCount))
            }
        }
    }

    /// All-notes-off NOW (flush contract): hard silence, envelopes and filter
    /// state cleared. Output is true zeros until the next noteOn.
    /// m16-b2: controller state neutralizes with the voice wipe — bend to
    /// center, pedal up (design-m16b §4.3): a ring-overflow reset can no more
    /// stick the pedal than a dropped note-off can stick a voice.
    func reset() {
        for index in 0..<Self.voiceCount {
            voices[index] = Voice()
        }
        bendFactor = 1.0
        pedalDown = false
        // m39-g: the sub-voice block is voice state too — a stale phase left
        // here would make the next note-on start mid-cycle on a patch whose
        // unison is supposed to begin fresh.
        for slot in 0..<(Self.voiceCount * Self.extraUnison) {
            extraPhase[slot] = 0
            extraIncrement[slot] = 0
        }
        // ⭐ RE-SEEDED, not merely carried forward. `reset()` is the flush
        // contract, and an offline render that starts from a flush must produce
        // the same samples every time or none of the randomised features
        // (jitter, drift, noise) can be tested at all. Determinism is a
        // TESTABILITY requirement here, not an aesthetic one.
        rngState = Self.rngSeed
    }

    // MARK: - Per-sample synthesis (render thread)

    /// Returns (left, right). ⚠️ When `stereoActive` is false the right term is
    /// never computed and the returned pair is (mono, mono) — the caller writes
    /// only the left. That is not a micro-optimisation: it is what keeps a
    /// default patch's arithmetic bit-for-bit the pre-m39-g arithmetic.
    @inline(__always)
    private func renderFrame() -> (Float, Float) {
        var sampleL: Float = 0
        var sampleR: Float = 0
        for index in 0..<Self.voiceCount where voices[index].active {
            // 1. Envelope — the RAMP is unchanged: linear segments, same
            //    steps, same comparisons, same exact-zero release that frees
            //    the voice after exactly `release` seconds. m39-g's curve knob
            //    does NOT change the ramp or any segment's duration; it maps
            //    the ramp through a shaping function to get the AMPLITUDE.
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
            // The amplitude the envelope is actually AT. Without a curve this
            // is the ramp itself, read straight through — one branch, no
            // arithmetic, which is what the identity goldens require.
            let amp = envCurveActive ? shapedAmplitude(at: index) : voices[index].level

            // 2. Oscillator(s) at the CURRENT phase, then advance. Saw and
            //    square carry the standard 2-sample polyBLEP residual around
            //    each discontinuity; triangle (1/n² rolloff) and sine stay
            //    naive.
            let t = voices[index].phase
            let dt = voices[index].phaseIncrement
            let osc = Self.oscillator(code: waveformCode, t, dt)
            voices[index].phase = t + dt
            if voices[index].phase >= 1.0 { voices[index].phase -= 1.0 }

            // 2a. UNISON. Sub-voice 0 is the oscillator just read; the extra
            //     sub-voices live in the parallel block. Mono sums them into
            //     one signal; a spread patch keeps an L and an R sum so the
            //     detuned copies can sit in different places.
            var mixL: Double
            var mixR: Double
            if unisonActive {
                if stereoActive {
                    mixL = osc * Double(unisonPanL[0])
                    mixR = osc * Double(unisonPanR[0])
                    for k in 1..<unisonCount {
                        let slot = index * Self.extraUnison + (k - 1)
                        let tk = extraPhase[slot]
                        let dtk = extraIncrement[slot]
                        let oscK = Self.oscillator(code: waveformCode, tk, dtk)
                        var next = tk + dtk
                        if next >= 1.0 { next -= 1.0 }
                        extraPhase[slot] = next
                        mixL += oscK * Double(unisonPanL[k])
                        mixR += oscK * Double(unisonPanR[k])
                    }
                } else {
                    mixL = osc
                    for k in 1..<unisonCount {
                        let slot = index * Self.extraUnison + (k - 1)
                        let tk = extraPhase[slot]
                        let dtk = extraIncrement[slot]
                        mixL += Self.oscillator(code: waveformCode, tk, dtk)
                        var next = tk + dtk
                        if next >= 1.0 { next -= 1.0 }
                        extraPhase[slot] = next
                    }
                    mixR = 0
                }
                mixL *= Double(unisonNorm)
                mixR *= Double(unisonNorm)
            } else if stereoActive {
                // Jitter-only stereo: one oscillator, centred, both sides.
                mixL = osc * 0.707_106_781_186_547_5
                mixR = mixL
            } else {
                mixL = osc
                mixR = 0
            }

            // 2b. SUB-OSCILLATOR — a fixed octave below, its own shape and
            //     level, centred. Skipped entirely at zero level.
            if subActive {
                let st = voices[index].subPhase
                let sdt = voices[index].subIncrement
                let sub = Self.oscillator(code: subWaveformCode, st, sdt) * Double(subLevel)
                voices[index].subPhase = st + sdt
                if voices[index].subPhase >= 1.0 { voices[index].subPhase -= 1.0 }
                if stereoActive {
                    let centred = sub * 0.707_106_781_186_547_5
                    mixL += centred
                    mixR += centred
                } else {
                    mixL += sub
                }
            }

            // 2c. NOISE LAYER — pre-filter on purpose, so the filter (and a
            //     boosted resonance) shapes it. `noiseMixLP`/`noiseMixWhite`
            //     resolve the colour tilt into two coefficients at generation
            //     time, so the per-sample cost is one one-pole and two
            //     multiplies.
            if noiseActive {
                let white = Float(nextRandomBipolar())
                voices[index].noiseLP += noiseLPCoeff * (white - voices[index].noiseLP)
                let coloured = noiseMixLP * voices[index].noiseLP + noiseMixWhite * white
                let scaled = Double(coloured * noiseLevel)
                if stereoActive {
                    let centred = scaled * 0.707_106_781_186_547_5
                    mixL += centred
                    mixR += centred
                } else {
                    mixL += scaled
                }
            }

            // 3. DRIVE — waveshaper at the filter INPUT, so the low-pass that
            //    follows removes the harmonics it adds above cutoff. See
            //    `adaaTanh` for why it is antiderivative-antialiased rather
            //    than a naive `tanh`.
            if driveActive {
                mixL = adaaTanh(mixL, at: index)
                if stereoActive { mixR = adaaTanh(mixR, at: index, rightChannel: true) }
            }
            let inputL = Float(mixL)
            let inputR = Float(mixR)

            // 4. Low-pass: 2-pole SVF (Simper TPT), per-voice state. The
            //    coefficients are the SHARED ones unless velocity/key tracking
            //    or jitter gave this voice a cutoff of its own — and when they
            //    did, they were computed once at note-on, never per sample.
            let a1 = perVoiceCutoff ? voices[index].svfA1 : svfA1
            let a2 = perVoiceCutoff ? voices[index].svfA2 : svfA2
            let a3 = perVoiceCutoff ? voices[index].svfA3 : svfA3
            let v3 = inputL - voices[index].ic2eq
            let v1 = a1 * voices[index].ic1eq + a2 * v3
            let v2 = voices[index].ic2eq + a2 * voices[index].ic1eq + a3 * v3
            voices[index].ic1eq = 2 * v1 - voices[index].ic1eq
            voices[index].ic2eq = 2 * v2 - voices[index].ic2eq

            if stereoActive {
                let w3 = inputR - voices[index].ic2eqR
                let w1 = a1 * voices[index].ic1eqR + a2 * w3
                let w2 = voices[index].ic2eqR + a2 * voices[index].ic1eqR + a3 * w3
                voices[index].ic1eqR = 2 * w1 - voices[index].ic1eqR
                voices[index].ic2eqR = 2 * w2 - voices[index].ic2eqR
                let voiceGain = amp * voices[index].velocityAmp * Self.voiceAmplitude
                sampleL += v2 * voiceGain * voices[index].panL
                sampleR += w2 * voiceGain * voices[index].panR
            } else {
                // ⛔⛔ THE MULTIPLY ORDER HERE IS LOAD-BEARING. Float
                // multiplication is not associative, and hoisting
                // `amp × velocityAmp × voiceAmplitude` into a common
                // sub-expression — which is what a tidier version of this
                // function did — re-rounds the product and moved the DEFAULT
                // render by one ULP. Nothing measured it but the identity
                // goldens, and they are why it was caught. Left-to-right,
                // exactly as the pre-m39-g engine wrote it.
                sampleL += v2 * amp * voices[index].velocityAmp * Self.voiceAmplitude
            }
        }
        return (sampleL, sampleR)
    }

    /// ONE oscillator body, shared by the main stack, every unison sub-voice
    /// and the sub-oscillator — so "which waveform does code 1 mean" can only
    /// ever be answered in one place.
    @inline(__always)
    private static func oscillator(code: UInt8, _ t: Double, _ dt: Double) -> Double {
        switch code {
        case 0:  // saw: naive ramp minus the step residual at the wrap
            return 2.0 * t - 1.0 - polyBLEP(t, dt)
        case 1:  // square: corrected edges at t = 0 (up) and t = 0.5 (down)
            var tDown = t + 0.5
            if tDown >= 1.0 { tDown -= 1.0 }
            return (t < 0.5 ? 1.0 : -1.0) + polyBLEP(t, dt) - polyBLEP(tDown, dt)
        case 2:  // triangle
            return 4.0 * abs(t - 0.5) - 1.0
        default:  // sine
            return sin(2.0 * .pi * t)
        }
    }

    /// The envelope curve, m39-g. `p` is the segment's linear progress and the
    /// shape is `p + c·(p² − p)`: at c = 0 it is exactly `p` (which is why the
    /// caller can branch around it entirely), at c = +1 it is `p²` — the
    /// slow-start attack and fast-then-lingering decay real envelopes have —
    /// and at c = −1 it is `2p − p²`, the mirror image.
    ///
    /// Two multiplies and an add. No `pow`, no division, no table.
    @inline(__always)
    private func shape(_ p: Float) -> Float { p + envCurve * (p * p - p) }

    /// The curved amplitude for one voice at its current ramp position.
    ///
    /// ⭐ THE RELEASE LEG IS WHY `releaseAmp` EXISTS. A curved release must
    /// start from the amplitude the voice was ACTUALLY at when the key lifted,
    /// not from its ramp value — those differ under a curve, and starting from
    /// the ramp value would step the output at every note-off. Since
    /// `shape(1) == 1` exactly, anchoring on `releaseAmp` makes the first
    /// released sample equal the last held one.
    @inline(__always)
    private func shapedAmplitude(at index: Int) -> Float {
        switch voices[index].stage {
        case Stage.attack:
            return shape(voices[index].level)
        case Stage.decay:
            let p = (voices[index].level - sustainLevel) * invOneMinusSustain
            return sustainLevel + (1 - sustainLevel) * shape(p)
        case Stage.sustain:
            return sustainLevel
        default:  // Stage.release
            return voices[index].releaseAmp * shape(voices[index].level
                                                    * voices[index].releaseFromInv)
        }
    }

    /// ⛔⛔ WHY THE DRIVE KNOB IS NOT A BARE `tanh`, and why that mattered
    /// enough to change the design mid-item.
    ///
    /// A memoryless nonlinearity generates harmonics without bound. Every one
    /// it makes above Nyquist folds back as INHARMONIC aliasing, and on a synth
    /// this is the worst case in the whole app: the signals being driven are
    /// bright saws and squares, and the artefacts get worse the higher you
    /// play. The tell is unmistakable once you look for it — partials that move
    /// DOWN as the note moves UP. This tree has already shipped one
    /// un-oversampled `tanh` (`SaturatorEffect`) and has a standing,
    /// acknowledged debt on it; a second one was not worth adding.
    ///
    /// So this is FIRST-ORDER ANTIDERIVATIVE ANTIALIASING (Parker/Zavalishin/
    /// Le Bivic, DAFx-16): instead of evaluating f(x) at the sample point,
    /// evaluate the average of f across the segment between this input and the
    /// last, using f's antiderivative —
    ///
    ///     y[n] = (F(x[n]) − F(x[n−1])) / (x[n] − x[n−1]),   F = ∫tanh = ln cosh
    ///
    /// — which suppresses the folded harmonics without running the whole voice
    /// at 2× or 4× the sample rate.
    ///
    /// ⭐ MEASURED, NOT ASSUMED (`PolySynthRichnessTests`:
    /// `adaaDriveSuppressesTheFoldback` and `drivenSawInterHarmonicFloor`,
    /// against the control `naiveTanhAliasesOnARisingRun`). Versus a naive
    /// `tanh` at the same drive:
    ///
    ///   · sine, probed at the EXACT fold frequencies — 4.8–14.4× (13–23 dB).
    ///     This is the load-bearing evidence: `tanh` is odd, so every folded
    ///     partial is at a frequency computed rather than searched for, and the
    ///     probe is aimed exactly there.
    ///   · bright SAW, the realistic worst case — the inter-harmonic floor
    ///     improves 25–33× at pitches 60–96. ⚠️ TREAT THAT AS A RATIO, NOT AS
    ///     ABSOLUTE LEVELS: a saw's folds are dense, so this probe samples
    ///     BETWEEN the harmonics as a leakage proxy rather than hitting a fold
    ///     head-on, and the absolute floors it reports under-read. The residue
    ///     is 13 dB above the polyBLEP oscillator's own floor at pitch 60 and
    ///     18 dB above at 72 — near it, not at it.
    ///
    /// ⚠️ THE DOCUMENTED LIMIT: the residual foldback in the audible band stays
    /// under −40 dB through pitch 96 (C7) and first crosses it at pitch 108
    /// (C8), reaching ≈ −15 dB at pitch 126. First-order ADAA loses its
    /// advantage as the signal approaches Nyquist; that is inherent to the
    /// method, not a tuning miss. If a sustained tone above C7 ever becomes a
    /// real use case, the fix is oversampling, not a coefficient.
    ///
    /// ⚠️ It costs ONE SAMPLE OF STATE per voice per channel, so the brief's
    /// "stateless per sample" is no longer literally true of this unit. It
    /// remains allocation-free, lock-free and branch-light, which is what the
    /// render contract actually requires.
    ///
    /// The `|Δx| < ε` fallback is not optional: the quotient is 0/0 at a
    /// stationary input (a held DC value, or silence), which is exactly what a
    /// released voice decays into.
    @inline(__always)
    private func adaaTanh(_ input: Double, at index: Int, rightChannel: Bool = false) -> Double {
        let x = input * driveGain
        let f = Self.logCosh(x)
        let previousX = rightChannel ? voices[index].driveX1R : voices[index].driveX1
        let previousF = rightChannel ? voices[index].driveF1R : voices[index].driveF1
        let delta = x - previousX
        let shaped: Double
        // ⚠️⚠️ THE THRESHOLD AND THE PRECISION ARE A PAIR. `F(x) = ln cosh x` is
        // ~7.3 at |x| = 8, where a Float ULP is ~5e-7 — so `F(x) − F(x₁)`
        // carries ~1e-6 of absolute error, and dividing that by a small `delta`
        // AMPLIFIES it: at delta = 1e-5 the quotient is ~10 % wrong. A sine
        // spends many samples near its peaks, where delta is small, so that
        // error is not rare and it is not harmonic — it is broadband noise
        // injected by the antialiaser itself. Computing in Double drops the
        // error to ~1e-15 and makes the 1e-5 threshold comfortable again.
        if abs(delta) > 1e-5 {
            shaped = (f - previousF) / delta
        } else {
            shaped = tanh(0.5 * (x + previousX))
        }
        if rightChannel {
            voices[index].driveX1R = x
            voices[index].driveF1R = f
        } else {
            voices[index].driveX1 = x
            voices[index].driveF1 = f
        }
        return shaped * driveNorm
    }

    /// ln(cosh x), written so it cannot overflow: `cosh` of anything past ~89
    /// is `+inf` in `Float`, and the drive stage can legitimately see large
    /// inputs. |x| + ln(1 + e^−2|x|) − ln 2 is the same function, evaluated
    /// where the exponential is always ≤ 1.
    @inline(__always)
    private static func logCosh(_ x: Double) -> Double {
        let a = abs(x)
        return a + log1p(exp(-2 * a)) - 0.693_147_180_559_945_3
    }

    /// xorshift64*, on the render thread: no allocation, no locks, no libc RNG
    /// (`arc4random` takes a lock and can syscall). Returns [-1, 1).
    @inline(__always)
    private func nextRandomBipolar() -> Double {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let value = rngState &* 0x2545_F491_4F6C_DD1D
        // Top 53 bits → [0, 1), then centre.
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0) * 2.0 - 1.0
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
        // m34-q: resolved to a plain Int here, once per snapshot — the render
        // thread never sees an Optional. A lowered cap takes effect at the NEXT
        // note-on rather than instantly, the same rule the Sampler's voice mode
        // follows and for the same reason: trimming already-sounding notes at a
        // snapshot boundary would be a fade the user never played, for a knob
        // they turned between notes anyway.
        pedalHoldLimit = params.effectivePedalHoldLimit

        // MARK: m39-g coefficients — ONCE PER GENERATION, never per sample
        //
        // ⛔ THE CONTRACT THIS FUNCTION IS: everything derived here is frozen
        // for the life of the snapshot. Nothing below may be recomputed while a
        // note sounds. A filter envelope or an LFO would have to, which is
        // exactly why neither is in this item (research §0, §8 — m39-e).

        // Unison. `unisonNorm` is 1/√n so stacking voices adds weight without
        // adding level; at n = 1 it is exactly 1.0, and `x * 1.0` cannot move a
        // bit — but the caller branches anyway rather than relying on that.
        unisonCount = params.effectiveUnisonVoices
        unisonActive = params.unisonIsEffective
        unisonNorm = unisonActive ? Float(1.0 / Double(unisonCount).squareRoot()) : 1
        stereoActive = params.stereoSpreadIsEffective
        let detune = params.effectiveUnisonDetuneCents
        let spread = params.effectiveUnisonStereoSpread
        for k in 0..<Self.maxUnison {
            guard unisonCount > 1, k < unisonCount else {
                unisonRatio[k] = 1
                unisonPanL[k] = 0.707_106_78
                unisonPanR[k] = 0.707_106_78
                continue
            }
            // Spread evenly across ±detune/2. With an ODD count the middle
            // sub-voice lands exactly on 0 cents, so the played pitch is still
            // literally in the stack rather than merely averaged.
            let position = Double(k) / Double(unisonCount - 1) - 0.5   // -0.5 ... +0.5
            unisonRatio[k] = exp2(position * detune / 1_200.0)
            // Equal power, so the stack's total energy does not dip in the
            // middle of the field the way a linear pan law's would.
            let pan = position * 2.0 * spread                          // -1 ... +1
            let angle = (pan + 1.0) * .pi / 4.0
            unisonPanL[k] = Float(cos(angle))
            unisonPanR[k] = Float(sin(angle))
        }

        // Sub-oscillator.
        subActive = params.subIsEffective
        subLevel = Float(params.effectiveSubLevel)
        subRatio = exp2(Double(params.effectiveSubOctave))
        switch params.effectiveSubWaveform {
        case .saw: subWaveformCode = 0
        case .square: subWaveformCode = 1
        case .triangle: subWaveformCode = 2
        case .sine: subWaveformCode = 3
        }

        // Noise. The colour tilt resolves to two mix coefficients so the
        // per-sample path is one one-pole and two multiplies — 0 = fully
        // low-passed, 0.5 = white, 1 = fully high-passed.
        noiseActive = params.noiseIsEffective
        noiseLevel = Float(params.effectiveNoiseLevel)
        noiseLPCoeff = Float(1.0 - exp(-2.0 * .pi * 2_000.0 / sampleRate))
        let colour = params.effectiveNoiseColor
        if colour <= 0.5 {
            noiseMixLP = Float(1.0 - 2.0 * colour)
            noiseMixWhite = Float(2.0 * colour)
        } else {
            noiseMixLP = Float(-(2.0 * colour - 1.0))
            noiseMixWhite = 1
        }

        // Drift — depth in OCTAVES, so the per-block update is one exp2.
        driftActive = params.driftIsEffective
        driftDepth = params.effectiveDrift * PolySynthParams.driftMaxCents / 1_200.0

        // Drive. The gain scales from 0, so as the knob approaches zero the
        // normalised shaper approaches the identity — continuous with the
        // bypass, instead of snapping into saturation the moment it leaves 0.
        driveActive = params.driveIsEffective
        driveGain = params.effectiveDrive * 8.0
        driveNorm = driveGain > 1e-4 ? 1.0 / tanh(driveGain) : 1

        // Cutoff tracking + jitter. All three merely decide whether a voice
        // gets a cutoff of its own; the cutoff itself is computed at NOTE-ON.
        perVoiceCutoff = params.cutoffIsPerVoice
        velToCutoffOctaves = params.effectiveVelocityToCutoff
            * PolySynthParams.cutoffTrackMaxOctaves
        keyToCutoffOctaves = params.effectiveKeyToCutoff
        jitterActive = params.effectiveVoiceJitter > 0
        jitterAmount = params.effectiveVoiceJitter

        // Envelope curve.
        envCurveActive = params.envelopeCurveIsEffective
        envCurve = Float(params.effectiveEnvelopeCurve)
        // Guarded: at sustain == 1 the decay segment is zero-length, and the
        // progress it would divide by is zero.
        invOneMinusSustain = params.sustain < 1
            ? Float(1.0 / (1.0 - params.sustain)) : 0

        // The shared filter, unchanged in the default case. `effectiveQ`
        // returns the legacy `0.5 + resonance × 9.5` verbatim whenever
        // `resonanceBoost` is 0, so a pre-m39-g patch derives a bit-identical
        // coefficient triple.
        baseCutoffHz = params.cutoffHz
        filterQ = params.effectiveQ
        // m39-e P1: the base the depth law offsets. Captured here, where the
        // params are adopted, so a modulated value is always relative to the
        // patch the user set rather than to the last modulated value.
        modulationBaseParams = params
        let cutoff = min(params.cutoffHz, sampleRate * 0.45)  // tan() stability guard
        let g = Float(tan(.pi * cutoff / sampleRate))
        let k = Float(1.0 / filterQ)
        svfA1 = 1 / (1 + g * (g + k))
        svfA2 = g * svfA1
        svfA3 = g * svfA2

        // A per-voice cutoff patch must re-derive its SOUNDING voices' own
        // coefficients too, or a live cutoff edit would be inaudible until the
        // next note — the opposite of the pre-m39-g behaviour, where held notes
        // adopt a new cutoff in place. Sixteen `tan()` calls at a parameter
        // edit, and none at all for a patch that does not track.
        if perVoiceCutoff {
            for index in 0..<Self.voiceCount where voices[index].active {
                updateVoiceFilter(at: index)
            }
        }
    }

    // MARK: - m39-e P1 — modulation

    /// Resolves the snapshot's instrument targets to fields, ONCE per
    /// generation, on the render thread but off the per-frame path. A strip
    /// with no instrument route leaves `modulationActive` false and the render
    /// loop's stride branch is a single Bool test that can never fire.
    private func adoptModulationTargets(_ snapshot: ModulationSnapshot) {
        let wasActive = modulationActive
        modTargetCutoff = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.cutoffHz.code, snapshot: snapshot)
        modTargetResonance = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.resonance.code, snapshot: snapshot)
        modTargetGain = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.gain.code, snapshot: snapshot)
        modTargetAttack = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.attack.code, snapshot: snapshot)
        modTargetDecay = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.decay.code, snapshot: snapshot)
        modTargetSustain = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.sustain.code, snapshot: snapshot)
        modTargetRelease = ModulationEvaluator.targetIndex(
            forInstrumentParamCode: InstrumentParamID.release.code, snapshot: snapshot)
        modulationTouchesFilter = modTargetCutoff >= 0 || modTargetResonance >= 0
        modulationTouchesEnvelope = modTargetAttack >= 0 || modTargetDecay >= 0
            || modTargetSustain >= 0 || modTargetRelease >= 0
        modulationActive = modulationTouchesFilter || modulationTouchesEnvelope
            || modTargetGain >= 0
        // A route that has just been REMOVED must restore the frozen
        // coefficients, or the last modulated value would stick — a setter's
        // return is not proof it took, and neither is a route's removal.
        if wasActive, !modulationActive { recomputeCoefficients(modulationBaseParams) }
    }

    /// One stride's worth of modulated parameters. Re-derives ONLY what a
    /// route actually addresses: a cutoff route costs one `tan` and three
    /// divides (measured 11.5–18.2 ns at `-O`), an envelope route costs four
    /// divides, and a patch that modulates neither never gets here.
    ///
    /// ⚠️ A per-voice-cutoff patch re-derives its SOUNDING voices too, the same
    /// sixteen `tan()` calls `recomputeCoefficients` already accepts at a
    /// parameter edit — otherwise a tracking patch's held notes would ignore
    /// the modulation entirely, which is the inverse of the behaviour a user
    /// gets from the knob.
    private func applyModulation(_ snapshot: ModulationSnapshot, atSample p: Int64) {
        let positionValid = snapshot.positionValid
        if modulationTouchesFilter {
            var cutoff = modulationBaseParams.cutoffHz
            if modTargetCutoff >= 0 {
                cutoff = ModulationEvaluator.modulated(
                    base: cutoff, forTargetAt: modTargetCutoff, snapshot: snapshot,
                    atSample: p, positionValid: positionValid)
            }
            var q = modulationBaseParams.effectiveQ
            if modTargetResonance >= 0 {
                let resonance = ModulationEvaluator.modulated(
                    base: modulationBaseParams.resonance, forTargetAt: modTargetResonance,
                    snapshot: snapshot, atSample: p, positionValid: positionValid)
                // `effectiveQ`'s own formula, with the modulated resonance —
                // NOT a second taper. `effectiveResonanceBoost` is a frozen
                // patch property, so the boost multiplier is carried verbatim.
                let base = 0.5 + resonance * 9.5
                let boost = modulationBaseParams.effectiveResonanceBoost
                q = boost > 0
                    ? base * pow(PolySynthParams.maxBoostedQ / 10.0, boost)
                    : base
            }
            baseCutoffHz = cutoff
            filterQ = q
            let guarded = min(max(cutoff, 10.0), sampleRate * 0.45)
            let g = Float(tan(.pi * guarded / sampleRate))
            let k = Float(1.0 / q)
            svfA1 = 1 / (1 + g * (g + k))
            svfA2 = g * svfA1
            svfA3 = g * svfA2
            if perVoiceCutoff {
                for index in 0..<Self.voiceCount where voices[index].active {
                    updateVoiceFilter(at: index)
                }
            }
        }
        if modTargetGain >= 0 {
            outputGain = Float(ModulationEvaluator.modulated(
                base: modulationBaseParams.gain, forTargetAt: modTargetGain,
                snapshot: snapshot, atSample: p, positionValid: positionValid))
        }
        if modulationTouchesEnvelope {
            // ADSR values are consumed at note-on (the attack/decay/release
            // STEPS are, at least — a sounding voice keeps the slope it
            // started with, which `InstrumentParamSpec`'s note says out loud).
            var sustain = modulationBaseParams.sustain
            if modTargetSustain >= 0 {
                sustain = ModulationEvaluator.modulated(
                    base: sustain, forTargetAt: modTargetSustain, snapshot: snapshot,
                    atSample: p, positionValid: positionValid)
            }
            var attack = modulationBaseParams.attack
            if modTargetAttack >= 0 {
                attack = ModulationEvaluator.modulated(
                    base: attack, forTargetAt: modTargetAttack, snapshot: snapshot,
                    atSample: p, positionValid: positionValid)
            }
            var decay = modulationBaseParams.decay
            if modTargetDecay >= 0 {
                decay = ModulationEvaluator.modulated(
                    base: decay, forTargetAt: modTargetDecay, snapshot: snapshot,
                    atSample: p, positionValid: positionValid)
            }
            var release = modulationBaseParams.release
            if modTargetRelease >= 0 {
                release = ModulationEvaluator.modulated(
                    base: release, forTargetAt: modTargetRelease, snapshot: snapshot,
                    atSample: p, positionValid: positionValid)
            }
            attackStep = Float(1.0 / (max(attack, 1e-6) * sampleRate))
            decayStep = Float((1.0 - sustain) / (max(decay, 1e-6) * sampleRate))
            sustainLevel = Float(sustain)
            releaseSlope = Float(1.0 / (max(release, 1e-6) * sampleRate))
            invOneMinusSustain = sustain < 1 ? Float(1.0 / (1.0 - sustain)) : 0
        }
    }

    /// Derives ONE voice's filter coefficients from its frozen `cutoffScale`.
    /// Called at note-on and on a parameter-generation change — never per
    /// sample, which is the whole contract.
    private func updateVoiceFilter(at index: Int) {
        let scaled = baseCutoffHz * voices[index].cutoffScale
        // The same stability guard the shared path uses, applied AFTER the
        // scaling — tracking can push a cutoff well past where `tan()` is
        // usable, and a 4-octave lift from an 8 kHz base certainly does.
        let cutoff = min(max(scaled, 10.0), sampleRate * 0.45)
        let g = Float(tan(.pi * cutoff / sampleRate))
        let k = Float(1.0 / filterQ)
        let a1 = 1 / (1 + g * (g + k))
        voices[index].svfA1 = a1
        voices[index].svfA2 = g * a1
        voices[index].svfA3 = g * (g * a1)
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

    // MARK: - Pedal hold limit (m34-q, render thread)

    /// THE PEDAL-UP SWEEP BODY, for ONE voice — factored out so the sweep and
    /// the m34-q hold-limit eviction cannot drift into sounding different.
    /// There is exactly ONE way a pedal-held note stops in this instrument and
    /// this is it: the deferred note-off, delivered now, into the patch's own
    /// release ramp.
    ///
    /// ⛔ CALLERS MUST HAVE ESTABLISHED `active && sustained`. It deliberately
    /// does not re-check, because the one thing this must never do is release a
    /// voice whose KEY IS STILL DOWN (`sustained == false`) — that would cut a
    /// note under the player's finger — and a caller forced to filter is a
    /// caller that had to think about it.
    @inline(__always)
    private func releaseSustainedVoice(at index: Int) {
        voices[index].sustained = false
        if voices[index].level <= 0 {
            voices[index] = Voice()  // off before the first audible sample
        } else {
            beginRelease(at: index)
        }
    }

    /// ENTERING RELEASE, for one voice — the ONE body, so the direct note-off
    /// and the pedal-up sweep cannot drift into sounding different. (They were
    /// already two copies of two lines; m39-g gives them a third and a fourth,
    /// which is when two copies stop being acceptable.)
    ///
    /// ⚠️ `releaseAmp` MUST be captured from the amplitude the voice is AT, not
    /// from its ramp level. Under a curve those differ, and anchoring on the
    /// ramp would step the output at every single note-off — a click on every
    /// key lift, and a louder one on a pedal-up sweep releasing several at
    /// once. Caller must have established `level > 0`, so the reciprocal is
    /// finite.
    @inline(__always)
    private func beginRelease(at index: Int) {
        voices[index].releaseAmp = envCurveActive
            ? shapedAmplitude(at: index) : voices[index].level
        voices[index].releaseFromInv = 1 / voices[index].level
        voices[index].stage = Stage.release
        voices[index].releaseFrom = voices[index].level
    }

    /// Re-derives every phase increment a voice owns — the main oscillator,
    /// each extra unison sub-voice, and the sub-oscillator — from the current
    /// bend, drift and per-note detune.
    ///
    /// ⭐ THE NEUTRAL CASE IS EXACT, NOT MERELY CLOSE. `driftFactor` and
    /// `detuneScale` are both exactly 1.0 on a voice whose patch uses neither,
    /// and multiplication by 1.0 is exact in IEEE 754 — so this produces
    /// literally `baseIncrement × bendFactor`, the pre-m39-g expression, bit
    /// for bit. The unison and sub loops below are skipped, not run with
    /// neutral values.
    @inline(__always)
    private func refreshIncrements(at index: Int) {
        let factor = bendFactor * voices[index].driftFactor * voices[index].detuneScale
        voices[index].phaseIncrement = voices[index].baseIncrement * factor
        if unisonActive {
            // Sub-voice 0 IS `phaseIncrement`, so it carries ratio 0 too.
            voices[index].phaseIncrement *= unisonRatio[0]
            for k in 1..<unisonCount {
                extraIncrement[index * Self.extraUnison + (k - 1)] =
                    voices[index].baseIncrement * factor * unisonRatio[k]
            }
        }
        if subActive {
            voices[index].subIncrement = voices[index].baseIncrement * factor * subRatio
        }
    }

    /// How many distinct NOTES the pedal is holding — notes, not voices. Here
    /// they are the same number (one note-on allocates one voice), and the
    /// shape is still written note-wise so this instrument and the Sampler,
    /// where one note-on CAN sound several layered voices, answer the user's
    /// question ("how many notes to hold") identically.
    ///
    /// O(voices²) worst case at EVENT rate, and only while a cap is set: 16
    /// voices, so at most 120 integer compares, on a path that already walks
    /// all 16 slots to find one. Nothing allocates, locks or logs.
    private func sustainedNoteCount() -> Int {
        var count = 0
        for index in 0..<Self.voiceCount
        where voices[index].active && voices[index].sustained {
            var isFirstVoiceOfNote = true
            for other in 0..<index
            where voices[other].active && voices[other].sustained
                && voices[other].noteID == voices[index].noteID {
                isFirstVoiceOfNote = false
                break
            }
            if isFirstVoiceOfNote { count &+= 1 }
        }
        return count
    }

    /// Releases every voice of the OLDEST pedal-held note — lowest serial, the
    /// same "oldest" this instrument's voice stealing already means. Returns
    /// false when the pedal is holding nothing, which is what terminates the
    /// eviction loop; a trusted counter would not.
    private func releaseOldestSustainedNote() -> Bool {
        var oldestSerial: UInt64 = 0
        var oldestNoteID: UInt64 = 0
        var found = false
        for index in 0..<Self.voiceCount
        where voices[index].active && voices[index].sustained {
            if !found || voices[index].serial < oldestSerial {
                oldestSerial = voices[index].serial
                oldestNoteID = voices[index].noteID
                found = true
            }
        }
        guard found else { return false }
        // EVERY voice of that note, not merely the lowest-serial one — a
        // layered note releasing one layer at a time would half-stop.
        for index in 0..<Self.voiceCount
        where voices[index].active && voices[index].sustained
            && voices[index].noteID == oldestNoteID {
            releaseSustainedVoice(at: index)
        }
        return true
    }

    /// m34-q enforcement, from the note-on path with the pedal down. Counts
    /// ONCE and then evicts a known number of notes: each eviction removes
    /// exactly one distinct note, so recounting per round would only buy an
    /// O(n³) worst case.
    ///
    /// `>=`, not `>`: the note being struck right now becomes the cap-th
    /// pedal-held note the moment its key is released, so the room has to be
    /// made here.
    private func enforcePedalHoldLimit() {
        var held = sustainedNoteCount()
        while held >= pedalHoldLimit {
            guard releaseOldestSustainedNote() else { return }
            held -= 1
        }
    }

    // MARK: - Voice allocation (render thread)

    private func apply(_ event: ScheduledMIDIEvent) {
        if event.kind == ScheduledMIDIEvent.noteOn {
            // m34-q: the hold limit binds HERE, at the note-on — the moment the
            // ear can hear the trade being made, and the same moment a player
            // lifting a key early would have made it. `Int.max` (the nil
            // default) can never be <= the voice count, so an instrument with
            // no cap runs not one extra instruction and renders byte-identically
            // to the pre-m34-q engine. A cap ABOVE the pool is likewise
            // unreachable and therefore means unlimited.
            if pedalDown, pedalHoldLimit <= Self.voiceCount {
                enforcePedalHoldLimit()
            }
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
            voice.baseIncrement = frequency / sampleRate
            voice.velocityAmp = Float(event.velocity) / 127.0
            voice.stage = Stage.attack

            // m39-g — PER-NOTE RANDOMISATION, rolled ONCE, here. Everything
            // random about a voice is decided at note-on and then frozen, so a
            // later parameter edit re-derives the voice's coefficients without
            // re-rolling its character mid-note.
            var cutoffOctaves = 0.0
            if jitterActive {
                // Small, independent offsets — "no two notes sound quite the
                // same", not "every note is a surprise".
                voice.detuneScale = exp2(nextRandomBipolar() * jitterAmount * 8.0 / 1_200.0)
                cutoffOctaves += nextRandomBipolar() * jitterAmount * 0.3
                let pan = nextRandomBipolar() * jitterAmount * 0.5
                let angle = (pan + 1.0) * .pi / 4.0
                voice.panL = Float(cos(angle)) * 1.414_213_56
                voice.panR = Float(sin(angle)) * 1.414_213_56
            }
            // Velocity and key tracking on the filter — a SCALAR FORMULA AT
            // NOTE-ON (research §7.2), not a per-sample cost. Velocity opens
            // the filter from the patch's cutoff upward; key tracking pivots
            // around middle C so a patch voiced there keeps its character.
            if velToCutoffOctaves > 0 {
                cutoffOctaves += velToCutoffOctaves * Double(event.velocity) / 127.0
            }
            if keyToCutoffOctaves > 0 {
                cutoffOctaves += keyToCutoffOctaves
                    * (Double(event.pitch) - PolySynthParams.keyTrackCenterPitch) / 12.0
            }
            voice.cutoffScale = cutoffOctaves == 0 ? 1.0 : exp2(cutoffOctaves)

            voices[slot] = voice
            // Sub-voice phases. A unison patch randomises every start phase —
            // that is what makes the stack read as a chorus rather than as one
            // louder oscillator (research §3: "phase-randomized starts"). A
            // patch WITHOUT unison leaves phase at exactly 0, as it always has.
            if unisonActive {
                voices[slot].phase = (nextRandomBipolar() + 1.0) * 0.5
                for k in 1..<unisonCount {
                    extraPhase[slot * Self.extraUnison + (k - 1)] =
                        (nextRandomBipolar() + 1.0) * 0.5
                }
            }
            refreshIncrements(at: slot)
            if perVoiceCutoff { updateVoiceFilter(at: slot) }
            nextSerial &+= 1
        } else if event.kind == ScheduledMIDIEvent.noteOff {
            for index in 0..<Self.voiceCount
            where voices[index].active && voices[index].noteID == event.noteID {
                if pedalDown {
                    // Sustain (m16-b2): the pedal DEFERS the release — the
                    // voice keeps sounding, marked for the pedal-up sweep.
                    voices[index].sustained = true
                } else if voices[index].level <= 0 {
                    voices[index] = Voice()  // off before the first audible sample
                } else {
                    beginRelease(at: index)
                }
            }
        } else if event.kind == ScheduledMIDIEvent.controlChange {
            // m16-b2 (design-m16b §4.3): the built-in honors CC64 (sustain)
            // only; every other CC is deliberately ignored here (documented —
            // hosted AUs receive them all).
            if event.pitch == 64 {
                let down = event.velocity >= 64
                if pedalDown, !down {
                    // Pedal up: release every pedal-held voice — the deferred
                    // noteOffs, delivered now.
                    for index in 0..<Self.voiceCount
                    where voices[index].active && voices[index].sustained {
                        releaseSustainedVoice(at: index)  // m34-q: the ONE body
                    }
                }
                pedalDown = down
            }
        } else if event.kind == ScheduledMIDIEvent.pitchBend {
            // m16-b2: data1 = LSB, data2 = MSB (THE ONE DATA RULE); center
            // 8192 → factor 1. Applied to every sounding voice in place —
            // releasing tails bend too, like a real synth.
            let raw = Int(event.pitch & 0x7F) | (Int(event.velocity & 0x7F) << 7)
            bendFactor = exp2(Double(raw - 8_192) / 8_192.0
                              * Self.bendRangeSemitones / 12.0)
            // m39-g: EVERY increment the voice owns, not just the main
            // oscillator's — a bend that moved the carrier but left the unison
            // stack and the sub-oscillator behind would shear the patch apart.
            for index in 0..<Self.voiceCount where voices[index].active {
                refreshIncrements(at: index)
            }
        }
        // Channel pressure (kind 4) and any future kind fall through
        // silently — the C4 unknown-kind contract.
    }
}
