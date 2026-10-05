import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m34-q — THE PEDAL HOLD LIMIT: a cap on how many notes the CC 64 sustain
// pedal keeps ringing, with the OLDEST RELEASED (not cut) when the cap is
// exceeded.
//
// ══ THE ASK, VERBATIM ═══════════════════════════════════════════════════════
// "can we then specify how many notes to hold and fade the oldest ones?"
//
// Asked about an organ patch, which correctly holds forever under the pedal
// (m34-o). This is a HOLD limit, not a polyphony override: it decides WHEN a
// pedal-held note starts releasing, and the instrument's own envelope still
// decides WHAT that release sounds like.
//
// ⛔ THE ONE CORRECTNESS CONSTRAINT: only a voice with `sustained == true` may
// ever be evicted. A voice with `sustained == false` has its key physically
// down, and cutting it would silence a note under the player's finger.
// `heldKeysAreNeverEvicted*` is the gate for that, on both instruments.
//
// ⭐ EVERY GATE HERE MEASURES RENDERED AUDIO — a golden hash of the samples, a
// Goertzel bin, or a sample-to-sample slope. None reads a voice array back off
// the instrument. A test that asserts `voices[3].sustained == false` cannot
// tell you the note stopped.
//
// ⚠️ EXTENSIONS on `SamplerTests` / `PolySynthTests`, not new `@Suite`s — the
// `MainActorOccupancySiteTests` cap on @MainActor-isolated suites is 330 and
// the tree sits exactly on it (m23-aw-4), the reason
// `SamplerBendRangeVoiceModeTests` and `SamplerGlobalEnvelopeTests` record for
// doing the same. Helpers are file-local free functions: a different file
// cannot see either suite's `private` ones.

// MARK: - File-local harness

/// FNV-1a 64 over the raw IEEE bit patterns of every sample, left then right.
/// Bit patterns, not values: `==` on Float says 0.0 == -0.0 and says nothing at
/// all about NaN, and BYTE-identity is the claim being made.
private func pedalHash(_ left: [Float], _ right: [Float]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    func feed(_ bits: UInt32) {
        var shift = 0
        while shift < 32 {
            hash ^= UInt64((bits >> UInt32(shift)) & 0xFF)
            hash &*= 0x1000_0000_01B3
            shift += 8
        }
    }
    for sample in left { feed(sample.bitPattern) }
    for sample in right { feed(sample.bitPattern) }
    return hash
}

/// A Float32 WAV at 44.1 kHz, amp 0.5, mono, written from a closed-form
/// expression so the fixture is bit-reproducible run to run — which is what
/// lets a golden hash mean anything.
private func writePedalSineFixture(to url: URL, frequency: Double, seconds: Double) throws {
    let fileRate = 44_100.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: fileRate,
        AVNumberOfChannelsKey: UInt32(1),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int(fileRate * seconds)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate,
                                     channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(frames)),
          let data = buffer.floatChannelData else {
        throw NSError(domain: "PedalHoldLimitTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
    }
    for frame in 0..<frames {
        data[0][frame] = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

private enum PedalFixture {
    nonisolated(unsafe) private static var cached: URL?

    /// 8 seconds — every scenario below holds notes for several seconds under
    /// the pedal, and a short fixture would run OUT OF SAMPLE MATERIAL and fall
    /// silent on its own. Every "the note stopped" gate would then pass for the
    /// wrong reason.
    static func url() throws -> URL {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m34q-pedal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sine440_44k1_mono_8s.wav")
        try writePedalSineFixture(to: url, frequency: 440, seconds: 8)
        cached = url
        return url
    }
}

private func pedalEvent(at sampleTime: Int64, down: Bool) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: 0,
                       kind: ScheduledMIDIEvent.controlChange,
                       pitch: 64, velocity: down ? 127 : 0)
}

private func pedalNote(on: Int64, off: Int64, pitch: UInt8,
                       velocity: UInt8 = 100, id: UInt64) -> [ScheduledMIDIEvent] {
    [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                        kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
     ScheduledMIDIEvent(sampleTime: off, noteID: id,
                        kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
}

/// Renders any built-in instrument directly in 512-frame quanta, replicating
/// `InstrumentRenderer`'s slicing. Generic over `InstrumentRendering` on
/// purpose: the sampler and the poly synth must be driven by the SAME harness,
/// or a difference between the two gates could be the harness rather than the
/// instrument.
private func renderPedalQuanta(_ instrument: some InstrumentRendering,
                               events unsorted: [ScheduledMIDIEvent],
                               frames totalFrames: Int,
                               sampleRate: Double = 48_000,
                               quantum: Int = 512) throws -> (left: [Float], right: [Float]) {
    // THE SCHEDULE'S OWN ORDER (MIDISchedule's kindRank): at one sample time a
    // note-OFF sorts before a note-on, so two abutting notes behave here as
    // they do through the real schedule.
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

// MARK: - The shared scenarios

/// THE BYTE-IDENTITY SCENARIO, one event list driving both instruments.
///
/// It exercises every path the feature touches: the pedal goes DOWN first, five
/// notes are struck and their keys RELEASED under it (so all five become
/// pedal-held), and the pedal comes UP near the end so the sweep runs and every
/// voice releases through the envelope. If the enforcement branch leaked into
/// any of those, the hash moves.
private let pedalByteIdentityPitches: [UInt8] = [60, 64, 67, 72, 76]

private func pedalByteIdentityEvents() -> [ScheduledMIDIEvent] {
    var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
    // Odd offsets on purpose, so events land MID-quantum rather than only on
    // 512-frame boundaries.
    for (index, pitch) in pedalByteIdentityPitches.enumerated() {
        let on = Int64(1_300 + index * 7_100)
        events += pedalNote(on: on, off: on + 2_900, pitch: pitch, id: UInt64(index + 1))
    }
    events.append(pedalEvent(at: 61_500, down: false))
    return events
}

private func pedalSamplerParams(_ fixture: URL) -> SamplerParams {
    // gain 0.4, not the 0.8 the other sampler suites use: five sine voices
    // sounding together peak at 1.43 with 0.8, and a scenario that clips is a
    // bad place to measure a sample-to-sample slope.
    SamplerParams(zones: [SamplerZone(audioFileURL: fixture, rootPitch: 69)],
                  attack: 0.005, release: 0.4, gain: 0.4)
}

private func makePedalSampler(_ params: SamplerParams) -> SamplerInstrument {
    // A FIXED seed: the m19-a selection RNG is drawn once per note-on even when
    // no zone gates on it, and a golden hash may not depend on the clock.
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    return sampler
}

private func pedalSynthParams() -> PolySynthParams {
    PolySynthParams(waveform: .saw, attack: 0.005, decay: 0.08, sustain: 0.7,
                    release: 0.4, cutoffHz: 8_000, resonance: 0.1, gain: 0.8)
}

/// The MEASUREMENT synth: a SINE, so every Goertzel bin below reads one note
/// and only that note. A saw's harmonic series would put pitch 60's second
/// partial straight into another note's bin, and "did this note stop?" would
/// stop being answerable. The byte-identity gate deliberately uses the default
/// saw instead, so the shipped waveform is the one pinned for bit-compatibility.
private func pedalMeasurementSynthParams() -> PolySynthParams {
    PolySynthParams(waveform: .sine, attack: 0.005, decay: 0.08, sustain: 0.7,
                    release: 0.4, cutoffHz: 18_000, resonance: 0, gain: 0.8)
}

private func makePedalSynth(_ params: PolySynthParams) -> PolySynthInstrument {
    let synth = PolySynthInstrument(params: params)
    synth.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    return synth
}

/// The frames every byte-identity render covers: 1.75 s, so the pedal-up sweep
/// at frame 61 500 (1.281 s) is followed by the whole 0.4 s release tail.
private let pedalByteIdentityFrames = 84_000

// MARK: - 1. BYTE IDENTITY AT THE DEFAULT (the load-bearing gates)

extension SamplerTests {

    /// ⛔ THE GATE THE WHOLE CHANGE TURNS ON, sampler half. The hold limit adds
    /// an enforcement branch to the note-on path of an instrument every project
    /// on disk already uses. If that branch perturbs so much as one mantissa
    /// bit with the field UNSET, every sampler project renders differently on
    /// load, in a way no ear would catch and no other test in this tree would
    /// either.
    ///
    /// The constant below was CAPTURED FROM THE TREE BEFORE A LINE OF THE
    /// FEATURE WAS WRITTEN, and confirmed identical on two consecutive runs
    /// first. That ordering is the whole method: a hash taken after the edit
    /// would be measuring the change against itself.
    @Test("m34-q byte-identical: a pedal passage with NO hold limit renders exactly as it did before")
    func defaultPedalHoldIsByteIdenticalSampler() throws {
        let fixture = try PedalFixture.url()
        // Built through the ordinary path with no mention of the new field —
        // this is a pre-existing project, not one opting back into old
        // behaviour.
        let params = pedalSamplerParams(fixture)
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: pedalByteIdentityEvents(),
                                        frames: pedalByteIdentityFrames)
        let hash = pedalHash(out.left, out.right)
        let peak = TestSignals.peak(out.left, in: 0..<out.left.count)
        print("[measured] sampler default-pedal render: fnv1a="
              + "0x\(String(hash, radix: 16, uppercase: true)) frames=\(out.left.count) "
              + "peak=\(peak) s40000=\(out.left[40_000]) s70000=\(out.left[70_000])")

        // A CONTROL ON THE HASH ITSELF: one that cannot see a one-bit change
        // would pass this test forever.
        var perturbed = out.left
        perturbed[40_000] = Float(bitPattern: perturbed[40_000].bitPattern ^ 1)
        #expect(pedalHash(perturbed, out.right) != hash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(hash == 0xFAB8_D688_EDA0_D601,
                """
                the sampler no longer renders a pedal passage byte-identically to the \
                pre-m34-q engine — every project already on disk just moved
                """)
        // Corroborating instruments, so a mismatch arrives with a
        // human-readable direction instead of only "the number differs".
        #expect(out.left.count == pedalByteIdentityFrames)
        #expect(out.left == out.right)  // mono source, both channels
        #expect(abs(peak - 0.71471244) < 1e-7)
        #expect(out.left[40_000] == -0.08817689)
        #expect(out.left[70_000] == -0.0050515397)
    }
}

extension PolySynthTests {

    /// ⛔ THE GATE THE WHOLE CHANGE TURNS ON, poly-synth half — and the FIRST
    /// golden-hash gate this instrument has had. Same method and same reason as
    /// the sampler's above; the poly synth is the DEFAULT instrument on a fresh
    /// instrument track, so its render is what most existing projects are made
    /// of.
    @Test("m34-q byte-identical: a pedal passage with NO hold limit renders exactly as it did before")
    func defaultPedalHoldIsByteIdenticalPolySynth() throws {
        let params = pedalSynthParams()
        let out = try renderPedalQuanta(makePedalSynth(params),
                                        events: pedalByteIdentityEvents(),
                                        frames: pedalByteIdentityFrames)
        let hash = pedalHash(out.left, out.right)
        let peak = TestSignals.peak(out.left, in: 0..<out.left.count)
        print("[measured] polysynth default-pedal render: fnv1a="
              + "0x\(String(hash, radix: 16, uppercase: true)) frames=\(out.left.count) "
              + "peak=\(peak) s40000=\(out.left[40_000]) s70000=\(out.left[70_000])")

        var perturbed = out.left
        perturbed[40_000] = Float(bitPattern: perturbed[40_000].bitPattern ^ 1)
        #expect(pedalHash(perturbed, out.right) != hash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(hash == 0xBB9B_E655_75BF_7435,
                """
                the poly synth no longer renders a pedal passage byte-identically to the \
                pre-m34-q engine — every project already on disk just moved
                """)
        #expect(out.left.count == pedalByteIdentityFrames)
        #expect(out.left == out.right)  // the synth is stereo-identical by design
        #expect(abs(peak - 0.52378464) < 1e-7)
        #expect(out.left[40_000] == 0.06270236)
        #expect(out.left[70_000] == -0.1345529)
    }
}

// MARK: - Measurement helpers for the behaviour gates

/// Goertzel magnitude at exactly `hz`, HANN-WINDOWED. Absolute scale is
/// arbitrary; only ratios between bins of the SAME window are ever compared.
///
/// ⚠️ THE WINDOW IS LOAD-BEARING, and it was added after a measurement, not on
/// principle. A rectangular window's sidelobes fall off as 1/Δ: on the layered
/// scenario below, a note sounding at 415.3 Hz leaked 2.2 % of its magnitude
/// into the 392.0 Hz bin of a note that had genuinely stopped, which is
/// indistinguishable from a note that never did. Hann's sidelobes fall off far
/// faster, so a bin near zero here means the frequency is ABSENT rather than
/// merely 30 dB down.
private func pedalGoertzel(_ samples: ArraySlice<Float>, hz: Double,
                           sampleRate: Double = 48_000) -> Double {
    let count = samples.count
    guard count > 1 else { return 0 }
    let w = 2.0 * Double.pi * hz / sampleRate
    let coeff = 2.0 * cos(w)
    let windowStep = 2.0 * Double.pi / Double(count - 1)
    var s1 = 0.0
    var s2 = 0.0
    for (index, x) in samples.enumerated() {
        let window = 0.5 - 0.5 * cos(windowStep * Double(index))
        let s0 = Double(x) * window + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return max(0, power).squareRoot() / Double(count)
}

/// Equal-temperament frequency of a MIDI pitch, optionally detuned — the same
/// arithmetic both instruments do (the sampler's fixture roots at 69, so a zone
/// with no `tuneCents` sounds exactly this).
private func pedalHz(_ pitch: Int, cents: Double = 0) -> Double {
    440.0 * exp2((Double(pitch) - 69.0) / 12.0) * exp2(cents / 1200.0)
}

/// One Goertzel bin per named frequency over one window, printed as measured.
/// Every "this note stopped / that note did not" claim below is made on THESE
/// numbers, never on a voice array.
private func pedalBins(_ samples: [Float], window: Range<Int>,
                       frequencies: [Double], label: String) -> [Double] {
    let bins = frequencies.map { pedalGoertzel(samples[window], hz: $0) }
    print("[measured] \(label): "
          + zip(frequencies, bins)
              .map { "\(String(format: "%.1f", $0.0))Hz=\(String(format: "%.6f", $0.1))" }
              .joined(separator: "  "))
    return bins
}

/// Largest single-sample step in a window — the instrument that tells a RELEASE
/// from a CUT. Deliberately relative: the fixture's own slope is the baseline,
/// and an absolute epsilon would encode the amplitude of one scenario.
private func pedalMaxStep(_ samples: [Float], _ window: Range<Int>) -> Float {
    var worst: Float = 0
    for i in window.lowerBound..<(window.upperBound - 1) {
        worst = max(worst, abs(samples[i + 1] - samples[i]))
    }
    return worst
}

private func pedalPeak(_ samples: [Float], _ window: Range<Int>) -> Float {
    var peak: Float = 0
    for i in window { peak = max(peak, abs(samples[i])) }
    return peak
}

// MARK: - The behaviour scenarios (shared by both instruments)

/// FOUR notes, each struck and its key RELEASED under a held pedal, so all four
/// try to accumulate as pedal-held. With a cap of 2 the first two must be gone
/// by the measurement window and the last two must still be ringing — which is
/// serial order asserted twice over, since evicting "some" voice rather than
/// the oldest would leave a different pair.
private let pedalFourPitches = [60, 63, 68, 70]

private func pedalFourNoteEvents() -> [ScheduledMIDIEvent] {
    var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
    let ons: [Int64] = [1_000, 8_000, 15_000, 22_000]
    for (index, pitch) in pedalFourPitches.enumerated() {
        events += pedalNote(on: ons[index], off: ons[index] + 3_000,
                            pitch: UInt8(pitch), id: UInt64(index + 1))
    }
    return events
}

/// THREE KEYS PHYSICALLY DOWN for the whole render (no note-off is ever sent
/// for them), then three more notes played and released under the pedal.
/// `pedalHeldTrio` must be untouchable at any cap; `pedalPlayedTrio`'s oldest
/// is the only thing a cap of 2 may take.
private let pedalHeldTrio = [60, 63, 68]
private let pedalPlayedTrio = [70, 73, 77]

private func pedalHeldKeysEvents() -> [ScheduledMIDIEvent] {
    var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
    let holdOns: [Int64] = [1_000, 2_500, 4_000]
    for (index, pitch) in pedalHeldTrio.enumerated() {
        // NOTE-ON ONLY. No note-off anywhere in the list, so these three voices
        // never mark `sustained` and are structurally out of the cap's reach.
        events.append(ScheduledMIDIEvent(sampleTime: holdOns[index], noteID: UInt64(100 + index),
                                         kind: ScheduledMIDIEvent.noteOn,
                                         pitch: UInt8(pitch), velocity: 100))
    }
    let playOns: [Int64] = [20_000, 28_000, 36_000]
    for (index, pitch) in pedalPlayedTrio.enumerated() {
        events += pedalNote(on: playOns[index], off: playOns[index] + 3_000,
                            pitch: UInt8(pitch), id: UInt64(200 + index))
    }
    return events
}

/// The window every four-note / held-key claim is read in: 1.46 s – 2.08 s,
/// which is past the 0.4 s release of anything evicted at 36 000 frames and
/// still inside the 8 s fixture.
private let pedalMeasureWindow = 70_000..<100_000
private let pedalMeasureFrames = 120_000

// MARK: - 2. The cap evicts the OLDEST pedal-held note

extension SamplerTests {

    /// Four notes released under the pedal, cap 2. The two OLDEST must be gone
    /// and the two newest still ringing — asserted on Goertzel bins of the
    /// rendered audio, one per note, so "gone" means the frequency is not there
    /// rather than a flag being false.
    ///
    /// The uncapped CONTROL in the same test is what makes it falsifiable: the
    /// identical event list with no cap leaves all four bins strong, so a green
    /// result cannot come from a scenario that was silent anyway.
    @Test("m34-q sampler: a cap of 2 leaves the two NEWEST pedal-held notes and releases the two oldest")
    func capEvictsTheOldestSustainedNoteSampler() throws {
        let fixture = try PedalFixture.url()
        let frequencies = pedalFourPitches.map { pedalHz($0) }
        let events = pedalFourNoteEvents()

        var uncapped = pedalSamplerParams(fixture)
        uncapped.pedalHoldLimit = nil
        let control = try renderPedalQuanta(makePedalSampler(uncapped),
                                            events: events, frames: pedalMeasureFrames)
        let controlBins = pedalBins(control.left, window: pedalMeasureWindow,
                                    frequencies: frequencies, label: "sampler no cap")
        for (index, bin) in controlBins.enumerated() {
            #expect(bin > 0.01,
                    "without a cap all four notes must still ring — pitch \(pedalFourPitches[index]) did not")
        }

        var capped = pedalSamplerParams(fixture)
        capped.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSampler(capped),
                                        events: events, frames: pedalMeasureFrames)
        let bins = pedalBins(out.left, window: pedalMeasureWindow,
                             frequencies: frequencies, label: "sampler cap 2")
        let survivors = min(bins[2], bins[3])
        #expect(survivors > 0.01, "the two NEWEST notes must still be ringing")
        #expect(bins[0] < 0.02 * survivors,
                "the OLDEST note (pitch 60) is still sounding: \(bins[0]) vs \(survivors)")
        #expect(bins[1] < 0.02 * survivors,
                "the second-oldest note (pitch 63) is still sounding: \(bins[1]) vs \(survivors)")
    }

    /// ⭐⭐ THE CONSTRAINT MOST LIKELY TO BE GOT WRONG. Three keys are physically
    /// DOWN — no note-off is ever sent for them — while three more notes are
    /// played and released under a pedal capped at 2. The three held notes must
    /// ALL still be sounding: a voice with `sustained == false` has a finger on
    /// it, and evicting one would cut a note under the player's hand.
    @Test("m34-q sampler: three physically-held keys survive a cap of 2 untouched")
    func heldKeysAreNeverEvictedSampler() throws {
        let fixture = try PedalFixture.url()
        var params = pedalSamplerParams(fixture)
        params.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: pedalHeldKeysEvents(),
                                        frames: pedalMeasureFrames)
        let heldBins = pedalBins(out.left, window: pedalMeasureWindow,
                                 frequencies: pedalHeldTrio.map { pedalHz($0) },
                                 label: "sampler cap 2 — KEYS DOWN")
        let playedBins = pedalBins(out.left, window: pedalMeasureWindow,
                                   frequencies: pedalPlayedTrio.map { pedalHz($0) },
                                   label: "sampler cap 2 — keys released")
        for (index, bin) in heldBins.enumerated() {
            #expect(bin > 0.01,
                    "pitch \(pedalHeldTrio[index]) had its KEY DOWN and was evicted anyway")
        }
        // And the cap did do its job among the pedal-held three: the oldest of
        // those (and only it) is gone. Without this the test above would pass
        // on an engine where the cap never fired at all.
        let playedSurvivors = min(playedBins[1], playedBins[2])
        #expect(playedSurvivors > 0.01, "the two newest RELEASED notes must still ring")
        #expect(playedBins[0] < 0.02 * playedSurvivors,
                "the oldest PEDAL-HELD note should have been released: \(playedBins[0])")
    }
}

extension PolySynthTests {

    @Test("m34-q poly synth: a cap of 2 leaves the two NEWEST pedal-held notes and releases the two oldest")
    func capEvictsTheOldestSustainedNotePolySynth() throws {
        let frequencies = pedalFourPitches.map { pedalHz($0) }
        let events = pedalFourNoteEvents()
        // SINE, not the default saw: every claim here is a Goertzel bin at a
        // fundamental, and a saw's harmonic series would put one note's energy
        // in another note's bin. The byte-identity gate above uses the default
        // saw, so the shipped waveform is still covered.
        var uncapped = pedalMeasurementSynthParams()
        uncapped.pedalHoldLimit = nil
        let control = try renderPedalQuanta(makePedalSynth(uncapped),
                                            events: events, frames: pedalMeasureFrames)
        let controlBins = pedalBins(control.left, window: pedalMeasureWindow,
                                    frequencies: frequencies, label: "polysynth no cap")
        for (index, bin) in controlBins.enumerated() {
            #expect(bin > 0.005,
                    "without a cap all four notes must still ring — pitch \(pedalFourPitches[index]) did not")
        }

        var capped = pedalMeasurementSynthParams()
        capped.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSynth(capped),
                                        events: events, frames: pedalMeasureFrames)
        let bins = pedalBins(out.left, window: pedalMeasureWindow,
                             frequencies: frequencies, label: "polysynth cap 2")
        let survivors = min(bins[2], bins[3])
        #expect(survivors > 0.005, "the two NEWEST notes must still be ringing")
        #expect(bins[0] < 0.02 * survivors,
                "the OLDEST note (pitch 60) is still sounding: \(bins[0]) vs \(survivors)")
        #expect(bins[1] < 0.02 * survivors,
                "the second-oldest note (pitch 63) is still sounding: \(bins[1]) vs \(survivors)")
    }

    /// ⭐⭐ The poly synth's half of the held-key constraint. See the sampler's
    /// twin for why this is the gate that matters most.
    @Test("m34-q poly synth: three physically-held keys survive a cap of 2 untouched")
    func heldKeysAreNeverEvictedPolySynth() throws {
        var params = pedalMeasurementSynthParams()
        params.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSynth(params),
                                        events: pedalHeldKeysEvents(),
                                        frames: pedalMeasureFrames)
        let heldBins = pedalBins(out.left, window: pedalMeasureWindow,
                                 frequencies: pedalHeldTrio.map { pedalHz($0) },
                                 label: "polysynth cap 2 — KEYS DOWN")
        let playedBins = pedalBins(out.left, window: pedalMeasureWindow,
                                   frequencies: pedalPlayedTrio.map { pedalHz($0) },
                                   label: "polysynth cap 2 — keys released")
        for (index, bin) in heldBins.enumerated() {
            #expect(bin > 0.005,
                    "pitch \(pedalHeldTrio[index]) had its KEY DOWN and was evicted anyway")
        }
        let playedSurvivors = min(playedBins[1], playedBins[2])
        #expect(playedSurvivors > 0.005, "the two newest RELEASED notes must still ring")
        #expect(playedBins[0] < 0.02 * playedSurvivors,
                "the oldest PEDAL-HELD note should have been released: \(playedBins[0])")
    }
}

// MARK: - 3. The evicted note RELEASES — it does not cut

/// ONE loud note held by the pedal, then a second note struck at velocity 1
/// (≈0.8 % of the first's amplitude, so it contributes essentially nothing to
/// the waveform) whose only job is to trip a cap of 1. Everything measured
/// afterwards is the FIRST note's release.
private let pedalEvictionFrame = 24_000
private let pedalCutFrames = 60_000

private func pedalEvictionEvents() -> [ScheduledMIDIEvent] {
    var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
    events += pedalNote(on: 0, off: 4_800, pitch: 69, velocity: 127, id: 1)
    events += pedalNote(on: Int64(pedalEvictionFrame), off: 28_000,
                        pitch: 76, velocity: 1, id: 2)
    return events
}

/// The whole release/cut measurement, in one place so both instruments make
/// EXACTLY the same claim. Returns nothing; it records its own expectations,
/// including a SELF-POSITIVE-CONTROL that splices a hard cut into the very same
/// samples and requires the same arithmetic to catch it.
private func expectEvictionReleases(_ samples: [Float], label: String) {
    let before = pedalEvictionFrame - 2_000..<pedalEvictionFrame
    // STARTS ONE FRAME EARLY, and that off-by-one IS the measurement: a cut
    // shows up as the step from the last pre-eviction sample to the first
    // post-eviction one. A window starting exactly at the eviction frame cannot
    // see that step at all — the self-positive-control below caught this, having
    // read 0.0 for a render that had been hard-zeroed.
    let after = pedalEvictionFrame - 1..<pedalEvictionFrame + 2_000
    let stepBefore = pedalMaxStep(samples, before)
    let stepAfter = pedalMaxStep(samples, after)
    // Peaks across the release, so "it faded" is a CURVE and not merely "it
    // eventually stopped". 0.4 s release from frame 24 000 lands at 43 200.
    let peaks = [25_000, 30_000, 35_000, 40_000, 46_000].map {
        pedalPeak(samples, $0..<($0 + 1_000))
    }
    print("[measured] \(label): maxStep before=\(stepBefore) after=\(stepAfter) "
          + "peaks=\(peaks.map { String(format: "%.5f", $0) }.joined(separator: " "))")

    // ⭐ THE CUT/RELEASE DISCRIMINATOR, stated relatively: the biggest
    // sample-to-sample step across the eviction boundary must stay in the same
    // league as the waveform's own slope a moment earlier. An absolute epsilon
    // would encode this scenario's amplitude and nothing else.
    #expect(stepAfter < 2.0 * stepBefore,
            """
            \(label): the level JUMPED at the eviction — that is a cut, not a release \
            (\(stepAfter) vs \(stepBefore))
            """)

    // SELF-POSITIVE-CONTROL: hard-cut the same render and require the same
    // comparison to go red. Without it, a scenario where the note was already
    // silent would pass the assertion above forever.
    //
    // ⚠️ THE CUT IS PLACED AT THE WORST PHASE WITHIN ONE CYCLE of the boundary,
    // and that detail was earned: the first version of this control zeroed at
    // the eviction frame exactly, the waveform happened to be near a zero
    // crossing there, and the "hard cut" it planted produced a step no larger
    // than the ordinary slope — a positive control that could not fire. A real
    // cut lands at whatever phase it lands at; the probe has to catch the ones
    // that land badly, because those are the audible ones.
    var cutIndex = pedalEvictionFrame - 1
    for i in (pedalEvictionFrame - 120)..<pedalEvictionFrame
    where abs(samples[i]) > abs(samples[cutIndex]) { cutIndex = i }
    var cut = samples
    for i in (cutIndex + 1)..<cut.count { cut[i] = 0 }
    let cutStep = pedalMaxStep(cut, cutIndex..<(cutIndex + 3))
    print("[measured] \(label): planted cut at \(cutIndex) |x|=\(abs(samples[cutIndex])) "
          + "→ step \(cutStep)")
    #expect(cutStep >= 2.0 * stepBefore,
            "\(label): the discontinuity probe cannot even see a HARD CUT — it proves nothing")

    // And it really did fade, monotonically, to nothing.
    for i in 1..<peaks.count {
        #expect(peaks[i] < peaks[i - 1],
                "\(label): the release is not monotonic at window \(i)")
    }
    #expect(peaks[0] > 0.02, "\(label): the note must be loud before it is released")
    #expect(peaks[4] < 0.02 * peaks[0],
            "\(label): the released note never reached the floor: \(peaks[4]) vs \(peaks[0])")
}

extension SamplerTests {

    @Test("m34-q sampler: an evicted note RAMPS to silence through the patch's release — no cut")
    func evictedNoteReleasesRatherThanCutsSampler() throws {
        let fixture = try PedalFixture.url()
        var params = pedalSamplerParams(fixture)
        params.pedalHoldLimit = 1
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: pedalEvictionEvents(), frames: pedalCutFrames)
        expectEvictionReleases(out.left, label: "sampler cap 1 eviction")
    }

    /// A cap ABOVE the voice pool is unlimited, asserted in the strongest form
    /// available: the SAME golden hash the unset default produces. Anything
    /// weaker would let "128 nearly does nothing" pass.
    @Test("m34-q sampler: a cap larger than the voice pool renders identically to no cap at all")
    func capAboveVoicePoolIsUnlimitedSampler() throws {
        let fixture = try PedalFixture.url()
        var params = pedalSamplerParams(fixture)
        params.pedalHoldLimit = 128
        #expect(params.pedalHoldLimit == 128, "the clamp must not have eaten the value")
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: pedalByteIdentityEvents(),
                                        frames: pedalByteIdentityFrames)
        let hash = pedalHash(out.left, out.right)
        print("[measured] sampler cap 128: fnv1a=0x\(String(hash, radix: 16, uppercase: true))")
        #expect(hash == 0xFAB8_D688_EDA0_D601,
                "a cap of 128 changed the render — it is above the 64-voice pool and cannot bind")
    }

    /// Pedal-up must still deliver every deferred note-off with a cap set. The
    /// control is the same render WITHOUT the pedal-up event, which must still
    /// be ringing in the same window — otherwise "silent at the end" would be
    /// a fixture that simply ran out.
    @Test("m34-q sampler: pedal-up still releases everything when a cap is set")
    func pedalUpStillWorksWithACapSetSampler() throws {
        let fixture = try PedalFixture.url()
        var params = pedalSamplerParams(fixture)
        params.pedalHoldLimit = 2
        var lifted = pedalFourNoteEvents()
        lifted.append(pedalEvent(at: 60_000, down: false))
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: lifted, frames: 90_000)
        let held = try renderPedalQuanta(makePedalSampler(params),
                                         events: pedalFourNoteEvents(), frames: 90_000)
        let before = pedalPeak(out.left, 50_000..<59_000)
        let after = pedalPeak(out.left, 80_000..<90_000)
        let controlAfter = pedalPeak(held.left, 80_000..<90_000)
        print("[measured] sampler cap 2 pedal-up: before=\(before) after=\(after) "
              + "no-pedal-up-control=\(controlAfter)")
        #expect(before > 0.02, "the capped notes must be sounding before the pedal comes up")
        #expect(controlAfter > 0.02,
                "without pedal-up the same window must still ring — otherwise this proves nothing")
        #expect(after < 1e-6, "pedal-up left something sounding: \(after)")
    }

    /// ⭐ NOTES, NOT VOICES — the reason `sustainedNoteCount` is not a one-line
    /// count. Two zones in DIFFERENT m19-a groups make one note-on sound TWO
    /// voices (here detuned a fifth apart so both are separately measurable).
    /// With a cap of 2, three such notes must leave TWO WHOLE NOTES ringing —
    /// four voices — and the evicted note must lose BOTH its layers. A
    /// voice-counting cap would hold one note; a per-voice eviction would leave
    /// half of the oldest note playing, which is a broken sound rather than a
    /// quieter one.
    @Test("m34-q sampler: a LAYERED note counts as one note and both its layers release together")
    func layeredNoteCountsAsOneNoteSampler() throws {
        let fixture = try PedalFixture.url()
        let zones = [
            SamplerZone(audioFileURL: fixture, rootPitch: 69, group: 0),
            SamplerZone(audioFileURL: fixture, rootPitch: 69, group: 1, tuneCents: 700),
        ]
        var params = SamplerParams(zones: zones, attack: 0.005, release: 0.4, gain: 0.3)
        params.pedalHoldLimit = 2
        let pitches = [60, 63, 68]
        var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
        let ons: [Int64] = [1_000, 9_000, 17_000]
        for (index, pitch) in pitches.enumerated() {
            events += pedalNote(on: ons[index], off: ons[index] + 3_000,
                                pitch: UInt8(pitch), id: UInt64(index + 1))
        }
        let frequencies = pitches.flatMap { [pedalHz($0), pedalHz($0, cents: 700)] }
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: events, frames: pedalMeasureFrames)
        let bins = pedalBins(out.left, window: pedalMeasureWindow,
                             frequencies: frequencies, label: "sampler layered, cap 2")
        // bins[0]/[1] = note 1's two layers; [2]/[3] = note 2's; [4]/[5] = note 3's.
        let survivors = [bins[2], bins[3], bins[4], bins[5]].min() ?? 0
        #expect(survivors > 0.005,
                "TWO WHOLE NOTES — four voices — must survive a cap of 2 on a layered patch")
        #expect(bins[0] < 0.02 * survivors,
                "the oldest note's first layer is still sounding: \(bins[0])")
        #expect(bins[1] < 0.02 * survivors,
                """
                the oldest note's SECOND layer is still sounding — half a note is worse \
                than none: \(bins[1])
                """)
    }
}

extension PolySynthTests {

    @Test("m34-q poly synth: an evicted note RAMPS to silence through the patch's release — no cut")
    func evictedNoteReleasesRatherThanCutsPolySynth() throws {
        var params = pedalMeasurementSynthParams()
        params.pedalHoldLimit = 1
        let out = try renderPedalQuanta(makePedalSynth(params),
                                        events: pedalEvictionEvents(), frames: pedalCutFrames)
        expectEvictionReleases(out.left, label: "polysynth cap 1 eviction")
    }

    @Test("m34-q poly synth: a cap larger than the voice pool renders identically to no cap at all")
    func capAboveVoicePoolIsUnlimitedPolySynth() throws {
        var params = pedalSynthParams()
        params.pedalHoldLimit = 128
        #expect(params.pedalHoldLimit == 128, "the clamp must not have eaten the value")
        let out = try renderPedalQuanta(makePedalSynth(params),
                                        events: pedalByteIdentityEvents(),
                                        frames: pedalByteIdentityFrames)
        let hash = pedalHash(out.left, out.right)
        print("[measured] polysynth cap 128: fnv1a=0x\(String(hash, radix: 16, uppercase: true))")
        #expect(hash == 0xBB9B_E655_75BF_7435,
                "a cap of 128 changed the render — it is above the 16-voice pool and cannot bind")
    }

    @Test("m34-q poly synth: pedal-up still releases everything when a cap is set")
    func pedalUpStillWorksWithACapSetPolySynth() throws {
        var params = pedalMeasurementSynthParams()
        params.pedalHoldLimit = 2
        var lifted = pedalFourNoteEvents()
        lifted.append(pedalEvent(at: 60_000, down: false))
        let out = try renderPedalQuanta(makePedalSynth(params), events: lifted, frames: 90_000)
        let held = try renderPedalQuanta(makePedalSynth(params),
                                         events: pedalFourNoteEvents(), frames: 90_000)
        let before = pedalPeak(out.left, 50_000..<59_000)
        let after = pedalPeak(out.left, 80_000..<90_000)
        let controlAfter = pedalPeak(held.left, 80_000..<90_000)
        print("[measured] polysynth cap 2 pedal-up: before=\(before) after=\(after) "
              + "no-pedal-up-control=\(controlAfter)")
        #expect(before > 0.02, "the capped notes must be sounding before the pedal comes up")
        #expect(controlAfter > 0.02,
                "without pedal-up the same window must still ring — otherwise this proves nothing")
        #expect(after < 1e-6, "pedal-up left something sounding: \(after)")
    }
}

// MARK: - 4. The CATCH-UP loop — more than one note evicted by one note-on

/// FOUR keys struck and then all four released under the pedal WITH NO NOTE-ON
/// IN BETWEEN, so nothing trims them: the cap binds at note-on, and there is no
/// note-on until the fifth. That fifth must catch all the way up in a single
/// enforcement — three evictions from one event — which is the only branch of
/// `enforcePedalHoldLimit`'s loop no other scenario here reaches. (It is also
/// the branch a cap LOWERED live between notes lands in.)
private let pedalCatchUpPitches = [60, 63, 68, 70, 73]

private func pedalCatchUpEvents() -> [ScheduledMIDIEvent] {
    var events: [ScheduledMIDIEvent] = [pedalEvent(at: 0, down: true)]
    let ons: [Int64] = [1_000, 2_000, 3_000, 4_000]
    for (index, pitch) in pedalCatchUpPitches.prefix(4).enumerated() {
        events.append(ScheduledMIDIEvent(sampleTime: ons[index], noteID: UInt64(index + 1),
                                         kind: ScheduledMIDIEvent.noteOn,
                                         pitch: UInt8(pitch), velocity: 100))
    }
    // Every key comes up together, well after the last note-on — four
    // pedal-held notes and nothing to trim them.
    for (index, pitch) in pedalCatchUpPitches.prefix(4).enumerated() {
        events.append(ScheduledMIDIEvent(sampleTime: Int64(10_000 + index * 100),
                                         noteID: UInt64(index + 1),
                                         kind: ScheduledMIDIEvent.noteOff,
                                         pitch: UInt8(pitch), velocity: 0))
    }
    events += pedalNote(on: 20_000, off: 23_000, pitch: UInt8(pedalCatchUpPitches[4]), id: 5)
    return events
}

private func expectCatchUp(_ samples: [Float], floor: Double, label: String) {
    let bins = pedalBins(samples, window: pedalMeasureWindow,
                         frequencies: pedalCatchUpPitches.map { pedalHz($0) }, label: label)
    let survivors = min(bins[3], bins[4])
    #expect(survivors > floor,
            "\(label): the newest two notes must still ring after the catch-up")
    for index in 0..<3 {
        #expect(bins[index] < 0.02 * survivors,
                """
                \(label): note \(index + 1) (pitch \(pedalCatchUpPitches[index])) survived — one \
                note-on must evict ALL the excess, not just one note: \(bins[index])
                """)
    }
}

extension SamplerTests {

    @Test("m34-q sampler: one note-on catches a cap of 2 all the way up from four pedal-held notes")
    func capCatchesUpInOneNoteOnSampler() throws {
        let fixture = try PedalFixture.url()
        var params = pedalSamplerParams(fixture)
        params.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSampler(params),
                                        events: pedalCatchUpEvents(), frames: pedalMeasureFrames)
        expectCatchUp(out.left, floor: 0.01, label: "sampler cap 2 catch-up")
    }
}

extension PolySynthTests {

    @Test("m34-q poly synth: one note-on catches a cap of 2 all the way up from four pedal-held notes")
    func capCatchesUpInOneNoteOnPolySynth() throws {
        var params = pedalMeasurementSynthParams()
        params.pedalHoldLimit = 2
        let out = try renderPedalQuanta(makePedalSynth(params),
                                        events: pedalCatchUpEvents(), frames: pedalMeasureFrames)
        expectCatchUp(out.left, floor: 0.005, label: "polysynth cap 2 catch-up")
    }
}
