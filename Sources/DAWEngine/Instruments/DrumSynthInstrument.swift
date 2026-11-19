import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// m39-dm — the built-in 808/909-lineage synthesised drum machine.
///
/// Eight fixed, NAMED, monophonic one-shot voices, each a hand-written
/// synthesis topology rather than a generic engine with a mode switch. Which
/// note plays which voice is the kit's `noteLayout` (m39-tpl-0): `pads`, notes
/// 36–43 one-to-one (the MPC/Drum Rack base), or `gm`, the General MIDI drum
/// map — `DrumVoice.voice(forNote:layout:)`, the one home for both.
///
/// ⭐ WHY THIS INSTRUMENT NEEDS NONE OF POLYSYNTH'S MODULATION MACHINERY:
/// a one-shot consumes its parameters AT NOTE-ON and nowhere else. That is what
/// a one-shot IS. So there is no 32-frame coefficient re-derivation stride and
/// no block-rate zipper problem: every COEFFICIENT is derived once, at an
/// EVENT, and frozen for the life of the hit. The two exceptions are `level`
/// and `pan`, which are the voice's output stage rather than its topology and
/// therefore move continuously.
///
/// ⚠️ To be exact, since "no per-sample transcendental" would be false as a
/// blanket claim: the SIGNAL path still evaluates `sin` per sample for the
/// sine-bodied voices and `tanh` per sample in `saturate`. What is absent is
/// per-sample transcendental work to RE-DERIVE COEFFICIENTS, which is the cost
/// the modulation stride exists to amortise. Neither allocates, locks or
/// messages, so neither touches the RT-safety contract below — they are CPU,
/// not safety.
///
/// ⛔ RENDER-THREAD CONTRACT. `render()`/`reset()` run on the audio thread: no
/// allocation, no locks, no ObjC, no logging. Every buffer here is allocated
/// ONCE in `init`, at its maximum size, and never resized. Specifically:
///   · voice state is an `UnsafeMutablePointer<VoiceState>`, NEVER a Swift
///     `Array` — an array subscripted inside the sample loop pays a
///     copy-on-write uniqueness check PER SAMPLE;
///   · every write into that block is ELEMENT-WISE (`voices[i].amp = …`), never
///     a whole-struct or whole-array reassignment;
///   · no parameter is passed to `Int()` without `DrumDSP.sampleCount`, because
///     `Int(Double.nan)` TRAPS rather than returning zero, and a modulated
///     value can arrive non-finite.
final class DrumSynthInstrument: InstrumentRendering, @unchecked Sendable {

    // MARK: - Fixed sizes

    /// Eight voices, TWO SUB-SLOTS EACH.
    ///
    /// ⭐ The second sub-slot is what makes a retrigger click-free WITHOUT
    /// delaying it. The obvious alternative — fade the sounding voice for 3 ms
    /// and then start the new hit — puts a 3 ms timing error on every fast
    /// repeat, which on a drum machine is exactly the wrong thing to trade. So
    /// the new hit starts on THIS sample in the other sub-slot while the old one
    /// fades out underneath it. A retrigger faster than 3 ms (333 Hz) still
    /// cuts; nothing musical lives there.
    private static let voiceCount = 8
    private static let slotsPerVoice = 2
    private static let slotCount = voiceCount * slotsPerVoice
    /// Six oscillators in the 808 hat/cymbal bank.
    private static let bankSize = 6
    /// The choke/retrigger fade, in seconds. Never a hard cut.
    private static let fadeSeconds = 0.003

    /// The 808 hi-hat/cymbal oscillator set, sourced (Baratatronix).
    ///
    /// ⚠️ The SET matters; the digits are nominal. Only the 800 Hz and 540 Hz
    /// oscillators are tunable in the real circuit and measured units vary by
    /// up to ~20% from resistor tolerance, so nothing here depends on the exact
    /// values — `tune` scales all six together.
    private static let bankFrequencies: [Double] =
        [800.0, 540.0, 522.7, 369.6, 304.4, 205.3]

    /// The hats' fixed bandpass, and the cymbal's SHORT band. Sourced.
    private static let hatBandHz = 7100.0
    /// The hats' post-band highpass.
    private static let hatHighpassHz = 6000.0

    // MARK: - Voice state (POD, fixed block)

    private struct VoiceState {
        var active = false
        var topology: Int32 = 0
        var chokeGroup: Int8 = -1

        /// Choke/retrigger gain. 1.0 with a coefficient of 1.0 normally; a
        /// choke swaps the coefficient to the 3 ms fade. Never a hard cut.
        var gate = 1.0
        var gateCoef = 1.0
        /// Retirement tracker — the voice's LONGEST time constant. Not in the
        /// signal path; it exists so a voice whose audible envelope lives
        /// inside a modal resonator still knows when it has finished.
        var tracker = 1.0
        var trackerCoef = 0.0

        // Primary amplitude envelope (kick, hats, clap, cymbal low band).
        var amp = 0.0
        var ampCoef = 0.0
        // Secondary envelope (cymbal high band, snare noise).
        var amp2 = 0.0
        var amp2Coef = 0.0
        var amp2Gain = 0.0

        // Pitch envelope + sine oscillator (kick, tom).
        var pitchEnv = 0.0
        var pitchCoef = 0.0
        var pitchAmount = 0.0
        var baseFreq = 0.0
        var phase = 0.0

        // Transient click (kick beater, tom stick, rim click).
        var click = 0.0
        var clickCoef = 0.0
        var clickGain = 0.0
        var clickHpState = 0.0
        var clickHpCoef = 0.0

        // Modal resonators — partials whose frequency does not sweep.
        var m1y1 = 0.0, m1y2 = 0.0, m1a1 = 0.0, m1a2 = 0.0, m1Gain = 0.0
        var m2y1 = 0.0, m2y2 = 0.0, m2a1 = 0.0, m2a2 = 0.0, m2Gain = 0.0

        // State-variable filters.
        var svf1Ic1 = 0.0, svf1Ic2 = 0.0
        var svf1A1 = 0.0, svf1A2 = 0.0, svf1A3 = 0.0, svf1K = 0.0
        var svf2Ic1 = 0.0, svf2Ic2 = 0.0
        var svf2A1 = 0.0, svf2A2 = 0.0, svf2A3 = 0.0, svf2K = 0.0

        // Post-band highpass. TWO cascaded one-poles, not one.
        //
        // ⚠️ MEASURED, NOT PREFERRED: a single 6 dB/octave pole left the hats
        // with −28 dB of sub-500 Hz energy against a −30 dB bound. The 808
        // circuit this voice follows has THREE high-pass stages after the
        // bandpass (the Baratatronix source the design cites says so), so one
        // pole was under-implementing the lineage, not merely under-shooting a
        // threshold. Two brings it to −40 dB and costs one multiply.
        var hpState = 0.0
        var hpState2 = 0.0
        var hpCoef = 0.0

        // Tone tilt: blend between a one-pole lowpass and the dry signal.
        var toneState = 0.0
        var toneCoef = 0.0
        var toneMix = 1.0

        // Attack shaping (hats, cymbal) — `snap` on those voices.
        var attack = 1.0
        var attackRate = 1.0

        // Clap pulse machine — integers only, no allocation.
        var sampleIndex: Int32 = 0
        var clapPulse: Int32 = 0
        var clapNext: Int32 = 0
        var clapSpread: Int32 = 0
        var burst = 0.0, burstCoef = 0.0, burstGain = 0.0
        var tail = 0.0, tailCoef = 0.0, tailGain = 0.0

        // Noise + drive.
        var rng: UInt32 = 1
        var noiseGain = 0.0
        var driveGain = 1.0
        var driveNorm = 1.0
        var adaaX = 0.0, adaaF = 0.0

        // Output stage. `baseLevel`/`basePan` are the un-modulated knob values;
        // `level`/`panL`/`panR` are what the sample loop multiplies by.
        var baseLevel = 1.0
        var basePan = 0.0
        var velocityScale = 1.0
        var kitGain = 1.0
        var level = 1.0
        var panL = 1.0
        var panR = 1.0
    }

    /// ⛔ AN `UnsafeMutablePointer`, NOT AN ARRAY. A Swift `Array` subscripted
    /// for mutation inside the per-sample loop pays an `isUniquelyReferenced`
    /// check on EVERY access.
    private let voices: UnsafeMutablePointer<VoiceState>
    /// Which sub-slot of each voice is the CURRENT one.
    private let currentSub: UnsafeMutablePointer<Int32>
    /// Hat/cymbal bank oscillator phases and increments, `slot * bankSize + k`.
    private let bankPhase: UnsafeMutablePointer<Double>
    private let bankInc: UnsafeMutablePointer<Double>

    // MARK: - Parameter delivery

    private final class KitSnapshot {
        let generation: UInt64
        let params: DrumKitParams
        init(generation: UInt64, params: DrumKitParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>
    private var retired: [(snapshot: KitSnapshot, retiredAt: ContinuousClock.Instant)] = []
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: DrumKitParams
    private var lastParamsGeneration = UInt64.max
    /// The live kit the render thread reads. Updated only at a quantum top,
    /// from the atomic slot.
    private var kit: DrumKitParams

    private let modulationSlot: UnsafeMutablePointer<daw_atomic_ptr>
    private var retiredModulation:
        [(snapshot: ModulationSnapshot, retiredAt: ContinuousClock.Instant)] = []
    private var lastModulationGeneration = UInt64.max
    private var modulationActive = false
    /// Whether ANY route addresses a `level` or `pan` — the only two parameters
    /// that need re-evaluating inside the sample loop. False for every other
    /// modulated kit, which keeps the stride branch off the hot path entirely.
    private var modulationTouchesOutput = false

    /// Resolved target index per spec-table row, or −1. Preallocated at
    /// `DrumKitParams.paramSpecs.count` (77 since W8-HAT's two trims) in `init`.
    private let modTarget: UnsafeMutablePointer<Int32>
    private let modTargetCount: Int
    /// `scopeIndex * leafStride + leafSlot` → spec-table row, or −1. Built once
    /// in `init`; the render thread never searches a table or touches a String.
    private let specRow: UnsafeMutablePointer<Int32>
    /// One more than the highest `DrumLeafParam.slot`, DERIVED in `init`.
    ///
    /// ⛔ W8-HAT: this was the literal 18, which held exactly the 18 leaves
    /// m39-dm shipped. The two appended trims carry slots 18 and 19, so with
    /// the literal `kit.hatsLevelDb` would have indexed `specRow[8 * 18 + 18]`
    /// — one past the allocation — on the render thread. An instance constant
    /// computed from the enum cannot fall behind a 21st leaf; a stored `let` is
    /// a plain load in the sample-rate code, never a lazy global.
    private let leafStride: Int
    private static let scopeCount = 9

    private var sampleRate = 48_000.0

    // MARK: - Lifecycle

    init(params: DrumKitParams = DrumKitParams()) {
        lastAppliedParams = params
        kit = params

        voices = .allocate(capacity: Self.slotCount)
        voices.initialize(repeating: VoiceState(), count: Self.slotCount)
        currentSub = .allocate(capacity: Self.voiceCount)
        currentSub.initialize(repeating: 0, count: Self.voiceCount)
        let bankSlots = Self.slotCount * Self.bankSize
        bankPhase = .allocate(capacity: bankSlots)
        bankPhase.initialize(repeating: 0, count: bankSlots)
        bankInc = .allocate(capacity: bankSlots)
        bankInc.initialize(repeating: 0, count: bankSlots)

        let specs = DrumKitParams.paramSpecs
        modTargetCount = specs.count
        modTarget = .allocate(capacity: specs.count)
        modTarget.initialize(repeating: -1, count: specs.count)

        let stride = Int(DrumLeafParam.allCases.map(\.slot).max() ?? 0) + 1
        leafStride = stride
        let rowCount = Self.scopeCount * stride
        specRow = .allocate(capacity: rowCount)
        specRow.initialize(repeating: -1, count: rowCount)
        for (row, spec) in specs.enumerated() {
            let scope = Int(spec.voice?.slot ?? 8)
            specRow[scope * stride + Int(spec.leaf.slot)] = Int32(row)
        }

        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        modulationSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(modulationSlot)
        let snapshot = KitSnapshot(generation: 0, params: params)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<KitSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
        if let raw = daw_atomic_ptr_exchange(modulationSlot, nil) {
            Unmanaged<ModulationSnapshot>.fromOpaque(raw).release()
        }
        modulationSlot.deallocate()
        voices.deinitialize(count: Self.slotCount)
        voices.deallocate()
        currentSub.deinitialize(count: Self.voiceCount)
        currentSub.deallocate()
        let bankSlots = Self.slotCount * Self.bankSize
        bankPhase.deinitialize(count: bankSlots)
        bankPhase.deallocate()
        bankInc.deinitialize(count: bankSlots)
        bankInc.deallocate()
        modTarget.deinitialize(count: modTargetCount)
        modTarget.deallocate()
        specRow.deinitialize(count: Self.scopeCount * leafStride)
        specRow.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes a new kit for pickup at the top of the next render quantum.
    /// Sounding voices keep the parameters they latched — that is the one-shot
    /// contract, not a limitation — except `level` and `pan`, which move.
    @MainActor
    func apply(params: DrumKitParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = KitSnapshot(generation: publishedGeneration, params: params)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<KitSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

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
        lastParamsGeneration = .max
    }

    func reset() {
        for slot in 0..<Self.slotCount {
            voices[slot].active = false
            voices[slot].gate = 0
        }
        for voice in 0..<Self.voiceCount { currentSub[voice] = 0 }
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard let first = output.first, let firstData = first.mData else { return }
        let channel0 = firstData.assumingMemoryBound(to: Float.self)
        let channel1: UnsafeMutablePointer<Float>? = output.count >= 2
            ? output[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        // Adopt a newly published kit — borrowed, no retain/release; the retire
        // bin guarantees its lifetime for at least a second.
        if let raw = daw_atomic_ptr_load(paramsSlot) {
            let snapshot = Unmanaged<KitSnapshot>.fromOpaque(raw).takeUnretainedValue()
            if snapshot.generation != lastParamsGeneration {
                lastParamsGeneration = snapshot.generation
                kit = snapshot.params
                refreshOutputStages()
            }
        }

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
            modulationActive = false
            modulationTouchesOutput = false
            lastModulationGeneration = UInt64.max
            for row in 0..<modTargetCount { modTarget[row] = -1 }
            refreshOutputStages()
        }

        var eventIndex = 0
        for frame in 0..<frameCount {
            // The output stride. `level`/`pan` are the ONLY parameters a
            // sounding voice re-reads, so this whole branch is skipped unless a
            // route actually addresses one of them.
            if let modulation, modulationTouchesOutput,
               frame % ModulationDepth.evaluationStrideFrames == 0 {
                applyOutputModulation(modulation,
                                      atSample: modulationPosition &+ Int64(frame))
            }
            while eventIndex < events.count {
                let event = events[eventIndex]
                let offset = max(0, Int(event.sampleTime - renderStart))
                guard offset <= frame else { break }
                handle(event, atSample: renderStart &+ Int64(frame),
                       modulation: modulation,
                       modulationSample: modulationPosition &+ Int64(frame))
                eventIndex += 1
            }
            var left = 0.0
            var right = 0.0
            for slot in 0..<Self.slotCount where voices[slot].active {
                let mono = renderSlot(slot)
                left += mono * voices[slot].panL
                right += mono * voices[slot].panR
            }
            channel0[frame] = Float(left)
            if let channel1 { channel1[frame] = Float(right) }
        }
        if channel1 == nil, output.count >= 2 {
            for index in 1..<output.count {
                guard let data = output[index].mData else { continue }
                data.assumingMemoryBound(to: Float.self)
                    .update(from: channel0, count: frameCount)
            }
        }
    }

    // MARK: - Modulation resolution

    private func adoptModulationTargets(_ snapshot: ModulationSnapshot) {
        let specs = DrumKitParams.paramSpecs
        var any = false
        var touchesOutput = false
        for row in 0..<modTargetCount {
            let index = ModulationEvaluator.targetIndex(
                forInstrumentParamCode: specs[row].code, snapshot: snapshot)
            modTarget[row] = index
            if index >= 0 {
                any = true
                if specs[row].leaf == .level || specs[row].leaf == .pan { touchesOutput = true }
            }
        }
        modulationActive = any
        modulationTouchesOutput = touchesOutput
        if !touchesOutput { refreshOutputStages() }
    }

    /// The modulated value of one parameter at one sample, or the knob value
    /// when nothing addresses it. Called at NOTE-ON (an event), never per
    /// sample — except for `level`/`pan`, which ride the output stride.
    @inline(__always)
    private func modulated(scope: Int32, leaf: DrumLeafParam, base: Double,
                           snapshot: ModulationSnapshot?, atSample: Int64) -> Double {
        guard let snapshot else { return base }
        let row = specRow[Int(scope) * leafStride + Int(leaf.slot)]
        guard row >= 0 else { return base }
        let target = modTarget[Int(row)]
        guard target >= 0 else { return base }
        let value = ModulationEvaluator.modulated(
            base: base, forTargetAt: target, snapshot: snapshot,
            atSample: atSample, positionValid: snapshot.positionValid)
        return DrumDSP.finite(value, base)
    }

    /// Re-derives every SOUNDING slot's output stage. Used when modulation
    /// stops or a NEW KIT ARRIVES.
    ///
    /// ⛔ IT RE-READS `level`/`pan` FROM THE CURRENT KIT, and an earlier version
    /// that re-used the slot's latched `baseLevel` was WRONG IN A WAY THAT
    /// LOOKED RIGHT: a level edit published while a cymbal was ringing changed
    /// nothing, because the "base" being refreshed was the value latched at
    /// note-on. `level` and `pan` are the two parameters that are explicitly
    /// NOT latched — they are the voice's output stage — so the whole point of
    /// this function is to pick up their new values.
    /// `velocityScale` and `kitGain` stay latched: those belong to the HIT.
    ///
    /// ⛔ RENDER THREAD (W8-RTFIX, RT review F1/F4). The slot → voice lookup is
    /// `DrumVoice.voice(forSlot:)`, a `switch`, and the kit read is
    /// `kit.voiceParams(_:)`, a `switch` over stored fields. The
    /// `DrumVoice.allCases.first(where:)` scan this replaced built an array per
    /// sounding slot in the debug build — 192 000 malloc events per 1 000
    /// adoptions with eight voices sounding (`DrumNoteLayoutRenderTests`) — and
    /// the KeyPath subscript costs a `swift_getAtKeyPath` and a release per read
    /// in the release build. The loop is a `while`, not `for … in 0..<n`: at
    /// -Onone a `Range` loop raises malloc events of its own (the m23-r1 law,
    /// `ModulationEvaluator`). The increment is UNCONDITIONAL, so the nil
    /// branch (a topology no voice has; unreachable today) cannot spin.
    private func refreshOutputStages() {
        var slot = 0
        while slot < Self.slotCount {
            if voices[slot].active, let voice = DrumVoice.voice(forSlot: voices[slot].topology) {
                let params = kit.voiceParams(voice)
                voices[slot].baseLevel = params.level
                voices[slot].basePan = params.pan
                setOutput(slot: slot, level: voices[slot].baseLevel, pan: voices[slot].basePan)
            }
            slot += 1
        }
    }

    private func applyOutputModulation(_ snapshot: ModulationSnapshot, atSample: Int64) {
        for slot in 0..<Self.slotCount where voices[slot].active {
            let scope = voices[slot].topology
            let level = modulated(scope: scope, leaf: .level,
                                  base: voices[slot].baseLevel,
                                  snapshot: snapshot, atSample: atSample)
            let pan = modulated(scope: scope, leaf: .pan,
                                base: voices[slot].basePan,
                                snapshot: snapshot, atSample: atSample)
            setOutput(slot: slot, level: level, pan: pan)
        }
    }

    @inline(__always)
    private func setOutput(slot: Int, level: Double, pan: Double) {
        let clampedLevel = min(max(DrumDSP.finite(level, 0), 0), 1)
        let clampedPan = min(max(DrumDSP.finite(pan, 0), -1), 1)
        voices[slot].level = clampedLevel * voices[slot].velocityScale * voices[slot].kitGain
        let angle = (clampedPan + 1.0) * (Double.pi / 4.0)
        voices[slot].panL = cos(angle) * Double.squareRootOfTwo
        voices[slot].panR = sin(angle) * Double.squareRootOfTwo
    }

    // MARK: - Events

    private func handle(_ event: ScheduledMIDIEvent, atSample sample: Int64,
                        modulation: ModulationSnapshot?, modulationSample: Int64) {
        // A one-shot ignores note-off entirely — every trigger plays to its end
        // — and it consumes no CC, bend or aftertouch, which is what
        // `MIDIControllerRouting` tells the user out loud.
        //
        // m39-tpl-0 — ⛔ RENDER THREAD. The layout is read from `kit`, THIS
        // thread's own copy, adopted from the atomic slot at the top of the
        // quantum; it is never read from the model here. The lookup is a plain
        // `switch` (no table, no `allCases` scan: F-4). A layout change
        // therefore takes effect at the next note-on, and a hit already
        // sounding keeps playing — it is latched in its slot by topology, not
        // by note.
        guard event.kind == ScheduledMIDIEvent.noteOn, event.velocity > 0,
              let voice = DrumVoice.voice(forNote: event.pitch, layout: kit.noteLayout)
        else { return }
        trigger(voice: voice, velocity: event.velocity, atSample: sample,
                modulation: modulation, modulationSample: modulationSample)
    }

    private func trigger(voice: DrumVoice, velocity: UInt8, atSample sample: Int64,
                         modulation: ModulationSnapshot?, modulationSample: Int64) {
        let scope = voice.slot
        // W8-RTFIX (F4): a `switch` read, never the KeyPath subscript.
        let params = kit.voiceParams(voice)
        let group = params.resolvedChokeGroup
        let fadeCoef = DrumDSP.decayCoefficient(seconds: Self.fadeSeconds,
                                                sampleRate: sampleRate)

        // ⛔ FIRE THE CHOKE BEFORE WRITING THE NEW VOICE'S SLOT, so a note can
        // never choke itself. That ordering was a bug in the sampler once
        // (`SamplerInstrument` :2044-2046) and it is copied deliberately.
        if group >= 0 {
            for other in 0..<Self.voiceCount where Int32(other) != scope {
                for sub in 0..<Self.slotsPerVoice {
                    let slot = other * Self.slotsPerVoice + sub
                    guard voices[slot].active, voices[slot].chokeGroup == group else { continue }
                    voices[slot].gateCoef = fadeCoef
                }
            }
        }
        // A retrigger of THIS voice fades the sounding sub-slot and starts the
        // new hit in the other one, on this very sample — no timing error.
        let sub = Int(currentSub[Int(scope)])
        let previous = Int(scope) * Self.slotsPerVoice + sub
        if voices[previous].active { voices[previous].gateCoef = fadeCoef }
        let nextSub = (sub + 1) % Self.slotsPerVoice
        currentSub[Int(scope)] = Int32(nextSub)
        let slot = Int(scope) * Self.slotsPerVoice + nextSub

        start(slot: slot, voice: voice, params: params, velocity: velocity,
              group: group, sample: sample, modulation: modulation,
              modulationSample: modulationSample)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func start(slot: Int, voice: DrumVoice, params: DrumVoiceParams,
                       velocity: UInt8, group: Int8, sample: Int64,
                       modulation: ModulationSnapshot?, modulationSample: Int64) {
        let scope = voice.slot
        let fs = sampleRate

        // ── every latched parameter, resolved through modulation ONCE ──
        @inline(__always)
        func p(_ leaf: DrumLeafParam, _ base: Double) -> Double {
            modulated(scope: scope, leaf: leaf, base: base,
                      snapshot: modulation, atSample: modulationSample)
        }
        let kitScope: Int32 = 8
        @inline(__always)
        func kp(_ leaf: DrumLeafParam, _ base: Double) -> Double {
            modulated(scope: kitScope, leaf: leaf, base: base,
                      snapshot: modulation, atSample: modulationSample)
        }

        let tune = p(.tune, params.tune)
        let decay = max(p(.decay, params.decay), 0.001)
        var tone = p(.tone, params.tone)
        let snap = min(max(p(.snap, params.snap), 0), 1)
        let drive = min(max(p(.drive, params.drive), 0), 1)
        let voiceVelocity = min(max(p(.velocity, params.velocity), 0), 1)

        // ── velocity and accent (design §5) ──
        // Two mechanisms because two callers need them: continuous dynamics for
        // an agent that thinks in velocities, and a step-property ACCENT for one
        // that thinks in "accent beats 1 and 3" — which is what the 808 has.
        let v = Double(velocity) / 127.0
        var velocityScale = 1.0 - voiceVelocity * (1.0 - v)
        let velocityToTone = min(max(kp(.velocityToTone, kit.velocityToTone), 0), 1)
        var toneShift = voiceVelocity * velocityToTone * (v - 0.5) * 2.0
        let accentThreshold = kp(.accentThreshold, kit.accentThreshold)
        let accentDepth = min(max(kp(.accentDepth, kit.accentDepth), 0), 1)
        if Double(velocity) >= accentThreshold {
            velocityScale *= 1.0 + accentDepth
            toneShift += accentDepth * 0.5
        }
        // ⭐ AMPLITUDE ALONE IS WHAT "TICKS". A real drum struck harder is
        // BRIGHTER, not merely louder, so velocity moves the tone tilt too.
        tone = min(max(tone + toneShift, 0), 1)

        voices[slot].active = true
        voices[slot].topology = scope
        voices[slot].chokeGroup = group
        voices[slot].gate = 1
        voices[slot].gateCoef = 1
        voices[slot].sampleIndex = 0
        voices[slot].rng = DrumDSP.seed(noteOnSample: sample, voiceSlot: scope)
        voices[slot].velocityScale = min(max(velocityScale, 0), 4)
        voices[slot].kitGain = min(max(kp(.gain, kit.gain), 0), 2)
        // W8-HAT — the hats/cymbals LEVEL TRIM, latched with the hit exactly as
        // `kit.gain` is (it rides `kitGain`, which `refreshOutputStages` keeps).
        // Only the voices `levelTrimLeaf` names hear it. ⭐ BIT-EXACT AT 0 dB:
        // `levelTrimGain` returns exactly 1.0 there without calling `pow`, and
        // x · 1.0 == x, so every kit at the neutral renders as it did before.
        // RT: a `switch`, one optional enum, and `pow` only off the neutral —
        // at a NOTE-ON, never per sample; no allocation, lock or message.
        if let trimLeaf = DrumKitParams.levelTrimLeaf(for: voice) {
            let trimDb = kp(trimLeaf, kit.levelTrimDb(for: voice))
            voices[slot].kitGain *= DrumKitParams.levelTrimGain(dB: trimDb)
        }
        voices[slot].baseLevel = p(.level, params.level)
        voices[slot].basePan = p(.pan, params.pan)
        setOutput(slot: slot, level: voices[slot].baseLevel, pan: voices[slot].basePan)

        // Reset every filter and resonator state — a sub-slot is reused.
        voices[slot].svf1Ic1 = 0; voices[slot].svf1Ic2 = 0
        voices[slot].svf2Ic1 = 0; voices[slot].svf2Ic2 = 0
        voices[slot].hpState = 0
        voices[slot].hpState2 = 0
        voices[slot].toneState = 0
        voices[slot].clickHpState = 0
        voices[slot].adaaX = 0
        voices[slot].adaaF = DrumDSP.logCosh(0)
        voices[slot].m1y1 = 0; voices[slot].m1y2 = 0
        voices[slot].m2y1 = 0; voices[slot].m2y2 = 0
        voices[slot].m1Gain = 0; voices[slot].m2Gain = 0
        voices[slot].amp = 0; voices[slot].ampCoef = 0
        voices[slot].amp2 = 0; voices[slot].amp2Coef = 0; voices[slot].amp2Gain = 0
        voices[slot].click = 0; voices[slot].clickGain = 0
        voices[slot].pitchEnv = 0; voices[slot].pitchAmount = 0
        voices[slot].phase = 0
        voices[slot].noiseGain = 0
        voices[slot].burst = 0; voices[slot].burstGain = 0
        voices[slot].tail = 0; voices[slot].tailGain = 0
        voices[slot].clapPulse = 0; voices[slot].clapNext = 0
        voices[slot].attack = 1; voices[slot].attackRate = 1

        // Drive: a level-compensated ADAA tanh, so `drive` adds HARMONICS
        // rather than level. The compensation is normalised at drive 0 so a
        // clean voice is bit-identical to no drive stage at all.
        let driveDepth: Double
        switch voice {
        case .kick: driveDepth = 6
        case .snare: driveDepth = 5
        case .tom: driveDepth = 4
        default: driveDepth = 3
        }
        let g = 1.0 + driveDepth * drive
        voices[slot].driveGain = g
        voices[slot].driveNorm = DrumDSP.driveNormalisation(gain: g)

        // Tone tilt: one-pole lowpass blended with the dry signal. At tone 1 the
        // voice is untouched; at tone 0 only the lowpass survives.
        let toneCutoff = 300.0 * pow(40.0, tone)
        voices[slot].toneCoef = DrumDSP.onePoleCoefficient(cutoff: toneCutoff, sampleRate: fs)
        voices[slot].toneMix = tone

        var longest = decay

        switch voice {
        case .kick:
            // 808: a sine plus TWO independent exponential envelopes — one on
            // pitch (fast) and one on amplitude (slow). The pitch drop is what
            // reads as impact rather than as tone.
            let pitchAmount = max(p(.pitchAmount, params.pitchAmount), 0)
            // A hard hit shortens the pitch envelope — the second half of
            // "struck harder is brighter".
            let pitchDecay = max(p(.pitchDecay, params.pitchDecay), 0.0005)
                * (1.0 - 0.3 * min(max(toneShift, -1), 1))
            voices[slot].baseFreq = max(tune, 1)
            voices[slot].pitchAmount = pitchAmount
            voices[slot].pitchEnv = 1
            voices[slot].pitchCoef = DrumDSP.decayCoefficient(
                seconds: max(pitchDecay, 0.0005), sampleRate: fs)
            voices[slot].amp = 1
            voices[slot].ampCoef = DrumDSP.decayCoefficient(seconds: decay, sampleRate: fs)
            voices[slot].click = 1
            voices[slot].clickCoef = DrumDSP.decayCoefficient(seconds: 0.004, sampleRate: fs)
            voices[slot].clickGain = snap
            voices[slot].clickHpCoef = DrumDSP.onePoleCoefficient(cutoff: 1200, sampleRate: fs)

        case .snare:
            // Two drumhead modes plus a gated noise band (McGill).
            let ratio = max(p(.partial2Ratio, params.partial2Ratio), 1.0)
            let noiseTone = p(.noiseTone, params.noiseTone)
            let m1 = DrumDSP.modalCoefficients(frequency: tune, seconds: decay, sampleRate: fs)
            voices[slot].m1a1 = m1.a1; voices[slot].m1a2 = m1.a2
            voices[slot].m1y1 = m1.y1; voices[slot].m1y2 = m1.y2
            voices[slot].m1Gain = 1.0 - snap
            let m2 = DrumDSP.modalCoefficients(frequency: tune * ratio,
                                               seconds: decay * 0.55, sampleRate: fs)
            voices[slot].m2a1 = m2.a1; voices[slot].m2a2 = m2.a2
            voices[slot].m2y1 = m2.y1; voices[slot].m2y2 = m2.y2
            voices[slot].m2Gain = 0.6 * (1.0 - snap)
            let svf = DrumDSP.svfCoefficients(cutoff: noiseTone, q: 1.1, sampleRate: fs)
            voices[slot].svf1A1 = svf.a1; voices[slot].svf1A2 = svf.a2
            voices[slot].svf1A3 = svf.a3; voices[slot].svf1K = svf.k
            voices[slot].hpCoef = DrumDSP.onePoleCoefficient(cutoff: 300, sampleRate: fs)
            voices[slot].amp2 = 1
            voices[slot].amp2Coef = DrumDSP.decayCoefficient(seconds: decay * 0.75,
                                                             sampleRate: fs)
            voices[slot].amp2Gain = snap * 1.4
            voices[slot].noiseGain = 1

        case .closedHat, .openHat:
            // The 808 six-square bank through a FIXED 7100 Hz band and a
            // 6000 Hz highpass. `tune` scales the oscillators; the filters
            // deliberately do NOT follow, which is what §8.3's sweep asserts.
            configureBank(slot: slot, tune: tune, fs: fs)
            let centre = Self.hatBandHz * pow(2.0, (tone - 0.5) * 2.0)
            let svf = DrumDSP.svfCoefficients(cutoff: centre, q: 1.6, sampleRate: fs)
            voices[slot].svf1A1 = svf.a1; voices[slot].svf1A2 = svf.a2
            voices[slot].svf1A3 = svf.a3; voices[slot].svf1K = svf.k
            voices[slot].hpCoef = DrumDSP.onePoleCoefficient(cutoff: Self.hatHighpassHz,
                                                             sampleRate: fs)
            voices[slot].amp = 1
            voices[slot].ampCoef = DrumDSP.decayCoefficient(seconds: decay, sampleRate: fs)
            // `snap` is ATTACK SHARPNESS here: at 1 the gate opens instantly.
            let attackSeconds = (1.0 - snap) * 0.006 + 0.00005
            voices[slot].attack = 0
            voices[slot].attackRate = min(1.0 / max(attackSeconds * fs, 1), 1)
            voices[slot].toneMix = 1  // the band already placed the tone

        case .clap:
            // The four-pulse retrigger IS the sound. Three fast bursts plus one
            // longer diffuse tail is what makes it read as many hands.
            let spread = max(p(.spread, params.spread), 0.0005)
            let svf = DrumDSP.svfCoefficients(cutoff: tune, q: 1.4, sampleRate: fs)
            voices[slot].svf1A1 = svf.a1; voices[slot].svf1A2 = svf.a2
            voices[slot].svf1A3 = svf.a3; voices[slot].svf1K = svf.k
            voices[slot].clapSpread = max(DrumDSP.sampleCount(seconds: spread,
                                                              sampleRate: fs,
                                                              fallback: 1), 1)
            voices[slot].clapPulse = 0
            voices[slot].clapNext = 0
            voices[slot].burstCoef = DrumDSP.decayCoefficient(seconds: 0.0045, sampleRate: fs)
            voices[slot].tailCoef = DrumDSP.decayCoefficient(seconds: decay, sampleRate: fs)
            voices[slot].burstGain = 1.0 - 0.35 * snap
            voices[slot].tailGain = 0.55 + 0.45 * snap
            voices[slot].noiseGain = 1
            longest = decay + spread * 3

        case .tom:
            // The kick topology at a much shallower sweep, plus a second
            // inharmonic mode and a stick transient.
            let pitchAmount = max(p(.pitchAmount, params.pitchAmount), 0)
            voices[slot].baseFreq = max(tune, 1)
            voices[slot].pitchAmount = pitchAmount
            voices[slot].pitchEnv = 1
            voices[slot].pitchCoef = DrumDSP.decayCoefficient(
                seconds: DrumKitParams.tomPitchDecay(forDecay: decay), sampleRate: fs)
            voices[slot].amp = 1
            voices[slot].ampCoef = DrumDSP.decayCoefficient(seconds: decay, sampleRate: fs)
            let m2 = DrumDSP.modalCoefficients(frequency: tune * 1.52,
                                               seconds: decay * 0.4, sampleRate: fs)
            voices[slot].m2a1 = m2.a1; voices[slot].m2a2 = m2.a2
            voices[slot].m2y1 = m2.y1; voices[slot].m2y2 = m2.y2
            voices[slot].m2Gain = 0.35
            voices[slot].click = 1
            voices[slot].clickCoef = DrumDSP.decayCoefficient(seconds: 0.006, sampleRate: fs)
            voices[slot].clickGain = snap
            voices[slot].clickHpCoef = DrumDSP.onePoleCoefficient(cutoff: 2000, sampleRate: fs)

        case .rim:
            // One very short ring plus a tiny click. The same circuit with a
            // longer, purer ring is a clave.
            let m1 = DrumDSP.modalCoefficients(frequency: tune, seconds: decay, sampleRate: fs)
            voices[slot].m1a1 = m1.a1; voices[slot].m1a2 = m1.a2
            voices[slot].m1y1 = m1.y1; voices[slot].m1y2 = m1.y2
            voices[slot].m1Gain = 1
            let m2 = DrumDSP.modalCoefficients(frequency: tune * 2.7,
                                               seconds: decay * 0.5, sampleRate: fs)
            voices[slot].m2a1 = m2.a1; voices[slot].m2a2 = m2.a2
            voices[slot].m2y1 = m2.y1; voices[slot].m2y2 = m2.y2
            voices[slot].m2Gain = tone
            voices[slot].click = 1
            voices[slot].clickCoef = DrumDSP.decayCoefficient(seconds: 0.0015, sampleRate: fs)
            voices[slot].clickGain = snap
            voices[slot].clickHpCoef = DrumDSP.onePoleCoefficient(cutoff: 1500, sampleRate: fs)
            voices[slot].toneMix = 1  // `tone` is the second ring's level here

        case .cymbal:
            // ⭐ THE SAME BANK AS THE HATS, THROUGH THE **OTHER** BANDPASS —
            // and the decay applies to the LOWER band only. That asymmetry is
            // the entire difference between a cymbal and a very long hat, and
            // it is the thing a copy-paste of the hat's constants would lose.
            configureBank(slot: slot, tune: tune, fs: fs)
            let band = p(.band, params.band)
            let low = DrumDSP.svfCoefficients(cutoff: band, q: 1.1, sampleRate: fs)
            voices[slot].svf1A1 = low.a1; voices[slot].svf1A2 = low.a2
            voices[slot].svf1A3 = low.a3; voices[slot].svf1K = low.k
            let high = DrumDSP.svfCoefficients(cutoff: Self.hatBandHz, q: 1.6, sampleRate: fs)
            voices[slot].svf2A1 = high.a1; voices[slot].svf2A2 = high.a2
            voices[slot].svf2A3 = high.a3; voices[slot].svf2K = high.k
            voices[slot].amp = 1
            voices[slot].ampCoef = DrumDSP.decayCoefficient(seconds: decay, sampleRate: fs)
            voices[slot].amp2 = 1
            voices[slot].amp2Coef = DrumDSP.decayCoefficient(seconds: decay * 0.25,
                                                             sampleRate: fs)
            voices[slot].amp2Gain = 1.0 - tone
            let attackSeconds = (1.0 - snap) * 0.006 + 0.00005
            voices[slot].attack = 0
            voices[slot].attackRate = min(1.0 / max(attackSeconds * fs, 1), 1)
            voices[slot].toneMix = 1
        }

        voices[slot].tracker = 1
        voices[slot].trackerCoef = DrumDSP.decayCoefficient(
            seconds: max(longest, 0.005) * 1.35, sampleRate: fs)
    }

    private func configureBank(slot: Int, tune: Double, fs: Double) {
        let scale = min(max(DrumDSP.finite(tune, 1), 0.05), 8)
        for k in 0..<Self.bankSize {
            let index = slot * Self.bankSize + k
            let frequency = min(Self.bankFrequencies[k] * scale, fs * 0.45)
            bankInc[index] = frequency / fs
            // Phases are reset per hit, so the render is a pure function of
            // position — the same determinism rule the PRNG seeding follows.
            bankPhase[index] = Double(k) * 0.137
        }
    }

    // MARK: - Per-slot synthesis

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @inline(__always)
    private func renderSlot(_ slot: Int) -> Double {
        let fs = sampleRate
        var out = 0.0

        switch voices[slot].topology {
        case 0, 5:  // kick, tom — a swept sine plus transients
            voices[slot].amp *= voices[slot].ampCoef
            voices[slot].pitchEnv *= voices[slot].pitchCoef
            let frequency = voices[slot].baseFreq
                * (1.0 + voices[slot].pitchAmount * voices[slot].pitchEnv)
            voices[slot].phase += min(frequency, fs * 0.49) / fs
            if voices[slot].phase >= 1 { voices[slot].phase -= 1 }
            var body = sin(2.0 * Double.pi * voices[slot].phase) * voices[slot].amp
            if voices[slot].m2Gain != 0 {
                let y = voices[slot].m2a1 * voices[slot].m2y1
                    - voices[slot].m2a2 * voices[slot].m2y2
                voices[slot].m2y2 = voices[slot].m2y1
                voices[slot].m2y1 = y
                body += y * voices[slot].m2Gain
            }
            if voices[slot].clickGain != 0 {
                voices[slot].click *= voices[slot].clickCoef
                let n = DrumDSP.nextNoise(&voices[slot].rng)
                let hp = DrumDSP.onePoleHighpass(n, state: &voices[slot].clickHpState,
                                                 coefficient: voices[slot].clickHpCoef)
                body += hp * voices[slot].click * voices[slot].clickGain
            }
            out = saturate(slot: slot, input: body)

        case 1:  // snare — two drumhead modes plus gated noise
            let y1 = voices[slot].m1a1 * voices[slot].m1y1
                - voices[slot].m1a2 * voices[slot].m1y2
            voices[slot].m1y2 = voices[slot].m1y1
            voices[slot].m1y1 = y1
            let y2 = voices[slot].m2a1 * voices[slot].m2y1
                - voices[slot].m2a2 * voices[slot].m2y2
            voices[slot].m2y2 = voices[slot].m2y1
            voices[slot].m2y1 = y2
            var value = y1 * voices[slot].m1Gain + y2 * voices[slot].m2Gain
            voices[slot].amp2 *= voices[slot].amp2Coef
            let n = DrumDSP.nextNoise(&voices[slot].rng)
            let band = DrumDSP.svfStep(n, ic1: &voices[slot].svf1Ic1,
                                       ic2: &voices[slot].svf1Ic2,
                                       a1: voices[slot].svf1A1, a2: voices[slot].svf1A2,
                                       a3: voices[slot].svf1A3, k: voices[slot].svf1K).band
            let hp = DrumDSP.onePoleHighpass(band, state: &voices[slot].hpState,
                                             coefficient: voices[slot].hpCoef)
            value += hp * voices[slot].amp2 * voices[slot].amp2Gain
            out = saturate(slot: slot, input: value)

        case 2, 3:  // closed / open hat — six squares, fixed band, fixed highpass
            voices[slot].amp *= voices[slot].ampCoef
            voices[slot].attack += (1.0 - voices[slot].attack) * voices[slot].attackRate
            var sum = 0.0
            let base = slot * Self.bankSize
            for k in 0..<Self.bankSize {
                let index = base + k
                let dt = bankInc[index]
                sum += DrumDSP.blepSquare(phase: bankPhase[index], dt: dt)
                var phase = bankPhase[index] + dt
                if phase >= 1 { phase -= 1 }
                bankPhase[index] = phase
            }
            sum *= 1.0 / Double(Self.bankSize)
            let band = DrumDSP.svfStep(sum, ic1: &voices[slot].svf1Ic1,
                                       ic2: &voices[slot].svf1Ic2,
                                       a1: voices[slot].svf1A1, a2: voices[slot].svf1A2,
                                       a3: voices[slot].svf1A3, k: voices[slot].svf1K).band
            let hp1 = DrumDSP.onePoleHighpass(band, state: &voices[slot].hpState,
                                              coefficient: voices[slot].hpCoef)
            let hp = DrumDSP.onePoleHighpass(hp1, state: &voices[slot].hpState2,
                                             coefficient: voices[slot].hpCoef)
            // ⛔ THE DRIVE STAGE IS HERE BECAUSE THE SPEC TABLE SAYS `drive`
            // EXISTS ON THIS VOICE. The design doc's §3.5 lists the core eight
            // — `drive` included — on every voice, but its §2.3/§2.7/§2.8
            // signal paths for the hats, rim and cymbal omit the saturator
            // entirely. Both cannot be true: a parameter in the schema with no
            // consumer is an INERT KNOB that accepts a value, echoes it back
            // and does nothing, which is this tree's signature defect.
            // `everyParameterHasAConsumer` caught all four voices at once.
            // Resolved toward the table, because 75 is the published count and
            // a driven hat is a real sound.
            out = saturate(slot: slot, input: hp * voices[slot].amp * voices[slot].attack)

        case 4:  // clap — the four-pulse retrigger
            voices[slot].burst *= voices[slot].burstCoef
            voices[slot].tail *= voices[slot].tailCoef
            if voices[slot].clapPulse < 4,
               voices[slot].sampleIndex >= voices[slot].clapNext {
                if voices[slot].clapPulse < 3 {
                    voices[slot].burst = 1
                } else {
                    voices[slot].tail = 1
                }
                voices[slot].clapPulse += 1
                voices[slot].clapNext += voices[slot].clapSpread
            }
            let n = DrumDSP.nextNoise(&voices[slot].rng)
            let band = DrumDSP.svfStep(n, ic1: &voices[slot].svf1Ic1,
                                       ic2: &voices[slot].svf1Ic2,
                                       a1: voices[slot].svf1A1, a2: voices[slot].svf1A2,
                                       a3: voices[slot].svf1A3, k: voices[slot].svf1K).band
            let envelope = voices[slot].burst * voices[slot].burstGain
                + voices[slot].tail * voices[slot].tailGain
            out = saturate(slot: slot, input: band * envelope)

        case 6:  // rim — one short ring plus a click
            let y1 = voices[slot].m1a1 * voices[slot].m1y1
                - voices[slot].m1a2 * voices[slot].m1y2
            voices[slot].m1y2 = voices[slot].m1y1
            voices[slot].m1y1 = y1
            let y2 = voices[slot].m2a1 * voices[slot].m2y1
                - voices[slot].m2a2 * voices[slot].m2y2
            voices[slot].m2y2 = voices[slot].m2y1
            voices[slot].m2y1 = y2
            voices[slot].click *= voices[slot].clickCoef
            let n = DrumDSP.nextNoise(&voices[slot].rng)
            let hp = DrumDSP.onePoleHighpass(n, state: &voices[slot].clickHpState,
                                             coefficient: voices[slot].clickHpCoef)
            // Drive: see the hat branch — the table lists it on every voice.
            out = saturate(slot: slot,
                           input: y1 * voices[slot].m1Gain + y2 * voices[slot].m2Gain
                               + hp * voices[slot].click * voices[slot].clickGain)

        default:  // 7 — cymbal
            voices[slot].amp *= voices[slot].ampCoef
            voices[slot].amp2 *= voices[slot].amp2Coef
            voices[slot].attack += (1.0 - voices[slot].attack) * voices[slot].attackRate
            var sum = 0.0
            let base = slot * Self.bankSize
            for k in 0..<Self.bankSize {
                let index = base + k
                let dt = bankInc[index]
                sum += DrumDSP.blepSquare(phase: bankPhase[index], dt: dt)
                var phase = bankPhase[index] + dt
                if phase >= 1 { phase -= 1 }
                bankPhase[index] = phase
            }
            sum *= 1.0 / Double(Self.bankSize)
            let low = DrumDSP.svfStep(sum, ic1: &voices[slot].svf1Ic1,
                                      ic2: &voices[slot].svf1Ic2,
                                      a1: voices[slot].svf1A1, a2: voices[slot].svf1A2,
                                      a3: voices[slot].svf1A3, k: voices[slot].svf1K).band
            let high = DrumDSP.svfStep(sum, ic1: &voices[slot].svf2Ic1,
                                       ic2: &voices[slot].svf2Ic2,
                                       a1: voices[slot].svf2A1, a2: voices[slot].svf2A2,
                                       a3: voices[slot].svf2A3, k: voices[slot].svf2K).band
            // Drive: see the hat branch — the table lists it on every voice.
            out = saturate(slot: slot,
                           input: (low * voices[slot].amp
                               + high * voices[slot].amp2 * voices[slot].amp2Gain)
                               * voices[slot].attack)
        }

        // Tone tilt (skipped where the voice placed its own tone).
        if voices[slot].toneMix < 1 {
            voices[slot].toneState = out + voices[slot].toneCoef
                * (voices[slot].toneState - out)
            out = voices[slot].toneState
                + (out - voices[slot].toneState) * voices[slot].toneMix
        }

        voices[slot].gate *= voices[slot].gateCoef
        voices[slot].tracker *= voices[slot].trackerCoef
        voices[slot].sampleIndex &+= 1
        out *= voices[slot].gate * voices[slot].level

        // Retirement. Also the denormal guard: without it the envelope
        // recursions walk into subnormals, where some CPUs take a large
        // per-operation penalty and the voice never stops.
        if voices[slot].tracker < DrumDSP.silenceFloor
            || voices[slot].gate < DrumDSP.silenceFloor {
            voices[slot].active = false
            voices[slot].gate = 0
        }
        return DrumDSP.finite(out, 0)
    }

    @inline(__always)
    private func saturate(slot: Int, input: Double) -> Double {
        guard voices[slot].driveGain != 1.0 else { return input }
        let shaped = DrumDSP.adaaTanh(input * voices[slot].driveGain,
                                      prevX: voices[slot].adaaX,
                                      prevF: voices[slot].adaaF)
        voices[slot].adaaX = shaped.x
        voices[slot].adaaF = shaped.f
        return shaped.value * voices[slot].driveNorm
    }
}

private extension Double {
    /// Equal-power pan normaliser: `cos(π/4)·√2 == 1`, so centre pan is unity
    /// rather than 0.707 and a centred voice is not quietly attenuated.
    static let squareRootOfTwo = 1.4142135623730951
}
