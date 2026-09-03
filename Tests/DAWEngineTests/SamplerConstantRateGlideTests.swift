import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m34-w — CONSTANT-RATE GLIDE on the built-in sampler.
//
// ⭐ THE DEFECT THE USER HEARD BEFORE ASKING, in their words: they wanted to
// *"allow range for slideTime"*, and asked to choose between three readings
// picked "speed scales with the leap". Under `.constantTime` every transition
// takes the SAME duration whatever its distance, so a semitone crawls while an
// octave is rushed through at twelve times the speed and stops sounding like
// the same gesture. `.constantRate` bills DISTANCE: `glideTime` buys a whole
// tone, and every other leap is proportional.
//
// ⚠️ AN EXTENSION OF `SamplerTests`, NOT A NEW `@Suite` — the
// `MainActorOccupancySiteTests` Leg C cap on isolated suites has no headroom,
// and the m34-t file next door established this host for exactly these
// measurements. Helpers are file-local free functions because a neighbouring
// file's `private` ones cannot be seen from here; that duplication is the
// established pattern in this directory.
//
// ⭐⭐ EVERY GATE MEASURES RENDERED AUDIO. The duration of a glide is read off
// the WAVEFORM — the time at which the sounding pitch crosses the halfway point
// of the interval — never off `glideRemaining`, `glideCoeff` or a mode flag. A
// test that reads the frame count back cannot tell you the frame count reached
// the sound, and this whole item is one number changing meaning.
//
// ⛔ AND EVERY RATIO GATE CARRIES ITS CONTROL. `.constantTime` renders the SAME
// two intervals and is asserted to make them EQUAL. A gate that passed in both
// modes would be measuring nothing at all.
//
// ⛔ OFFLINE AND DETERMINISTIC ONLY. No wall clock, no live metering.

// MARK: - File-local harness

/// FNV-1a 64 over the raw IEEE bit patterns of every sample, left then right —
/// the m34-t byte-identity instrument, restated because that file's copy is
/// `private` to it.
private func crFnv1a(_ left: [Float], _ right: [Float]) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    func feed(_ bits: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            hash ^= UInt64((bits >> UInt32(shift)) & 0xFF)
            hash &*= 0x1000_0000_01B3
        }
    }
    for sample in left { feed(sample.bitPattern) }
    for sample in right { feed(sample.bitPattern) }
    return hash
}

/// A pure sine fixture at the sampler's own file rate. 440 Hz at root pitch 69,
/// so a rendered note's frequency is `440 × 2^((pitch − 69)/12)` and the pitch
/// during a glide can be read straight off the zero crossings.
private func crWriteSine(to url: URL, seconds: Double) throws {
    let rate = 44_100.0
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = Int(rate * seconds)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let channel = try #require(buffer.floatChannelData)[0]
    for index in 0..<frames {
        channel[index] = Float(0.9 * sin(2.0 * Double.pi * 440.0 * Double(index) / rate))
    }
    try file.write(from: buffer)
}

private enum CRFixture {
    nonisolated(unsafe) static var cached: URL?
    /// 14 s is long enough that the widest, slowest glide measured here (a
    /// 3.0 s slide, played back at 2× rate) never reads off the end of the
    /// file — a voice that ran out of sample would measure silence and pass
    /// nothing.
    static func sine() throws -> URL {
        if let cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-constant-rate-glide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sine440_44k1_mono_14s.wav")
        try crWriteSine(to: url, seconds: 14)
        cached = url
        return url
    }
}

private func crNoteOn(_ sampleTime: Int64, pitch: UInt8, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: 110)
}

private func crNoteOff(_ sampleTime: Int64, pitch: UInt8, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)
}

private func crBend(at sampleTime: Int64, raw: Int, id: UInt64 = 900) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
}

private let crRate = 48_000.0

/// Renders in 512-frame quanta with `MIDISchedule`'s own event order — the
/// m34-t harness, so two abutting notes behave here exactly as they do through
/// the real schedule.
private func crRender(_ instrument: SamplerInstrument,
                      events unsorted: [ScheduledMIDIEvent],
                      frames totalFrames: Int) throws -> [Float] {
    let quantum = 512
    let events = unsorted.sorted { a, b in
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        if rankA != rankB { return rankA < rankB }
        return a.noteID < b.noteID
    }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: crRate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
    let channels = try #require(buffer.floatChannelData)

    var left: [Float] = []
    left.reserveCapacity(totalFrames)
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
        rendered += frames
    }
    return left
}

/// Renders BOTH channels, for the byte-identity gates where the claim is about
/// every rendered bit rather than about pitch.
private func crRenderStereo(_ instrument: SamplerInstrument,
                            events unsorted: [ScheduledMIDIEvent],
                            frames totalFrames: Int) throws -> (left: [Float], right: [Float]) {
    let quantum = 512
    let events = unsorted.sorted { a, b in
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        if rankA != rankB { return rankA < rankB }
        return a.noteID < b.noteID
    }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: crRate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
    let channels = try #require(buffer.floatChannelData)
    var left: [Float] = []
    var right: [Float] = []
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

/// ⭐⭐ THE INSTRUMENT THE WHOLE ITEM IS MEASURED WITH: how long a glide
/// actually LASTED, in seconds, read off the rendered waveform.
///
/// The ramp is geometric, i.e. EXACTLY LINEAR IN log₂(frequency), so the pitch
/// passes the interval's halfway point at exactly half the glide's duration —
/// wherever that halfway point happens to be in Hz. Timing that ONE crossing
/// and doubling it therefore recovers the duration with NO threshold to tune
/// and, critically, NO INTERVAL-DEPENDENT BIAS.
///
/// ⛔ THAT LAST PROPERTY IS WHY IT IS NOT A LANDING DETECTOR. "The pitch is
/// within 0.5 % of target" fires at 91 % of the way through a one-semitone
/// glide and at 99 % of a twelve-semitone one, because the geometric tail is
/// shallower for a narrow interval. A ratio gate built on that would read 13.0
/// where the truth is 12.0 — a systematic error pointing the same way as the
/// hypothesis, which is the worst kind.
///
/// Frequency is estimated from `periods` consecutive positive-going zero
/// crossings (sub-sample linear interpolation) and DATED AT THE MIDPOINT of
/// that span, so the estimator's lag is second-order rather than half a window.
/// The crossing time is then linearly interpolated between the two estimates
/// that straddle the halfway frequency.
///
/// Returns nil when the sweep never reaches its halfway point in the window —
/// which a caller must treat as a failed measurement, never as a zero.
private func crGlideSeconds(_ samples: [Float],
                            from startSample: Int,
                            to endSample: Int,
                            fromHz: Double,
                            toHz: Double,
                            periods: Int = 6) -> Double? {
    // Positive-going zero crossings with linear interpolation for the fraction.
    var crossings: [Double] = []
    crossings.reserveCapacity(4096)
    var index = max(1, startSample)
    let limit = min(endSample, samples.count)
    while index < limit {
        let previous = samples[index - 1]
        let current = samples[index]
        if previous <= 0, current > 0 {
            let fraction = Double(-previous) / Double(current - previous)
            crossings.append(Double(index - 1) + fraction)
        }
        index += 1
    }
    guard crossings.count > periods + 1 else { return nil }

    // log₂ of the halfway frequency — the value whose crossing is timed.
    let halfHz = fromHz * pow(toHz / fromHz, 0.5)
    // Direction: an upward glide crosses from below, a downward one from above.
    let rising = toHz > fromHz

    var previousTime = 0.0
    var previousHz = 0.0
    var have = false
    for k in 0..<(crossings.count - periods) {
        let span = crossings[k + periods] - crossings[k]
        guard span > 0 else { continue }
        let hz = Double(periods) * crRate / span
        let time = (crossings[k] + crossings[k + periods]) / 2.0
        if have {
            let before = rising ? previousHz < halfHz : previousHz > halfHz
            let after = rising ? hz >= halfHz : hz <= halfHz
            if before, after {
                // Linear interpolation on the estimate pair that straddles it.
                let t = (halfHz - previousHz) / (hz - previousHz)
                let crossSample = previousTime + t * (time - previousTime)
                return 2.0 * (crossSample - Double(startSample)) / crRate
            }
        }
        previousTime = time
        previousHz = hz
        have = true
    }
    return nil
}

/// The frequency of a note at `pitch` on a fixture whose root pitch is 69 and
/// whose recorded tone is 440 Hz.
private func crHz(_ pitch: Int) -> Double { 440.0 * pow(2.0, Double(pitch - 69) / 12.0) }

private func crParams(_ fixture: URL,
                      glideTime: Double?,
                      glideMode: SamplerGlideMode?,
                      voiceMode: SamplerVoiceMode? = .legato) -> SamplerParams {
    SamplerParams(zones: [SamplerZone(audioFileURL: fixture, rootPitch: 69)],
                  attack: 0.001, release: 0.05, gain: 0.8,
                  voiceMode: voiceMode, glideTime: glideTime, glideMode: glideMode)
}

private func crSampler(_ params: SamplerParams) -> SamplerInstrument {
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: crRate, maxFramesPerQuantum: 512, channelCount: 2)
    return sampler
}

/// ONE slur: hold pitch 69, then a note-on at `slurAt` on `toPitch` with the
/// first key still down, so `.legato` continues the voice and the pitch slides.
/// Returns the measured glide duration in seconds.
private func crMeasureSlur(fixture: URL,
                           toPitch: Int,
                           glideTime: Double,
                           glideMode: SamplerGlideMode?,
                           slurAt: Int = 4_800,
                           totalFrames: Int,
                           periods: Int = 6) throws -> Double {
    let sampler = crSampler(crParams(fixture, glideTime: glideTime, glideMode: glideMode))
    let events = [
        crNoteOn(0, pitch: 69, id: 1),
        crNoteOn(Int64(slurAt), pitch: UInt8(toPitch), id: 2),
        crNoteOff(Int64(totalFrames - 1), pitch: UInt8(toPitch), id: 2),
    ]
    let rendered = try crRender(sampler, events: events, frames: totalFrames)
    let measured = crGlideSeconds(rendered, from: slurAt, to: totalFrames,
                                  fromHz: crHz(69), toHz: crHz(toPitch), periods: periods)
    return try #require(
        measured,
        """
        the sweep to pitch \(toPitch) never reached its halfway frequency inside the render — \
        the measurement FAILED and must not be read as a duration
        """)
}

extension SamplerTests {

    // MARK: - m34-w · 1. Byte identity (the additive-only gates)

    /// ⛔ HALF ONE OF THE ADDITIVE-ONLY CLAIM: an EXPLICIT `.constantTime`
    /// renders bit-for-bit what an unset mode renders. This is the assertion
    /// that says the default is a real default rather than a new code path that
    /// merely resembles the old one — the whole m34-t golden-hash pair rests on
    /// `nil`, and nothing else in this tree would notice if the two diverged.
    @Test("m34-w: an explicit constantTime renders bit-for-bit like no mode at all")
    func explicitConstantTimeIsByteIdenticalToUnset() throws {
        let fixture = try CRFixture.sine()
        func render(_ mode: SamplerGlideMode?) throws -> (left: [Float], right: [Float]) {
            let sampler = crSampler(crParams(fixture, glideTime: 0.2, glideMode: mode))
            return try crRenderStereo(sampler, events: [
                crNoteOn(0, pitch: 69, id: 1),
                crNoteOn(9_600, pitch: 76, id: 2),
                crNoteOn(24_000, pitch: 72, id: 3),
                crNoteOff(43_000, pitch: 72, id: 3),
            ], frames: 48_000)
        }
        let unset = try render(nil)
        let explicit = try render(.constantTime)
        let unsetHash = crFnv1a(unset.left, unset.right)
        let explicitHash = crFnv1a(explicit.left, explicit.right)
        print("[measured] m34-w mode identity: unset=0x"
              + String(unsetHash, radix: 16, uppercase: true)
              + " constantTime=0x" + String(explicitHash, radix: 16, uppercase: true))

        // CONTROL ON THE INSTRUMENT: the hash must be able to say NO. Without
        // this, a hash that ignored its input would make the line below pass.
        var perturbed = unset.left
        perturbed[20_000] = Float(bitPattern: perturbed[20_000].bitPattern ^ 1)
        #expect(crFnv1a(perturbed, unset.right) != unsetHash,
                "the hash is blind to a one-bit change — this gate proves nothing")

        #expect(explicitHash == unsetHash,
                """
                an explicit glideMode 'constantTime' no longer renders identically to an unset \
                one. The default has moved, and every project on disk sounds different.
                """)

        // ⭐ AND THE SAME CONTROL FROM THE OTHER SIDE: constantRate on the same
        // events MUST differ, or the two assertions above would both pass on an
        // engine that ignored `glideMode` entirely.
        let rate = try render(.constantRate)
        #expect(crFnv1a(rate.left, rate.right) != unsetHash,
                "constantRate renders identically to constantTime — the mode is not reaching the sound")
    }

    /// ⛔ HALF TWO: `.constantRate` with NO GLIDE is not a glide. Scaling zero
    /// by a distance must still be zero, and the pitch must still step.
    @Test("m34-w: constantRate with glideTime 0 renders exactly like no glide at all")
    func constantRateWithoutATimeIsExactlyNoGlide() throws {
        let fixture = try CRFixture.sine()
        func render(_ time: Double?, _ mode: SamplerGlideMode?) throws -> UInt64 {
            let sampler = crSampler(crParams(fixture, glideTime: time, glideMode: mode))
            let out = try crRenderStereo(sampler, events: [
                crNoteOn(0, pitch: 69, id: 1),
                crNoteOn(9_600, pitch: 81, id: 2),
                crNoteOff(40_000, pitch: 81, id: 2),
            ], frames: 48_000)
            return crFnv1a(out.left, out.right)
        }
        let noGlide = try render(nil, nil)
        let zeroRate = try render(0, .constantRate)
        print("[measured] m34-w zero-rate: noGlide=0x" + String(noGlide, radix: 16, uppercase: true)
              + " constantRate@0=0x" + String(zeroRate, radix: 16, uppercase: true))
        #expect(zeroRate == noGlide,
                "constantRate with glideTime 0 invented a slide out of nothing")

        // CONTROL: a real rate-mode glide on the same events must differ, or
        // the equality above is satisfied by an engine that never glides.
        let realGlide = try render(0.3, .constantRate)
        #expect(realGlide != noGlide,
                "control failed: a 0.3 s constantRate glide renders like no glide")
    }

    // MARK: - m34-w · 2. THE GATE: distance sets duration

    /// ⭐⭐⭐ THE GATE THE ITEM EXISTS FOR, AND IT IS A PAIRED MEASUREMENT
    /// RATHER THAN A SINGLE ONE. In `.constantRate` a twelve-semitone leap must
    /// take about TWELVE TIMES as long as a one-semitone leap. In
    /// `.constantTime` — the same engine, the same notes, the same `glideTime`,
    /// one field changed — those two must take the SAME time.
    ///
    /// ⛔ THE CONTROL IS THE POINT. A gate that passed in both modes would be
    /// measuring the harness rather than the feature, and this is precisely the
    /// shape that can silently do that: both modes glide, both land on the
    /// right pitch, and only the DURATIONS differ.
    ///
    /// `glideTime` is 0.5 s here rather than the musical 0.12 so that the
    /// narrow glide (0.25 s at constant rate) is long enough to time to a few
    /// percent; the calibration gate below measures the real musical value.
    @Test("m34-w GATE: in constantRate an octave takes ~12x a semitone — constantTime is the control")
    func distanceSetsDurationOnlyInConstantRate() throws {
        let fixture = try CRFixture.sine()
        let time = 0.5

        // Rate mode: expected 0.5 × 1/2 = 0.25 s and 0.5 × 12/2 = 3.0 s.
        let rateNarrow = try crMeasureSlur(fixture: fixture, toPitch: 70, glideTime: time,
                                           glideMode: .constantRate, totalFrames: 40_000)
        let rateWide = try crMeasureSlur(fixture: fixture, toPitch: 81, glideTime: time,
                                         glideMode: .constantRate, totalFrames: 220_000)
        // Time mode: expected 0.5 s for BOTH.
        let timeNarrow = try crMeasureSlur(fixture: fixture, toPitch: 70, glideTime: time,
                                           glideMode: .constantTime, totalFrames: 60_000)
        let timeWide = try crMeasureSlur(fixture: fixture, toPitch: 81, glideTime: time,
                                         glideMode: .constantTime, totalFrames: 60_000)

        let rateRatio = rateWide / rateNarrow
        let timeRatio = timeWide / timeNarrow
        print(String(format: """
            [measured] m34-w GATE at glideTime %.2f s — \
            constantRate: 1 st %.4f s, 12 st %.4f s, ratio %.3f (expect ~12); \
            CONSTANT-TIME CONTROL: 1 st %.4f s, 12 st %.4f s, ratio %.3f (expect ~1)
            """, time, rateNarrow, rateWide, rateRatio, timeNarrow, timeWide, timeRatio))

        // The absolute durations, each within 8 % — a ratio alone could be
        // right while both halves were wrong by the same factor.
        #expect(abs(rateNarrow - 0.25) < 0.02,
                "a 1-semitone constantRate glide at 0.5 s/whole-tone should last 0.25 s, measured \(rateNarrow)")
        #expect(abs(rateWide - 3.0) < 0.24,
                "a 12-semitone constantRate glide at 0.5 s/whole-tone should last 3.0 s, measured \(rateWide)")

        #expect(rateRatio > 10.5 && rateRatio < 13.5,
                """
                constantRate did not scale duration with distance: an octave took \(rateWide) s \
                and a semitone \(rateNarrow) s, a ratio of \(rateRatio) where ~12 was required.
                """)

        // ⛔ THE CONTROL. If this ALSO showed ~12, the gate above would be
        // measuring the measurement instrument and not the mode.
        #expect(timeRatio > 0.88 && timeRatio < 1.14,
                """
                THE CONTROL FAILED: under constantTime an octave took \(timeWide) s and a \
                semitone \(timeNarrow) s, a ratio of \(timeRatio). Constant TIME must make them \
                equal — if it does not, the ratio gate above proves nothing about the mode.
                """)
        #expect(rateRatio > timeRatio * 8,
                "the two modes are not separated: rate ratio \(rateRatio) vs time ratio \(timeRatio)")
    }

    /// ⭐⭐ THE CALIBRATION GATE, AND IT HAS A REAL DATUM BEHIND IT. The project
    /// owner listened to three renders and approved `glideTime: 0.12` under
    /// CONSTANT TIME, on a phrase (A4–C5–D5–E5–D5–C5–A4) whose slurred
    /// intervals are four whole tones and two minor thirds. The reference
    /// interval was chosen at 2 semitones for exactly one reason: so that
    /// FLIPPING THE MODE KEEPS THE SOUND THEY ALREADY PICKED.
    ///
    /// ⛔ BOTH of the phrase's intervals are asserted, not just the flattering
    /// one. At R = 2 the whole tones land on 0.120 s — the approved number
    /// itself — and the minor thirds on 0.180 s, which is the honest cost of
    /// constant rate and is still unmistakably a slide.
    ///
    /// For contrast, and this is why neither obvious unit was taken: seconds
    /// per OCTAVE would have put these at 0.020 s and 0.030 s, four to six
    /// times faster, which does not read as a slide at all.
    @Test("m34-w CALIBRATION: the user's approved 0.12 still slides a 2-3 semitone slur in ~0.12 s")
    func theApprovedGlideSurvivesTheModeFlip() throws {
        let fixture = try CRFixture.sine()
        let approved = 0.12

        // The two intervals the approved phrase actually contains.
        let wholeTone = try crMeasureSlur(fixture: fixture, toPitch: 71, glideTime: approved,
                                          glideMode: .constantRate, totalFrames: 24_000,
                                          periods: 3)
        let minorThird = try crMeasureSlur(fixture: fixture, toPitch: 72, glideTime: approved,
                                           glideMode: .constantRate, totalFrames: 24_000,
                                           periods: 3)
        // The number they actually approved, for the direct comparison.
        let underConstantTime = try crMeasureSlur(fixture: fixture, toPitch: 71,
                                                  glideTime: approved, glideMode: nil,
                                                  totalFrames: 24_000, periods: 3)
        print(String(format: """
            [measured] m34-w CALIBRATION at the approved glideTime %.2f s — \
            constantRate: whole tone (2 st) %.4f s, minor third (3 st) %.4f s; \
            the approved constantTime rendering of the same whole tone: %.4f s. \
            Seconds-per-octave would have given %.4f s / %.4f s.
            """, approved, wholeTone, minorThird, underConstantTime,
            approved * 2 / 12, approved * 3 / 12))

        #expect(abs(wholeTone - 0.12) < 0.015,
                """
                a WHOLE TONE at glideTime 0.12 in constantRate lasted \(wholeTone) s, not ~0.12. \
                The reference interval is 2 semitones precisely so the user's approved sound \
                survives the mode flip; if this moved, it did not.
                """)
        #expect(abs(minorThird - 0.18) < 0.02,
                "a MINOR THIRD at glideTime 0.12 in constantRate lasted \(minorThird) s, not ~0.18")

        // The two intervals of one phrase must stay in the same neighbourhood —
        // that is what "the sound they picked survives" means in one number.
        #expect(minorThird / wholeTone > 1.3 && minorThird / wholeTone < 1.7,
                "a minor third must cost 1.5x a whole tone, measured \(minorThird / wholeTone)")

        // CONTROL: the same interval under the mode they actually approved must
        // measure the same 0.12 — if the harness could not reproduce THAT, the
        // assertions above would be measuring the harness.
        #expect(abs(underConstantTime - 0.12) < 0.015,
                "control failed: the approved constantTime glide measures \(underConstantTime), not 0.12")

        // ⛔ AND THE REJECTED UNIT, MADE FALSIFIABLE. Seconds-per-octave would
        // have produced 0.02 s here. Asserting the measurement is NOT that is
        // what stops a future refactor quietly changing the reference interval.
        #expect(wholeTone > 4 * (approved * 2 / 12),
                """
                a whole tone measured \(wholeTone) s, which is the SECONDS-PER-OCTAVE answer \
                (\(approved * 2 / 12) s), not the seconds-per-whole-tone one. The rate unit has \
                changed and the user's approved sound has been discarded.
                """)
    }

    /// A DOWNWARD leap must cost what the upward one costs. The reference is a
    /// distance, and distance has no sign — a phrase that turns around would
    /// otherwise slur unevenly on the way back down, which is exactly the
    /// asymmetry the geometric ramp was chosen to avoid in the first place.
    @Test("m34-w: a downward leap takes as long as the same leap upward")
    func downwardLeapsCostTheSame() throws {
        let fixture = try CRFixture.sine()
        let up = try crMeasureSlur(fixture: fixture, toPitch: 76, glideTime: 0.4,
                                   glideMode: .constantRate, totalFrames: 130_000)

        // Down: start on 76 and slur to 69 — the same 7 semitones, reversed.
        let sampler = crSampler(crParams(fixture, glideTime: 0.4, glideMode: .constantRate))
        let events = [
            crNoteOn(0, pitch: 76, id: 1),
            crNoteOn(4_800, pitch: 69, id: 2),
            crNoteOff(129_999, pitch: 69, id: 2),
        ]
        let rendered = try crRender(sampler, events: events, frames: 130_000)
        let down = try #require(
            crGlideSeconds(rendered, from: 4_800, to: 130_000,
                           fromHz: crHz(76), toHz: crHz(69)),
            "the downward sweep never reached its halfway frequency")

        print(String(format: "[measured] m34-w direction: up (69→76) %.4f s, down (76→69) %.4f s;"
                     + " expected %.4f s both", up, down, 0.4 * 7 / 2))
        #expect(abs(up - 1.4) < 0.12, "7 semitones at 0.4 s/whole-tone should last 1.4 s, up measured \(up)")
        #expect(abs(down - 1.4) < 0.12, "…and down measured \(down)")
        #expect(abs(up - down) < 0.14, "the same interval costs different times by direction")
    }

    // MARK: - m34-w · 3. It composes with everything m34-t shipped

    /// GATE 4: bend still composes with glide, in the NEW mode. The ramp walks
    /// `baseIncrement` and bend multiplies on top, so neither knows about the
    /// other — but `glideFrameCount` is new arithmetic on the arming path and
    /// "the glide is now bent" is a failure no other gate here would see.
    @Test("m34-w: GLIDE and PITCH BEND still compose under constantRate")
    func bendComposesWithConstantRateGlide() throws {
        let fixture = try CRFixture.sine()
        // +1 semitone of bend at the default ±2 range: raw 8192 + 4096.
        let bentUp = 8_192 + 4_096
        let sampler = crSampler(crParams(fixture, glideTime: 0.3, glideMode: .constantRate))
        let events = [
            crBend(at: 0, raw: bentUp),
            crNoteOn(0, pitch: 69, id: 1),
            crNoteOn(4_800, pitch: 76, id: 2),
            crNoteOff(190_000, pitch: 76, id: 2),
        ]
        let rendered = try crRender(sampler, events: events, frames: 192_000)

        // Under a constant +1 semitone bend the whole sweep is transposed, so
        // the glide runs 466.16 → 659.26 Hz and must still take 7 × 0.3 / 2 s.
        let bentFrom = crHz(69) * pow(2.0, 1.0 / 12.0)
        let bentTo = crHz(76) * pow(2.0, 1.0 / 12.0)
        let duration = try #require(
            crGlideSeconds(rendered, from: 4_800, to: 192_000, fromHz: bentFrom, toHz: bentTo),
            "the bent sweep never reached its halfway frequency")

        // And it must LAND transposed, not at the unbent target.
        let landed = TestSignals.dominantFrequency(
            byZeroCrossings: rendered, sampleRate: crRate, in: 160_000..<180_000)
        print(String(format: """
            [measured] m34-w bend × rate glide: duration %.4f s (expected %.4f s); \
            landed %.2f Hz, bent target %.2f Hz, UNBENT target %.2f Hz
            """, duration, 0.3 * 7 / 2, landed, bentTo, crHz(76)))

        #expect(abs(duration - 1.05) < 0.10,
                "a bent 7-semitone constantRate glide should still last 1.05 s, measured \(duration)")
        #expect(abs(landed - bentTo) / bentTo < 0.01,
                "the glide did not land on the BENT target \(bentTo) Hz — measured \(landed) Hz")
        #expect(abs(landed - crHz(76)) / crHz(76) > 0.02,
                "control failed: the bend did nothing, so 'landed transposed' is unfalsifiable here")
    }

    /// PLAIN MONO, not just legato. The two arming sites are different code —
    /// one derives the interval from an increment RATIO, the other from two
    /// MIDI note numbers — and only one of them is exercised by every gate
    /// above. A mode that reached the slur but not the retrigger would leave
    /// half the feature silently on the old behaviour.
    @Test("m34-w: constant-rate glide reaches the plain MONO retrigger path too")
    func constantRateReachesTheMonoRetriggerPath() throws {
        let fixture = try CRFixture.sine()
        func measure(_ mode: SamplerGlideMode) throws -> Double {
            let sampler = crSampler(SamplerParams(
                zones: [SamplerZone(audioFileURL: fixture, rootPitch: 69)],
                attack: 0.001, release: 0.05, gain: 0.8,
                voiceMode: .mono, glideTime: 0.4, glideMode: mode))
            // Mono RE-ATTACKS, so the old note is released and a new voice
            // starts at the old pitch. Give the attack room before measuring.
            let events = [
                crNoteOn(0, pitch: 69, id: 1),
                crNoteOff(9_600, pitch: 69, id: 1),
                crNoteOn(9_600, pitch: 81, id: 2),
                crNoteOff(180_000, pitch: 81, id: 2),
            ]
            let rendered = try crRender(sampler, events: events, frames: 192_000)
            return try #require(
                crGlideSeconds(rendered, from: 10_400, to: 192_000,
                               fromHz: crHz(69), toHz: crHz(81)),
                "the mono sweep never reached its halfway frequency in \(mode.rawValue)")
        }
        let rate = try measure(.constantRate)
        let flat = try measure(.constantTime)
        print(String(format: """
            [measured] m34-w MONO retrigger: constantRate %.4f s (expected ~2.4), \
            constantTime %.4f s (expected ~0.4)
            """, rate, flat))
        // 12 semitones at 0.4 s per whole tone = 2.4 s. The measurement starts
        // 600 frames after the note-on (past the attack), so it reads slightly
        // short of the true duration; the bound accommodates that offset.
        #expect(rate > 2.2 && rate < 2.6,
                "a 12-semitone MONO constantRate glide should last ~2.4 s, measured \(rate)")
        #expect(flat > 0.33 && flat < 0.45,
                "control: the SAME leap under constantTime must still last ~0.4 s, measured \(flat)")
        #expect(rate > flat * 4,
                "the mono retrigger path ignored glideMode: \(rate) vs \(flat)")
    }

    // MARK: - m34-w · 4. It survives the real save/open path

    /// A mode that does not survive a save is not a setting — the m34-s lesson,
    /// and this asserts it on the SOUND rather than on the decoded struct.
    @Test("m34-w: a SAVED AND REOPENED constantRate patch still scales with distance")
    func reopenedConstantRateStillScales() throws {
        let fixture = try CRFixture.sine()
        let params = crParams(fixture, glideTime: 0.4, glideMode: .constantRate)
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
        #expect(restored.glideMode == .constantRate,
                "glideMode did not survive the real save/open path")

        let sampler = crSampler(restored)
        let events = [
            crNoteOn(0, pitch: 69, id: 1),
            crNoteOn(4_800, pitch: 81, id: 2),
            crNoteOff(190_000, pitch: 81, id: 2),
        ]
        let rendered = try crRender(sampler, events: events, frames: 192_000)
        let duration = try #require(
            crGlideSeconds(rendered, from: 4_800, to: 192_000,
                           fromHz: crHz(69), toHz: crHz(81)),
            "the reopened sweep never reached its halfway frequency")
        print(String(format: "[measured] m34-w REOPENED: 12 st at 0.4 s/whole-tone = %.4f s"
                     + " (expected 2.4; a constantTime reopen would give 0.4)", duration))
        #expect(duration > 2.2 && duration < 2.6,
                """
                a reopened constantRate patch glided for \(duration) s where 2.4 was required. \
                0.4 would mean the mode was silently dropped on save and the patch fell back to \
                constant time — the m34-s failure shape.
                """)
    }

    // MARK: - m34-w · 5. The model's own law

    /// The one home for the rule, asserted directly — cheap, and it is what the
    /// prose in `SKILL.md`, the wire's warning and the engine all quote.
    @Test("m34-w model: glideDuration scales by distance in rate mode and ignores it in time mode")
    func glideDurationContracts() {
        let flat = SamplerParams(voiceMode: .legato, glideTime: 0.12)
        #expect(flat.effectiveGlideMode == .constantTime, "nil must resolve to constantTime")
        #expect(flat.glideDuration(forSemitones: 1) == 0.12)
        #expect(flat.glideDuration(forSemitones: 12) == 0.12)
        #expect(flat.glideDuration(forSemitones: 0) == 0.12)

        let rate = SamplerParams(voiceMode: .legato, glideTime: 0.12, glideMode: .constantRate)
        #expect(rate.effectiveGlideMode == .constantRate)
        #expect(SamplerParams.glideRateReferenceSemitones == 2.0,
                "the reference interval IS the calibration — 0.12 s per whole tone")
        // The user's approved phrase, in numbers.
        #expect(abs(rate.glideDuration(forSemitones: 2) - 0.12) < 1e-12)
        #expect(abs(rate.glideDuration(forSemitones: 3) - 0.18) < 1e-12)
        #expect(abs(rate.glideDuration(forSemitones: 12) - 0.72) < 1e-12)
        // Sign-free.
        #expect(rate.glideDuration(forSemitones: -12) == rate.glideDuration(forSemitones: 12))
        // Clamped to the MIDI gamut, so no ratio can ask for an unbounded ramp.
        #expect(rate.glideDuration(forSemitones: 5_000)
                == rate.glideDuration(forSemitones: SamplerParams.glideMaxIntervalSemitones))
        #expect(rate.glideDuration(forSemitones: .nan) == 0.12,
                "a non-finite interval must fall back to the flat time, never to NaN frames")

        // MODE IS ORTHOGONAL TO EFFECTIVENESS — a rate-mode glide is neither
        // more nor less audible than a flat one, and folding the mode into
        // `glideIsEffective` would make a statement about the mode masquerade
        // as a statement about whether anything will be heard.
        #expect(rate.glideIsEffective)
        #expect(!SamplerParams(voiceMode: .poly, glideTime: 0.12,
                              glideMode: .constantRate).glideIsEffective)
        #expect(!SamplerParams(voiceMode: .legato, glideTime: 0,
                              glideMode: .constantRate).glideIsEffective)
        // nil stays nil, so an untouched project's JSON is unchanged.
        #expect(SamplerParams().glideMode == nil)
    }
}
