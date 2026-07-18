import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m19-b (design 2026-07-16 §3/§4.4/§4.5): per-zone playback scalars —
/// tuneCents, pan, ampVelTrack, one-shot override, start/end frames, and the
/// per-voice 4-stage envelope — plus the A5 zone-gain relax to 2.0.
///
/// Direct-render idiom from `SamplerTests`/`SamplerSelectionTests`: 512-frame
/// quanta, hand-built event arrays, programmatic temp-dir fixtures. The
/// existing `SamplerTests` + `SamplerSelectionTests` suites are the hard
/// legacy-regression gate for this item and run UNCHANGED; the nil-collapse
/// test below additionally replays the PRE-m19-b playback law in-test and
/// asserts the new engine reproduces it sample-for-sample.
@MainActor
@Suite("Sampler playback scalars (m19-b)", .serialized)
struct SamplerPlaybackTests {
    private let sampleRate = 48_000.0

    // MARK: - Fixtures (written once per run)

    private struct Fixtures {
        let dir: URL
        /// 1.0 s, 440 Hz sine, amp 0.5, 44.1 kHz, MONO.
        let sine440Mono: URL
        /// 1.0 s, 44.1 kHz MONO marker file: 22 050 frames of EXACT silence,
        /// then 22 050 frames of 440 Hz sine (amp 0.5) — the start/end-frame
        /// structure probe.
        let silenceThenTone: URL
    }

    private static var cachedFixtures: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cachedFixtures { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sampler-playback-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sine440Mono = dir.appendingPathComponent("sine440_44k1_mono.wav")
        try Self.writeMono(to: sine440Mono) { frame, fileRate in
            0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / fileRate)
        }
        let silenceThenTone = dir.appendingPathComponent("silence_then_tone_44k1_mono.wav")
        try Self.writeMono(to: silenceThenTone) { frame, fileRate in
            frame < 22_050 ? 0 : 0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / fileRate)
        }
        let set = Fixtures(dir: dir, sine440Mono: sine440Mono, silenceThenTone: silenceThenTone)
        Self.cachedFixtures = set
        return set
    }

    /// 1.0 s mono Float32 WAV at 44.1 kHz. Scoped so the AVAudioFile flushes
    /// and closes before anyone reads it.
    private static func writeMono(to url: URL,
                                  sample: (Int, Double) -> Double) throws {
        let fileRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(fileRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SamplerPlaybackTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for frame in 0..<frames {
            data[0][frame] = Float(sample(frame, fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // MARK: - Harness (the SamplerTests direct-render idiom)

    private func makeSampler(_ params: SamplerParams) -> SamplerInstrument {
        let sampler = SamplerInstrument(params: params)
        sampler.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return sampler
    }

    private func note(on: Int64, off: Int64, pitch: UInt8,
                      velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    /// Renders the instrument directly in 512-frame quanta, replicating
    /// InstrumentRenderer's slicing. Returns BOTH channels.
    private func renderDirect(
        _ instrument: SamplerInstrument,
        events unsorted: [ScheduledMIDIEvent],
        frames totalFrames: Int,
        quantum: Int = 512
    ) throws -> (left: [Float], right: [Float]) {
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
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
                instrument.render(events: slice, renderStart: Int64(rendered),
                                  frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return (left, right)
    }

    private func params(zones: [SamplerZone], oneShot: Bool = false,
                        gain: Double = 0.8) -> SamplerParams {
        SamplerParams(zones: zones, oneShot: oneShot,
                      attack: 0.001, release: 0.05, gain: gain)
    }

    // MARK: - 1. ADSR staged envelope

    @Test("per-zone ADSR: attack ramp, decay slope to the sustain plateau, release to exact zero")
    func adsrStagedEnvelope() throws {
        let fixtures = try fixtures()
        // attack 0.01 s (480 frames), decay 0.1 s (4 800 frames, time-accurate
        // 1 → sustain), sustain 0.25, release 0.05 s (2 400 frames). Fixture
        // amp 0.5 × zone gain 1 × params gain 0.8 ⇒ full-level peak 0.4,
        // plateau peak 0.4 × 0.25 = 0.1.
        let zone = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                               attack: 0.01, decay: 0.1, sustain: 0.25, release: 0.05)
        let out = try renderDirect(makeSampler(params(zones: [zone])),
                                   events: note(on: 0, off: 12_000, pitch: 69, id: 0),
                                   frames: 24_000)

        // Attack: mid-ramp is audible but well below full level.
        let midAttack = TestSignals.peak(out.left, in: 0..<240)
        // Decay: monotone slope down — early window louder than late window,
        // late window still above the plateau. (Decay spans 480...5 280.)
        let decayEarly = TestSignals.rms(out.left, in: 900..<1_500)
        let decayLate = TestSignals.rms(out.left, in: 3_000..<3_600)
        // Sustain plateau (decay done at 5 280): peak ≈ sustain × amp = 0.1;
        // 6 000..<10 800 is 4 800 frames = 44 whole cycles of 440 Hz.
        let plateauPeak = TestSignals.peak(out.left, in: 6_000..<10_800)
        let plateauRMS = TestSignals.rms(out.left, in: 6_000..<10_800)
        // Release from noteOff (12 000): tail, then EXACT zeros from
        // 14 400 + one quantum of slack (voice freed).
        let tail = TestSignals.peak(out.left, in: 12_100..<12_600)
        let silence = TestSignals.peak(out.left, in: 15_000..<24_000)
        print("[measured] ADSR — midAttack: \(midAttack), decayEarly: \(decayEarly), "
              + "decayLate: \(decayLate), plateau peak: \(plateauPeak) (expected ≈ 0.1), "
              + "plateau RMS: \(plateauRMS), tail: \(tail), silence: \(silence)")
        #expect(midAttack > 0.01)                  // ramp is sounding…
        #expect(midAttack < 0.25)                  // …but measurably below full level
        #expect(decayEarly > 1.3 * decayLate)      // decay slopes down
        #expect(decayLate > 1.5 * plateauRMS)      // …and is still above the plateau
        #expect(abs(plateauPeak - 0.1) < 0.01)     // plateau ≈ sustain × amp
        #expect(abs(Double(plateauRMS) - 0.1 / 2.0.squareRoot()) < 0.005)
        #expect(tail > 0.01)                       // release is a ramp, not a cut
        #expect(silence == 0)                      // exact zeros: voice freed
    }

    // MARK: - 2. Envelope nil-collapse (the byte gate)

    @Test("nil-field zone reproduces the pre-m19-b playback law sample-for-sample")
    func nilEnvelopeCollapsesToLegacyLaw() throws {
        let fixtures = try fixtures()
        // Replay the EXACT pre-m19-b per-frame law in-test — attack ramp to 1,
        // hold, release from noteOff, level×amp×outputGain with linear
        // interpolation — and assert the new stage machine + per-channel gain
        // path produces the identical sample sequence for a zone with every
        // m19-b field nil. Velocity 100 + zone gain 0.9 keep the amp law
        // non-trivial.
        let zone = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69, gain: 0.9)
        let out = try renderDirect(
            makeSampler(params(zones: [zone])),
            events: note(on: 0, off: 6_000, pitch: 69, velocity: 100, id: 0),
            frames: 12_000)

        let source = try TestSignals.readFile(fixtures.sine440Mono)[0]
        let frameCount = source.count
        #expect(frameCount == 44_100)
        let amp = Float(100) / 127.0 * Float(0.9)          // velocity/127 × zone.gain
        let outputGain = Float(0.8)
        let attackStep = Float(1.0 / max(1.0, 0.001 * sampleRate))
        let releaseSlope = Float(1.0 / max(1.0, 0.05 * sampleRate))
        let increment = exp2((69.0 - 69.0) / 12.0) * 44_100.0 / sampleRate
        var expected = [Float](repeating: 0, count: 12_000)
        var level: Float = 0
        var releaseFrom: Float = 0
        var releasing = false
        var alive = true
        var position = 0.0
        for frame in 0..<12_000 where alive {
            if frame == 6_000 {                            // noteOff lands here
                releasing = true
                releaseFrom = level
            }
            if releasing {
                level -= releaseFrom * releaseSlope
                if level <= 0 { alive = false; continue }
            } else if level < 1 {
                level += attackStep
                if level > 1 { level = 1 }
            }
            let idx = Int(position)
            if idx >= frameCount { alive = false; continue }
            let frac = Float(position - Double(idx))
            let s0 = source[idx]
            let s1 = idx + 1 < frameCount ? source[idx + 1] : 0
            expected[frame] = ((s0 + (s1 - s0) * frac) * (level * amp)) * outputGain
            position += increment
        }

        var firstMismatch = -1
        for frame in 0..<12_000 where out.left[frame] != expected[frame] {
            firstMismatch = frame
            break
        }
        print("[measured] nil-collapse — first mismatch frame: \(firstMismatch) "
              + "(-1 = byte-identical), peak: \(TestSignals.peak(out.left, in: 0..<12_000))")
        #expect(out.left == expected)
        #expect(out.left == out.right)                     // mono, unity pan gains
        // The null means something: steady peak ≈ 0.5 × (100/127 × 0.9) × 0.8
        // = 0.2835.
        #expect(TestSignals.peak(out.left, in: 1_200..<6_000) > 0.25)
    }

    // MARK: - 3. Pan

    @Test("pan: −1 hard left, +1 hard right, explicit 0 at the −3 dB center, nil at unity")
    func panLaws() throws {
        let fixtures = try fixtures()
        func render(pan: Double?) throws -> (left: [Float], right: [Float]) {
            let zone = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69, pan: pan)
            return try renderDirect(makeSampler(params(zones: [zone])),
                                    events: note(on: 0, off: 90_000, pitch: 69, id: 0),
                                    frames: 12_000)
        }
        let base = try render(pan: nil)
        let hardLeft = try render(pan: -1)
        let hardRight = try render(pan: 1)
        let center = try render(pan: 0)
        let window = 1_200..<6_000  // 44 whole cycles of 440 Hz

        // nil = unity dual-mono: both channels identical, full level.
        #expect(base.left == base.right)
        #expect(TestSignals.peak(base.left, in: window) > 0.3)

        // pan −1: left bit-identical to the nil render (cos(0) = 1 exactly —
        // the ×1.0 identity chain), right EXACT silence (sin(0) = 0).
        #expect(hardLeft.left == base.left)
        #expect(TestSignals.peak(hardLeft.right, in: 0..<12_000) == 0)

        // pan +1 mirrored: right bit-identical, left at −∞ish (cos(π/2) is
        // the 6e-17 Double residue, not exactly 0).
        #expect(hardRight.right == base.right)
        #expect(TestSignals.peak(hardRight.left, in: 0..<12_000) < 1e-9)

        // Explicit 0 ≠ nil: BOTH channels at the constant-power −3 dB center,
        // 0.7071× the unity render.
        let ratioL = Double(TestSignals.rms(center.left, in: window))
            / Double(TestSignals.rms(base.left, in: window))
        let ratioR = Double(TestSignals.rms(center.right, in: window))
            / Double(TestSignals.rms(base.right, in: window))
        print("[measured] pan — center/unity RMS ratios: L \(ratioL), R \(ratioR) "
              + "(expected 0.70711)")
        #expect(abs(ratioL - 0.5.squareRoot()) < 0.001)
        #expect(abs(ratioR - 0.5.squareRoot()) < 0.001)
    }

    // MARK: - 4. tuneCents

    @Test("tuneCents +1200 at the root renders bit-identically to the untuned zone one octave up")
    func tuneCentsOctaveEquivalence() throws {
        let fixtures = try fixtures()
        // Both paths compute baseIncrement = 2.0 × fileRate/graphRate exactly
        // (exp2(0)·exp2(1200/1200) vs exp2(12/12)·1.0), so the renders must
        // be bit-identical — the same math path, factor folded at trigger.
        let tuned = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                                tuneCents: 1_200)
        let untuned = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)
        let tunedOut = try renderDirect(makeSampler(params(zones: [tuned])),
                                        events: note(on: 0, off: 90_000, pitch: 69, id: 0),
                                        frames: 12_000)
        let octaveUp = try renderDirect(makeSampler(params(zones: [untuned])),
                                        events: note(on: 0, off: 90_000, pitch: 81, id: 0),
                                        frames: 12_000)
        let measured = TestSignals.dominantFrequency(
            byZeroCrossings: tunedOut.left, sampleRate: sampleRate, in: 1_200..<12_000)
        print("[measured] tuneCents +1200 — frequency: \(measured) Hz (expected 880)")
        #expect(tunedOut.left == octaveUp.left)
        #expect(tunedOut.right == octaveUp.right)
        #expect(abs(measured - 880) < 8.8)
        #expect(TestSignals.peak(tunedOut.left, in: 1_200..<12_000) > 0.3)
    }

    // MARK: - 5. startFrame / endFrame

    @Test("startFrame skips the source head; endFrame frees the voice early with true zeros")
    func startEndFrameTrims() throws {
        let fixtures = try fixtures()
        // The marker file is 22 050 frames of silence then 22 050 of tone.
        // Without startFrame, output is silent until source frame 22 050
        // (output ≈ 24 000 at the 44.1→48 k ratio); with startFrame 22 050
        // the tone sounds immediately.
        let trimmed = SamplerZone(audioFileURL: fixtures.silenceThenTone, rootPitch: 69,
                                  startFrame: 22_050)
        let untrimmed = SamplerZone(audioFileURL: fixtures.silenceThenTone, rootPitch: 69)
        let events = note(on: 0, off: 90_000, pitch: 69, id: 0)
        let skipped = try renderDirect(makeSampler(params(zones: [trimmed])),
                                       events: events, frames: 12_000)
        let full = try renderDirect(makeSampler(params(zones: [untrimmed])),
                                    events: events, frames: 26_000)
        let skippedRMS = TestSignals.rms(skipped.left, in: 1_200..<6_000)
        let fullHead = TestSignals.peak(full.left, in: 0..<23_000)
        let fullTone = TestSignals.peak(full.left, in: 24_500..<26_000)
        print("[measured] startFrame — trimmed RMS: \(skippedRMS), untrimmed head peak: "
              + "\(fullHead), untrimmed tone peak: \(fullTone)")
        #expect(skippedRMS > 0.25)          // tone from the first window
        #expect(fullHead == 0)              // source silence renders as exact zeros
        #expect(fullTone > 0.3)             // …until the marker

        // endFrame 22 050 on the plain sine: the voice frees itself at output
        // ≈ 24 000 even though the note is still held — true zeros after.
        let ended = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                                endFrame: 22_050)
        let out = try renderDirect(makeSampler(params(zones: [ended])),
                                   events: note(on: 0, off: 90_000, pitch: 69, id: 1),
                                   frames: 30_000)
        let sounding = TestSignals.peak(out.left, in: 20_000..<23_500)
        let afterEnd = TestSignals.peak(out.left, in: 24_500..<30_000)
        print("[measured] endFrame — sounding: \(sounding), after end: \(afterEnd)")
        #expect(sounding > 0.3)
        #expect(afterEnd == 0)

        // Degenerate span (start past the file end): the engine clamps to
        // the last frame and says so — the zoneLoadNotes honesty idiom.
        let degenerate = makeSampler(params(zones: [
            SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                        startFrame: 500_000),
        ]))
        print("[measured] degenerate start/end notes: \(degenerate.zoneLoadNotes)")
        #expect(degenerate.zoneLoadNotes.count == 1)
        #expect(degenerate.zoneLoadNotes[0].contains("clamped"))
    }

    // MARK: - 6. Per-zone one-shot

    @Test("zone oneShot=true ignores noteOff under a false global; zone false releases under a true global")
    func perZoneOneShotOverrides() throws {
        let fixtures = try fixtures()
        // 1.0 s file at root ⇒ ~48 000 output frames; noteOff halfway.
        let events = note(on: 0, off: 24_000, pitch: 69, id: 0)

        // Zone override ON, global OFF: plays through the off to buffer end.
        let forcedOn = try renderDirect(
            makeSampler(params(zones: [
                SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69, oneShot: true),
            ], oneShot: false)),
            events: events, frames: 52_000)
        let onPastOff = TestSignals.peak(forcedOn.left, in: 30_000..<44_000)
        let onPastEnd = TestSignals.peak(forcedOn.left, in: 48_600..<52_000)

        // Zone override OFF, global ON: releases on noteOff (release 0.05 s
        // = 2 400 frames → exact zeros from 26 400 + quantum slack).
        let forcedOff = try renderDirect(
            makeSampler(params(zones: [
                SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69, oneShot: false),
            ], oneShot: true)),
            events: events, frames: 52_000)
        let offPastRelease = TestSignals.peak(forcedOff.left, in: 27_500..<52_000)

        // Nil zone under global ON still inherits: plays to the end.
        let inherited = try renderDirect(
            makeSampler(params(zones: [
                SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69),
            ], oneShot: true)),
            events: events, frames: 52_000)
        let inheritedPastOff = TestSignals.peak(inherited.left, in: 30_000..<44_000)

        print("[measured] one-shot — zone-on past off: \(onPastOff), past end: \(onPastEnd); "
              + "zone-off past release: \(offPastRelease); inherited past off: \(inheritedPastOff)")
        #expect(onPastOff > 0.3)          // override beat the false global
        #expect(onPastEnd == 0)           // …and still frees at buffer end
        #expect(offPastRelease == 0)      // override beat the true global
        #expect(inheritedPastOff > 0.3)   // nil keeps tracking the global
    }

    // MARK: - 7. ampVelTrack

    @Test("ampVelTrack 0 makes velocity 1 and 127 render identically; nil keeps the velocity/127 law")
    func ampVelTrackDepth() throws {
        let fixtures = try fixtures()
        func render(velocity: UInt8, ampVelTrack: Double?) throws -> [Float] {
            let zone = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                                   ampVelTrack: ampVelTrack)
            return try renderDirect(
                makeSampler(params(zones: [zone])),
                events: note(on: 0, off: 90_000, pitch: 69, velocity: velocity, id: 0),
                frames: 12_000).left
        }
        // vt = 0: velocity vanishes from the amp law entirely.
        let soft = try render(velocity: 1, ampVelTrack: 0)
        let hard = try render(velocity: 127, ampVelTrack: 0)
        #expect(soft == hard)
        #expect(TestSignals.peak(soft, in: 1_200..<6_000) > 0.3)  // at FULL level

        // vt nil: today's velocity/127 law — RMS scales as 100/127.
        let window = 1_200..<6_000
        let nil100 = try render(velocity: 100, ampVelTrack: nil)
        let nil127 = try render(velocity: 127, ampVelTrack: nil)
        let ratio = Double(TestSignals.rms(nil100, in: window))
            / Double(TestSignals.rms(nil127, in: window))
        print("[measured] ampVelTrack — nil vel-100/vel-127 RMS ratio: \(ratio) "
              + "(expected \(100.0 / 127.0))")
        #expect(abs(ratio - 100.0 / 127.0) < 0.01)
    }

    // MARK: - 8. Zone gain 2.0 (A5)

    @Test("zone gain reaches 2.0 and renders +6 dB over gain 1.0")
    func zoneGainTwoRendersPlus6dB() throws {
        let fixtures = try fixtures()
        // Model: the A5 relax admits 2.0 and clamps above it.
        #expect(SamplerZone(audioFileURL: fixtures.sine440Mono, gain: 2.0).gain == 2.0)
        #expect(SamplerZone(audioFileURL: fixtures.sine440Mono, gain: 2.5).gain == 2.0)
        #expect(SamplerZone(audioFileURL: fixtures.sine440Mono, gain: -1).gain == 0)

        func render(zoneGain: Double) throws -> [Float] {
            let zone = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                                   gain: zoneGain)
            // params gain 0.4 keeps the boosted render inside ±1.
            return try renderDirect(makeSampler(params(zones: [zone], gain: 0.4)),
                                    events: note(on: 0, off: 90_000, pitch: 69, id: 0),
                                    frames: 12_000).left
        }
        let window = 1_200..<6_000
        let unity = try render(zoneGain: 1.0)
        let boosted = try render(zoneGain: 2.0)
        let ratio = Double(TestSignals.rms(boosted, in: window))
            / Double(TestSignals.rms(unity, in: window))
        print("[measured] zone gain 2.0 — RMS ratio: \(ratio) (expected 2)")
        #expect(abs(ratio - 2.0) < 0.02)
        #expect(TestSignals.peak(boosted, in: window) < 1.0)  // headroom held
    }

    // MARK: - 9. Codable + clamping

    @Test("legacy zone JSON decodes the ten m19-b fields as nil and encodes none of them")
    func legacyJSONDecodesAllNil() throws {
        let legacy = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/kick.wav"),
                                 rootPitch: 36, minPitch: 35, maxPitch: 38, gain: 0.9)
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let newKeys = ["tuneCents", "pan", "ampVelTrack", "oneShot", "startFrame",
                       "endFrame", "attack", "decay", "sustain", "release"]
        print("[measured] legacy zone JSON keys: \(json.keys.sorted())")
        for key in newKeys {
            #expect(json[key] == nil, "legacy zone must not encode '\(key)'")
        }

        let decoded = try JSONDecoder().decode(SamplerZone.self, from: data)
        #expect(decoded == legacy)
        #expect(decoded.tuneCents == nil)
        #expect(decoded.pan == nil)
        #expect(decoded.ampVelTrack == nil)
        #expect(decoded.oneShot == nil)
        #expect(decoded.startFrame == nil)
        #expect(decoded.endFrame == nil)
        #expect(decoded.attack == nil)
        #expect(decoded.decay == nil)
        #expect(decoded.sustain == nil)
        #expect(decoded.release == nil)
    }

    @Test("m19-b fields clamp per their documented ranges and round-trip through Codable")
    func playbackFieldClampingAndRoundTrip() throws {
        // Out-of-range inputs clamp: tune ±4800, pan ±1, vt 0...1, start ≥ 0,
        // end > start (raised, not swapped), attack 0...1, decay 0...8 (NO
        // 0.001 floor — present-0 equals the nil default and stays legal),
        // sustain 0...1, release 0.001...8.
        let clamped = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                  tuneCents: 9_600, pan: -3, ampVelTrack: 1.5,
                                  oneShot: false, startFrame: -5, endFrame: -10,
                                  attack: 5, decay: 9, sustain: -0.5, release: 0)
        #expect(clamped.tuneCents == 4_800)
        #expect(clamped.pan == -1)
        #expect(clamped.ampVelTrack == 1)
        #expect(clamped.oneShot == false)       // present false ≠ nil (inherit)
        #expect(clamped.startFrame == 0)
        #expect(clamped.endFrame == 1)          // raised above start, not swapped
        #expect(clamped.attack == 1)
        #expect(clamped.decay == 8)
        #expect(clamped.sustain == 0)
        #expect(clamped.release == 0.001)

        let raised = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                 startFrame: 10, endFrame: 3)
        #expect(raised.startFrame == 10)
        #expect(raised.endFrame == 11)

        // Present-0 decay is legal and preserved (it equals the nil default).
        let zeroDecay = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                    tuneCents: -9_600, pan: 2, decay: 0)
        #expect(zeroDecay.decay == 0)
        #expect(zeroDecay.tuneCents == -4_800)
        #expect(zeroDecay.pan == 1)

        let configured = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/hat.wav"),
                                     tuneCents: -150, pan: 0.5, ampVelTrack: 0.25,
                                     oneShot: true, startFrame: 100, endFrame: 2_000,
                                     attack: 0.01, decay: 0.5, sustain: 0.6, release: 0.2)
        let decoded = try JSONDecoder().decode(
            SamplerZone.self, from: JSONEncoder().encode(configured))
        #expect(decoded == configured)
        #expect(decoded.tuneCents == -150)
        #expect(decoded.pan == 0.5)
        #expect(decoded.ampVelTrack == 0.25)
        #expect(decoded.oneShot == true)
        #expect(decoded.startFrame == 100)
        #expect(decoded.endFrame == 2_000)
        #expect(decoded.attack == 0.01)
        #expect(decoded.decay == 0.5)
        #expect(decoded.sustain == 0.6)
        #expect(decoded.release == 0.2)
    }
}
