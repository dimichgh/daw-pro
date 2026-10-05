import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// Two sampler controls asked for by an external sax-library team, both
// justified with measurement: a per-instrument PITCH-BEND RANGE (was a
// hard-wired 2.0) and a MONO voice mode with LAST-NOTE priority.
//
// ⚠️ AN EXTENSION, NOT A NEW `@Suite`, AND DELIBERATELY SO — the
// `MainActorOccupancySiteTests` cap on `@MainActor`-isolated suites is 330 and
// the tree sits exactly on it (m23-aw-4). `SamplerTests` is the right host: it
// already owns this instrument's pitch and byte-identity measurements. Helpers
// are file-local free functions rather than reuses of `SamplerTests`' `private`
// ones, which a different file cannot see.
//
// ⭐ EVERY GATE HERE MEASURES RENDERED AUDIO — a hash of the samples, or a
// frequency read off the waveform. None of them asserts on `bendFactor`, on a
// mode flag, or on the shape of the source. A test that reads the multiplier
// back cannot tell you the multiplier reached the sound.

// MARK: - File-local harness

/// FNV-1a 64 over the raw IEEE bit patterns of every sample, left channel then
/// right. Bit patterns, not values: `==` on Float says 0.0 == -0.0 and says
/// nothing at all about NaN, and BYTE-identity is the claim being made.
private func fnv1a(_ left: [Float], _ right: [Float]) -> UInt64 {
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

/// A Float32 WAV at 44.1 kHz, amp 0.5, mono — written from a closed-form
/// expression so the fixture itself is bit-reproducible run to run, which is
/// what lets a golden hash mean anything.
private func writeSineFixture(to url: URL, frequency: Double, seconds: Double) throws {
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
        throw NSError(domain: "SamplerBendRangeTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
    }
    for frame in 0..<frames {
        data[0][frame] = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

/// Fixture cache — written once per process, into one directory per run.
private enum BendFixtures {
    nonisolated(unsafe) private static var cached: (short: URL, long: URL)?

    /// `.short` is 1.0 s (the byte-identity scenario, whose golden hash is tied
    /// to this exact length); `.long` is 4.0 s, because a bent or choked note
    /// has to still be sounding when the measurement window opens.
    static func urls() throws -> (short: URL, long: URL) {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-bendrange-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let short = dir.appendingPathComponent("sine440_44k1_mono_1s.wav")
        try writeSineFixture(to: short, frequency: 440, seconds: 1)
        let long = dir.appendingPathComponent("sine440_44k1_mono_4s.wav")
        try writeSineFixture(to: long, frequency: 440, seconds: 4)
        let set = (short: short, long: long)
        cached = set
        return set
    }
}

private func bendEvent(at sampleTime: Int64, raw: Int, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
}

private func noteEvents(on: Int64, off: Int64, pitch: UInt8,
                        velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
    [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                        kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
     ScheduledMIDIEvent(sampleTime: off, noteID: id,
                        kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
}

/// Renders directly in 512-frame quanta, replicating `InstrumentRenderer`'s
/// slicing (the `SamplerTests.renderDirect` contract, re-stated because that
/// one is `private` to its own file).
private func renderQuanta(_ instrument: SamplerInstrument,
                          events unsorted: [ScheduledMIDIEvent],
                          frames totalFrames: Int,
                          sampleRate: Double = 48_000,
                          quantum: Int = 512) throws -> (left: [Float], right: [Float]) {
    let events = unsorted.sorted { a, b in
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        // THE SCHEDULE'S OWN ORDER: at one sample time, note-OFF sorts BEFORE
        // note-on (MIDISchedule's kindRank), which is what makes two abutting
        // notes behave the same here as they do through the real schedule.
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

/// Goertzel magnitude at exactly `hz`. Absolute scale arbitrary; only ratios
/// between bins of the same window are compared.
private func goertzel(_ samples: ArraySlice<Float>, hz: Double,
                      sampleRate: Double = 48_000) -> Double {
    let w = 2.0 * Double.pi * hz / sampleRate
    let coeff = 2.0 * cos(w)
    var s1 = 0.0
    var s2 = 0.0
    for x in samples {
        let s0 = Double(x) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return max(0, power).squareRoot() / Double(samples.count)
}

/// Asserts the window is dominant at `hz` by TWO independent instruments —
/// a Goertzel bin ratio against the octave either side, and a zero-crossing
/// frequency estimate — and returns the zero-crossing figure.
@discardableResult
private func expectPitch(_ samples: [Float], hz: Double, window: Range<Int>,
                         tolerance: Double = 0.005, label: String) -> Double {
    let target = goertzel(samples[window], hz: hz)
    let below = goertzel(samples[window], hz: hz / 2)
    let above = goertzel(samples[window], hz: hz * 2)
    let measured = TestSignals.dominantFrequency(
        byZeroCrossings: samples, sampleRate: 48_000, in: window)
    print("[measured] \(label): zero-crossing \(measured) Hz (expected \(hz)); "
          + "Goertzel @\(hz) \(target), @\(hz / 2) \(below), @\(hz * 2) \(above)")
    #expect(target > 10 * below)
    #expect(target > 10 * above)
    #expect(abs(measured - hz) < tolerance * hz,
            "\(label): measured \(measured) Hz, expected \(hz) Hz")
    return measured
}

/// The single full-span zone every scenario here plays, on a fixture whose
/// root pitch is 69 — so note 69 sounds 440 Hz and every deviation from it is
/// the thing under test.
private func bendParams(fixture: URL,
                        bendRange: Double? = nil,
                        voiceMode: SamplerVoiceMode? = nil,
                        release: Double = 0.05) -> SamplerParams {
    SamplerParams(zones: [SamplerZone(audioFileURL: fixture, rootPitch: 69)],
                  attack: 0.001, release: release, gain: 0.8,
                  bendRangeSemitones: bendRange, voiceMode: voiceMode)
}

private func makeSampler(_ params: SamplerParams) -> SamplerInstrument {
    // A FIXED seed: the m19-a selection RNG is drawn once per note-on even when
    // no zone gates on it, and a golden hash may not depend on the clock.
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    return sampler
}

/// m34-s — THE REAL SAVE/OPEN PATH: params → `InstrumentDocument` → JSON →
/// `InstrumentDocument` → `instrumentDescriptor`. Deliberately NOT
/// `SamplerParams`' own `Codable`, which round-trips all fifteen fields and so
/// cannot fail the way a project does — that is precisely the gap m34-s closed,
/// and `settingsSurviveSaveAndLoad` below only ever exercised the params half.
///
/// ⚠️ Zone media rides as an ABSOLUTE path (`ProjectDocument.resolveMedia`'s
/// documented recovery-bundle form): a zone whose media does not resolve is
/// DROPPED on open, and a dropped zone would let every measurement below pass
/// on silence. The zone-count check is what makes that loud.
private func reopenThroughTheSaveFormat(_ params: SamplerParams) throws -> SamplerParams {
    let mediaRefs: [UUID: String?] = Dictionary(
        uniqueKeysWithValues: params.zones.map { ($0.id, $0.audioFileURL.path as String?) })
    let document = InstrumentDocument(
        from: InstrumentDescriptor(kind: .sampler, sampler: params), mediaRefs: mediaRefs)
    let data = try JSONEncoder().encode(document)
    let reopened = try JSONDecoder().decode(InstrumentDocument.self, from: data)
    var warnings: [String] = []
    let restored = try #require(
        reopened.instrumentDescriptor(bundleURL: URL(fileURLWithPath: "/tmp"),
                                      warn: { warnings.append($0) }).sampler)
    #expect(warnings.isEmpty, "the round trip must not warn: \(warnings)")
    #expect(restored.zones.count == params.zones.count,
            "a dropped zone would make every measurement here pass on silence")
    return restored
}

extension SamplerTests {

    // MARK: - 1. Byte identity at the default (THE LOAD-BEARING GATE)

    /// ⛔ THE GATE THE WHOLE CHANGE TURNS ON. Bend range moved from a
    /// `static let 2.0` compiled into the pitch-bend branch to a per-instrument
    /// setting read off the scalar snapshot. If that move perturbed so much as
    /// one mantissa bit at the default, every project already on disk — every
    /// one of which has `bendRangeSemitones == nil` — would render differently
    /// on load, in a way no ear would catch and no other test in this tree
    /// would either.
    ///
    /// The constant below was CAPTURED FROM THE UNMODIFIED TREE (HEAD 412cb33)
    /// before a line of this feature was written, and confirmed identical on
    /// two consecutive runs first. That ordering is the whole method: a hash
    /// taken after the edit would be measuring the change against itself.
    ///
    /// It fails on ANY render difference, which is the point — including one
    /// arriving from somewhere else entirely. If it goes red on a change that
    /// is not about bend, the honest reading is "something moved the sampler's
    /// output", and that is worth knowing.
    @Test("byte-identical: a bend lane with NO explicit range renders exactly as it did before")
    func defaultBendRangeIsByteIdentical() throws {
        let fixtures = try BendFixtures.urls()
        // Deliberately built through the ordinary path, with no mention of the
        // new fields at all — this is a pre-existing project, not one that
        // opts back into the old behaviour.
        let params = SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.short, rootPitch: 69)],
            attack: 0.001, release: 0.05, gain: 0.8)
        #expect(params.bendRangeSemitones == nil, "the scenario must carry NO explicit range")
        #expect(params.voiceMode == nil, "the scenario must carry NO explicit voice mode")

        var events = noteEvents(on: 0, off: 18_000, pitch: 69, id: 1)
        // A hand-authored bend lane at odd offsets, so events land mid-quantum
        // rather than only on quantum boundaries: centre, up, further up, back
        // through centre, down, home, and finally the 16383 extreme.
        let lane: [(Int64, Int)] = [
            (1_000, 8_192), (2_500, 10_000), (4_100, 12_288), (6_700, 8_192),
            (9_300, 6_000), (11_900, 4_096), (14_500, 8_192), (16_100, 16_383),
        ]
        for (time, raw) in lane { events.append(bendEvent(at: time, raw: raw, id: 900)) }

        let out = try renderQuanta(makeSampler(params), events: events, frames: 24_000)
        let hash = fnv1a(out.left, out.right)
        let peak = TestSignals.peak(out.left, in: 0..<out.left.count)
        print("[measured] default-range bend render: fnv1a="
              + "0x\(String(hash, radix: 16, uppercase: true)) frames=\(out.left.count) "
              + "peak=\(peak) s12000=\(out.left[12_000]) s20000=\(out.left[20_000])")

        // A CONTROL ON THE INSTRUMENT ITSELF: a hash that cannot see a one-bit
        // change would pass this test forever. Perturb the smallest thing a
        // Float can carry and require the hash to move.
        var perturbed = out.left
        perturbed[12_000] = Float(bitPattern: perturbed[12_000].bitPattern ^ 1)
        #expect(fnv1a(perturbed, out.right) != hash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(hash == 0x9D0C_171A_C39D_E2BD,
                """
                the default bend range no longer renders byte-identically to the \
                pre-change engine — every already-authored bend lane just moved
                """)
        // Two corroborating instruments, so a hash mismatch comes with a
        // human-readable direction instead of only "the number differs".
        #expect(out.left.count == 24_000)
        #expect(out.left == out.right)  // mono source, both channels
        #expect(abs(peak - 0.39999148) < 1e-7)
        #expect(out.left[12_000] == 0.047756236)
        #expect(out.left[20_000] == 0.02305962)
    }

    /// The other half of "the default is preserved": nil and an EXPLICIT 2.0
    /// must be the same sound, or `bendRangeSemitones: 2` would be a way to
    /// change a project by writing down what it already did.
    @Test("an explicit bendRangeSemitones 2 renders identically to leaving it unset")
    func explicitTwoMatchesUnset() throws {
        let fixtures = try BendFixtures.urls()
        var events = noteEvents(on: 0, off: 18_000, pitch: 69, id: 1)
        events.append(bendEvent(at: 4_000, raw: 12_288, id: 900))

        let unset = try renderQuanta(makeSampler(bendParams(fixture: fixtures.short)),
                                     events: events, frames: 24_000)
        let explicit = try renderQuanta(makeSampler(bendParams(fixture: fixtures.short,
                                                               bendRange: 2)),
                                        events: events, frames: 24_000)
        print("[measured] nil vs explicit-2: "
              + "0x\(String(fnv1a(unset.left, unset.right), radix: 16, uppercase: true)) vs "
              + "0x\(String(fnv1a(explicit.left, explicit.right), radix: 16, uppercase: true))")
        #expect(fnv1a(unset.left, unset.right) == fnv1a(explicit.left, explicit.right))
    }

    // MARK: - 2. The range, MEASURED AS A FREQUENCY

    /// ⛔ Measured off the WAVEFORM, never off `bendFactor`. Two deflections
    /// per range, one of which is exact:
    ///  · raw 0 is exactly −8192 from centre, so it is exactly −1 × range —
    ///    at range 12 that is exactly one octave down, 220.000 Hz from a
    ///    440 Hz root, an assertion with no rounding in it at all;
    ///  · raw 16383 is +8191, one unit short of symmetric, so a full upward
    ///    deflection is 8191/8192 of the range — 879.925 Hz at range 12 rather
    ///    than a round 880. Asserting 880 exactly would be asserting a bug.
    @Test("bend range 12: a full deflection moves a whole OCTAVE, measured as frequency")
    func bendRangeTwelveMovesAnOctave() throws {
        let fixtures = try BendFixtures.urls()
        let params = bendParams(fixture: fixtures.long, bendRange: 12)

        // Centre first: the range setting must not detune an unbent note.
        let centred = try renderQuanta(makeSampler(params),
                                       events: noteEvents(on: 0, off: 200_000, pitch: 69, id: 1),
                                       frames: 48_000)
        expectPitch(centred.left, hz: 440, window: 9_600..<28_800, label: "range 12, centred")

        // Full DOWN — exact: 440 × 2^(−12/12) = 220.000 Hz.
        var down = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        down.append(bendEvent(at: 100, raw: 0, id: 900))
        let downOut = try renderQuanta(makeSampler(params), events: down, frames: 48_000)
        expectPitch(downOut.left, hz: 220, window: 9_600..<28_800, label: "range 12, raw 0")

        // Full UP — 440 × 2^(12 × 8191/8192 / 12) = 879.9255 Hz.
        var up = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        up.append(bendEvent(at: 100, raw: 16_383, id: 900))
        let upOut = try renderQuanta(makeSampler(params), events: up, frames: 48_000)
        let expectedUp = 440.0 * exp2(12.0 * (8_191.0 / 8_192.0) / 12.0)
        #expect(abs(expectedUp - 879.9255) < 0.001)   // the arithmetic, stated
        expectPitch(upOut.left, hz: expectedUp, window: 9_600..<28_800,
                    label: "range 12, raw 16383")
    }

    /// The SAME deflections at the default range must move a WHOLE TONE, not
    /// an octave — the assertion that would catch a widened default even if
    /// the golden hash above were somehow satisfied.
    @Test("the DEFAULT range: the same full deflection moves a whole tone, not an octave")
    func defaultRangeMovesAWholeTone() throws {
        let fixtures = try BendFixtures.urls()
        // No range set — the pre-existing-project shape.
        let params = bendParams(fixture: fixtures.long)

        // Full DOWN — exact: 440 × 2^(−2/12) = 391.995 Hz, a whole tone below.
        var down = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        down.append(bendEvent(at: 100, raw: 0, id: 900))
        let downOut = try renderQuanta(makeSampler(params), events: down, frames: 48_000)
        expectPitch(downOut.left, hz: 440.0 * exp2(-2.0 / 12.0), window: 9_600..<28_800,
                    label: "default range, raw 0")

        // Full UP — 440 × 2^(2 × 8191/8192 / 12) = 493.876 Hz, a whole tone up.
        var up = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        up.append(bendEvent(at: 100, raw: 16_383, id: 900))
        let upOut = try renderQuanta(makeSampler(params), events: up, frames: 48_000)
        let expectedUp = 440.0 * exp2(2.0 * (8_191.0 / 8_192.0) / 12.0)
        #expect(abs(expectedUp - 493.8764) < 0.001)
        expectPitch(upOut.left, hz: expectedUp, window: 9_600..<28_800,
                    label: "default range, raw 16383")
        // …and emphatically NOT an octave. Stated separately because "a whole
        // tone" and "not six times a whole tone" are the two halves of the
        // deviation this feature deliberately made from what was requested.
        #expect(abs(expectedUp - 879.9245) > 300)
    }

    /// A range change while a note is HELD AND DEFLECTED must retune it at
    /// once. Without `applyBendFactor` on snapshot adoption the note would keep
    /// the old range's pitch until the lane's next point — on a held note,
    /// forever — which is a setter that returns success and changes nothing.
    @Test("changing the range mid-note retunes a currently-deflected held note")
    func rangeChangeRetunesAHeldNote() async throws {
        let fixtures = try BendFixtures.urls()
        let sampler = makeSampler(bendParams(fixture: fixtures.long, bendRange: 2))
        var events = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        events.append(bendEvent(at: 100, raw: 0, id: 900))   // full down, held there

        // Render the first half at range 2, publish range 12, render the rest.
        let before = try renderQuanta(sampler, events: events, frames: 24_000)
        expectPitch(before.left, hz: 440.0 * exp2(-2.0 / 12.0), window: 4_800..<24_000,
                    label: "held + deflected, range 2")

        sampler.apply(params: bendParams(fixture: fixtures.long, bendRange: 12))
        // No further bend events: the ONLY thing that can retune the note is
        // the snapshot adoption.
        let after = try renderQuanta(sampler, events: [], frames: 48_000)
        expectPitch(after.left, hz: 220, window: 9_600..<28_800,
                    label: "same held note after range → 12")
    }

    // MARK: - 3. Mono, last-note priority

    /// ⛔ THE TEST CASE THE REQUESTER NAMED: overlapping notes must retrigger
    /// to the NEWEST pitch. The poly render is the control — same events, same
    /// instrument, and it must show BOTH pitches, or the mono result would
    /// prove nothing about mono.
    @Test("mono is LAST-NOTE priority: an overlapping note takes over the airstream")
    func monoOverlapRetriggersToTheNewestPitch() throws {
        let fixtures = try BendFixtures.urls()
        // A (69 → 440 Hz) is held throughout; B (81 → 880 Hz) starts on top of
        // it — the legato overlap a slur is written as.
        let events = noteEvents(on: 0, off: 140_000, pitch: 69, id: 1)
            + noteEvents(on: 24_000, off: 140_000, pitch: 81, id: 2)
        // 0.4 s, a whole number of cycles at BOTH 440 and 880, opening well
        // after the choke's 0.05 s release has run out.
        let window = 28_000..<47_200

        let poly = try renderQuanta(makeSampler(bendParams(fixture: fixtures.long)),
                                    events: events, frames: 60_000)
        let polyLow = goertzel(poly.left[window], hz: 440)
        let polyHigh = goertzel(poly.left[window], hz: 880)
        print("[measured] POLY control during the overlap: @440 \(polyLow), @880 \(polyHigh)")
        #expect(polyLow > 0.02, "the poly control must still be sounding the OLD note")
        #expect(polyHigh > 0.02, "the poly control must also be sounding the NEW note")

        let mono = try renderQuanta(
            makeSampler(bendParams(fixture: fixtures.long, voiceMode: .mono)),
            events: events, frames: 60_000)
        let monoLow = goertzel(mono.left[window], hz: 440)
        let monoHigh = goertzel(mono.left[window], hz: 880)
        print("[measured] MONO during the overlap: @440 \(monoLow), @880 \(monoHigh) "
              + "(poly had @440 \(polyLow))")
        // The new pitch is there…
        expectPitch(mono.left, hz: 880, window: window, label: "mono, newest pitch wins")
        // …and the old one is GONE, measured against the poly control rather
        // than against an absolute floor picked to pass.
        #expect(monoLow < polyLow / 50,
                """
                mono left the superseded note sounding: @440 was \(monoLow) vs the \
                poly control's \(polyLow)
                """)
        #expect(monoHigh > 20 * monoLow)
    }

    /// A note-on that selects NO zone must not choke the note that is
    /// sounding. Mono means "the newest note takes the airstream"; a note that
    /// sounds nothing never took it, and silencing the line for it would open
    /// a hole no player could produce.
    @Test("mono does not choke on a note-on that sounds nothing")
    func monoDoesNotChokeOnAnUnmappedNote() throws {
        let fixtures = try BendFixtures.urls()
        // One zone covering 60...84 only; note 40 falls outside it.
        var zone = SamplerZone(audioFileURL: fixtures.long, rootPitch: 69)
        zone.minPitch = 60
        zone.maxPitch = 84
        let params = SamplerParams(zones: [zone], attack: 0.001, release: 0.05, gain: 0.8,
                                   voiceMode: .mono)
        let events = noteEvents(on: 0, off: 140_000, pitch: 69, id: 1)
            + noteEvents(on: 24_000, off: 140_000, pitch: 40, id: 2)
        let out = try renderQuanta(makeSampler(params), events: events, frames: 60_000)
        expectPitch(out.left, hz: 440, window: 28_000..<47_200,
                    label: "held note survives an unmapped note-on")
    }

    // MARK: - 4. The decision: note-off while an earlier note is still held

    /// ⛔ THE DOCUMENTED DECISION, MEASURED. Mono does NOT fall back: when the
    /// note that is sounding is released, a note still held underneath does not
    /// come back.
    ///
    /// Why this and not the keyboard convention. The overlap that creates the
    /// case at all is the LEGATO idiom — start B before A ends so the two slur
    /// — and in it A's note-off arrives after B has started. Fallback would
    /// fire a phantom backwards slur to A on every slurred pair in the part.
    /// The convention it comes from exists so a player can trill by holding a
    /// low note with the other hand; a sax player has one airstream and cannot.
    /// The earlier note ended when the player moved, and on a wind instrument
    /// it cannot return without a new articulation — i.e. a new note-on.
    ///
    /// A long release (0.5 s) is deliberate: it keeps the superseded voice
    /// ALIVE in its release ramp at the moment the decision is taken, so a
    /// fallback implementation would have something to revive and this test
    /// would see it.
    @Test("mono note-off does NOT fall back to a note still held underneath")
    func monoNoteOffDoesNotFallBackToAHeldNote() throws {
        let fixtures = try BendFixtures.urls()
        let params = bendParams(fixture: fixtures.long, voiceMode: .mono, release: 0.5)
        // A (440 Hz) held to the very end; B (880 Hz) supersedes it at 24 000
        // and is itself released at 40 000 — while A is STILL DOWN.
        let events = noteEvents(on: 0, off: 190_000, pitch: 69, id: 1)
            + noteEvents(on: 24_000, off: 40_000, pitch: 81, id: 2)
        let out = try renderQuanta(makeSampler(params), events: events, frames: 120_000)

        // B was sounding. MEASURED AFTER A'S RELEASE HAS RUN OUT, not during it:
        // A is choked at 24 000 and its DELIBERATELY long 0.5 s release keeps 440 Hz
        // in the signal until 48 000, which overlaps the whole of B's sustain
        // (24 000-40 000). There is therefore NO window in which B sustains and A is
        // silent, and asserting B's dominance inside that overlap contradicts the
        // fixture this test is built on. 48 500..<63 000 is after A is gone and before
        // B's own release ends at 64 000, so it isolates B.
        expectPitch(out.left, hz: 880, window: 48_500..<63_000,
                    label: "mono, B alone once A's release has ended")

        // After both release ramps have run out (A choked at 24 000 + 0.5 s =
        // 48 000; B released at 40 000 + 0.5 s = 64 000) the line is SILENT,
        // even though A's key is still down.
        let silence = 72_000..<110_000
        let peak = TestSignals.peak(out.left, in: silence)
        let low = goertzel(out.left[silence], hz: 440)
        let high = goertzel(out.left[silence], hz: 880)
        print("[measured] after B's note-off with A still held: peak \(peak), "
              + "@440 \(low), @880 \(high)")
        #expect(peak < 1e-6,
                """
                something is still sounding after the active mono note was released \
                — peak \(peak)
                """)
        #expect(low < 1e-6, "the held earlier note came BACK: @440 \(low)")
    }

    /// The other ordering, and the one the legato idiom actually produces: the
    /// SUPERSEDED note's off arrives while the newest note sounds. It must be
    /// discarded — the newest note keeps playing, undisturbed.
    @Test("mono discards the note-off of an already-superseded note")
    func monoDiscardsASupersededNoteOff() throws {
        let fixtures = try BendFixtures.urls()
        let params = bendParams(fixture: fixtures.long, voiceMode: .mono, release: 0.5)
        // A is superseded at 24 000, and its own note-off lands at 30 000 —
        // after B started, exactly as a written slur produces.
        let events = noteEvents(on: 0, off: 30_000, pitch: 69, id: 1)
            + noteEvents(on: 24_000, off: 190_000, pitch: 81, id: 2)
        let out = try renderQuanta(makeSampler(params), events: events, frames: 120_000)

        // B is still going strong long after A's note-off — that off must not
        // have touched it.
        expectPitch(out.left, hz: 880, window: 76_000..<95_200,
                    label: "B survives the superseded note's off")
        let late = 76_000..<95_200
        let peak = TestSignals.peak(out.left, in: late)
        print("[measured] long after the superseded note-off: peak \(peak), "
              + "@880 \(goertzel(out.left[late], hz: 880)), "
              + "@440 \(goertzel(out.left[late], hz: 440))")
        #expect(peak > 0.1, "the newest note was cut short by an older note's note-off")
        // And A really is gone: its 0.5 s choke release ended at 48 000, so a
        // note-off that RESTARTED that ramp (the bug the discard rule prevents)
        // would still be audible here.
        #expect(goertzel(out.left[late], hz: 440) < 1e-6)
    }

    // MARK: - 5. Persistence — the PARAMS half only (see §6 for the save format)

    /// A project saved before these fields existed must still open, and open as
    /// the same instrument. Both directions, on `SamplerParams`' own `Codable`
    /// conformance.
    ///
    /// ⚠️⚠️ CORRECTION 2026-08-31 (ROADMAP m34-s), left in place because the
    /// gap it names is the interesting part: THIS TEST WAS GREEN THE WHOLE TIME
    /// THE FEATURE DID NOT SURVIVE A SAVE. `SamplerParams` does not persist
    /// through its own `Codable` — `SamplerDocument` (ProjectDocument.swift) is
    /// the save format, and until m34-s neither key was in ITS CodingKeys, so a
    /// user's mono/±12 patch reopened as poly/±2. A test named "persistence"
    /// that exercises a type the save path never encodes is exactly this tree's
    /// characteristic failure shape: the record says X, the source says Y, and
    /// nothing compares them. The comparison now lives in §6 below and in
    /// `PedalHoldLimitCodableTests`; this test keeps its narrower, still-true
    /// claim about the model type.
    @Test("persistence: absent keys decode as nil, set values round-trip, nil emits nothing")
    func settingsSurviveSaveAndLoad() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // A pre-existing project's sampler JSON: no bendRangeSemitones, no
        // voiceMode, not even a null.
        let legacy = Data("""
        {"zones":[],"oneShot":false,"attack":0.001,"release":0.05,"gain":0.8}
        """.utf8)
        let decoded = try decoder.decode(SamplerParams.self, from: legacy)
        #expect(decoded.bendRangeSemitones == nil)
        #expect(decoded.voiceMode == nil)
        // …and nil resolves to the behaviour it always had.
        #expect(decoded.effectiveBendRangeSemitones == 2)
        #expect(decoded.effectiveVoiceMode == .poly)

        // An untouched sampler must not GROW the two keys on save, or every
        // project file would change the first time it was opened.
        let untouched = try encoder.encode(SamplerParams())
        let untouchedText = try #require(String(data: untouched, encoding: .utf8))
        #expect(!untouchedText.contains("bendRangeSemitones"))
        #expect(!untouchedText.contains("voiceMode"))
        // A control on that check: the same probe MUST find the keys once set,
        // or "absent" above would only mean the probe never worked.
        let set = SamplerParams(bendRangeSemitones: 6, voiceMode: .mono)
        let setText = try #require(String(data: try encoder.encode(set), encoding: .utf8))
        #expect(setText.contains("bendRangeSemitones"))
        #expect(setText.contains("\"voiceMode\":\"mono\""))

        let round = try decoder.decode(SamplerParams.self, from: try encoder.encode(set))
        #expect(round.bendRangeSemitones == 6)
        #expect(round.voiceMode == .mono)
        #expect(round == set)

        // Out-of-range clamps at the model boundary, as every sibling field does.
        #expect(SamplerParams(bendRangeSemitones: 99).bendRangeSemitones == 48)
        #expect(SamplerParams(bendRangeSemitones: -5).bendRangeSemitones == 0)
    }

    // MARK: - 6. m34-s — the same two settings, after a SAVE and a REOPEN

    /// ⛔ BOTH SETTINGS SHIPPED WITHOUT A SAVE. `bendRangeSemitones` and
    /// `voiceMode` were absent from `SamplerDocument`'s CodingKeys until
    /// 2026-08-31, so the sax team's instrument reopened at ±2 and poly no
    /// matter what had been set — measured, filed as ROADMAP m34-s.
    ///
    /// ⭐ This asserts the reopened patch BENDS AN OCTAVE, in Hz. Reading
    /// `restored.bendRangeSemitones == 12` back would not tell you the number
    /// reached the sound.
    @Test("m34-s: a SAVED AND REOPENED bend range 12 still moves a whole OCTAVE")
    func reopenedBendRangeTwelveStillMovesAnOctave() throws {
        let fixtures = try BendFixtures.urls()
        let restored = try reopenThroughTheSaveFormat(
            bendParams(fixture: fixtures.long, bendRange: 12))
        #expect(restored.bendRangeSemitones == 12,
                "the save format dropped the bend range — ROADMAP m34-s")

        var down = noteEvents(on: 0, off: 200_000, pitch: 69, id: 1)
        down.append(bendEvent(at: 100, raw: 0, id: 900))
        let downOut = try renderQuanta(makeSampler(restored), events: down, frames: 48_000)
        expectPitch(downOut.left, hz: 220, window: 9_600..<28_800,
                    label: "REOPENED range 12, raw 0")

        // ⛔ THE COMPAT CONTROL: the SAME deflection on a patch that never set a
        // range must still be a WHOLE TONE after a reopen. Every bend lane
        // already authored in every existing project was written against ±2, so
        // an absent key resolving to anything else would rescale all of them.
        let plain = try reopenThroughTheSaveFormat(bendParams(fixture: fixtures.long))
        #expect(plain.bendRangeSemitones == nil, "an unset range must reopen unset")
        let plainOut = try renderQuanta(makeSampler(plain), events: down, frames: 48_000)
        expectPitch(plainOut.left, hz: 440.0 * exp2(-2.0 / 12.0), window: 9_600..<28_800,
                    label: "REOPENED default range, raw 0")
    }

    /// The item's brief singled this one out: `voiceMode` changes VOICE
    /// ALLOCATION, so its reopen gate must HEAR mono behaviour rather than read
    /// the field back. Same scenario as `monoOverlapRetriggersToTheNewestPitch`
    /// — an overlapping D5 over a held A4 — with both renders taken through the
    /// save format, so the comparison is mono-vs-poly and not reopened-vs-not.
    @Test("m34-s: a SAVED AND REOPENED mono patch still collapses the superseded note")
    func reopenedMonoStillCollapsesTheSupersededNote() throws {
        let fixtures = try BendFixtures.urls()
        let events = noteEvents(on: 0, off: 140_000, pitch: 69, id: 1)
            + noteEvents(on: 24_000, off: 140_000, pitch: 81, id: 2)
        let window = 28_000..<47_200

        let reopenedPoly = try reopenThroughTheSaveFormat(bendParams(fixture: fixtures.long))
        #expect(reopenedPoly.voiceMode == nil, "an unset mode must reopen unset, and mean poly")
        let poly = try renderQuanta(makeSampler(reopenedPoly), events: events, frames: 60_000)
        let polyLow = goertzel(poly.left[window], hz: 440)
        #expect(polyLow > 0.02, "the reopened POLY control must still sound the OLD note")

        let restored = try reopenThroughTheSaveFormat(
            bendParams(fixture: fixtures.long, voiceMode: .mono))
        #expect(restored.voiceMode == .mono,
                "the save format dropped the voice mode — ROADMAP m34-s")
        let mono = try renderQuanta(makeSampler(restored), events: events, frames: 60_000)
        let monoLow = goertzel(mono.left[window], hz: 440)
        let monoHigh = goertzel(mono.left[window], hz: 880)
        print("[measured] REOPENED MONO during the overlap: @440 \(monoLow), @880 \(monoHigh) "
              + "(reopened poly had @440 \(polyLow))")
        expectPitch(mono.left, hz: 880, window: window, label: "reopened mono, newest pitch wins")
        #expect(monoLow < polyLow / 50,
                """
                a REOPENED mono patch left the superseded note sounding: @440 was \(monoLow) \
                vs the reopened poly control's \(polyLow)
                """)
        #expect(monoHigh > 20 * monoLow)
    }
}
