import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m19-a (design 2026-07-16 §4.2/§7): the Sampler's zone-SELECTION dimension —
/// velocity layers, group layering, round-robin, and random alternation.
///
/// Direct-render idiom from `SamplerTests`: 512-frame quanta, hand-built
/// event arrays, programmatic temp-dir sine fixtures at DISTINCT frequencies
/// so Goertzel magnitudes prove exactly which zone fired. Every random-gate
/// test pins the RNG through the `randomSeed` init seam, so all assertions
/// here are deterministic.
///
/// The existing `SamplerTests` suite is the hard legacy-regression gate for
/// this item and runs UNCHANGED; the legacy tests below add the byte-identical
/// first-match proof on top.
@MainActor
@Suite("Sampler selection (m19-a)", .serialized)
struct SamplerSelectionTests {
    private let sampleRate = 48_000.0

    // MARK: - Fixtures (written once per run)

    /// One mono 44.1 kHz sine per distinct frequency — each frequency is one
    /// zone's fingerprint. All windows asserted below are whole-cycle at
    /// every fingerprint (0.1 s → 25/30/35/44/45/55/100 cycles), so Goertzel
    /// bins are leakage-free.
    private struct Fixtures {
        let dir: URL
        let byHz: [Double: URL]
    }

    private static let fingerprintHz: [Double] = [250, 300, 350, 440, 450, 550, 1_000]
    private static var cachedFixtures: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cachedFixtures { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sampler-selection-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var byHz: [Double: URL] = [:]
        for hz in Self.fingerprintHz {
            let url = dir.appendingPathComponent("sine\(Int(hz))_44k1_mono.wav")
            try Self.writeSine(to: url, frequency: hz)
            byHz[hz] = url
        }
        let set = Fixtures(dir: dir, byHz: byHz)
        Self.cachedFixtures = set
        return set
    }

    /// 1.0 s mono Float32 WAV at 44.1 kHz, amp 0.5. Scoped so the AVAudioFile
    /// flushes and closes before anyone reads it.
    private static func writeSine(to url: URL, frequency: Double) throws {
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
            throw NSError(domain: "SamplerSelectionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for frame in 0..<frames {
            data[0][frame] = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    private func zoneURL(_ hz: Double) throws -> URL {
        try #require(try fixtures().byHz[hz])
    }

    // MARK: - Harness (the SamplerTests direct-render idiom)

    private func makeSampler(_ params: SamplerParams,
                             randomSeed: UInt64? = nil) -> SamplerInstrument {
        let sampler = SamplerInstrument(params: params, randomSeed: randomSeed)
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
    /// InstrumentRenderer's slicing. Returns the LEFT channel (all fixtures
    /// are mono → both channels identical).
    private func renderDirect(
        _ instrument: SamplerInstrument,
        events unsorted: [ScheduledMIDIEvent],
        frames totalFrames: Int,
        quantum: Int = 512
    ) throws -> [Float] {
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

    /// Goertzel magnitude at exactly `hz` (windows below all hold a whole
    /// number of cycles, so bins are leakage-free). Absolute scale arbitrary.
    private func magnitude(_ samples: ArraySlice<Float>, hz: Double) -> Double {
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

    /// Which of `candidates` dominates `window` — asserts the winner beats
    /// every other candidate by ≥ 10× and returns it.
    private func dominantCandidate(_ samples: [Float], window: Range<Int>,
                                   candidates: [Double], label: String) -> Double {
        let magnitudes = candidates.map { magnitude(samples[window], hz: $0) }
        let winnerIndex = magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] }!
        print("[measured] \(label): "
              + zip(candidates, magnitudes).map { "\(Int($0)) Hz → \($1)" }
                .joined(separator: ", "))
        for index in magnitudes.indices where index != winnerIndex {
            #expect(magnitudes[winnerIndex] > 10 * magnitudes[index],
                    "\(label): \(candidates[winnerIndex]) Hz should dominate \(candidates[index]) Hz by 10×")
        }
        return candidates[winnerIndex]
    }

    /// The steady whole-cycle analysis window for a note starting at `on`:
    /// 4 800 frames (0.1 s) from 1 200 frames past the trigger.
    private func steadyWindow(noteOnAt on: Int) -> Range<Int> {
        (on + 1_200)..<(on + 6_000)
    }

    // MARK: - Velocity layers

    @Test("velocity 30 routes to the 0-62 layer, velocity 100 to the 63-127 layer")
    func velocityLayerRouting() throws {
        // Two full-keyboard zones split by velocity — the SViolinVib shape.
        let params = SamplerParams(
            zones: [
                SamplerZone(audioFileURL: try zoneURL(300), rootPitch: 60,
                            maxVelocity: 62),
                SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 60,
                            minVelocity: 63),
            ],
            attack: 0.001, release: 0.05, gain: 0.8)

        let soft = try renderDirect(
            makeSampler(params),
            events: note(on: 0, off: 6_000, pitch: 60, velocity: 30, id: 0), frames: 12_000)
        let softHz = dominantCandidate(soft, window: steadyWindow(noteOnAt: 0),
                                       candidates: [300, 1_000], label: "velocity 30")
        #expect(softHz == 300)

        let loud = try renderDirect(
            makeSampler(params),
            events: note(on: 0, off: 6_000, pitch: 60, velocity: 100, id: 0), frames: 12_000)
        let loudHz = dominantCandidate(loud, window: steadyWindow(noteOnAt: 0),
                                       candidates: [300, 1_000], label: "velocity 100")
        #expect(loudHz == 1_000)
    }

    // MARK: - Round-robin

    @Test("4-slot round-robin rotates deterministically over 8 triggers")
    func roundRobinRotatesDeterministically() throws {
        // Four same-group zones, seqLength 4, seqPosition 1...4. Counters
        // advance on every range match, so 8 identical triggers must walk
        // 1,2,3,4,1,2,3,4 — no RNG involved (rand gates are nil = full span).
        let slotHz: [Double] = [250, 350, 450, 550]
        let params = SamplerParams(
            zones: try slotHz.enumerated().map { index, hz in
                SamplerZone(audioFileURL: try zoneURL(hz), rootPitch: 60,
                            seqLength: 4, seqPosition: index + 1)
            },
            attack: 0.001, release: 0.05, gain: 0.8)
        let sampler = makeSampler(params)

        var events: [ScheduledMIDIEvent] = []
        for trigger in 0..<8 {
            events += note(on: Int64(trigger * 12_000), off: Int64(trigger * 12_000 + 6_000),
                           pitch: 60, id: UInt64(trigger))
        }
        let out = try renderDirect(sampler, events: events, frames: 96_000)

        for trigger in 0..<8 {
            let expected = slotHz[trigger % 4]
            let measured = dominantCandidate(
                out, window: steadyWindow(noteOnAt: trigger * 12_000),
                candidates: slotHz, label: "RR trigger \(trigger)")
            #expect(measured == expected,
                    "trigger \(trigger) should play the seqPosition \(trigger % 4 + 1) zone")
        }
    }

    // MARK: - Random alternation

    @Test("seeded RNG partitions randMin/randMax gates reproducibly")
    func seededRandomPartition() throws {
        // Two same-group zones splitting [0,1): draws < 0.5 fire the 300 Hz
        // zone, ≥ 0.5 the 1 kHz zone — exactly one per note-on by
        // construction. The seed seam makes the whole render deterministic.
        let params = SamplerParams(
            zones: [
                SamplerZone(audioFileURL: try zoneURL(300), rootPitch: 60, randMax: 0.5),
                SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 60, randMin: 0.5),
            ],
            attack: 0.001, release: 0.05, gain: 0.8)
        let seed: UInt64 = 0x5EED_F00D_5EED_F00D

        var events: [ScheduledMIDIEvent] = []
        for trigger in 0..<8 {
            events += note(on: Int64(trigger * 12_000), off: Int64(trigger * 12_000 + 6_000),
                           pitch: 60, id: UInt64(trigger))
        }
        let first = try renderDirect(makeSampler(params, randomSeed: seed),
                                     events: events, frames: 96_000)
        let second = try renderDirect(makeSampler(params, randomSeed: seed),
                                      events: events, frames: 96_000)
        // Same seed + fresh init → bit-identical renders (the design's
        // offline-determinism contract, §4.3).
        #expect(first == second)

        // Exactly one zone per note-on; over 8 draws this seed hits BOTH
        // sides of the partition (deterministic — pinned by the seed).
        var pattern: [Double] = []
        for trigger in 0..<8 {
            pattern.append(dominantCandidate(
                first, window: steadyWindow(noteOnAt: trigger * 12_000),
                candidates: [300, 1_000], label: "random trigger \(trigger)"))
        }
        print("[measured] seeded partition pattern: \(pattern.map { Int($0) })")
        #expect(pattern.contains(300), "seed should land at least one draw below 0.5")
        #expect(pattern.contains(1_000), "seed should land at least one draw at/above 0.5")
    }

    // MARK: - Group layering

    @Test("different groups layer (one voice per group); same group fires exactly one voice")
    func groupsLayerSameGroupAlternates() throws {
        let events = note(on: 0, off: 6_000, pitch: 60, id: 0)
        let window = steadyWindow(noteOnAt: 0)
        func zones(_ groupA: Int?, _ groupB: Int?) throws -> [SamplerZone] {
            [SamplerZone(audioFileURL: try zoneURL(300), rootPitch: 60, group: groupA),
             SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 60, group: groupB)]
        }
        func render(_ zones: [SamplerZone]) throws -> [Float] {
            try renderDirect(
                makeSampler(SamplerParams(zones: zones,
                                          attack: 0.001, release: 0.05, gain: 0.8)),
                events: events, frames: 12_000)
        }

        // Solo references.
        let soloLow = try render([SamplerZone(audioFileURL: try zoneURL(300), rootPitch: 60)])
        let soloHigh = try render([SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 60)])

        // DIFFERENT groups: both zones fire on one note-on. Each frequency's
        // magnitude matches its solo render, and the powers ADD (300/1000 Hz
        // are orthogonal over the whole-cycle window).
        let layered = try render(try zones(1, 2))
        let low = magnitude(layered[window], hz: 300)
        let high = magnitude(layered[window], hz: 1_000)
        let soloLowMag = magnitude(soloLow[window], hz: 300)
        let soloHighMag = magnitude(soloHigh[window], hz: 1_000)
        let layeredRMS = TestSignals.rms(layered, in: window)
        let expectedRMS = (pow(Double(TestSignals.rms(soloLow, in: window)), 2)
                           + pow(Double(TestSignals.rms(soloHigh, in: window)), 2)).squareRoot()
        print("[measured] layered — 300 Hz: \(low) (solo \(soloLowMag)), "
              + "1 kHz: \(high) (solo \(soloHighMag)), "
              + "RMS: \(layeredRMS) (expected \(expectedRMS))")
        #expect(abs(low / soloLowMag - 1) < 0.02)
        #expect(abs(high / soloHighMag - 1) < 0.02)
        #expect(abs(Double(layeredRMS) / expectedRMS - 1) < 0.02)

        // SAME group: exactly one voice — the first zone in array order —
        // and the render is BIT-IDENTICAL to that zone alone.
        let sameGroup = try render(try zones(5, 5))
        let highLeak = magnitude(sameGroup[window], hz: 1_000)
        print("[measured] same-group — 1 kHz leak magnitude: \(highLeak)")
        #expect(sameGroup == soloLow)
        #expect(highLeak < magnitude(sameGroup[window], hz: 300) / 1_000)
    }

    // MARK: - Legacy degenerate case

    @Test("legacy nil-field zones keep first-match: overlapping zones render bit-identically to the first alone")
    func legacyZonesFirstMatchByteIdentical() throws {
        // Two overlapping ALL-NIL zones — the pre-m19 shape. Both land in
        // implicit group 0, so the selection loop must fire ONLY the first:
        // bit-for-bit the same output as a one-zone instrument.
        let first = SamplerZone(audioFileURL: try zoneURL(440), rootPitch: 60)
        let shadowed = SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 60)
        let events = note(on: 0, off: 6_000, pitch: 60, id: 0)

        let overlapping = try renderDirect(
            makeSampler(SamplerParams(zones: [first, shadowed],
                                      attack: 0.001, release: 0.05, gain: 0.8)),
            events: events, frames: 12_000)
        let single = try renderDirect(
            makeSampler(SamplerParams(zones: [first],
                                      attack: 0.001, release: 0.05, gain: 0.8)),
            events: events, frames: 12_000)
        let leak = magnitude(overlapping[steadyWindow(noteOnAt: 0)], hz: 1_000)
        print("[measured] legacy first-match — shadowed-zone leak magnitude: \(leak)")
        #expect(overlapping == single)
        #expect(TestSignals.peak(overlapping, in: 1_200..<6_000) > 0.3)  // the null means something
    }

    // MARK: - Voice pool

    @Test("64-voice pool: the 65th voice steals the OLDEST; 64 concurrent voices all survive")
    func voicePool64StealsOldest() throws {
        // One held 440 Hz voice (the oldest), then a burst of 1 kHz notes at
        // frame 4 800. A 63-note burst fills the pool exactly (64 voices) and
        // the old voice survives; a 64-note burst needs a 65th slot and must
        // steal the OLDEST — the 440 Hz voice vanishes, no 1 kHz voice does.
        let params = SamplerParams(
            zones: [
                SamplerZone(audioFileURL: try zoneURL(440), rootPitch: 40,
                            minPitch: 0, maxPitch: 59),
                SamplerZone(audioFileURL: try zoneURL(1_000), rootPitch: 72,
                            minPitch: 60, maxPitch: 127),
            ],
            attack: 0.001, release: 0.05, gain: 0.8)
        let before = 1_200..<4_800     // 3 600 frames: 33 whole cycles of 440 Hz
        let after = 9_600..<14_400     // 4 800 frames, burst fully sounding

        func render(burstCount: Int) throws -> [Float] {
            var events = note(on: 0, off: 90_000, pitch: 40, id: 1_000)
            for burst in 0..<burstCount {
                events += note(on: 4_800, off: 80_000, pitch: 72, id: UInt64(burst))
            }
            return try renderDirect(makeSampler(params), events: events, frames: 24_000)
        }

        let full = try render(burstCount: 63)   // 1 + 63 = 64 voices: no steal
        let fullBefore = magnitude(full[before], hz: 440)
        let fullAfter = magnitude(full[after], hz: 440)
        print("[measured] 63-note burst — 440 Hz before: \(fullBefore), after: \(fullAfter)")
        #expect(fullAfter > 0.8 * fullBefore, "64 concurrent voices must all fit the pool")

        let stolen = try render(burstCount: 64)  // 1 + 64 = 65: steal the oldest
        let stolenBefore = magnitude(stolen[before], hz: 440)
        let stolenAfter = magnitude(stolen[after], hz: 440)
        let burstLevel = magnitude(stolen[after], hz: 1_000)
        print("[measured] 64-note burst — 440 Hz before: \(stolenBefore), "
              + "after: \(stolenAfter), 1 kHz after: \(burstLevel)")
        #expect(stolenBefore > 0.1)                       // the held voice was sounding
        #expect(stolenAfter < 0.05 * stolenBefore,        // …and is GONE after the burst
                "the oldest voice should have been stolen")
        #expect(burstLevel > 10 * stolenAfter)            // every burst voice survived
    }

    // MARK: - DAWCore Codable back-compat

    @Test("legacy zone JSON (no m19-a keys) decodes to all-nil and equals the legacy-built zone")
    func legacyJSONDecodesAllNil() throws {
        // A zone built the pre-m19 way encodes WITHOUT any of the new keys
        // (optionals omit) — i.e. its JSON is byte-compatible with a pre-m19
        // project file. Decoding that JSON restores an EQUAL zone, all new
        // fields nil.
        let legacy = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/kick.wav"),
                                 rootPitch: 36, minPitch: 35, maxPitch: 38, gain: 0.9)
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let newKeys = ["minVelocity", "maxVelocity", "group",
                       "seqLength", "seqPosition", "randMin", "randMax"]
        print("[measured] legacy zone JSON keys: \(json.keys.sorted())")
        for key in newKeys {
            #expect(json[key] == nil, "legacy zone must not encode '\(key)'")
        }

        let decoded = try JSONDecoder().decode(SamplerZone.self, from: data)
        #expect(decoded == legacy)
        #expect(decoded.minVelocity == nil)
        #expect(decoded.maxVelocity == nil)
        #expect(decoded.group == nil)
        #expect(decoded.seqLength == nil)
        #expect(decoded.seqPosition == nil)
        #expect(decoded.randMin == nil)
        #expect(decoded.randMax == nil)
        // nil-tolerant velocity membership reads the full 0/127 span.
        #expect(decoded.contains(pitch: 36, velocity: 0))
        #expect(decoded.contains(pitch: 36, velocity: 127))
        #expect(!decoded.contains(pitch: 60, velocity: 64))
    }

    @Test("new selection fields clamp and round-trip through Codable")
    func selectionFieldClampingAndRoundTrip() throws {
        // The model init clamps/swaps with the pitch-span idiom: velocities
        // into 0...127 (swapped when reversed), group ≥ 0, seqLength ≥ 1,
        // seqPosition into 1...seqLength, rand span into 0...1 (swapped).
        let zone = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/snare.wav"),
                               minVelocity: 200, maxVelocity: -3,
                               group: -7, seqLength: 0, seqPosition: 9,
                               randMin: 1.5, randMax: -0.25)
        #expect(zone.minVelocity == 0)     // swapped from (127, 0) after clamping
        #expect(zone.maxVelocity == 127)
        #expect(zone.group == 0)
        #expect(zone.seqLength == 1)
        #expect(zone.seqPosition == 1)     // clamped into 1...seqLength
        #expect(zone.randMin == 0)         // swapped from (1, 0) after clamping
        #expect(zone.randMax == 1)

        let configured = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/hat.wav"),
                                     minVelocity: 63, maxVelocity: 100,
                                     group: 2, seqLength: 4, seqPosition: 3,
                                     randMin: 0.25, randMax: 0.75)
        let decoded = try JSONDecoder().decode(
            SamplerZone.self, from: JSONEncoder().encode(configured))
        #expect(decoded == configured)
        #expect(decoded.contains(pitch: 60, velocity: 63))
        #expect(!decoded.contains(pitch: 60, velocity: 30))
    }
}
