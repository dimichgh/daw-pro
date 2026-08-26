import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m30-a: the Sampler, smoke-tested with NO external content.
//
// ⛔ THE POINT OF THIS FILE, and the only thing it claims that
// `SamplerBendRangeVoiceModeTests` does not: every scenario here mounts a
// sample the REPO SHIPS, resolved BY NAME through `BundledSamples`, with no
// fixture written to a temp directory and no path known to the test. That
// file proves the bend-range and voice-mode features are correct against
// hand-built content; this one proves they are REACHABLE by someone who has
// none. Before m30-a, a fresh project could not make the Sampler produce a
// single sound, so a first-time caller's experience of any sampler feature was
// silence — which is indistinguishable from the feature being broken.
//
// ⚠️ A FREE SUITE, no `@MainActor`, deliberately: `MainActorOccupancySiteTests`
// caps `@MainActor`-isolated suites at 330 and the tree sits exactly on it
// (m23-aw-4). Nothing here needs the main actor — `SamplerInstrument.render`
// is the render path, which touches no actors by law.
//
// ⚠️ Pitch is measured by AUTOCORRELATION, not by `TestSignals`'
// `dominantFrequency(byZeroCrossings:)`, and that is a consequence of the
// sample's design: the bundled one-shot deliberately carries two harmonics so
// a human smoke test hears a NOTE rather than a test tone, and a zero-crossing
// estimator's own doc says it assumes a single steady tone.

// MARK: - File-local harness

/// Renders in 512-frame quanta, replicating `InstrumentRenderer`'s slicing.
/// (Restated here rather than reused: the equivalents in `SamplerTests` and
/// `SamplerBendRangeVoiceModeTests` are `private` to their own files.)
private func renderQuanta(_ instrument: SamplerInstrument,
                          events unsorted: [ScheduledMIDIEvent],
                          frames totalFrames: Int,
                          sampleRate: Double = 48_000,
                          quantum: Int = 512) throws -> [Float] {
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
    left.reserveCapacity(totalFrames)
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
        rendered += frames
    }
    return left
}

/// Goertzel magnitude at exactly `hz`. Absolute scale is arbitrary; only ratios
/// between bins of the same window are ever compared.
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

/// Fundamental frequency by autocorrelation peak with parabolic interpolation,
/// searched over 100...1500 Hz. Unlike zero-crossing counting this reports the
/// PERIOD, so a waveform carrying harmonics still reads as its fundamental —
/// which the bundled sample deliberately does.
private func autocorrelationFrequency(_ samples: ArraySlice<Float>,
                                      sampleRate: Double = 48_000,
                                      low: Double = 100, high: Double = 1_500) -> Double {
    let x = Array(samples).map(Double.init)
    let minLag = Int(sampleRate / high)
    let maxLag = min(Int(sampleRate / low), x.count - 2)
    guard maxLag > minLag + 1 else { return 0 }
    func correlate(_ lag: Int) -> Double {
        var sum = 0.0
        for i in 0..<(x.count - lag) { sum += x[i] * x[i + lag] }
        return sum
    }
    var bestLag = minLag
    var bestValue = -Double.infinity
    for lag in minLag...maxLag {
        let value = correlate(lag)
        if value > bestValue {
            bestValue = value
            bestLag = lag
        }
    }
    guard bestLag > minLag, bestLag < maxLag else { return sampleRate / Double(bestLag) }
    let y0 = correlate(bestLag - 1)
    let y1 = bestValue
    let y2 = correlate(bestLag + 1)
    let denominator = y0 - 2 * y1 + y2
    let delta = denominator == 0 ? 0 : 0.5 * (y0 - y2) / denominator
    return sampleRate / (Double(bestLag) + delta)
}

private func cents(_ measured: Double, from expected: Double) -> Double {
    1_200.0 * log2(measured / expected)
}

private func noteEvents(on: Int64, off: Int64, pitch: UInt8, id: UInt64) -> [ScheduledMIDIEvent] {
    [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                        kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: 110),
     ScheduledMIDIEvent(sampleTime: off, noteID: id,
                        kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
}

private func bendEvent(at sampleTime: Int64, raw: Int, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id,
                       kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
}

private func makeSampler(_ params: SamplerParams) -> SamplerInstrument {
    let sampler = SamplerInstrument(params: params, randomSeed: 0xD1CE_5EED)
    sampler.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
    return sampler
}

/// A one-zone sampler built ENTIRELY from the catalog: the URL comes from
/// `BundledSamples.resolve`, and the root pitch from the same entry rather than
/// from a number typed into this file. If the shipped facts and the shipped
/// bytes ever disagree, these tests are what says so.
private func bundledParams(_ entry: BundledSamples.Entry,
                           bendRange: Double? = nil,
                           voiceMode: SamplerVoiceMode? = nil,
                           release: Double = 0.01) throws -> SamplerParams {
    let url = try BundledSamples.resolve(entry.wireName)
    return SamplerParams(
        zones: [SamplerZone(audioFileURL: url, rootPitch: entry.rootPitch)],
        attack: 0.001, release: release, gain: 0.9,
        bendRangeSemitones: bendRange, voiceMode: voiceMode)
}

private func requireTestTone() throws -> BundledSamples.Entry {
    try #require(BundledSamples.entry(named: "builtin:test-tone-a4"),
                 "the bundled test tone is missing from the catalog")
}

@Suite("Bundled sample — the Sampler is self-testable with no external content (m30-a)")
struct BundledSampleSmokeTests {

    // MARK: - 1. The sample exists, and it SOUNDS at its documented root pitch

    /// ⛔ THE GATE THE ITEM TURNS ON. Resolve by NAME, mount at the root pitch
    /// the catalog states, play that note, and read the pitch back off the
    /// rendered waveform. Nothing here knows a filesystem path, so this is
    /// exactly the sequence available to an agent on a machine with no sample
    /// library — and if the bundled file is missing from the build, or the
    /// catalog's root pitch does not match the bytes, this goes red.
    @Test("resolves by name and sounds at the documented root pitch")
    func bundledToneSoundsAtItsRootPitch() throws {
        let entry = try requireTestTone()
        let url = try BundledSamples.resolve(entry.wireName)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "resolved to \(url.path), which is not there")
        #expect(url.path.hasPrefix("/"), "a resolved bundled sample must be an absolute path")

        let out = try renderQuanta(makeSampler(try bundledParams(entry)),
                                   events: noteEvents(on: 0, off: 40_000,
                                                      pitch: UInt8(entry.rootPitch), id: 1),
                                   frames: 16_000)
        // 0.05 s ... 0.25 s: past the attack, inside the file (0.35 s).
        let window = 2_400..<12_000
        let measured = autocorrelationFrequency(out[window])
        let error = cents(measured, from: entry.frequencyHz)
        let peak = out.map(abs).max() ?? 0
        print("[measured] bundled tone at root pitch \(entry.rootPitch): \(measured) Hz "
              + "(catalog says \(entry.frequencyHz) Hz, \(error) cents), peak \(peak), "
              + "resolved \(url.path)")

        // AUDIBLE, not merely present — a smoke test a human runs has to make
        // a sound, and a floor of 0.05 is ~ -26 dBFS.
        #expect(peak > 0.05, "the bundled sample rendered at peak \(peak) — inaudible")
        #expect(abs(error) < 25, """
            the bundled sample does not sound at its documented root pitch: \
            \(measured) Hz vs \(entry.frequencyHz) Hz (\(error) cents). Either the wav was \
            regenerated with a different recipe or the catalog's rootPitch is wrong.
            """)
        // Second, independent instrument on the same window: the fundamental is
        // the strongest partial. ⚠️ The margins are ASYMMETRIC and that is the
        // sample's design showing through, not a fudge — the octave BELOW is
        // empty (nothing generated it), while the octave ABOVE is the wav's own
        // 2nd harmonic at coefficient 0.30. MEASURED here: 0.1236 vs 0.0370, a
        // 3.3x margin, so a 2x floor is a real gate and a 4x floor would be
        // asserting the sample has no harmonics — which would fail the moment
        // anyone made it audible.
        let fundamental = goertzel(out[window], hz: entry.frequencyHz)
        let subOctave = goertzel(out[window], hz: entry.frequencyHz / 2)
        let secondHarmonic = goertzel(out[window], hz: entry.frequencyHz * 2)
        print("[measured] partials: @\(entry.frequencyHz / 2) \(subOctave), "
              + "@\(entry.frequencyHz) \(fundamental), @\(entry.frequencyHz * 2) "
              + "\(secondHarmonic)")
        #expect(fundamental > 4 * subOctave)
        #expect(fundamental > 2 * secondHarmonic)
    }

    /// The catalog is a set of CLAIMS about bytes it does not own. Check the
    /// two that a re-generated wav could silently invalidate.
    @Test("the catalog's stated frames/rate/size match the file that shipped")
    func catalogMatchesTheShippedFile() throws {
        let entry = try requireTestTone()
        let url = try BundledSamples.resolve(entry.wireName)
        let file = try AVAudioFile(forReading: url)
        let size = try #require((try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.intValue })
        print("[measured] shipped file: \(file.length) frames @ \(file.fileFormat.sampleRate) Hz, "
              + "\(file.fileFormat.channelCount) ch, \(size) bytes")
        #expect(file.length == Int64(entry.frames))
        #expect(file.fileFormat.sampleRate == entry.sampleRate)
        #expect(Int(file.fileFormat.channelCount) == entry.channels)
        // Small enough to live in the repo without anyone thinking about it.
        #expect(size < 64 * 1024, "the bundled sample has grown to \(size) bytes")

        // A name nobody shipped must FAIL, and say what it could have said —
        // the alternative is a nonsense URL and a silent track.
        #expect(throws: (any Error).self) { try BundledSamples.resolve("builtin:nope") }
        #expect(BundledSamples.isBundledName("builtin:anything"))
        #expect(!BundledSamples.isBundledName("/Users/someone/kick.wav"))
        #expect(BundledSamples.available().contains { $0.wireName == entry.wireName })
    }

    // MARK: - 2. The two m29 features, off the bundled content ALONE

    /// bend range 12 + a full DOWNWARD deflection = exactly one octave, because
    /// raw 0 is exactly −8192 from centre. 440 → 220.000 Hz with no rounding in
    /// the expectation at all. (`SamplerBendRangeVoiceModeTests` proves the
    /// feature; what is proved HERE is that it is reachable with no content of
    /// your own.)
    @Test("bend range 12 on the bundled sample lands a full bend an octave down")
    func bendRangeTwelveOffTheBundledSample() throws {
        let entry = try requireTestTone()
        var events = noteEvents(on: 0, off: 60_000, pitch: UInt8(entry.rootPitch), id: 1)
        events.append(bendEvent(at: 100, raw: 0, id: 900))

        // At half speed the 0.35 s one-shot lasts 0.70 s, so a late window is
        // still inside the file.
        let out = try renderQuanta(makeSampler(try bundledParams(entry, bendRange: 12)),
                                   events: events, frames: 30_000)
        let window = 4_800..<24_000
        let expected = entry.frequencyHz / 2
        let measured = autocorrelationFrequency(out[window])
        let error = cents(measured, from: expected)
        print("[measured] bundled tone, bendRange 12, raw 0: \(measured) Hz "
              + "(expected \(expected) Hz, \(error) cents)")
        #expect(abs(error) < 25, """
            full bend at range 12 landed \(measured) Hz, expected \(expected) Hz \
            (\(error) cents)
            """)
        // ⚠️ "Is 220 louder than 440?" is NOT the control here, and getting
        // that wrong is easy: bent down an octave the sample's own 2nd harmonic
        // lands ON 440, so that comparison would be measuring the bent note
        // against itself. The honest control is the SAME schedule with no bend
        // event at all — the unbent render has no energy at 220 whatsoever,
        // because its partials are 440/880/1320.
        let unbent = try renderQuanta(makeSampler(try bundledParams(entry, bendRange: 12)),
                                      events: noteEvents(on: 0, off: 60_000,
                                                         pitch: UInt8(entry.rootPitch), id: 1),
                                      frames: 30_000)
        let bentEnergy = goertzel(out[window], hz: expected)
        let unbentEnergy = goertzel(unbent[window], hz: expected)
        print("[measured] energy @\(expected) Hz: bent \(bentEnergy), unbent control "
              + "\(unbentEnergy)")
        #expect(bentEnergy > 10 * unbentEnergy,
                "no new energy appeared an octave down — the bend did not take")
    }

    /// mono voice mode: a second note takes the airstream, and the superseded
    /// note's energy COLLAPSES. Measured as a RATIO against a poly render of the
    /// identical schedule, because "gone" and "masked by a louder neighbour"
    /// look the same to any absolute floor — and that distinction is the entire
    /// feature.
    ///
    /// ⚠️ The second note is +6 semitones, NOT +12. An octave would put the new
    /// note's fundamental exactly on the old note's 2nd harmonic and its own
    /// harmonics on the bin being measured, so the "collapse" number would be
    /// measuring the new note.
    @Test("mono voice mode: the superseded note COLLAPSES, measured against a poly control")
    func monoTakeoverCollapsesTheSupersededNoteOffTheBundledSample() throws {
        let entry = try requireTestTone()
        let root = UInt8(entry.rootPitch)
        let overlapping = UInt8(entry.rootPitch + 6)          // 440 → 622.25 Hz
        let events = noteEvents(on: 0, off: 60_000, pitch: root, id: 1)
            + noteEvents(on: 3_000, off: 60_000, pitch: overlapping, id: 2)
        // Opens well after the 0.01 s release has run out (480 frames from the
        // takeover at 3,000) and closes inside the shorter, faster-playing
        // second note.
        let window = 5_000..<13_000
        let newPitch = entry.frequencyHz * exp2(6.0 / 12.0)

        let poly = try renderQuanta(makeSampler(try bundledParams(entry)),
                                    events: events, frames: 16_000)
        let polyOld = goertzel(poly[window], hz: entry.frequencyHz)
        let polyNew = goertzel(poly[window], hz: newPitch)
        print("[measured] POLY control: @\(entry.frequencyHz) \(polyOld), @\(newPitch) \(polyNew)")
        #expect(polyOld > 0.002, "the poly control must still be sounding the OLD note")
        #expect(polyNew > 0.002, "the poly control must also be sounding the NEW note")

        let mono = try renderQuanta(makeSampler(try bundledParams(entry, voiceMode: .mono)),
                                    events: events, frames: 16_000)
        let monoOld = goertzel(mono[window], hz: entry.frequencyHz)
        let monoNew = goertzel(mono[window], hz: newPitch)
        let collapse = monoOld > 0 ? polyOld / monoOld : .infinity
        print("[measured] MONO: @\(entry.frequencyHz) \(monoOld), @\(newPitch) \(monoNew) "
              + "— superseded-note collapse \(collapse)x vs the poly control")

        #expect(monoNew > 0.002, "mono lost the NEW note as well — that is not a takeover")
        #expect(collapse > 20, """
            mono left the superseded note sounding: @\(entry.frequencyHz) was \(monoOld) vs the \
            poly control's \(polyOld) — a \(collapse)x collapse, and 'gone' should be far more \
            than 'quieter'
            """)
    }
}
