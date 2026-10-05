import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m27-b ANTI-DRIFT PIN — ties `MIDIControllerRouting` (DAWCore's ONE table of
// "does this controller reach the sound?") to what the ENGINE actually does.
//
// ⭐ WHY THIS SUITE EXISTS, and why the DAWCore suite is not enough:
// `MIDIControllerRouting` lives in DAWCore, which cannot import DAWEngine, so
// it MIRRORS the engine's branches rather than reading them. A mirror rots
// silently — and a wrong
// honoured-set is exactly the false confidence m27-b exists to remove, since it
// would make `track.setInstrument` confidently warn about the wrong thing (or
// confidently stay silent). So each claim is checked against RENDERED AUDIO:
// send the controller mid-note, and assert the output differs from the
// no-controller render IF AND ONLY IF the table says the controller is
// honoured. Drift in either direction reddens.
//
// ⛔ DELIBERATELY NOT COVERED: `.audioUnit` / `.soundBank`. Two reasons, both
// substantive rather than convenience. (1) "Honoured" for the hosted kinds
// means FORWARDED, and `HostedAUInstrument`'s event switch re-emits every CC as
// raw 0xB0 with no filter — there is no per-controller branch that CAN drift,
// and the byte translation itself is already pinned by
// MIDIControllerInstrumentTests' `hostedAUByteTranslation`. (2) What the loaded
// plug-in then does with CC 11 is the plug-in's business, so a render-diff
// assertion would be testing Apple's AUSampler, and it would ride the known
// AUPrepare load flake. The table's claim for those kinds is a claim about
// FORWARDING, and forwarding is pinned where it happens.
//
// 48 kHz throughout, matching the MIDIControllerInstrumentTests harness.

private let pinRate = 48_000.0

private func pinNoteOn(_ t: Int64, pitch: UInt8, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.noteOn,
                       pitch: pitch, velocity: 100)
}

private func pinNoteOff(_ t: Int64, pitch: UInt8, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.noteOff,
                       pitch: pitch, velocity: 0)
}

private func pinCC(_ t: Int64, controller: UInt8, value: UInt8, id: UInt64)
    -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.controlChange,
                       pitch: controller, velocity: value)
}

private func pinBend(_ t: Int64, value: Int, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(value & 0x7F), velocity: UInt8((value >> 7) & 0x7F))
}

@MainActor
@Suite("Honoured-controller table matches the engine (m27-b)", .serialized)
struct InstrumentControllerHonorPinTests {

    /// The `MIDIControllerInstrumentTests.renderDirect` idiom: 512-frame
    /// quanta, canonical event order, channel 0 returned.
    private func renderDirect(_ instrument: any InstrumentRendering,
                              events unsorted: [ScheduledMIDIEvent],
                              frames totalFrames: Int) throws -> [Float] {
        let events = unsorted.sorted(by: MIDIEventSchedule.orderedBefore)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: pinRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)

        var out: [Float] = []
        out.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(512, totalFrames - rendered)
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
            out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            rendered += frames
        }
        return out
    }

    /// Peak absolute difference between the controller render and the
    /// controller-free render of the SAME notes. Above the float-noise floor
    /// means the instrument acted on it.
    private func peakDifference(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var peak: Float = 0
        for index in 0..<a.count { peak = max(peak, abs(a[index] - b[index])) }
        return peak
    }

    private func makePolySynth() -> PolySynthInstrument {
        let synth = PolySynthInstrument(params: PolySynthParams(
            waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.2,
            cutoffHz: 18_000, resonance: 0, gain: 1.0))
        synth.prepare(sampleRate: pinRate, maxFramesPerQuantum: 512, channelCount: 2)
        return synth
    }

    private func makeSampler(_ params: SamplerParams) throws -> SamplerInstrument {
        let sampler = SamplerInstrument(params: params, sampleRate: pinRate)
        sampler.prepare(sampleRate: pinRate, maxFramesPerQuantum: 512, channelCount: 2)
        return sampler
    }

    private func sustainedSamplerParams(expressionModDepth: Double? = nil) throws
        -> SamplerParams {
        let fixtures = try TestSignals.fixtures()
        return SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.cos1k48,
                                rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 1)],
            oneShot: false, attack: 0.001, release: 0.05, gain: 1.0,
            expressionModDepth: expressionModDepth)
    }

    /// Notes long enough that a mid-note controller has half a render to act.
    private var heldNote: [ScheduledMIDIEvent] {
        [pinNoteOn(0, pitch: 60, id: 1), pinNoteOff(40_000, pitch: 60, id: 1)]
    }
    private let midNote: Int64 = 12_000
    private let pinFrames = 48_000
    /// Well above float round-off, well below any real controller effect.
    private let noiseFloor: Float = 1e-4

    // MARK: - polySynth: the table says CC64 + bend, nothing else

    @Test("polySynth: CC11 is INERT in rendered audio, exactly as the table claims")
    func polySynthIgnoresCC11() throws {
        let poly = InstrumentDescriptor(kind: .polySynth)
        #expect(MIDIControllerRouting.honors(.cc(controller: 11), instrument: poly) == false)

        let clean = try renderDirect(makePolySynth(), events: heldNote, frames: pinFrames)
        let withCC = try renderDirect(makePolySynth(), events: heldNote + [
            pinCC(midNote, controller: 11, value: 40, id: 2),
        ], frames: pinFrames)
        // BIT-IDENTICAL: the branch does not exist, so nothing can differ.
        #expect(clean == withCC,
                "polySynth rendered CC11 differently — the honoured table is now WRONG")
    }

    @Test("polySynth: CC7 and CC1 are inert too — the table enumerates only CC64")
    func polySynthIgnoresOtherCCs() throws {
        let poly = InstrumentDescriptor(kind: .polySynth)
        let clean = try renderDirect(makePolySynth(), events: heldNote, frames: pinFrames)
        for controller in [UInt8(1), 2, 7, 10, 74] {
            #expect(MIDIControllerRouting.honors(.cc(controller: Int(controller)),
                                                 instrument: poly) == false)
            let withCC = try renderDirect(makePolySynth(), events: heldNote + [
                pinCC(midNote, controller: controller, value: 20, id: 2),
            ], frames: pinFrames)
            #expect(clean == withCC, "polySynth acted on CC\(controller)")
        }
    }

    @Test("polySynth: CC64 and pitch bend DO change the render — the honoured half")
    func polySynthHonorsSustainAndBend() throws {
        let poly = InstrumentDescriptor(kind: .polySynth)
        #expect(MIDIControllerRouting.honors(.cc(controller: 64), instrument: poly))
        #expect(MIDIControllerRouting.honors(.pitchBend, instrument: poly))

        // Pedal down BEFORE the noteOff defers the release, so the tail
        // differs from the un-pedalled render.
        let clean = try renderDirect(makePolySynth(), events: heldNote, frames: pinFrames)
        let pedalled = try renderDirect(makePolySynth(), events: heldNote + [
            pinCC(midNote, controller: 64, value: 127, id: 2),
        ], frames: pinFrames)
        #expect(peakDifference(clean, pedalled) > noiseFloor,
                "CC64 did nothing — the table claims polySynth honours it")

        let bent = try renderDirect(makePolySynth(), events: heldNote + [
            pinBend(midNote, value: 12_288, id: 3),
        ], frames: pinFrames)
        #expect(peakDifference(clean, bent) > noiseFloor, "pitch bend did nothing")
    }

    // MARK: - sampler: CC11 unconditional, CC1/CC2 depth-gated

    @Test("sampler: CC11 DOES attenuate the render — the mechanism behind the 1.25 LU")
    func samplerHonorsCC11() throws {
        let params = try sustainedSamplerParams()
        let descriptor = InstrumentDescriptor(kind: .sampler, sampler: params)
        #expect(MIDIControllerRouting.honors(.cc(controller: 11), instrument: descriptor))

        let clean = try renderDirect(try makeSampler(params), events: heldNote,
                                     frames: pinFrames)
        let attenuated = try renderDirect(try makeSampler(params), events: heldNote + [
            pinCC(midNote, controller: 11, value: 42, id: 2),
        ], frames: pinFrames)
        #expect(peakDifference(clean, attenuated) > noiseFloor,
                "CC11 did nothing on the sampler — the table claims it is honoured")

        // ⭐ And it CUTS: the post-event window must be quieter, not merely
        // different. This is the defect's actual signature.
        let window = 20_000..<38_000
        let cleanPeak = clean[window].map(abs).max() ?? 0
        let cutPeak = attenuated[window].map(abs).max() ?? 0
        #expect(cutPeak < cleanPeak * 0.8,
                "CC11 = 42 should attenuate well below full scale")
    }

    @Test("sampler: CC1/CC2 are INERT at the default depth and LIVE above it")
    func samplerModDepthGate() throws {
        // The gate that makes the table descriptor-level rather than
        // kind-level. Both halves are asserted against rendered audio.
        let flat = try sustainedSamplerParams()
        let flatDescriptor = InstrumentDescriptor(kind: .sampler, sampler: flat)
        #expect(MIDIControllerRouting.honors(.cc(controller: 2),
                                             instrument: flatDescriptor) == false)

        let flatClean = try renderDirect(try makeSampler(flat), events: heldNote,
                                         frames: pinFrames)
        let flatWithCC = try renderDirect(try makeSampler(flat), events: heldNote + [
            pinCC(midNote, controller: 2, value: 10, id: 2),
        ], frames: pinFrames)
        #expect(peakDifference(flatClean, flatWithCC) <= noiseFloor,
                "CC2 moved the sampler at depth 0 — the table says it cannot")

        let deep = try sustainedSamplerParams(expressionModDepth: 0.8)
        let deepDescriptor = InstrumentDescriptor(kind: .sampler, sampler: deep)
        #expect(MIDIControllerRouting.honors(.cc(controller: 2), instrument: deepDescriptor))

        let deepClean = try renderDirect(try makeSampler(deep), events: heldNote,
                                         frames: pinFrames)
        let deepWithCC = try renderDirect(try makeSampler(deep), events: heldNote + [
            pinCC(midNote, controller: 2, value: 10, id: 2),
        ], frames: pinFrames)
        #expect(peakDifference(deepClean, deepWithCC) > noiseFloor,
                "CC2 did nothing at depth 0.8 — the table claims it is honoured")
    }

    @Test("sampler: an unrouted CC (CC7) leaves the render bit-identical")
    func samplerIgnoresUnroutedCC() throws {
        let params = try sustainedSamplerParams()
        let descriptor = InstrumentDescriptor(kind: .sampler, sampler: params)
        #expect(MIDIControllerRouting.honors(.cc(controller: 7), instrument: descriptor) == false)

        let clean = try renderDirect(try makeSampler(params), events: heldNote,
                                     frames: pinFrames)
        let withCC = try renderDirect(try makeSampler(params), events: heldNote + [
            pinCC(midNote, controller: 7, value: 20, id: 2),
        ], frames: pinFrames)
        #expect(clean == withCC, "the sampler acted on CC7 — the table says it does not")
    }

    // MARK: - testTone: the table says nothing at all

    @Test("testTone: every controller kind leaves the render bit-identical")
    func testToneIgnoresEverything() throws {
        let tone = InstrumentDescriptor(kind: .testTone)
        #expect(MIDIControllerRouting.honoredCCs(instrument: tone).isEmpty)
        #expect(MIDIControllerRouting.honors(.pitchBend, instrument: tone) == false)

        func fresh() -> TestToneInstrument {
            let tone = TestToneInstrument()
            tone.prepare(sampleRate: pinRate, maxFramesPerQuantum: 512, channelCount: 2)
            return tone
        }
        let clean = try renderDirect(fresh(), events: heldNote, frames: pinFrames)
        for controller in [UInt8(1), 7, 11, 64] {
            let withCC = try renderDirect(fresh(), events: heldNote + [
                pinCC(midNote, controller: controller, value: 30, id: 2),
            ], frames: pinFrames)
            #expect(clean == withCC, "testTone acted on CC\(controller)")
        }
        let bent = try renderDirect(fresh(), events: heldNote + [
            pinBend(midNote, value: 12_288, id: 3),
        ], frames: pinFrames)
        #expect(clean == bent, "testTone acted on pitch bend")
    }
}
