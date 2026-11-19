import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// W8-HAT (m39 wave 4, `dm-hat-gain`) — the RENDER half of the drum machine's
/// two level trims, `kit.hatsLevelDb` and `kit.cymbalsLevelDb`.
///
/// ⛔ PHYSICS, NEVER DISTINCTNESS. Distinct bytes prove nothing (this tree has
/// shipped an inert effect past a distinctness check). Every row here states a
/// level in dB with a tolerance, or a BIT-IDENTITY that a wrong implementation
/// would break: the commanded trim must move its own voices by exactly that
/// many dB, and every voice it does not reach must not move by one bit.
///
/// Deliberately NOT `@MainActor`: nothing here publishes through
/// `DrumSynthInstrument.apply(params:)` (the only main-actor member); every kit
/// is handed to the instrument at construction.
@Suite("Drum machine — W8-HAT level trims (render)")
struct DrumLevelTrimRenderTests {
    private static let sampleRate = 48_000.0

    private func makeDrums(_ kit: DrumKitParams) -> DrumSynthInstrument {
        let drums = DrumSynthInstrument(params: kit)
        drums.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return drums
    }

    private func note(_ pitch: UInt8, at seconds: Double, velocity: UInt8 = 100,
                      id: UInt64) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: Int64(seconds * Self.sampleRate), noteID: id,
                           kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity)
    }

    /// Renders in 512-frame quanta (the `InstrumentRenderer` slicing) and
    /// returns BOTH channels, interleaved L, R — so a byte comparison covers pan.
    private func render(_ kit: DrumKitParams, _ unsorted: [ScheduledMIDIEvent],
                        seconds: Double) throws -> [Float] {
        let drums = makeDrums(kit)
        let total = Int(seconds * Self.sampleRate)
        let events = unsorted.sorted { $0.sampleTime < $1.sampleTime }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        var out: [Float] = []
        out.reserveCapacity(total * 2)
        var cursor = 0, rendered = 0
        while rendered < total {
            let frames = min(512, total - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) { end += 1 }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                drums.render(events: UnsafeBufferPointer(rebasing: all[cursor..<end]),
                             renderStart: Int64(rendered), frameCount: frames, output: output)
            }
            cursor = end
            for index in 0..<frames {
                out.append(channels[0][index])
                out.append(channels[1][index])
            }
            rendered += frames
        }
        return out
    }

    /// ⛔ Compare sample arrays as a Bool BEFORE `#expect`. Handed `a == b`
    /// directly, swift-testing renders a collection DIFF of the two arrays on
    /// failure — measured under plant PL-B: one 1.3M-sample failure ran for
    /// minutes and wrote 12 MB of log. A red must be fast, so the message
    /// names the first differing sample instead.
    private func sameSamples(_ a: [Float], _ b: [Float]) -> (same: Bool, detail: String) {
        guard a.count == b.count else { return (false, "lengths \(a.count) vs \(b.count)") }
        guard let index = a.indices.first(where: { a[$0] != b[$0] }) else { return (true, "") }
        let differing = a.indices.reduce(0) { $0 + (a[$1] != b[$1] ? 1 : 0) }
        return (false, "\(differing) samples differ, first at \(index): \(a[index]) vs \(b[index])")
    }

    private func levelDb(_ samples: [Float]) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        return 10 * log10(max(sum / Double(max(samples.count, 1)), 1e-30))
    }

    private func kit(_ base: DrumKitParams = DrumKitParams(), layout: DrumNoteLayout = .pads,
                     hats: Double, cymbals: Double) -> DrumKitParams {
        var kit = base
        kit.noteLayout = layout
        kit.hatsLevelDb = hats
        kit.cymbalsLevelDb = cymbals
        return kit
    }

    /// One hit on every voice, staggered, in `layout`'s own notes.
    private func everyVoice(_ layout: DrumNoteLayout) -> [ScheduledMIDIEvent] {
        DrumVoice.allCases.enumerated().map { index, voice in
            note(voice.notes(in: layout)[0], at: 0.05 + 0.3 * Double(index),
                 velocity: index % 2 == 0 ? 110 : 80, id: UInt64(index + 1))
        }
    }

    // MARK: - The shipped-tone law, render half

    /// ⛔ ABSENT vs EXPLICIT-NEUTRAL, through the DECODER. For every factory
    /// preset in both layouts: the kit decoded from JSON that OMITS the trims
    /// (what every kit saved before them is) and the same kit with the trims
    /// set explicitly to the saved-kit neutral render BIT-IDENTICALLY — and the
    /// decoded kit really did omit them. (Bit-identity with the build BEFORE the
    /// trims is the DemoRender gate's job: it needs two binaries.)
    @Test("A kit saved without the trims renders bit-identically to one at the neutral")
    func absentAndNeutralTrimsRenderIdentically() throws {
        for preset in DrumKitParams.presets {
            for layout in DrumNoteLayout.allCases {
                let explicit = kit(preset.params, layout: layout,
                                   hats: DrumKitParams.savedKitLevelTrimDb,
                                   cymbals: DrumKitParams.savedKitLevelTrimDb)
                // The encoder OMITS a trim at the neutral, so its own output is
                // exactly a file saved before the trims existed: checked, then
                // decoded.
                let data = try JSONEncoder().encode(explicit)
                let text = String(decoding: data, as: UTF8.self)
                #expect(text.contains("hatsLevelDb") == false
                            && text.contains("cymbalsLevelDb") == false,
                        "\(preset.name)/\(layout): the neutral trims were written")
                let absent = try JSONDecoder().decode(DrumKitParams.self, from: data)
                let events = everyVoice(layout)
                let a = try render(absent, events, seconds: 2.8)
                let b = try render(explicit, events, seconds: 2.8)
                let check = sameSamples(a, b)
                #expect(check.same,
                        "\(preset.name)/\(layout): absent and neutral trims differ: \(check.detail)")
                #expect(levelDb(a) > -60, "\(preset.name)/\(layout): the render is silent")
            }
        }
    }

    // MARK: - Physics: each trim moves its own voices by exactly the commanded dB

    @Test("The hats trim moves both hats by the commanded dB and no other voice by one bit")
    func hatsTrimMovesOnlyTheHats() throws {
        for trim in [12.0, -12.0, 23.4] {
            for voice in DrumVoice.allCases {
                let events = [note(voice.note, at: 0, velocity: 100, id: 1)]
                let base = try render(kit(hats: 0, cymbals: 0), events, seconds: 1.5)
                let moved = try render(kit(hats: trim, cymbals: 0), events, seconds: 1.5)
                if voice == .closedHat || voice == .openHat {
                    let delta = levelDb(moved) - levelDb(base)
                    #expect(abs(delta - trim) < 0.01,
                            "\(voice): commanded \(trim) dB, measured \(delta) dB")
                } else {
                    let check = sameSamples(moved, base)
                    #expect(check.same, "the hats trim moved \(voice): \(check.detail)")
                }
            }
        }
    }

    @Test("The cymbals trim moves the cymbal by the commanded dB and no other voice by one bit")
    func cymbalsTrimMovesOnlyTheCymbal() throws {
        for trim in [5.7, -12.0, 24.0] {
            for voice in DrumVoice.allCases {
                let events = [note(voice.note, at: 0, velocity: 100, id: 1)]
                let base = try render(kit(hats: 0, cymbals: 0), events, seconds: 2.5)
                let moved = try render(kit(hats: 0, cymbals: trim), events, seconds: 2.5)
                if voice == .cymbal {
                    let delta = levelDb(moved) - levelDb(base)
                    #expect(abs(delta - trim) < 0.01,
                            "cymbal: commanded \(trim) dB, measured \(delta) dB")
                } else {
                    let check = sameSamples(moved, base)
                    #expect(check.same, "the cymbals trim moved \(voice): \(check.detail)")
                }
            }
        }
    }

    /// The listening set's groove in miniature: two bars of the audition drum
    /// pattern at 90 BPM in the `gm` layout (kick 36, snare 38, closed hat 42 on
    /// the eighths, open hat 46, crash 49). With the hats and the cymbal on
    /// their own clips, each trim's level change is MEASURED in context —
    /// including the closed hat choking the open one — and the kick + snare
    /// clip is bit-identical whatever the trims are.
    @Test("In a General MIDI groove each trim moves its own drums by its dB; kick and snare hold")
    func grooveLevelsTrackTheTrims() throws {
        let beat = 60.0 / 90.0
        func pattern(_ pitches: Set<UInt8>) -> [ScheduledMIDIEvent] {
            var events: [ScheduledMIDIEvent] = []
            var id: UInt64 = 1
            func add(_ pitch: UInt8, _ beats: Double, _ velocity: UInt8) {
                guard pitches.contains(pitch) else { return }
                events.append(note(pitch, at: beats * beat, velocity: velocity, id: id))
                id += 1
            }
            for bar in 0..<2 {
                let o = Double(bar * 4)
                for b in [0.0, 2.0] { add(36, o + b, 110) }
                for b in [1.0, 3.0] { add(38, o + b, 105) }
                for step in 0..<7 { add(42, o + Double(step) * 0.5, step % 2 == 0 ? 90 : 75) }
                add(46, o + 3.5, 85)
                if bar == 0 { add(49, o, 100) }
            }
            return events
        }
        let seconds = 8 * beat + 2.0
        let neutral = kit(layout: .gm, hats: 0, cymbals: 0)
        let picked = kit(layout: .gm, hats: 23.4, cymbals: 5.7)

        let hatsDelta = levelDb(try render(picked, pattern([42, 46]), seconds: seconds))
            - levelDb(try render(neutral, pattern([42, 46]), seconds: seconds))
        #expect(abs(hatsDelta - 23.4) < 0.05, "hats: commanded 23.4 dB, measured \(hatsDelta)")
        let crashDelta = levelDb(try render(picked, pattern([49]), seconds: seconds))
            - levelDb(try render(neutral, pattern([49]), seconds: seconds))
        #expect(abs(crashDelta - 5.7) < 0.05, "crash: commanded 5.7 dB, measured \(crashDelta)")
        let backbeat = pattern([36, 38])
        let check = sameSamples(try render(picked, backbeat, seconds: seconds),
                                try render(neutral, backbeat, seconds: seconds))
        #expect(check.same, "the trims moved the kick or the snare: \(check.detail)")
    }

    // MARK: - Guards

    /// The ends of both ranges, on every voice at once: finite everywhere (no
    /// NaN, no infinity reaching the bus), and the loud end still bounded.
    @Test("The trims at their range ends render finite samples")
    func extremeTrimsStayFinite() throws {
        for (hats, cymbals) in [(DrumKitParams.hatsLevelDbRange.upperBound,
                                 DrumKitParams.cymbalsLevelDbRange.upperBound),
                                (DrumKitParams.hatsLevelDbRange.lowerBound,
                                 DrumKitParams.cymbalsLevelDbRange.lowerBound)] {
            let samples = try render(kit(layout: .gm, hats: hats, cymbals: cymbals),
                                     everyVoice(.gm), seconds: 2.8)
            #expect(samples.allSatisfy { $0.isFinite }, "non-finite sample at \(hats)/\(cymbals)")
            let peak = samples.map { abs($0) }.max() ?? 0
            #expect(peak < 64, "peak \(peak) at \(hats)/\(cymbals)")
        }
    }
}
