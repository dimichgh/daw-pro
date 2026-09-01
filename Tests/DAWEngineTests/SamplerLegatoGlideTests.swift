import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m34-t — TRUE LEGATO (voice continuation) and GLIDE/PORTAMENTO on the built-in
// sampler.
//
// ⭐ THE DEFECT THIS CLOSES, stated as the engine actually behaved: `.mono` was
// voice STEALING, not continuation. A note-on choked the sounding voice into
// its RELEASE ramp and wrote a NEW voice with a FRESH ATTACK, so a slurred sax
// pair still re-articulated on the second note. Mono decided which note wins;
// it did not remove the tongue. `.legato` continues the sounding voice — same
// envelope, same zone, new pitch — and `glideTime` makes that pitch change a
// SLIDE rather than a step.
//
// ⚠️ AN EXTENSION, NOT A NEW `@Suite`, AND DELIBERATELY SO — the
// `MainActorOccupancySiteTests` cap on isolated suites has no headroom, and
// `SamplerTests` is the right host: it already owns this instrument's pitch and
// byte-identity measurements. Helpers are file-local free functions rather than
// reuses of the neighbouring files' `private` ones, which a different file
// cannot see. That duplication is the established pattern here.
//
// ⭐ EVERY GATE MEASURES RENDERED AUDIO — a hash of the samples, a
// frame-to-frame difference, or a frequency read off the waveform. Not one
// asserts on `glideCoeff`, on a mode flag, or on the shape of the source. A
// test that reads the multiplier back cannot tell you the multiplier reached
// the sound.
//
// ⛔ OFFLINE AND DETERMINISTIC ONLY. No wall clock, no live metering, no
// tolerance tuned until it passed — every bound below is either exact (a hash,
// a bit-for-bit frame delta) or carries its own negative control showing the
// bound can fail.

// MARK: - File-local harness

/// FNV-1a 64 over the raw IEEE bit patterns of every sample, left then right.
/// Bit patterns, not values: `==` on Float says 0.0 == -0.0 and says nothing at
/// all about NaN, and BYTE-identity is the claim being made.
private func lgFnv1a(_ left: [Float], _ right: [Float]) -> UInt64 {
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

/// A Float32 WAV at 44.1 kHz, mono, written from a closed-form expression so
/// the fixture itself is bit-reproducible run to run — which is what lets a
/// golden hash mean anything. `frequency == 0` writes a CONSTANT 0.5 (see
/// `LegatoFixtures.dc`).
private func lgWriteFixture(to url: URL, frequency: Double, seconds: Double) throws {
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
        throw NSError(domain: "SamplerLegatoGlideTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
    }
    for frame in 0..<frames {
        data[0][frame] = frequency == 0
            ? 0.5
            : Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

/// Fixture cache — written once per process, into one directory per run.
private enum LegatoFixtures {
    nonisolated(unsafe) private static var cached: (sine: URL, dc: URL, short: URL)?

    /// `.sine` is 440 Hz × 10 s — long enough that a 2 s glide up an octave
    /// (increment 1.8375 source frames per output frame) never runs off the end
    /// of the source and frees the voice mid-measurement.
    ///
    /// ⭐ `.dc` IS A CONSTANT 0.5, AND IT IS THE INSTRUMENT THAT MAKES THE
    /// ENVELOPE DIRECTLY VISIBLE. Linear interpolation of a constant is exact
    /// (`c + (c − c) × frac == c` for every frac), so the rendered signal is
    /// `0.5 × level × gain` and NOTHING ELSE — the pitch and the playhead drop
    /// out completely. A frame-to-frame difference in that signal therefore IS
    /// a frame-to-frame difference in the envelope, with no windowing, no
    /// smoothing and no tolerance in between. A continued voice at full level
    /// renders EXACTLY constant; a retriggered one cannot.
    ///
    /// `.short` is 1 s of 440 Hz, used only where the golden-hash scenario's
    /// length is part of what is pinned.
    static func urls() throws -> (sine: URL, dc: URL, short: URL) {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-legato-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sine = dir.appendingPathComponent("sine440_44k1_mono_10s.wav")
        try lgWriteFixture(to: sine, frequency: 440, seconds: 10)
        let dc = dir.appendingPathComponent("dc05_44k1_mono_10s.wav")
        try lgWriteFixture(to: dc, frequency: 0, seconds: 10)
        let short = dir.appendingPathComponent("sine440_44k1_mono_4s.wav")
        try lgWriteFixture(to: short, frequency: 440, seconds: 4)
        let set = (sine: sine, dc: dc, short: short)
        cached = set
        return set
    }
}

private func lgNotes(on: Int64, off: Int64, pitch: UInt8,
                     velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
    [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                        kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
     ScheduledMIDIEvent(sampleTime: off, noteID: id,
                        kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
}

private func lgBend(at sampleTime: Int64, raw: Int, id: UInt64 = 900) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
}

/// Renders directly in 512-frame quanta, replicating `InstrumentRenderer`'s
/// slicing and `MIDISchedule`'s own event order (note-OFF before note-on at one
/// sample time), so two abutting notes behave here exactly as through the real
/// schedule.
private func lgRender(_ instrument: SamplerInstrument,
                      events unsorted: [ScheduledMIDIEvent],
                      frames totalFrames: Int,
                      sampleRate: Double = 48_000,
                      quantum: Int = 512) throws -> (left: [Float], right: [Float]) {
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
        while end < events.count, events[end].sampleTime < Int64(rendered + frames) { end += 1 }
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

/// The LARGEST frame-to-frame step in a window — the envelope discontinuity
/// metric, on the DC fixture where the signal IS the envelope. A continued
/// voice holding at full level gives EXACTLY 0; anything that re-attacks or
/// releases cannot.
private func lgMaxStep(_ samples: [Float], in window: Range<Int>) -> Float {
    var worst: Float = 0
    for index in window.lowerBound + 1..<window.upperBound {
        worst = max(worst, abs(samples[index] - samples[index - 1]))
    }
    return worst
}

/// Goertzel magnitude at exactly `hz`. Absolute scale arbitrary; only ratios
/// between bins of the same window are compared.
private func lgGoertzel(_ samples: ArraySlice<Float>, hz: Double,
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

/// Zero-crossing frequency estimate over a window — the same instrument the
/// bend suite uses, re-stated because that one is file-private there.
private func lgFrequency(_ samples: [Float], in window: Range<Int>) -> Double {
    TestSignals.dominantFrequency(byZeroCrossings: samples, sampleRate: 48_000, in: window)
}

private func lgParams(fixture: URL,
                      voiceMode: SamplerVoiceMode? = nil,
                      glideTime: Double? = nil,
                      attack: Double = 0.001,
                      release: Double = 0.05) -> SamplerParams {
    SamplerParams(zones: [SamplerZone(audioFileURL: fixture, rootPitch: 69)],
                  attack: attack, release: release, gain: 0.8,
                  voiceMode: voiceMode, glideTime: glideTime)
}

private func lgSampler(_ params: SamplerParams) -> SamplerInstrument {
    // A FIXED seed: the m19-a selection RNG is drawn once per note-on even when
    // no zone gates on it, and a golden hash may not depend on the clock.
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    return sampler
}

/// THE REAL SAVE/OPEN PATH — params → `InstrumentDocument` → JSON →
/// `InstrumentDocument` → `instrumentDescriptor`. Deliberately NOT
/// `SamplerParams`' own `Codable`, which round-trips every field and so cannot
/// fail the way a project does: that was m34-s's whole finding, and m34-t adds
/// a field to the same save format.
private func lgReopen(_ params: SamplerParams) throws -> SamplerParams {
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

/// The three-note scenario both golden hashes below are taken over. ONE
/// definition, so the poly pin and the mono pin cannot drift apart.
private func lgGoldenEvents() -> [ScheduledMIDIEvent] {
    lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
        + lgNotes(on: 12_000, off: 40_000, pitch: 76, id: 2)
        + lgNotes(on: 26_000, off: 55_000, pitch: 72, id: 3)
}

extension SamplerTests {

    // MARK: - 1. Byte identity (THE LOAD-BEARING GATES)

    /// ⛔ THE GATE THE WHOLE CHANGE TURNS ON, HALF ONE: POLY IS UNTOUCHED.
    /// m34-t added a per-frame branch inside the voice loop, three fields to
    /// `Voice`, and a new first statement in the note-on path. Every project on
    /// disk today is `voiceMode == nil` — poly — and if any of that perturbed
    /// one mantissa bit, every one of them would render differently on load, in
    /// a way no ear would catch and no other test in this tree would either.
    ///
    /// The constant below was CAPTURED FROM THE UNMODIFIED TREE (HEAD aa81cd3)
    /// before a line of this feature was written, and confirmed identical on two
    /// consecutive runs first. That ordering is the whole method: a hash taken
    /// after the edit would be measuring the change against itself.
    @Test("m34-t byte-identical: a POLY render is exactly what it was before legato existed")
    func polyRenderIsByteIdenticalAfterLegato() throws {
        let fixtures = try LegatoFixtures.urls()
        // Built through the ordinary path with no mention of the new fields —
        // this is a pre-existing project, not one opting back into old behaviour.
        let params = SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.short, rootPitch: 69)],
            attack: 0.001, release: 0.05, gain: 0.8)
        #expect(params.voiceMode == nil, "the scenario must carry NO explicit voice mode")
        #expect(params.glideTime == nil, "the scenario must carry NO explicit glide")

        let out = try lgRender(lgSampler(params), events: lgGoldenEvents(), frames: 72_000)
        let hash = lgFnv1a(out.left, out.right)
        let peak = TestSignals.peak(out.left, in: 0..<out.left.count)
        print("[measured] m34-t POLY golden: fnv1a=0x\(String(hash, radix: 16, uppercase: true)) "
              + "peak=\(peak) s20000=\(out.left[20_000]) s35000=\(out.left[35_000])")

        // A CONTROL ON THE HASH ITSELF: one that cannot see a one-bit change
        // would pass this test forever.
        var perturbed = out.left
        perturbed[20_000] = Float(bitPattern: perturbed[20_000].bitPattern ^ 1)
        #expect(lgFnv1a(perturbed, out.right) != hash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(hash == 0xFE5F_34B9_BB31_C175,
                """
                POLY no longer renders byte-identically to the pre-m34-t engine — every \
                project on disk just moved
                """)
        #expect(out.left.count == 72_000)
        #expect(out.left == out.right)          // mono source, both channels
        #expect(abs(peak - 1.1689566) < 1e-6)
        #expect(out.left[20_000] == 0.06522288)
        #expect(out.left[35_000] == 0.0051493407)
    }

    /// ⛔ HALF TWO, AND THE ONE THE OTHER TESTS CANNOT COVER: `.mono` IS
    /// UNTOUCHED. m34-t rewired mono's own code paths — `ScalarParams`'
    /// `monoVoiceMode` widened from `== .mono` to "monophonic", the note-on
    /// branch gained a statement above the choke arm, and `trigger` gained a
    /// glide block. The neighbouring mono tests measure Goertzel DOMINANCE,
    /// which a subtle regression would sail through; this measures BYTES.
    ///
    /// Same provenance as the poly pin: captured on the unmodified tree, twice.
    @Test("m34-t byte-identical: a MONO render is exactly what it was before legato existed")
    func monoRenderIsByteIdenticalAfterLegato() throws {
        let fixtures = try LegatoFixtures.urls()
        let params = SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.short, rootPitch: 69)],
            attack: 0.001, release: 0.05, gain: 0.8, voiceMode: .mono)
        #expect(params.glideTime == nil, "the scenario must carry NO explicit glide")

        let out = try lgRender(lgSampler(params), events: lgGoldenEvents(), frames: 72_000)
        let hash = lgFnv1a(out.left, out.right)
        let peak = TestSignals.peak(out.left, in: 0..<out.left.count)
        print("[measured] m34-t MONO golden: fnv1a=0x\(String(hash, radix: 16, uppercase: true)) "
              + "peak=\(peak) s20000=\(out.left[20_000]) s35000=\(out.left[35_000])")

        var perturbed = out.left
        perturbed[20_000] = Float(bitPattern: perturbed[20_000].bitPattern ^ 1)
        #expect(lgFnv1a(perturbed, out.right) != hash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(hash == 0xF9ED_75A9_BE7F_4025,
                "MONO no longer renders byte-identically to the pre-m34-t engine")
        #expect(abs(peak - 0.7572404) < 1e-6)
        #expect(out.left[20_000] == -0.28118727)
        #expect(out.left[35_000] == 0.25407258)
        // The two golden renders must DIFFER, or one of them is measuring the
        // wrong instrument and both pins would be satisfied by silence.
        let poly = try lgRender(
            lgSampler(SamplerParams(zones: [SamplerZone(audioFileURL: fixtures.short,
                                                        rootPitch: 69)],
                                    attack: 0.001, release: 0.05, gain: 0.8)),
            events: lgGoldenEvents(), frames: 72_000)
        #expect(lgFnv1a(poly.left, poly.right) != hash,
                "poly and mono rendered the same bytes — the scenario does not exercise the mode")
    }

    /// ⛔ THE SCOPE DECISION, MADE LOAD-BEARING RATHER THAN DOCUMENTED: glide is
    /// MONOPHONIC-ONLY, so setting it on a poly sampler must change NOTHING —
    /// not approximately, not inaudibly. Under poly there is no single previous
    /// note to slide from, and inventing one would be a different feature with
    /// its own note-assignment rules.
    ///
    /// The negative control is in the same test: the identical glide under
    /// `.legato` must NOT be byte-identical, or this would pass with a glide
    /// implementation that does nothing anywhere.
    @Test("m34-t: glideTime on a POLY sampler is inert, bit for bit")
    func glideOnPolyIsInert() throws {
        let fixtures = try LegatoFixtures.urls()
        let events = lgGoldenEvents()
        let withoutGlide = try lgRender(lgSampler(lgParams(fixture: fixtures.short)),
                                        events: events, frames: 72_000)
        let withGlide = try lgRender(
            lgSampler(lgParams(fixture: fixtures.short, glideTime: 0.2)),
            events: events, frames: 72_000)
        let bare = lgFnv1a(withoutGlide.left, withoutGlide.right)
        let glided = lgFnv1a(withGlide.left, withGlide.right)
        print("[measured] poly glide inertness: bare=0x\(String(bare, radix: 16, uppercase: true)) "
              + "glide0.2=0x\(String(glided, radix: 16, uppercase: true))")
        #expect(bare == glided, "a glide reached a POLY sampler — poly must be unable to change")

        // CONTROL: the same glideTime under legato DOES change the render, so
        // "identical" above is a fact about poly and not about the feature.
        let legato = try lgRender(
            lgSampler(lgParams(fixture: fixtures.short, voiceMode: .legato, glideTime: 0.2)),
            events: events, frames: 72_000)
        #expect(lgFnv1a(legato.left, legato.right) != bare,
                "control failed: the same glide changed nothing under LEGATO either")
    }

    /// `.legato` with NO glide is still a real slur (the pitch steps), so it
    /// must NOT be byte-identical to poly or to mono. Cheap, and it is the
    /// assertion that would catch a `.legato` that silently decoded to poly —
    /// which is exactly what an old build does with the new rawValue, by design.
    @Test("m34-t: legato is a THIRD behaviour — it renders like neither poly nor mono")
    func legatoIsDistinctFromBothOtherModes() throws {
        let fixtures = try LegatoFixtures.urls()
        let events = lgGoldenEvents()
        func hash(_ mode: SamplerVoiceMode?) throws -> UInt64 {
            let out = try lgRender(lgSampler(lgParams(fixture: fixtures.short, voiceMode: mode)),
                                   events: events, frames: 72_000)
            return lgFnv1a(out.left, out.right)
        }
        let poly = try hash(nil)
        let mono = try hash(.mono)
        let legato = try hash(.legato)
        print("[measured] three modes: poly=0x\(String(poly, radix: 16, uppercase: true)) "
              + "mono=0x\(String(mono, radix: 16, uppercase: true)) "
              + "legato=0x\(String(legato, radix: 16, uppercase: true))")
        #expect(legato != poly, "legato rendered as POLY — the mode did not reach the engine")
        #expect(legato != mono, "legato rendered as MONO — the continuation did not happen")
        #expect(poly != mono)
    }

    // MARK: - 2. THE SLUR: no re-attack (envelope continuity)

    /// ⛔⛔ THE GATE THE FEATURE EXISTS FOR, AND IT COMES WITH ITS RED CONTROL
    /// BUILT IN AND PERMANENT.
    ///
    /// On the DC fixture the rendered signal IS the envelope (see
    /// `LegatoFixtures`), so the largest frame-to-frame step across the slur
    /// boundary is the largest step the envelope took there. A CONTINUED voice
    /// holding at full level takes NO step: the assertion is `== 0` exactly, not
    /// "small".
    ///
    /// ⭐ THE RED CONTROL IS `.mono` ON THE IDENTICAL EVENT LIST — the planted
    /// retrigger, except that nothing is planted: it is the shipped behaviour
    /// this item was filed against. Mono chokes the old voice into its release
    /// (slope 1/2400 per frame) and attacks a new one (step 1/48 per frame), so
    /// the same metric reads about 0.008. An assertion that cannot go red
    /// measures nothing; this one goes red against real, currently-shipping
    /// code, every run.
    @Test("m34-t LEGATO: the envelope does not step across the slur — mono is the red control")
    func legatoContinuesTheEnvelopeAcrossTheSlur() throws {
        let fixtures = try LegatoFixtures.urls()
        // A held from 0; B slurs in over the top at 24 000 — the legato idiom.
        // A's own note-off lands AFTER B started, exactly as written slurs do.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 60_000, pitch: 76, id: 2)
        // Opens 100 frames before the slur and runs 2 000 past it — long enough
        // to contain a 0.001 s attack (48 frames) several times over.
        let window = 23_900..<26_000

        let legato = try lgRender(
            lgSampler(lgParams(fixture: fixtures.dc, voiceMode: .legato)),
            events: events, frames: 72_000)
        let mono = try lgRender(
            lgSampler(lgParams(fixture: fixtures.dc, voiceMode: .mono)),
            events: events, frames: 72_000)

        let legatoStep = lgMaxStep(legato.left, in: window)
        let monoStep = lgMaxStep(mono.left, in: window)
        print("[measured] slur-boundary max frame step: legato \(legatoStep), MONO CONTROL "
              + "\(monoStep); legato level at 23 999 \(legato.left[23_999]) → at 24 001 "
              + "\(legato.left[24_001]); mono \(mono.left[23_999]) → \(mono.left[24_001])")

        #expect(legatoStep == 0,
                """
                the legato slur stepped the envelope by \(legatoStep) — a continued voice must \
                not re-attack, decay, or release at the boundary
                """)
        #expect(monoStep > 0.005,
                """
                control failed: MONO showed no envelope step either (\(monoStep)), so the \
                assertion above is measuring nothing
                """)
        // The same fact stated as a level rather than a derivative: legato holds
        // ONE value across the boundary; mono does not.
        #expect(legato.left[23_999] == legato.left[24_001])
        #expect(mono.left[23_999] != mono.left[24_001])
        // …and the signal is genuinely sounding, not a silent flat line that
        // would satisfy "no step" trivially.
        #expect(legato.left[24_500] > 0.3)
    }

    /// The other half of the same law: a DETACHED note — one arriving with
    /// nothing sounding — DOES attack, with the full ramp, even in legato. The
    /// player re-articulated; the mode must not swallow that.
    @Test("m34-t LEGATO: a DETACHED note still attacks — continuation is not a mute button")
    func legatoDetachedNoteStillAttacks() throws {
        let fixtures = try LegatoFixtures.urls()
        // A ends at 10 000; its 0.05 s release runs out at 12 400. B starts at
        // 20 000, long after — nothing is sounding, so this is a new breath.
        let events = lgNotes(on: 0, off: 10_000, pitch: 69, id: 1)
            + lgNotes(on: 20_000, off: 40_000, pitch: 76, id: 2)
        let out = try lgRender(lgSampler(lgParams(fixture: fixtures.dc, voiceMode: .legato)),
                               events: events, frames: 48_000)
        let silence = TestSignals.peak(out.left, in: 15_000..<19_999)
        let attackStep = lgMaxStep(out.left, in: 19_990..<20_200)
        print("[measured] detached note: pre-onset peak \(silence), onset max step \(attackStep), "
              + "level at 21 000 \(out.left[21_000])")
        #expect(silence < 1e-6, "the first note must be fully gone before the second starts")
        #expect(attackStep > 0.005,
                "a DETACHED note did not attack — legato swallowed a real articulation")
        #expect(out.left[21_000] > 0.3, "the detached note must actually sound")
    }

    /// The slur must reach the NEW PITCH — continuation without retuning would
    /// be a mode that ignores the notes you play, and the envelope gate above
    /// would happily pass it.
    @Test("m34-t LEGATO: the continued voice really does change pitch")
    func legatoSlurCarriesTheNewPitch() throws {
        let fixtures = try LegatoFixtures.urls()
        // 69 → 440 Hz, 81 → 880 Hz. No glide: the pitch steps at 24 000.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 140_000, pitch: 81, id: 2)
        let out = try lgRender(lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato)),
                               events: events, frames: 96_000)
        let before = lgFrequency(out.left, in: 4_800..<23_000)
        let after = lgFrequency(out.left, in: 28_000..<47_200)
        let lowBin = lgGoertzel(out.left[28_000..<47_200], hz: 440)
        let highBin = lgGoertzel(out.left[28_000..<47_200], hz: 880)
        print("[measured] legato slur pitch: before \(before) Hz, after \(after) Hz; "
              + "after-window bins @440 \(lowBin) @880 \(highBin)")
        #expect(abs(before - 440) < 0.5)
        #expect(abs(after - 880) < 1.0,
                "the continued voice did not retune — legato ignored the new pitch")
        #expect(highBin > 20 * lowBin, "the old pitch is still in the signal after the slur")
    }

    // MARK: - 3. The note-off rulings

    /// ⛔ THE LOAD-BEARING CONSEQUENCE OF ADOPTING THE NEW NOTE ID. A continued
    /// voice still carrying the OLD note's id would never match the new note's
    /// note-off, and THE SLURRED NOTE WOULD PLAY FOREVER — a hang, not a
    /// blemish, and one no pitch or envelope assertion in this file would see.
    @Test("m34-t LEGATO: the continued note's OWN note-off ends it")
    func legatoContinuedNoteEndsOnItsOwnNoteOff() throws {
        let fixtures = try LegatoFixtures.urls()
        // A on at 0, B slurs at 24 000, B released at 40 000. A's own off lands
        // at 30 000 — after B started, and therefore superseded.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 40_000, pitch: 81, id: 2)
        let out = try lgRender(lgSampler(lgParams(fixture: fixtures.dc, voiceMode: .legato)),
                               events: events, frames: 96_000)
        // B is sounding right up to its own note-off…
        #expect(out.left[39_000] > 0.3, "the slurred note stopped before its own note-off")
        // …and the 0.05 s release (2 400 frames) has run out by 43 000.
        let after = TestSignals.peak(out.left, in: 44_000..<95_000)
        print("[measured] after the continued note's own note-off: peak \(after) "
              + "(level at 39 000 was \(out.left[39_000]))")
        #expect(after < 1e-6,
                """
                the slurred note never ended — the continued voice did not adopt the new \
                note id, so its note-off matched nothing
                """)
    }

    /// ⛔⛔ THE IN-TREE RULING THIS ITEM WAS FORBIDDEN TO "IMPROVE", NOW PINNED
    /// UNDER LEGATO TOO. A note-off for a note that has already been superseded
    /// is DISCARDED — there is NO fall-back to a note still held underneath.
    ///
    /// A synth-trained implementer reflexively adds last-note fallback while
    /// wiring legato. It must not be added. The overlap that creates the case at
    /// all IS the legato idiom — start B before A ends so the two slur — and in
    /// it A's note-off arrives AFTER B has started. Falling back would fire a
    /// phantom BACKWARDS SLUR to A on every slurred pair in the part, which is
    /// both wrong and the exact thing the writing was trying to express. The
    /// keyboard convention exists so a player can trill by holding a low note
    /// with the other hand; a sax player has one airstream and cannot.
    ///
    /// Two orderings, because they fail differently:
    ///  ① the superseded off arrives WHILE the slurred note sounds — it must not
    ///    disturb it;
    ///  ② the slurred note is released while the earlier key is STILL DOWN — the
    ///    line goes silent and the earlier note does NOT come back.
    @Test("m34-t LEGATO: a superseded note-off is discarded, and there is NO fall-back")
    func legatoDiscardsSupersededNoteOffAndNeverFallsBack() throws {
        let fixtures = try LegatoFixtures.urls()

        // ① A's off at 30 000, after B slurred in at 24 000. B runs to 140 000.
        let ordering1 = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 140_000, pitch: 81, id: 2)
        let out1 = try lgRender(lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato)),
                                events: ordering1, frames: 96_000)
        let late = 40_000..<59_200
        let peak1 = TestSignals.peak(out1.left, in: late)
        print("[measured] ① long after the superseded note-off: peak \(peak1), "
              + "@880 \(lgGoertzel(out1.left[late], hz: 880)), "
              + "@440 \(lgGoertzel(out1.left[late], hz: 440))")
        #expect(peak1 > 0.3, "the slurred note was cut short by the OLDER note's note-off")
        #expect(abs(lgFrequency(out1.left, in: late) - 880) < 1.0)
        // A's pitch really is gone — a fallback would have brought 440 Hz back.
        #expect(lgGoertzel(out1.left[late], hz: 440) < 1e-6,
                "the superseded note came BACK — a last-note fallback was added")

        // ② A held to the very end; B slurs at 24 000 and is released at 40 000
        // while A's key is STILL DOWN. A DELIBERATELY LONG release (0.5 s) keeps
        // a fallback's revived voice audible if one existed.
        let ordering2 = lgNotes(on: 0, off: 190_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 40_000, pitch: 81, id: 2)
        let out2 = try lgRender(
            lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato, release: 0.5)),
            events: ordering2, frames: 144_000)
        // B released at 40 000 + 0.5 s = 64 000; measure well past that.
        let silence = 72_000..<140_000
        let peak2 = TestSignals.peak(out2.left, in: silence)
        let low = lgGoertzel(out2.left[silence], hz: 440)
        print("[measured] ② after the slurred note was released with the earlier key still "
              + "down: peak \(peak2), @440 \(low)")
        #expect(peak2 < 1e-6,
                """
                something is still sounding after the active legato note was released — \
                peak \(peak2)
                """)
        #expect(low < 1e-6, "the held earlier note came BACK: @440 \(low)")
    }

    // MARK: - 4. GLIDE / PORTAMENTO

    /// ⛔ THE GLIDE LANDS. Measured two ways in one render, because "it arrives"
    /// and "it stops" are different claims and only both together mean landed:
    ///  · the post-glide frequency is the TARGET, compared not to a literal but
    ///    to the frequency the same slur reaches with NO glide at all — which
    ///    cancels the estimator's own bias and makes the claim "the glided voice
    ///    ended up at exactly the pitch it would have stepped to";
    ///  · two ADJACENT later windows read the same frequency, which a voice
    ///    still creeping toward its target could not do.
    ///
    /// The negative control is the third measurement: INSIDE the glide the same
    /// estimator reads something clearly different, so the bounds above are not
    /// satisfiable by a glide that never moved.
    @Test("m34-t GLIDE: the pitch lands on the target after glideTime and stops moving")
    func glideLandsOnTheTargetAndStops() throws {
        let fixtures = try LegatoFixtures.urls()
        // 69 → 81 (440 → 880 Hz), slurred at 24 000, glide 1.0 s = 48 000 frames,
        // so the glide ends at 72 000.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 240_000, pitch: 81, id: 2)
        let glided = try lgRender(
            lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato, glideTime: 1.0)),
            events: events, frames: 168_000)
        let stepped = try lgRender(
            lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato)),
            events: events, frames: 168_000)

        let windowA = 76_000..<100_000     // 4 000 frames after the glide ends
        let windowB = 100_000..<124_000    // the next, adjacent window
        let glidedA = lgFrequency(glided.left, in: windowA)
        let glidedB = lgFrequency(glided.left, in: windowB)
        let steppedA = lgFrequency(stepped.left, in: windowA)
        let midGlide = lgFrequency(glided.left, in: 40_000..<52_000)
        print("[measured] glide landing: glided A \(glidedA) Hz, B \(glidedB) Hz; "
              + "no-glide reference A \(steppedA) Hz; mid-glide \(midGlide) Hz")

        // ① It arrives where the STEP would have put it.
        #expect(abs(glidedA - steppedA) < 0.01,
                """
                a 1 s glide did not land on the pitch the same slur steps to: \(glidedA) Hz \
                vs \(steppedA) Hz
                """)
        // ② And it has stopped: two adjacent windows agree.
        #expect(abs(glidedA - glidedB) < 0.01,
                "the pitch is still moving after glideTime elapsed: \(glidedA) → \(glidedB)")
        // ③ CONTROL — the same estimator, inside the glide, reads something else
        // entirely, so ① and ② are not satisfiable by a glide that never ran.
        #expect(abs(midGlide - glidedA) > 100,
                """
                control failed: the mid-glide window reads the same as the landed one \
                (\(midGlide) vs \(glidedA)) — nothing actually slid
                """)
        #expect(midGlide > 440, "the glide is going the wrong way")
        #expect(midGlide < 880)
    }

    /// ⛔ THE DOMAIN CHOICE, MEASURED RATHER THAN DOCUMENTED. The ramp is
    /// GEOMETRIC on the playback increment, i.e. LINEAR IN SEMITONES: halfway
    /// through a 440 → 880 Hz glide the pitch is at the GEOMETRIC mean
    /// 622.25 Hz, not the arithmetic 660 Hz a linear ramp on the increment would
    /// give. That is what makes a slide sound even across the interval, and it
    /// is the only choice under which two glides of the same interval sound
    /// alike wherever on the keyboard they start.
    ///
    /// ⚠️ THE EXPECTED NUMBER IS NOT `sqrt(440 × 880)` FLAT, and pretending it
    /// were would be asserting a slightly wrong thing. The frequency is still
    /// MOVING inside the measurement window, and a zero-crossing count over
    /// [t₀ − w/2, t₀ + w/2] returns the window's MEAN, which for an exponential
    /// sweep is `f(t₀) × sinh(g ln2)/(g ln2)` with `g = w/2T`. The closed form
    /// is written out below and is +0.08 % here — far inside the 6 % that
    /// separates the two hypotheses, and stated rather than absorbed into a
    /// tolerance.
    @Test("m34-t GLIDE: the ramp is exponential (linear in semitones), not linear on the rate")
    func glideRampsInTheLogDomain() throws {
        let fixtures = try LegatoFixtures.urls()
        // Glide 0.5 s = 24 000 frames, starting at 24 000, so the midpoint is
        // frame 36 000. The window is ±2 400 frames (0.1 s) around it.
        let glideSeconds = 0.5
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 240_000, pitch: 81, id: 2)
        let out = try lgRender(
            lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .legato,
                               glideTime: glideSeconds)),
            events: events, frames: 120_000)

        let window = 33_600..<38_400
        let measured = lgFrequency(out.left, in: window)
        // f(t) = 440 × 2^(t/T); the window mean over ±w/2 is f(t₀) × sinh(x)/x
        // with x = (w/2T)·ln2. Here w = 0.1 s, T = 0.5 s ⇒ x = 0.0693.
        let geometricMean = (440.0 * 880.0).squareRoot()          // 622.2540…
        let x = (0.1 / (2 * glideSeconds)) * log(2.0)
        let expected = geometricMean * sinh(x) / x
        let linearMidpoint = (440.0 + 880.0) / 2                  // 660, the rejected law
        print("[measured] glide midpoint: \(measured) Hz; exponential prediction \(expected) Hz "
              + "(geometric mean \(geometricMean), sweep-mean correction "
              + "\(sinh(x) / x)); the LINEAR hypothesis would be \(linearMidpoint) Hz")

        #expect(abs(measured - expected) < 0.01 * expected,
                """
                the glide midpoint is \(measured) Hz, not the exponential prediction \
                \(expected) Hz — the ramp is not linear in semitones
                """)
        // And emphatically NOT the linear-on-the-increment law. Stated
        // separately: "close to 622" and "not 660" are the two halves of the
        // design decision, and a tolerance wide enough to blur them would gate
        // nothing.
        #expect(abs(measured - linearMidpoint) > 0.04 * linearMidpoint,
                "the glide midpoint sits at the LINEAR midpoint — the ramp domain is wrong")
    }

    /// ⛔ GLIDE IN PLAIN `.mono` — the retrigger half, which the roadmap asks for
    /// explicitly because it is how a hardware mono synth does portamento: the
    /// new voice DOES attack (mono is a re-articulation), but its pitch starts
    /// at the PREVIOUS note's and slides to its own.
    ///
    /// Both halves are asserted, because either alone would pass a wrong
    /// implementation: the ATTACK is there (it is not legato), and the pitch
    /// STARTS LOW (it is not a plain retrigger).
    @Test("m34-t GLIDE works in plain MONO too: the new note attacks, but slides from the old pitch")
    func glideWorksInMonoRetrigger() throws {
        let fixtures = try LegatoFixtures.urls()
        // A long glide (2 s = 96 000 frames) so an early window is still close
        // to the origin pitch rather than already halfway up.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 300_000, pitch: 81, id: 2)
        let out = try lgRender(
            lgSampler(lgParams(fixture: fixtures.sine, voiceMode: .mono, glideTime: 2.0)),
            events: events, frames: 216_000)

        // EARLY: past the choked note's 0.05 s release (ends 26 400), while the
        // glide has barely started. 440 × 2^(4000/96000) = 453 Hz at frame 28 000.
        let early = lgFrequency(out.left, in: 27_000..<33_000)
        // LATE: the glide ends at 24 000 + 96 000 = 120 000.
        let late = lgFrequency(out.left, in: 124_000..<160_000)
        print("[measured] MONO glide: early \(early) Hz (origin 440), late \(late) Hz "
              + "(target 880)")
        #expect(abs(early - 440) < abs(early - 880),
                "the retriggered note did not start near the PREVIOUS pitch: \(early) Hz")
        #expect(early < 480, "the glide origin is wrong — \(early) Hz is not near 440")
        #expect(abs(late - 880) < 1.0, "the mono glide never arrived: \(late) Hz")

        // …and it really did RE-ATTACK. Same events on the DC fixture, where the
        // envelope is the signal: mono must step at the boundary (legato does
        // not — that is `legatoContinuesTheEnvelopeAcrossTheSlur`).
        let dc = try lgRender(
            lgSampler(lgParams(fixture: fixtures.dc, voiceMode: .mono, glideTime: 2.0)),
            events: events, frames: 48_000)
        let step = lgMaxStep(dc.left, in: 23_900..<26_000)
        print("[measured] MONO glide still re-attacks: boundary max step \(step)")
        #expect(step > 0.005, "mono with a glide stopped re-attacking — that is legato's job")
    }

    /// A glide of ZERO (and an unset glide) must leave `.legato` a pure step —
    /// the slur is correct at glideTime 0, and that is the half of the feature
    /// that matters most for the sax line this was filed for.
    @Test("m34-t: legato with glideTime 0 renders identically to legato with no glide at all")
    func zeroGlideIsExactlyNoGlide() throws {
        let fixtures = try LegatoFixtures.urls()
        let events = lgGoldenEvents()
        let unset = try lgRender(
            lgSampler(lgParams(fixture: fixtures.short, voiceMode: .legato)),
            events: events, frames: 72_000)
        let zero = try lgRender(
            lgSampler(lgParams(fixture: fixtures.short, voiceMode: .legato, glideTime: 0)),
            events: events, frames: 72_000)
        let unsetHash = lgFnv1a(unset.left, unset.right)
        print("[measured] glide 0 vs unset: 0x\(String(unsetHash, radix: 16, uppercase: true)) "
              + "vs 0x\(String(lgFnv1a(zero.left, zero.right), radix: 16, uppercase: true))")
        #expect(lgFnv1a(zero.left, zero.right) == unsetHash)
        // Control: a NON-zero glide on the same scenario is different, so the
        // equality above is about the value 0 and not about glide being inert.
        let real = try lgRender(
            lgSampler(lgParams(fixture: fixtures.short, voiceMode: .legato, glideTime: 0.3)),
            events: events, frames: 72_000)
        #expect(lgFnv1a(real.left, real.right) != unsetHash,
                "control failed: a 0.3 s glide changed nothing either")
    }

    // MARK: - 5. Glide × pitch bend COMPOSE

    /// ⛔ THE COMPOSITION GATE. Glide ramps `baseIncrement`; bend multiplies on
    /// top (`increment = baseIncrement × bendFactor`). Neither knows about the
    /// other, and the claim is that this makes them compose EXACTLY — a glide
    /// under a held bend lands on the target pitch TRANSPOSED by the bend, and a
    /// bend arriving MID-GLIDE neither resets the slide nor is reset by it.
    ///
    /// Both orderings are rendered, because they fail differently: a glide that
    /// overwrote `increment` instead of `baseIncrement` would pass the first and
    /// fail the second (the mid-glide bend would be erased on the next frame).
    @Test("m34-t: GLIDE and PITCH BEND compose — a glide under a bend lands transposed")
    func glideAndBendCompose() throws {
        let fixtures = try LegatoFixtures.urls()
        // Default bend range 2 semitones; raw 0 is exactly −8192 from centre, so
        // exactly −1 × range = one whole tone down. No rounding in the target.
        let bentTarget = 880.0 * exp2(-2.0 / 12.0)      // 783.9909 Hz
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 240_000, pitch: 81, id: 2)
        let landed = 76_000..<110_000                   // glide (1 s) ends at 72 000
        let params = lgParams(fixture: fixtures.sine, voiceMode: .legato, glideTime: 1.0)

        // ① Bend applied BEFORE the glide starts and held down throughout.
        let early = try lgRender(lgSampler(params),
                                 events: events + [lgBend(at: 100, raw: 0)], frames: 168_000)
        let earlyHz = lgFrequency(early.left, in: landed)

        // ② Bend arriving at 48 000 — squarely INSIDE the glide (24 000-72 000).
        let mid = try lgRender(lgSampler(params),
                               events: events + [lgBend(at: 48_000, raw: 0)], frames: 168_000)
        let midHz = lgFrequency(mid.left, in: landed)

        // ③ CONTROL: the same glide with NO bend must land a whole tone higher,
        // or "transposed" would be indistinguishable from "the bend did nothing".
        let none = try lgRender(lgSampler(params), events: events, frames: 168_000)
        let noneHz = lgFrequency(none.left, in: landed)

        print("[measured] glide × bend: bend-first \(earlyHz) Hz, bend-mid-glide \(midHz) Hz, "
              + "no bend \(noneHz) Hz; expected bent target \(bentTarget) Hz, unbent 880 Hz")
        #expect(abs(noneHz - 880) < 1.0, "the unbent control did not land on the target")
        #expect(abs(earlyHz - bentTarget) < 1.0,
                """
                a glide under a HELD bend did not land on the transposed target: \(earlyHz) Hz \
                vs \(bentTarget) Hz — the two multipliers do not compose
                """)
        #expect(abs(midHz - bentTarget) < 1.0,
                """
                a bend arriving MID-GLIDE was erased by the glide (or erased it): \(midHz) Hz \
                vs \(bentTarget) Hz
                """)
        // The bend genuinely moved the landing point — a whole tone is 12 % of
        // 880 Hz, far outside the 1 Hz bounds above.
        #expect(abs(noneHz - earlyHz) > 50)
    }

    // MARK: - 6. Persistence — the REAL save/open path, RE-RENDERED

    /// ⛔ THE m34-s LESSON, APPLIED PROSPECTIVELY. A setting that does not
    /// survive a save is not a setting, and `SamplerParams` does NOT persist
    /// through its own `Codable` — `SamplerDocument` is the save format. m34-s
    /// found four globals silently dropped from it while a test named
    /// "persistence" stayed green by exercising only the model type.
    ///
    /// So this does not check fields. It SAVES a legato+glide patch, REOPENS it
    /// through the real path, and re-runs the two measurements that define the
    /// feature: the envelope does not step across the slur, and the pitch
    /// slides. A `voiceMode`/`glideTime` lost on save would make both fail.
    @Test("m34-t: a SAVED AND REOPENED legato+glide patch still slurs and still slides")
    func reopenedLegatoAndGlideStillWork() throws {
        let fixtures = try LegatoFixtures.urls()
        let configured = lgParams(fixture: fixtures.dc, voiceMode: .legato, glideTime: 0.5)
        let restored = try lgReopen(configured)
        #expect(restored.voiceMode == .legato,
                "a legato patch that reopens as poly is a different instrument")
        #expect(restored.glideTime == 0.5)

        // ① The slur survives — same DC measurement as the primary gate.
        let events = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 60_000, pitch: 76, id: 2)
        let dc = try lgRender(lgSampler(restored), events: events, frames: 72_000)
        let step = lgMaxStep(dc.left, in: 23_900..<26_000)
        print("[measured] REOPENED legato slur: boundary max step \(step)")
        #expect(step == 0, "the reopened patch re-attacks — voiceMode did not survive the save")
        #expect(dc.left[24_500] > 0.3, "the reopened patch is silent")

        // ② The glide survives — measured on the sine, mid-slide.
        let sineParams = try lgReopen(
            lgParams(fixture: fixtures.sine, voiceMode: .legato, glideTime: 0.5))
        let glideEvents = lgNotes(on: 0, off: 30_000, pitch: 69, id: 1)
            + lgNotes(on: 24_000, off: 240_000, pitch: 81, id: 2)
        let sine = try lgRender(lgSampler(sineParams), events: glideEvents, frames: 120_000)
        let mid = lgFrequency(sine.left, in: 33_600..<38_400)
        let landed = lgFrequency(sine.left, in: 56_000..<80_000)
        print("[measured] REOPENED glide: midpoint \(mid) Hz (≈622 expected), "
              + "landed \(landed) Hz (880 expected)")
        #expect(mid > 500, "the reopened patch stepped instead of sliding — glideTime was lost")
        #expect(mid < 700)
        #expect(abs(landed - 880) < 1.0)
    }

    // MARK: - 7. Model-level contracts

    /// `glideTime` clamps rather than refusing, matching every other field on
    /// `SamplerParams`; nil stays nil so an untouched project round-trips
    /// byte-identically; and the mode/glide conjunction has ONE home.
    @Test("m34-t model: glideTime clamps, nil stays nil, and glideIsEffective needs both halves")
    func glideTimeModelContracts() {
        #expect(SamplerParams().glideTime == nil)
        #expect(SamplerParams().effectiveGlideTime == 0)
        #expect(SamplerParams(glideTime: -3).glideTime == 0)
        #expect(SamplerParams(glideTime: 99).glideTime == SamplerParams.glideTimeRange.upperBound)
        #expect(SamplerParams(glideTime: 0.25).glideTime == 0.25)

        // The conjunction: a glide needs a TIME and a MONOPHONIC mode.
        #expect(!SamplerParams(voiceMode: .poly, glideTime: 0.5).glideIsEffective)
        #expect(!SamplerParams(glideTime: 0.5).glideIsEffective)          // nil ⇒ poly
        #expect(SamplerParams(voiceMode: .mono, glideTime: 0.5).glideIsEffective)
        #expect(SamplerParams(voiceMode: .legato, glideTime: 0.5).glideIsEffective)
        #expect(!SamplerParams(voiceMode: .legato).glideIsEffective)      // no time
        #expect(!SamplerParams(voiceMode: .legato, glideTime: 0).glideIsEffective)

        // The two mode predicates, which the engine branches on.
        #expect(!SamplerVoiceMode.poly.isMonophonic)
        #expect(SamplerVoiceMode.mono.isMonophonic)
        #expect(SamplerVoiceMode.legato.isMonophonic)
        #expect(!SamplerVoiceMode.poly.continuesVoices)
        #expect(!SamplerVoiceMode.mono.continuesVoices)
        #expect(SamplerVoiceMode.legato.continuesVoices)
        // The wire derives its legal-values message from `allCases`; a fourth
        // mode must force this test rather than slide in silently.
        #expect(SamplerVoiceMode.allCases.map(\.rawValue) == ["poly", "mono", "legato"])
    }
}
