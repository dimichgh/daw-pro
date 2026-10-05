import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-g — **THE BYTE-IDENTICAL DEFAULT-RENDER GATE** for the PolySynth
/// richness pass.
///
/// The bar: every field m39-g adds is additive-optional and defaults to
/// musically neutral, so a project saved BEFORE the richness pass renders
/// **bit-identically** after it. Not "close", not "within 1e-9" — identical
/// `Float` bit patterns, pinned by a 64-bit FNV-1a digest over every output
/// sample of every channel.
///
/// ⭐ HOW THE GOLDENS WERE MADE, AND WHY THAT IS THE WHOLE POINT: every digest
/// below was captured by running this file against the **PRE-m39-g**
/// `PolySynthInstrument.swift` / `PolySynthParams` — the pristine files, before
/// a single character of the richness pass was written. They are a genuine
/// reference to the old engine, not a recomputation of the new one. A golden
/// captured after the change would pin nothing at all.
///
/// The four fixtures are chosen to reach the code the richness pass REWRITES,
/// not merely to produce sound:
///
///  · A — default params through `OfflineRenderer`. The descriptor path a real
///    project takes, and the one every pre-m39-g project literally is.
///  · B — the seven legacy knobs at NON-defaults (square, slow attack, low
///    cutoff, high resonance), with overlapping notes and a long release, so
///    the decay/sustain/release branches and `releaseFrom` anchoring are all
///    exercised. Fixture A alone barely enters them.
///  · C — controllers, driven DIRECTLY at the instrument: pitch bend, CC 64
///    sustain (deferred note-offs + the pedal-up sweep) and 17 simultaneous
///    note-ons to force voice stealing. m39-g touches the `Voice` struct, both
///    note-off bodies and the bend handler; a project-level fixture cannot
///    reach those.
///  · D — `pedalHoldLimit` = 4, the m34-q eviction path, for the same reason.
///
/// ⚠️ These digests are pinned to this machine's libm: the engine calls `tan`,
/// `sin` and `exp2`, none of which is bit-guaranteed across platforms or OS
/// versions. A digest mismatch after an OS upgrade is not necessarily a
/// regression — the probe bit patterns printed on failure are there to tell the
/// two apart (a libm drift moves the low mantissa bits; a real regression moves
/// far more).
@MainActor
@Suite("m39-g PolySynth default-render identity", .serialized)
struct PolySynthRenderIdentityTests {
    private static let sampleRate = 48_000.0

    // MARK: - Goldens (captured against the PRE-m39-g PolySynth, 2026-09-19)

    private static let goldenDefaultDigest: UInt64 = 0x855C_8596_6A9F_3CF5
    private static let goldenLegacyDigest: UInt64 = 0xC79B_6622_31E4_E031
    private static let goldenControllerDigest: UInt64 = 0xC476_BB6A_6105_9BB9
    private static let goldenPedalCapDigest: UInt64 = 0xF797_5294_9752_CD75

    /// Individual channel-0 samples (bit patterns) from fixture A, so a failure
    /// reads as numbers rather than one opaque hash mismatch.
    private static let probeFrames = [6_000, 12_000, 24_000, 48_000, 72_000]
    private static let goldenDefaultProbes: [UInt32] =
        [0x3D34_8E9D, 0xBCAE_F279, 0x3D48_82CD, 0x3D9F_FF22, 0x0000_0000]

    // MARK: - Digest

    /// FNV-1a 64 over every sample's `Float.bitPattern`, channel by channel.
    private static func digest(_ channels: [[Float]]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    hash ^= UInt64(bits & 0xff)
                    hash = hash &* 0x0000_0100_0000_01b3
                    bits >>= 8
                }
            }
        }
        return hash
    }

    private static func channels(_ audio: RenderedAudio) -> [[Float]] {
        (0..<audio.channelData.count).map { Array(audio.channelData[$0][0..<audio.frameCount]) }
    }

    // MARK: - Fixtures

    /// Three overlapping notes at three velocities — the same shape the
    /// existing determinism pin uses, so both suites exercise one clip.
    private static func fixtureClip() -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
            MIDINote(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 1.5),
            MIDINote(pitch: 67, velocity: 110, startBeat: 1, lengthBeats: 1),
        ])
    }

    private static func render(_ params: PolySynthParams) throws -> RenderedAudio {
        try OfflineRenderer().render(
            tracks: [Track(name: "Keys", kind: .instrument, clips: [fixtureClip()],
                           instrument: InstrumentDescriptor(kind: .polySynth,
                                                            polySynth: params))],
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.0)
    }

    /// The seven legacy knobs OFF their defaults: a slow attack and a long
    /// release so tails overlap, a sustain below 1 so the decay ramp is real,
    /// and a low cutoff with high resonance so the SVF coefficients matter.
    private static func legacyParams() -> PolySynthParams {
        PolySynthParams(waveform: .square, attack: 0.05, decay: 0.3, sustain: 0.4,
                        release: 0.8, cutoffHz: 600, resonance: 0.9, gain: 0.55)
    }

    // MARK: - Direct-render harness (controllers reach only this way)

    private static func makeSynth(_ params: PolySynthParams) -> PolySynthInstrument {
        let synth = PolySynthInstrument(params: params)
        synth.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return synth
    }

    /// Renders directly in 512-frame quanta, replicating InstrumentRenderer's
    /// slicing. Returns BOTH channels, so the stereo-identical contract is
    /// inside the digest rather than asserted separately.
    private static func renderDirect(_ instrument: PolySynthInstrument,
                                     events unsorted: [ScheduledMIDIEvent],
                                     frames totalFrames: Int) throws -> [[Float]] {
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
                instrument.render(events: slice, renderStart: Int64(rendered),
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

    private static func note(on: Int64, off: Int64, pitch: UInt8,
                             velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    private static func cc(_ controller: UInt8, _ value: UInt8, at time: Int64)
        -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: time, noteID: 0,
                           kind: ScheduledMIDIEvent.controlChange,
                           pitch: controller, velocity: value)
    }

    private static func bend(_ raw: Int, at time: Int64) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: time, noteID: 0,
                           kind: ScheduledMIDIEvent.pitchBend,
                           pitch: UInt8(raw & 0x7F), velocity: UInt8((raw >> 7) & 0x7F))
    }

    /// Pitch bend + CC 64 (deferred note-offs and the pedal-up sweep) + 17
    /// note-ons to force voice stealing, in one event stream.
    private static func controllerEvents() -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        // 17 note-ons at frame 0; ids 0...15 lift at 20 000, id 16 at 60 000.
        for id in 0..<16 {
            events += note(on: 0, off: 20_000, pitch: UInt8(48 + id), velocity: 100,
                           id: UInt64(id))
        }
        events += note(on: 0, off: 60_000, pitch: 64, velocity: 120, id: 16)
        // Pedal DOWN before those note-offs, so they defer; UP at 40 000.
        events.append(cc(64, 127, at: 10_000))
        events.append(cc(64, 0, at: 40_000))
        // Bend up, then back to centre, while voices sound.
        events.append(bend(12_000, at: 5_000))
        events.append(bend(8_192, at: 30_000))
        // A late note that arrives AFTER the pedal lifted.
        events += note(on: 50_000, off: 70_000, pitch: 72, velocity: 80, id: 17)
        return events
    }

    /// The m34-q eviction path: a cap of 4 with the pedal down and more notes
    /// struck than the cap allows.
    private static func pedalCapEvents() -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        events.append(cc(64, 127, at: 0))
        for id in 0..<8 {
            let on = Int64(2_000 * id)
            events += note(on: on, off: on + 1_000, pitch: UInt8(55 + 2 * id),
                           velocity: 110, id: UInt64(id))
        }
        events.append(cc(64, 0, at: 40_000))
        return events
    }

    // MARK: - The gate

    @Test("A: a DEFAULT PolySynth project renders bit-identically to pre-m39-g")
    func defaultRenderIsBitIdentical() throws {
        let audio = try Self.render(PolySynthParams())
        let channels = Self.channels(audio)
        let actual = Self.digest(channels)

        // The golden means nothing if the render is silence.
        let peak = TestSignals.peak(channels[0], in: 0..<channels[0].count)
        print("[measured] m39-g fixture A digest: 0x\(String(actual, radix: 16, uppercase: true)) "
              + "peak: \(peak) frames: \(audio.frameCount) channels: \(channels.count)")
        print("[measured] m39-g fixture A probes: "
              + Self.probeFrames.map { frame in
                  frame < channels[0].count
                      ? "0x\(String(channels[0][frame].bitPattern, radix: 16, uppercase: true))"
                      : "oob"
              }.joined(separator: ", "))
        #expect(peak > 0.05, "control failed: a silent golden would pass vacuously")

        for (index, frame) in Self.probeFrames.enumerated() where frame < channels[0].count {
            #expect(channels[0][frame].bitPattern == Self.goldenDefaultProbes[index],
                    """
                    frame \(frame) drifted: got \
                    0x\(String(channels[0][frame].bitPattern, radix: 16, uppercase: true)), \
                    pinned 0x\(String(Self.goldenDefaultProbes[index], radix: 16, uppercase: true))
                    """)
        }
        #expect(actual == Self.goldenDefaultDigest, """
            A DEFAULT poly-synth project no longer renders bit-identically to the pre-m39-g \
            engine. Every m39-g field must default to musically neutral — one that does not \
            changes the sound of every project already on disk. \
            got 0x\(String(actual, radix: 16, uppercase: true)), \
            pinned 0x\(String(Self.goldenDefaultDigest, radix: 16, uppercase: true)).
            """)
        // Stereo-identical is part of the pre-m39-g contract (the instrument
        // renders channel 0 and copies it). Asserted as well as digested,
        // because the stereo path is what the unison spread feature changes.
        #expect(channels[0] == channels[1],
                "a default (spread-free) render must stay stereo-identical")
    }

    @Test("B: the seven LEGACY knobs at non-defaults render bit-identically to pre-m39-g")
    func legacyParamsRenderBitIdentically() throws {
        let audio = try Self.render(Self.legacyParams())
        let channels = Self.channels(audio)
        let actual = Self.digest(channels)
        let peak = TestSignals.peak(channels[0], in: 0..<channels[0].count)
        print("[measured] m39-g fixture B digest: 0x\(String(actual, radix: 16, uppercase: true)) "
              + "peak: \(peak)")
        #expect(peak > 0.02, "control failed: the legacy fixture must make sound")
        #expect(actual == Self.goldenLegacyDigest, """
            A project using the pre-m39-g knobs at non-default values changed sound. \
            got 0x\(String(actual, radix: 16, uppercase: true)), \
            pinned 0x\(String(Self.goldenLegacyDigest, radix: 16, uppercase: true)).
            """)
    }

    @Test("C: bend + CC 64 + voice stealing render bit-identically to pre-m39-g")
    func controllerPathRendersBitIdentically() throws {
        let channels = try Self.renderDirect(Self.makeSynth(Self.legacyParams()),
                                             events: Self.controllerEvents(), frames: 76_800)
        let actual = Self.digest(channels)
        let peak = TestSignals.peak(channels[0], in: 0..<channels[0].count)
        print("[measured] m39-g fixture C digest: 0x\(String(actual, radix: 16, uppercase: true)) "
              + "peak: \(peak)")
        #expect(peak > 0.05, "control failed: the controller fixture must make sound")
        #expect(actual == Self.goldenControllerDigest, """
            The controller path (pitch bend / sustain pedal / voice stealing) changed sound. \
            got 0x\(String(actual, radix: 16, uppercase: true)), \
            pinned 0x\(String(Self.goldenControllerDigest, radix: 16, uppercase: true)).
            """)
    }

    @Test("D: the m34-q pedal-hold cap renders bit-identically to pre-m39-g")
    func pedalHoldCapRendersBitIdentically() throws {
        var params = Self.legacyParams()
        params.pedalHoldLimit = 4
        let channels = try Self.renderDirect(Self.makeSynth(params),
                                             events: Self.pedalCapEvents(), frames: 61_440)
        let actual = Self.digest(channels)
        let peak = TestSignals.peak(channels[0], in: 0..<channels[0].count)
        print("[measured] m39-g fixture D digest: 0x\(String(actual, radix: 16, uppercase: true)) "
              + "peak: \(peak)")
        #expect(peak > 0.05, "control failed: the pedal-cap fixture must make sound")
        #expect(actual == Self.goldenPedalCapDigest, """
            The m34-q pedal-hold eviction path changed sound. \
            got 0x\(String(actual, radix: 16, uppercase: true)), \
            pinned 0x\(String(Self.goldenPedalCapDigest, radix: 16, uppercase: true)).
            """)
    }

    /// ⭐ THE CONTROL ON THE GATE ITSELF. A digest comparison that has never
    /// been seen to FAIL is indistinguishable from one that compares nothing.
    /// This renders the same fixture with ONE new m39-g field off its neutral
    /// default and asserts the digest MOVES — so the four assertions above are
    /// known to be load-bearing, permanently, not just on the day they were
    /// written.
    @Test("CONTROL: one non-neutral m39-g field must make the default digest differ")
    func aNonNeutralFieldMovesTheDigest() throws {
        let neutral = try Self.digest(Self.channels(Self.render(PolySynthParams())))
        #expect(neutral == Self.goldenDefaultDigest, "control precondition: the golden must hold")

        // Detune alone is inert without more than one unison voice — that pair
        // IS the neutrality rule, so the control sets both.
        var loud = PolySynthParams()
        loud.unisonVoices = 4
        loud.unisonDetuneCents = 12
        let moved = try Self.digest(Self.channels(Self.render(loud)))
        print("[measured] m39-g gate control — neutral: "
              + "0x\(String(neutral, radix: 16, uppercase: true)), unison(4, 12 cents): "
              + "0x\(String(moved, radix: 16, uppercase: true))")
        #expect(moved != neutral, """
            control failed: turning a richness feature ON did not change the render at all. \
            The four identity assertions in this suite are therefore measuring nothing.
            """)
    }
}
