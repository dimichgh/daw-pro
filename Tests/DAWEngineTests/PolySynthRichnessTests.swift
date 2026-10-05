import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-g — the PolySynth richness pass, measured.
///
/// `PolySynthRenderIdentityTests` proves the features change NOTHING when they
/// are off. This suite proves they do something REAL when they are on — every
/// assertion is a spectral or envelope measurement with a printed number, not a
/// "it rendered without crashing".
///
/// ⭐ The aliasing legs at the end are the ones worth reading first: they are
/// why this instrument's drive knob is not the naive `tanh` the brief
/// budgeted for.
/// ⛔ DELIBERATELY NOT `@MainActor`, AND DO NOT "TIDY" ONE BACK IN. This suite
/// builds `PolySynthInstrument` directly and drives `render()` — it touches no
/// main-actor type, so isolating it would add real occupancy to the census
/// `MainActorOccupancySiteTests` Leg C polices, for nothing. (It WAS written
/// `@MainActor` out of habit, which took that census to 381 against a cap of
/// 380; the sibling `PolySynthRenderIdentityTests` keeps its annotation because
/// `OfflineRenderer` genuinely is main-actor isolated. Removing the annotation
/// here is an occupancy REDUCTION; moving it onto each `@Test` would have been
/// the instrument-silencing move that gate exists to make unattractive.)
@Suite("m39-g PolySynth richness", .serialized)
struct PolySynthRichnessTests {
    private static let sampleRate = 48_000.0

    // MARK: - Harness

    private static func makeSynth(_ params: PolySynthParams) -> PolySynthInstrument {
        let synth = PolySynthInstrument(params: params)
        synth.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return synth
    }

    private static func note(on: Int64, off: Int64, pitch: UInt8,
                             velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    /// Direct render in 512-frame quanta; returns both channels.
    @discardableResult
    private static func render(_ params: PolySynthParams,
                               events unsorted: [ScheduledMIDIEvent],
                               frames totalFrames: Int) throws -> [[Float]] {
        let synth = makeSynth(params)
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        let quantum = 512
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let data = try #require(buffer.floatChannelData)

        var out: [[Float]] = [[], []]
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                synth.render(events: slice, renderStart: Int64(rendered),
                             frameCount: frames, output: output)
            }
            cursor = end
            for channel in 0..<2 {
                out[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frames))
            }
            rendered += frames
        }
        return out
    }

    /// One held note, 1 s, returned as both channels.
    private static func heldNote(_ params: PolySynthParams, pitch: UInt8 = 57,
                                 velocity: UInt8 = 127) throws -> [[Float]] {
        try render(params, events: note(on: 0, off: 200_000, pitch: pitch,
                                        velocity: velocity, id: 0), frames: 48_000)
    }

    // MARK: - Spectral probes

    /// Goertzel magnitude at `hz`, over a Hann-windowed slice. The window makes
    /// the probe usable at frequencies that are NOT a whole number of cycles in
    /// the slice, which matters because MIDI pitches never are.
    private static func magnitude(_ samples: [Float], from: Int, count: Int,
                                  hz: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for index in 0..<count {
            let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / Double(count - 1))
            let x = Double(samples[from + index]) * hann
            let s0 = x + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(0, power).squareRoot() / Double(count)
    }

    private static func frequency(ofPitch pitch: Int) -> Double {
        440.0 * exp2((Double(pitch) - 69.0) / 12.0)
    }

    /// A plain, non-throwing finiteness check. ⚠️ Deliberately not
    /// `allSatisfy(\.isFinite)` at the call sites: `allSatisfy` is `rethrows`,
    /// and inside `#expect`'s macro expansion that reads as a throwing call the
    /// expansion is not allowed to make.
    private static func allFinite(_ samples: [Float]) -> Bool {
        for sample in samples where !sample.isFinite { return false }
        return true
    }

    // MARK: - 1. Unison / detune / stereo spread

    @Test("unison: a detuned stack SMEARS energy off the exact fundamental")
    func unisonDetuneSmearsTheFundamental() throws {
        let pitch: UInt8 = 57                    // A3, 220 Hz
        let f0 = Self.frequency(ofPitch: Int(pitch))
        func fundamental(_ params: PolySynthParams) throws -> Double {
            let out = try Self.heldNote(params)
            return Self.magnitude(out[0], from: 8_000, count: 16_384, hz: f0)
        }
        let base = PolySynthParams(waveform: .sine, attack: 0.005, decay: 0.05,
                                   sustain: 1.0, release: 0.1, cutoffHz: 18_000,
                                   resonance: 0, gain: 1.0)
        var stacked = base
        stacked.unisonVoices = 7
        stacked.unisonDetuneCents = 30

        let single = try fundamental(base)
        let unison = try fundamental(stacked)
        print("[measured] unison — |f0| single: \(single), 7-voice 30-cent stack: \(unison), "
              + "ratio: \(unison / single)")
        // Seven detuned copies put most of their energy NEXT to f0, not on it.
        #expect(single > 0, "control failed: the single-voice reference must have a fundamental")
        #expect(unison < 0.85 * single,
                "a detuned stack that leaves the exact-f0 bin untouched is not detuning")
        // …and it is still a real, comparable signal, not just quieter.
        let singleRMS = TestSignals.rms(try Self.heldNote(base)[0], in: 8_000..<24_000)
        let unisonRMS = TestSignals.rms(try Self.heldNote(stacked)[0], in: 8_000..<24_000)
        print("[measured] unison — RMS single: \(singleRMS), stack: \(unisonRMS)")
        #expect(unisonRMS > 0.4 * singleRMS, "the stack must not collapse in level")
    }

    @Test("unison voices beyond the cap CLAMP rather than indexing past the allocation")
    func unisonVoicesClampToTheAllocation() throws {
        // The memory-safety leg. `PolySynthParams.maxUnisonVoices` bounds a
        // fixed render-thread allocation, so an out-of-range value must be
        // impossible to hand the engine — through the init OR through Codable,
        // which bypasses it.
        let viaInit = PolySynthParams(unisonVoices: 9_999)
        #expect(viaInit.unisonVoices == PolySynthParams.maxUnisonVoices)
        #expect(viaInit.effectiveUnisonVoices == PolySynthParams.maxUnisonVoices)

        var raw = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PolySynthParams())) as? [String: Any])
        raw["unisonVoices"] = 9_999
        let decoded = try JSONDecoder().decode(
            PolySynthParams.self,
            from: try JSONSerialization.data(withJSONObject: raw))
        print("[measured] unison clamp — decoded 9999 as: "
              + "\(String(describing: decoded.unisonVoices)), "
              + "effective: \(decoded.effectiveUnisonVoices)")
        #expect(decoded.effectiveUnisonVoices == PolySynthParams.maxUnisonVoices,
                "a project file may not hand the render thread an out-of-range voice count")
        #expect(decoded.effectiveUnisonVoices <= PolySynthParams.maxUnisonVoices)

        // POSITIVE CONTROL on the probe: an IN-range value must survive the
        // same path untouched, or the clamp above proves only that decoding is
        // broken.
        raw["unisonVoices"] = 5
        let sane = try JSONDecoder().decode(
            PolySynthParams.self,
            from: try JSONSerialization.data(withJSONObject: raw))
        #expect(sane.effectiveUnisonVoices == 5, "control failed: a legal count must survive")

        // And it renders, at the cap, without reading off the end.
        var maxed = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 18_000)
        maxed.unisonVoices = 9_999
        maxed.unisonDetuneCents = 50
        maxed.unisonStereoSpread = 1
        let out = try Self.heldNote(maxed)
        #expect(Self.allFinite(out[0]))
        #expect(TestSignals.peak(out[0], in: 0..<48_000) > 0)
    }

    @Test("stereo spread: channels DIFFER with spread, and are identical without it")
    func stereoSpreadSeparatesTheChannels() throws {
        var mono = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 18_000)
        mono.unisonVoices = 7
        mono.unisonDetuneCents = 25          // detune, but no spread
        var wide = mono
        wide.unisonStereoSpread = 1.0

        let monoOut = try Self.heldNote(mono)
        let wideOut = try Self.heldNote(wide)
        var widest: Float = 0
        for frame in 8_000..<24_000 {
            widest = max(widest, abs(wideOut[0][frame] - wideOut[1][frame]))
        }
        print("[measured] spread — max |L−R| spread=0: "
              + "\(zip(monoOut[0], monoOut[1]).map { abs($0 - $1) }.max() ?? 0), "
              + "spread=1: \(widest)")
        #expect(monoOut[0] == monoOut[1],
                "⛔ detune WITHOUT spread must stay mono — the pre-m39-g channel contract")
        #expect(widest > 0.01, "spread=1 must actually separate the channels")
        #expect(Self.allFinite(wideOut[0]) && Self.allFinite(wideOut[1]))
    }

    // MARK: - 2. Sub-oscillator

    @Test("sub-oscillator: level raises energy exactly one octave below the note")
    func subOscillatorAddsTheOctaveBelow() throws {
        let pitch: UInt8 = 57
        let f0 = Self.frequency(ofPitch: Int(pitch))
        let base = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                   resonance: 0, gain: 1.0)
        var withSub = base
        withSub.subLevel = 0.8
        withSub.subOctave = -1

        let dry = try Self.heldNote(base, pitch: pitch)
        let wet = try Self.heldNote(withSub, pitch: pitch)
        let dryOctaveDown = Self.magnitude(dry[0], from: 8_000, count: 16_384, hz: f0 / 2)
        let wetOctaveDown = Self.magnitude(wet[0], from: 8_000, count: 16_384, hz: f0 / 2)
        print("[measured] sub — |f0/2| without: \(dryOctaveDown), with: \(wetOctaveDown)")
        #expect(wetOctaveDown > 10 * max(dryOctaveDown, 1e-9),
                "a sub-oscillator that does not add the octave below is not a sub-oscillator")

        // -2 must be a DIFFERENT octave, not a relabelling of -1.
        var twoDown = withSub
        twoDown.subOctave = -2
        let deep = try Self.heldNote(twoDown, pitch: pitch)
        let quarter = Self.magnitude(deep[0], from: 8_000, count: 16_384, hz: f0 / 4)
        let halfInDeep = Self.magnitude(deep[0], from: 8_000, count: 16_384, hz: f0 / 2)
        print("[measured] sub — octave −2: |f0/4| \(quarter), |f0/2| \(halfInDeep)")
        #expect(quarter > halfInDeep, "subOctave −2 must sit two octaves down, not one")
    }

    // MARK: - 3. Noise layer

    @Test("noise layer: adds broadband energy, and colour tilts where that energy sits")
    func noiseLayerAddsColouredBroadbandEnergy() throws {
        let base = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                   resonance: 0, gain: 1.0)
        var dark = base
        dark.noiseLevel = 0.8
        dark.noiseColor = 0.0
        var bright = dark
        bright.noiseColor = 1.0

        // 7 kHz sits far from the 220 Hz note and every harmonic a sine has
        // (it has none), so anything measured there IS the noise layer.
        let dryHF = Self.magnitude(try Self.heldNote(base)[0],
                                   from: 8_000, count: 16_384, hz: 7_000)
        let darkOut = try Self.heldNote(dark)
        let brightOut = try Self.heldNote(bright)
        let darkHF = Self.magnitude(darkOut[0], from: 8_000, count: 16_384, hz: 7_000)
        let brightHF = Self.magnitude(brightOut[0], from: 8_000, count: 16_384, hz: 7_000)
        let darkLF = Self.magnitude(darkOut[0], from: 8_000, count: 16_384, hz: 400)
        let brightLF = Self.magnitude(brightOut[0], from: 8_000, count: 16_384, hz: 400)
        print("[measured] noise — 7 kHz: dry \(dryHF), dark \(darkHF), bright \(brightHF); "
              + "400 Hz: dark \(darkLF), bright \(brightLF)")
        #expect(brightHF > 5 * max(dryHF, 1e-9), "noise must add broadband energy")
        #expect(brightHF > darkHF,
                "colour 1 must put MORE energy up top than colour 0 — that is the tilt")
        #expect(darkLF > brightLF,
                "…and colour 0 must put more down low, or the tilt only goes one way")
    }

    // MARK: - 4. Oscillator drift

    @Test("drift: pitch wanders, smearing the exact fundamental, and stays bounded")
    func driftWandersThePitch() throws {
        let pitch: UInt8 = 69
        let f0 = Self.frequency(ofPitch: Int(pitch))
        let steady = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                     resonance: 0, gain: 1.0)
        var drifting = steady
        drifting.drift = 1.0

        // A long window: drift is SLOW by design, so a short one would not see
        // it move at all.
        let steadyOut = try Self.render(steady,
                                        events: Self.note(on: 0, off: 400_000, pitch: pitch, id: 0),
                                        frames: 192_000)
        let driftOut = try Self.render(drifting,
                                       events: Self.note(on: 0, off: 400_000, pitch: pitch, id: 0),
                                       frames: 192_000)
        let steadyF0 = Self.magnitude(steadyOut[0], from: 24_000, count: 131_072, hz: f0)
        let driftF0 = Self.magnitude(driftOut[0], from: 24_000, count: 131_072, hz: f0)
        print("[measured] drift — |f0| steady: \(steadyF0), drifting: \(driftF0), "
              + "ratio: \(driftF0 / steadyF0)")
        #expect(steadyF0 > 0, "control failed: the steady reference must have a fundamental")
        #expect(driftF0 < 0.98 * steadyF0,
                "drift that leaves the exact-f0 bin untouched is not drifting")
        // Bounded: drift is a shimmer, not a siren. Energy must still be
        // overwhelmingly NEAR f0 — within a couple of semitones.
        let farAway = Self.magnitude(driftOut[0], from: 24_000, count: 131_072, hz: f0 * 1.2)
        print("[measured] drift — |f0 × 1.2|: \(farAway)")
        #expect(farAway < 0.05 * driftF0, "drift must stay a shimmer, not a glissando")
        #expect(Self.allFinite(driftOut[0]))
    }

    // MARK: - 5. Filter self-oscillation headroom

    @Test("resonanceBoost: rings far harder at cutoff, and leaves the legacy Q untouched")
    func resonanceBoostAddsHeadroomAboveTheLegacyCeiling() throws {
        // ⭐ THE COMPATIBILITY HALF FIRST: the legacy mapping must be bit-exact
        // at boost 0, which is the whole reason this is a second field rather
        // than a wider `resonanceRange`.
        for resonance in [0.0, 0.1, 0.35, 0.7, 1.0] {
            let params = PolySynthParams(resonance: resonance)
            #expect(params.effectiveQ == 0.5 + resonance * 9.5,
                    "the legacy resonance→Q mapping moved at resonance \(resonance)")
        }
        #expect(PolySynthParams.resonanceRange == 0...1,
                "the legacy range must not have been widened")

        let cutoff = 1_500.0
        // Noise excites the filter across the band, so the resonant peak is
        // visible without sweeping an oscillator through it.
        var plain = PolySynthParams(waveform: .sine, sustain: 1.0,
                                    cutoffHz: cutoff, resonance: 1.0, gain: 1.0)
        plain.noiseLevel = 0.5
        var boosted = plain
        boosted.resonanceBoost = 1.0

        let plainPeak = Self.magnitude(try Self.heldNote(plain)[0],
                                       from: 8_000, count: 16_384, hz: cutoff)
        let boostedPeak = Self.magnitude(try Self.heldNote(boosted)[0],
                                         from: 8_000, count: 16_384, hz: cutoff)
        print("[measured] resonanceBoost — |cutoff| Q10: \(plainPeak), "
              + "Q\(PolySynthParams.maxBoostedQ): \(boostedPeak), "
              + "ratio: \(boostedPeak / plainPeak)")
        #expect(PolySynthParams(resonance: 1, resonanceBoost: 1).effectiveQ
                    == PolySynthParams.maxBoostedQ,
                "full boost at full resonance must reach the documented ceiling Q")
        #expect(boostedPeak > 2 * plainPeak,
                "boost that does not ring harder at cutoff is not headroom")
    }

    @Test("extreme settings stay finite: max resonance, max boost, max drive, max unison")
    func extremeSettingsProduceFiniteAudio() throws {
        var brutal = PolySynthParams(waveform: .saw, attack: 0.0005, decay: 0.001,
                                     sustain: 1.0, release: 0.001, cutoffHz: 40,
                                     resonance: 1.0, gain: 1.0)
        brutal.resonanceBoost = 1
        brutal.drive = 1
        brutal.unisonVoices = 8
        brutal.unisonDetuneCents = 50
        brutal.unisonStereoSpread = 1
        brutal.subLevel = 1
        brutal.noiseLevel = 1
        brutal.drift = 1
        brutal.voiceJitter = 1
        brutal.velocityToCutoff = 1
        brutal.keyToCutoff = 1
        brutal.envelopeCurve = 1

        var events: [ScheduledMIDIEvent] = []
        for id in 0..<20 {
            events += Self.note(on: Int64(id * 137), off: Int64(30_000 + id * 91),
                                pitch: UInt8(30 + 4 * id), velocity: 127, id: UInt64(id))
        }
        let out = try Self.render(brutal, events: events, frames: 96_000)
        let peak = max(TestSignals.peak(out[0], in: 0..<96_000),
                       TestSignals.peak(out[1], in: 0..<96_000))
        print("[measured] extremes — peak: \(peak), all finite: "
              + "\(Self.allFinite(out[0]) && Self.allFinite(out[1]))")
        #expect(Self.allFinite(out[0]), "left channel produced a NaN or infinity")
        #expect(Self.allFinite(out[1]), "right channel produced a NaN or infinity")
        #expect(peak > 0, "control failed: the extreme fixture must make sound")
        // Everything must eventually free and flush to EXACT zero — the
        // denormal guard's job, and the one a second filter could have broken.
        let tail = max(TestSignals.peak(out[0], in: 80_000..<96_000),
                       TestSignals.peak(out[1], in: 80_000..<96_000))
        print("[measured] extremes — tail peak after all releases: \(tail)")
        #expect(tail == 0, "voices must free to exact zeros, in BOTH channels")
    }

    // MARK: - 6. Velocity / key tracking on cutoff

    @Test("velocityToCutoff: a hard-struck note is brighter; at 0 velocity changes only level")
    func velocityTracksTheCutoff() throws {
        let pitch: UInt8 = 45                        // A2, 110 Hz
        let f0 = Self.frequency(ofPitch: Int(pitch))
        func brightness(_ params: PolySynthParams, velocity: UInt8) throws -> Double {
            let out = try Self.heldNote(params, pitch: pitch, velocity: velocity)
            let high = Self.magnitude(out[0], from: 8_000, count: 16_384, hz: f0 * 8)
            let low = Self.magnitude(out[0], from: 8_000, count: 16_384, hz: f0)
            return high / max(low, 1e-12)
        }
        let flat = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 400,
                                   resonance: 0, gain: 1.0)
        var tracking = flat
        tracking.velocityToCutoff = 1.0

        let flatSoft = try brightness(flat, velocity: 20)
        let flatHard = try brightness(flat, velocity: 127)
        let trackSoft = try brightness(tracking, velocity: 20)
        let trackHard = try brightness(tracking, velocity: 127)
        print("[measured] velToCutoff — H8/H1 ratio, amount 0: soft \(flatSoft) hard \(flatHard); "
              + "amount 1: soft \(trackSoft) hard \(trackHard)")
        // Without tracking, velocity is pure level: the harmonic RATIO is
        // unchanged. This is the control that the measurement sees TIMBRE, not
        // loudness.
        #expect(abs(flatHard - flatSoft) < 0.02 * max(flatHard, 1e-12),
                "control failed: without tracking, velocity must not change the spectrum shape")
        #expect(trackHard > 2.5 * trackSoft,
                "with full tracking, a hard-struck note must be markedly brighter")
    }

    @Test("keyToCutoff: a higher note opens the filter, pivoting on middle C")
    func keyTracksTheCutoff() throws {
        func brightness(_ params: PolySynthParams, pitch: UInt8) throws -> Double {
            let f0 = Self.frequency(ofPitch: Int(pitch))
            let out = try Self.heldNote(params, pitch: pitch)
            return Self.magnitude(out[0], from: 8_000, count: 16_384, hz: f0 * 6)
                / max(Self.magnitude(out[0], from: 8_000, count: 16_384, hz: f0), 1e-12)
        }
        let flat = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 600,
                                   resonance: 0, gain: 1.0)
        var tracking = flat
        tracking.keyToCutoff = 1.0

        let flatLow = try brightness(flat, pitch: 48)
        let flatHigh = try brightness(flat, pitch: 72)
        let trackLow = try brightness(tracking, pitch: 48)
        let trackHigh = try brightness(tracking, pitch: 72)
        print("[measured] keyToCutoff — H6/H1, amount 0: C3 \(flatLow) C5 \(flatHigh); "
              + "amount 1: C3 \(trackLow) C5 \(trackHigh)")
        // A fixed filter makes HIGH notes relatively DARKER (their harmonics
        // move up past a stationary cutoff). Key tracking is what undoes that.
        #expect(trackHigh / trackLow > flatHigh / flatLow,
                "key tracking must brighten the top of the keyboard relative to no tracking")
        #expect(PolySynthParams.keyTrackCenterPitch == 60,
                "the documented pivot is middle C")
    }

    // MARK: - 7. Per-voice randomisation

    @Test("voiceJitter: two notes at the SAME pitch differ; without it they are identical")
    func voiceJitterVariesOtherwiseIdenticalNotes() throws {
        // Two identical notes, sequential, same pitch and velocity. Without
        // jitter the second is a bit-exact repeat of the first.
        func twoNotes(_ params: PolySynthParams) throws -> (first: [Float], second: [Float]) {
            let events = Self.note(on: 0, off: 20_000, pitch: 60, id: 0)
                + Self.note(on: 48_000, off: 68_000, pitch: 60, id: 1)
            let out = try Self.render(params, events: events, frames: 96_000)
            return (Array(out[0][2_000..<18_000]), Array(out[0][50_000..<66_000]))
        }
        let plain = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 3_000,
                                    resonance: 0.3, gain: 1.0)
        var jittered = plain
        jittered.voiceJitter = 1.0

        let (a, b) = try twoNotes(plain)
        #expect(a == b, "control failed: without jitter two identical notes must be identical")

        let (c, d) = try twoNotes(jittered)
        var difference: Float = 0
        for index in 0..<min(c.count, d.count) {
            difference = max(difference, abs(c[index] - d[index]))
        }
        print("[measured] voiceJitter — max |note1 − note2| without: 0, with: \(difference)")
        #expect(difference > 0.001, "jitter must make two identical notes sound different")
        #expect(Self.allFinite(c) && Self.allFinite(d))
    }

    // MARK: - 8. Envelope curve shape

    @Test("envelopeCurve: +1 puts the attack midpoint at the SQUARE of linear's")
    func envelopeCurveReshapesTheAttack() throws {
        // 100 ms attack at 48 kHz = 4800 frames; a sine voice with the filter
        // wide open reads the envelope directly. The linear case's midpoint is
        // 0.5 of full (pinned by the existing suite); `p + c(p² − p)` at c = 1
        // is p², so the midpoint must land at 0.25.
        func attackShape(_ curve: Double?) throws -> (mid: Float, full: Float) {
            var params = PolySynthParams(waveform: .sine, attack: 0.1, decay: 0.5,
                                         sustain: 1.0, release: 0.1, cutoffHz: 18_000,
                                         resonance: 0, gain: 1.0)
            params.envelopeCurve = curve
            let out = try Self.heldNote(params, pitch: 69)
            return (TestSignals.peak(out[0], in: 2_200..<2_600),
                    TestSignals.peak(out[0], in: 4_800..<5_600))
        }
        let linear = try attackShape(nil)
        let curved = try attackShape(1.0)
        let inverse = try attackShape(-1.0)
        let linearRatio = Double(linear.mid / linear.full)
        let curvedRatio = Double(curved.mid / curved.full)
        let inverseRatio = Double(inverse.mid / inverse.full)
        print("[measured] envelopeCurve — attack midpoint / full: "
              + "linear \(linearRatio), curve +1 \(curvedRatio), curve −1 \(inverseRatio)")
        #expect(abs(linearRatio - 0.5) < 0.15, "control: the linear case is still linear")
        #expect(abs(curvedRatio - 0.25) < 0.08,
                "curve +1 must square the ramp — midpoint ≈ 0.25, got \(curvedRatio)")
        #expect(abs(inverseRatio - 0.75) < 0.08,
                "curve −1 must mirror it — midpoint ≈ 0.75, got \(inverseRatio)")
    }

    @Test("envelopeCurve: a curved release still reaches EXACT silence on time, with no click")
    func curvedReleaseStillEndsOnTimeWithoutAStep() throws {
        var params = PolySynthParams(waveform: .sine, attack: 0.005, decay: 0.05,
                                     sustain: 1.0, release: 0.1, cutoffHz: 18_000,
                                     resonance: 0, gain: 1.0)
        params.envelopeCurve = 1.0
        // Note off at 24 000; release 0.1 s = 4800 frames → silence by ≈ 28 800.
        let out = try Self.render(params,
                                  events: Self.note(on: 0, off: 24_000, pitch: 69, id: 0),
                                  frames: 48_000)
        let silence = TestSignals.peak(out[0], in: 29_500..<48_000)
        // ⭐ THE ANTI-CLICK LEG. A curved release anchored on the RAMP instead
        // of the AMPLITUDE steps at note-off. Compare the samples either side
        // of the boundary: a step would show up as a jump far larger than one
        // period's worth of change.
        var maxStep: Float = 0
        for frame in 23_990..<24_010 {
            maxStep = max(maxStep, abs(out[0][frame + 1] - out[0][frame]))
        }
        var typicalStep: Float = 0
        for frame in 20_000..<20_400 {
            typicalStep = max(typicalStep, abs(out[0][frame + 1] - out[0][frame]))
        }
        print("[measured] curved release — silence from 29 500: \(silence), "
              + "max step at note-off: \(maxStep), typical step while held: \(typicalStep)")
        #expect(silence == 0, "a curved release must still reach EXACT zero on schedule")
        #expect(maxStep < 1.5 * typicalStep,
                "the release boundary stepped — the curve is anchored on the wrong value")
    }

    // MARK: - 9. Determinism WITH the randomised features on

    @Test("determinism: jitter + drift + noise + unison still render identically run to run")
    func randomisedFeaturesAreStillDeterministic() throws {
        // ⚠️ The pre-existing determinism pin only covers the path that uses
        // NO random numbers, so it would stay green over a render-thread RNG
        // that was seeded from the clock. This is the leg that actually
        // exercises the generator.
        var params = PolySynthParams(waveform: .saw, sustain: 0.7, cutoffHz: 4_000,
                                     resonance: 0.4, gain: 0.9)
        params.unisonVoices = 5
        params.unisonDetuneCents = 20
        params.unisonStereoSpread = 0.8
        params.noiseLevel = 0.4
        params.drift = 0.7
        params.voiceJitter = 0.9

        let events = Self.note(on: 0, off: 30_000, pitch: 60, id: 0)
            + Self.note(on: 6_000, off: 36_000, pitch: 64, id: 1)
        let a = try Self.render(params, events: events, frames: 72_000)
        let b = try Self.render(params, events: events, frames: 72_000)
        print("[measured] randomised determinism — L equal: \(a[0] == b[0]), "
              + "R equal: \(a[1] == b[1]), peak: \(TestSignals.peak(a[0], in: 0..<72_000))")
        #expect(a[0] == b[0], "a seeded render thread must be reproducible sample for sample")
        #expect(a[1] == b[1])
        #expect(TestSignals.peak(a[0], in: 0..<72_000) > 0.05,
                "control failed: comparing two silences would pass vacuously")
    }

    // MARK: - 10. DRIVE, and the aliasing it could have shipped

    @Test("drive: adds harmonics a clean sine does not have")
    func driveAddsHarmonics() throws {
        let pitch: UInt8 = 45                       // A2, 110 Hz — room for many harmonics
        let f0 = Self.frequency(ofPitch: Int(pitch))
        let clean = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                    resonance: 0, gain: 1.0)
        var driven = clean
        driven.drive = 1.0

        let cleanOut = try Self.heldNote(clean, pitch: pitch)
        let drivenOut = try Self.heldNote(driven, pitch: pitch)
        func harmonic(_ samples: [Float], _ n: Double) -> Double {
            Self.magnitude(samples, from: 8_000, count: 16_384, hz: f0 * n)
        }
        let cleanH3 = harmonic(cleanOut[0], 3)
        let drivenH3 = harmonic(drivenOut[0], 3)
        let drivenH1 = harmonic(drivenOut[0], 1)
        print("[measured] drive — H3 clean: \(cleanH3), driven: \(drivenH3); "
              + "driven H3/H1: \(drivenH3 / drivenH1)")
        #expect(drivenH3 > 20 * max(cleanH3, 1e-9),
                "a drive knob that adds no harmonics is doing nothing")
        // tanh is an ODD nonlinearity: it makes 3rd/5th, not 2nd.
        let drivenH2 = harmonic(drivenOut[0], 2)
        print("[measured] drive — driven H2/H3: \(drivenH2 / drivenH3)")
        #expect(drivenH2 < 0.1 * drivenH3,
                "tanh is odd-symmetric: even harmonics must stay suppressed")
    }

    /// ⭐⭐ THE ALIASING MEASUREMENT, and the reason this knob is ADAA.
    ///
    /// A SINE source is the whole trick: a sine has no harmonics of its own, so
    /// EVERY partial in the output was made by the waveshaper, and every
    /// partial that is not an odd multiple of f0 is a fold-back. Measuring a
    /// saw instead would have mixed in polyBLEP's own residual and measured
    /// nothing conclusive.
    ///
    /// The probe reports, for a rising run of high notes, the frequency of the
    /// strongest INHARMONIC partial. Aliasing's signature is that this
    /// frequency DESCENDS as the played note ASCENDS.
    /// Where a partial at `hz` ACTUALLY appears once sampled at 48 kHz: folded
    /// into [0, Nyquist]. Above Nyquist this is the alias frequency.
    private static func foldedFrequency(_ hz: Double) -> Double {
        let wrapped = hz.truncatingRemainder(dividingBy: sampleRate)
        return wrapped > sampleRate / 2 ? sampleRate - wrapped : wrapped
    }

    /// Alias energy relative to the fundamental, for a SINE driven through a
    /// waveshaper.
    ///
    /// ⚠️⚠️ WHY THIS PROBES EXACT FREQUENCIES AND NOT A GRID. The first version
    /// of this measurement swept a 100 Hz grid and classified each probe as
    /// harmonic or not. It produced confident nonsense — alias/harmonic ratios
    /// above 1, which is impossible for a bounded signal. The cause: over a
    /// 16384-sample window a bin is 2.9 Hz wide, so a grid probe 14 Hz away
    /// from the fundamental sits outside the Hann mainlobe entirely and reads
    /// ~60 dB low, while an alias that happened to land ON a grid point read
    /// full scale. It was comparing a well-aimed alias against a mis-aimed
    /// fundamental.
    ///
    /// `tanh` is odd, so it makes only odd harmonics — every one of which is at
    /// a frequency we can compute rather than search for. Probing exactly there
    /// removes the aiming error completely.
    private static func aliasProfile(_ samples: [Float], f0: Double)
        -> (alias: Double, audible: Double, fundamental: Double, firstAliasHz: Double) {
        let nyquist = sampleRate / 2
        let fundamental = Self.magnitude(samples, from: 8_000, count: 16_384, hz: f0)

        // Every odd harmonic that is still BELOW Nyquist is real, wanted
        // content. A fold that lands on one of them is not separable from it,
        // so it is skipped rather than counted as inharmonic energy.
        var realHarmonics: [Double] = []
        var m = 1
        while Double(m) * f0 < nyquist {
            realHarmonics.append(Double(m) * f0)
            m += 2
        }

        var alias = 0.0
        var audible = 0.0
        var firstAliasHz = 0.0
        // ⚠️⚠️ THE HARMONIC CEILING IS WHERE THIS PROBE WENT BLIND TWICE.
        // Version 1 stopped at n = 21: at pitch 60 no harmonic that low even
        // reaches Nyquist, so the probe measured exactly zero foldback and
        // "passed". Version 2 stopped at 101: pitch 60's only candidate
        // (n = 101) landed 134 Hz from a real harmonic and was excluded by the
        // collision guard, so it measured zero again. A probe that cannot fail
        // is not a probe, and a zero it returns is indistinguishable from a
        // clean result.
        //
        // So: scan far enough up that every pitch has candidates (n ≤ 401),
        // but stop after `maxFolds` separable ones. That bounds the cost (each
        // one is a Goertzel pass over 16k samples) while guaranteeing coverage
        // at the bottom of the run, and the folds it keeps are the LOWEST
        // harmonics above Nyquist — which for a tanh are also the loudest.
        let maxFolds = 24
        var foldsCounted = 0
        for n in stride(from: 3, through: 401, by: 2) {
            guard foldsCounted < maxFolds else { break }
            let raw = Double(n) * f0
            guard raw > nyquist else { continue }
            let folded = Self.foldedFrequency(raw)
            guard folded > 20 else { continue }
            var collides = false
            for harmonic in realHarmonics where abs(folded - harmonic) < 200 { collides = true }
            guard !collides else { continue }
            let level = Self.magnitude(samples, from: 8_000, count: 16_384, hz: folded)
            alias += level
            // Folds above 16 kHz are real but sit where neither the patch's own
            // low-pass nor most listeners pass them. The absolute bar is applied
            // to the audible band; the full sum still drives the naive-vs-shipped
            // comparison so neither number can be gamed by the other.
            if folded < 16_000 { audible += level }
            if firstAliasHz == 0 { firstAliasHz = folded }
            foldsCounted += 1
        }
        return (alias, audible, fundamental, firstAliasHz)

    }

    /// Applies the NAIVE reference waveshaper at the same input scale the
    /// engine's shaper actually sees.
    ///
    /// ⚠️⚠️ THE SCALE HERE IS LOAD-BEARING, AND GETTING IT WRONG INVERTED THE
    /// VERDICT ONCE ALREADY. The engine shapes the RAW oscillator (±1) at
    /// `drive × 8`. A rendered buffer has already been through `voiceAmplitude`
    /// (0.25), so `tanh(rendered × 8)` is really `tanh(2 × osc)` — a gentle
    /// shaper that barely has a 7th harmonic — not the near-square `tanh(8 ×
    /// osc)` the engine produces. The first version of this comparison made
    /// exactly that mistake and reported the shipped ADAA path as WORSE than
    /// naive at the two lowest pitches on the run, which would have wrongly
    /// dropped the feature. Normalising to unit peak first recovers the
    /// oscillator's own scale without hardcoding the engine's private headroom
    /// constant.
    private static func naiveShaped(_ samples: [Float], gain: Float = 8) -> [Float] {
        var peak: Float = 0
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        guard peak > 1e-6 else { return samples }
        let scale = gain / peak
        let norm = Float(1.0 / tanh(Double(gain)))
        return samples.map { tanh($0 * scale) * norm }
    }

    @Test("drive aliasing: a NAIVE tanh folds partials downward as the note rises (the control)")
    func naiveTanhAliasesOnARisingRun() throws {
        // POSITIVE CONTROL ON THE PROBE ITSELF. This is not the shipped path —
        // it is the naive waveshaper the brief budgeted for, applied in the
        // TEST to the synth's own clean sine. If the probe cannot see aliasing
        // HERE, its verdict on the shipped path is worthless.
        //
        // Pitches 120/123/126 are chosen so the THIRD harmonic is the one that
        // folds (3·f0 > 24 kHz ⇒ f0 > 8 kHz) and folds further with every step
        // up — no wrap-around ambiguity in the range.
        let clean = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                    resonance: 0, gain: 1.0)
        var aliasFrequencies: [Double] = []
        var ratios: [Double] = []
        for pitch in [UInt8(120), 123, 126] {
            let f0 = Self.frequency(ofPitch: Int(pitch))
            let out = try Self.heldNote(clean, pitch: pitch)
            let shaped = Self.naiveShaped(out[0])
            let profile = Self.aliasProfile(shaped, f0: f0)
            aliasFrequencies.append(profile.firstAliasHz)
            ratios.append(profile.alias / max(profile.fundamental, 1e-12))
            print("[measured] NAIVE tanh — pitch \(pitch) (f0 \(Int(f0)) Hz): "
                  + "3rd harmonic folds to \(Int(profile.firstAliasHz)) Hz; "
                  + "alias/fundamental \(profile.alias / max(profile.fundamental, 1e-12)) "
                  + "(\(20 * log10(max(profile.alias / max(profile.fundamental, 1e-12), 1e-12))) dB)")
        }
        print("[measured] NAIVE tanh — alias frequency as the note RISES: \(aliasFrequencies)")
        // THE SIGNATURE: the note went up three times; the artefact went DOWN.
        var descends = true
        for index in 1..<aliasFrequencies.count
        where aliasFrequencies[index] >= aliasFrequencies[index - 1] { descends = false }
        #expect(descends, """
            control failed: the probe did not see a DESCENDING partial even from a naive tanh, \
            so it cannot be trusted to clear the shipped one.
            """)
        var sawSubstantialAliasing = false
        for ratio in ratios where ratio > 0.02 { sawSubstantialAliasing = true }
        #expect(sawSubstantialAliasing,
                "control failed: the naive shaper must show substantial inharmonic content")
    }

    /// ⭐⭐ THE DECISION LEG. The coordinator's standing instruction was: measure
    /// the drive knob's aliasing and either fix it, or DROP the feature — do not
    /// ship it unmeasured, because this tree already regrets one naive `tanh`.
    /// This is the measurement that decided it.
    ///
    /// ⚠️ HONEST CAVEAT, stated because it flatters the shipped path: the engine
    /// applies drive BEFORE its low-pass, so the 18 kHz filter attenuates
    /// whatever survives above it, while the naive reference is shaped AFTER the
    /// filter. That ordering is itself part of why the shipped path aliases
    /// less, and it is a real property of the design, not a measurement trick —
    /// but it does mean this compares two SIGNAL PATHS, not two waveshapers in
    /// isolation.
    @Test("drive aliasing: the SHIPPED path folds measurably less than a naive tanh")
    func adaaDriveSuppressesTheFoldback() throws {
        var driven = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                     resonance: 0, gain: 1.0)
        driven.drive = 1.0
        let clean = PolySynthParams(waveform: .sine, sustain: 1.0, cutoffHz: 18_000,
                                    resonance: 0, gain: 1.0)

        var improvements: [Double] = []
        var shippedRatios: [(UInt8, Double)] = []
        for pitch in [UInt8(60), 72, 84, 96, 108, 114, 120, 126] {
            let f0 = Self.frequency(ofPitch: Int(pitch))
            let shipped = Self.aliasProfile(try Self.heldNote(driven, pitch: pitch)[0], f0: f0)
            let shippedRatio = shipped.alias / max(shipped.fundamental, 1e-12)

            let cleanOut = try Self.heldNote(clean, pitch: pitch)
            let naiveProfile = Self.aliasProfile(Self.naiveShaped(cleanOut[0]), f0: f0)
            let naiveRatio = naiveProfile.alias / max(naiveProfile.fundamental, 1e-12)

            // Only a pitch where the NAIVE reference actually folds can say
            // anything about suppression; below that there is no defect to fix.
            if naiveRatio > 1e-4 { improvements.append(naiveRatio / max(shippedRatio, 1e-12)) }
            shippedRatios.append((pitch, shipped.audible / max(shipped.fundamental, 1e-12)))
            print("[measured] drive alias — pitch \(pitch) (f0 \(Int(f0)) Hz): "
                  + "naive alias/fundamental \(naiveRatio) "
                  + "(\(20 * log10(max(naiveRatio, 1e-12))) dB), "
                  + "shipped \(shippedRatio) (\(20 * log10(max(shippedRatio, 1e-12))) dB), "
                  + "improvement x\(naiveRatio / max(shippedRatio, 1e-12))")
        }
        print("[measured] drive alias — improvement factors across the run: \(improvements)")
        // The second half of the decision rule: beating naive is necessary but
        // not sufficient — the shipped artefact must also be INAUDIBLE through
        // the range anyone plays. -40 dB is the bar; report where it is first
        // crossed so the caveat in the docs is a measured pitch, not a guess.
        var firstAudiblePitch: UInt8?
        for (pitch, ratio) in shippedRatios where ratio > 0.01 && firstAudiblePitch == nil {
            firstAudiblePitch = pitch
        }
        print("[measured] drive alias — shipped path first exceeds -40 dB at pitch "
              + "\(firstAudiblePitch.map(String.init) ?? "none in range")")
        var quietThroughPitch96 = true
        for (pitch, ratio) in shippedRatios where pitch <= 96 && ratio > 0.01 {
            quietThroughPitch96 = false
        }
        #expect(quietThroughPitch96, """
            the shipped drive path's foldback exceeds -40 dB somewhere at or below pitch 96 \
            (C7) — inside the range people actually play. Per the m39-g course correction \
            that is a DROP condition for this feature, not a tuning problem.
            """)
        // ⭐ ANTI-VACUITY GUARD. If the reference stopped folding everywhere,
        // `improvements` would be empty and `allPass` would be trivially true —
        // the exact shape of failure this probe has already produced twice.
        #expect(improvements.count >= 5, """
            the naive reference showed measurable foldback at fewer than 5 pitches, so the \
            comparison below is close to vacuous. Fix the probe, do not trust the verdict.
            """)
        var improvementsAllPass = true
        for factor in improvements where factor <= 1.0 { improvementsAllPass = false }
        #expect(improvementsAllPass, """
            the shipped drive path folds MORE than a naive tanh at some pitch on the run. \
            Per the m39-g course correction that is a DROP condition for this feature, not a \
            tuning problem — see the suite comment.
            """)
    }

    /// ⭐⭐ THE REALISTIC WORST CASE, and the one the m39-g course correction
    /// named by name: "we drive bright saw/square waves at high cutoff."
    ///
    /// A sine gives a waveshaper only one partial to fold. A saw hands it
    /// harmonics all the way to Nyquist, so EVERY one of them folds — this is
    /// the case that decides whether the drive knob is shippable, and the sine
    /// measurement above flatters it.
    ///
    /// ⚠️ A saw's folds are dense, so the exact-fold-frequency probe used above
    /// cannot separate them. This measures the thing that is actually audible
    /// instead: the INTER-HARMONIC FLOOR — energy sitting halfway between the
    /// harmonics, where a periodic signal should have none. Aliasing is the
    /// only mechanism that puts energy there, so the floor IS the artefact.
    private static func interHarmonicFloor(_ samples: [Float], f0: Double) -> Double {
        var floor = 0.0
        var count = 0
        var m = 1.5
        while m * f0 < 16_000 && count < 40 {
            floor += Self.magnitude(samples, from: 8_000, count: 16_384, hz: m * f0)
            count += 1
            m += 1
        }
        return count > 0 ? floor / Double(count) : 0
    }

    @Test("drive aliasing: a bright SAW — the realistic worst case — stays below the naive floor")
    func drivenSawInterHarmonicFloor() throws {
        var driven = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 18_000,
                                     resonance: 0, gain: 1.0)
        driven.drive = 1.0
        let clean = PolySynthParams(waveform: .saw, sustain: 1.0, cutoffHz: 18_000,
                                    resonance: 0, gain: 1.0)

        var shippedBeatsNaiveEverywhere = true
        var sawRealDegradation = false
        for pitch in [UInt8(60), 72, 84, 96] {
            let f0 = Self.frequency(ofPitch: Int(pitch))
            let cleanOut = try Self.heldNote(clean, pitch: pitch)[0]
            let shippedOut = try Self.heldNote(driven, pitch: pitch)[0]

            let cleanFundamental = Self.magnitude(cleanOut, from: 8_000, count: 16_384, hz: f0)
            let shippedFundamental = Self.magnitude(shippedOut, from: 8_000, count: 16_384, hz: f0)

            // The polyBLEP saw has an inter-harmonic floor of its OWN. Quoting
            // the driven floor without it would blame the waveshaper for the
            // oscillator's residue, so the baseline is measured, not assumed.
            let cleanFloor = Self.interHarmonicFloor(cleanOut, f0: f0) / max(cleanFundamental, 1e-12)
            let naiveFloor = Self.interHarmonicFloor(Self.naiveShaped(cleanOut), f0: f0)
                / max(cleanFundamental, 1e-12)
            let shippedFloor = Self.interHarmonicFloor(shippedOut, f0: f0)
                / max(shippedFundamental, 1e-12)

            if shippedFloor >= naiveFloor { shippedBeatsNaiveEverywhere = false }
            if naiveFloor > cleanFloor * 3 { sawRealDegradation = true }
            print("[measured] SAW drive floor — pitch \(pitch) (f0 \(Int(f0)) Hz): "
                  + "oscillator baseline \(20 * log10(max(cleanFloor, 1e-12))) dB, "
                  + "naive \(20 * log10(max(naiveFloor, 1e-12))) dB, "
                  + "shipped \(20 * log10(max(shippedFloor, 1e-12))) dB, "
                  + "improvement x\(naiveFloor / max(shippedFloor, 1e-12))")
        }
        // POSITIVE CONTROL: if shaping a saw did not raise the floor well above
        // the oscillator's own, this probe is not measuring aliasing at all and
        // its verdict on the shipped path means nothing.
        #expect(sawRealDegradation, """
            control failed: a naive tanh on a bright saw did not measurably raise the \
            inter-harmonic floor above the oscillator's own baseline, so this probe cannot \
            see the defect it exists to catch.
            """)
        #expect(shippedBeatsNaiveEverywhere, """
            on a bright SAW — the realistic worst case for this knob — the shipped drive \
            path's inter-harmonic floor is no better than a naive tanh's. Per the m39-g \
            course correction that is a DROP condition for this feature.
            """)
    }

    // MARK: - 11. Voice-count budget (measured, not estimated)

    @Test("budget: 16 voices × 8 unison renders comfortably faster than real time")
    func unisonVoiceBudgetIsMeasured() throws {
        // The brief asked for thought about the voice-count budget; a number
        // answers it. ⚠️ This is a DEBUG build (`scripts/test.sh` does not
        // optimise) and other agents may be compiling concurrently, so the
        // bound is deliberately loose — it is a catastrophic-regression guard,
        // and the PRINTED figure is the actual deliverable.
        var worst = PolySynthParams(waveform: .saw, attack: 0.01, decay: 0.1,
                                    sustain: 1.0, release: 0.2, cutoffHz: 12_000,
                                    resonance: 0.5, gain: 0.8)
        worst.unisonVoices = PolySynthParams.maxUnisonVoices
        worst.unisonDetuneCents = 25
        worst.unisonStereoSpread = 1
        worst.subLevel = 0.5
        worst.noiseLevel = 0.3
        worst.drift = 0.5
        worst.drive = 0.8
        worst.voiceJitter = 0.5

        var events: [ScheduledMIDIEvent] = []
        for id in 0..<16 {
            events += Self.note(on: 0, off: 400_000, pitch: UInt8(40 + 3 * id), id: UInt64(id))
        }
        let frames = 48_000                      // one second of audio
        let started = ContinuousClock.now
        let out = try Self.render(worst, events: events, frames: frames)
        let elapsed = started.duration(to: ContinuousClock.now)
        let ms = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        print("[measured] budget — 16 voices × \(PolySynthParams.maxUnisonVoices) unison "
              + "(+ sub, noise, drift, drive, jitter, stereo): \(ms) ms per second of audio "
              + "= \(ms / 10) % of one core, DEBUG build")
        #expect(Self.allFinite(out[0]))
        #expect(TestSignals.peak(out[0], in: 0..<frames) > 0,
                "control failed: the budget fixture must make sound")
        #expect(ms < 10_000, "128 oscillators went slower than 10× real time even in debug")
    }
}
