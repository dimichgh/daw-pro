import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-dm §8.10 — THE TWO STRUCTURAL TESTS, and they exist because the two
/// worst sites in the instrument path are not compiler-forced.
///
/// ⛔⛔ EVERY TEST THAT CONSTRUCTS AN INSTRUMENT WITH ITS PARAMETERS AND THEN
/// RENDERS IT PASSES WITH `PlaybackGraph`'s parameter-delivery branch DELETED.
/// The whole of `DrumSynthTests` would stay green while every knob in the
/// product did nothing for the life of a session. Only a test that edits a
/// parameter on a LIVE, ALREADY-RENDERING instrument and re-renders can fail —
/// that is `parameterEditReachesASoundingInstrument` below, and plant P10
/// deletes the branch to prove the test is load-bearing rather than decorative.
@MainActor
@Suite("Drum machine — parameter delivery and table coverage", .serialized)
struct DrumSynthDeliveryTests {
    private static let sampleRate = 48_000.0

    private func makeDrums(_ kit: DrumKitParams = DrumKitParams()) -> DrumSynthInstrument {
        let drums = DrumSynthInstrument(params: kit)
        drums.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return drums
    }

    private func hit(_ voice: DrumVoice, at sample: Int64,
                     velocity: UInt8 = 100, id: UInt64 = 1) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: sample, noteID: id,
                           kind: ScheduledMIDIEvent.noteOn,
                           pitch: voice.note, velocity: velocity)
    }

    /// Renders, optionally publishing a new kit part-way through — the live
    /// edit. Returns channel 0.
    private func render(_ drums: DrumSynthInstrument,
                        events unsorted: [ScheduledMIDIEvent],
                        frames totalFrames: Int,
                        applyAt: Int? = nil,
                        apply kitToApply: DrumKitParams? = nil) throws -> [Float] {
        let events = unsorted.sorted { $0.sampleTime < $1.sampleTime }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        var out: [Float] = []
        var cursor = 0, rendered = 0, applied = false
        while rendered < totalFrames {
            if let applyAt, let kitToApply, !applied, rendered >= applyAt {
                drums.apply(params: kitToApply)
                applied = true
            }
            let frames = min(512, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                drums.render(events: slice, renderStart: Int64(rendered),
                             frameCount: frames, output: output)
            }
            cursor = end
            out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            rendered += frames
        }
        return out
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        return (sum / Double(samples.count)).squareRoot()
    }

    // MARK: - The Class C1 catch — THROUGH THE REAL GRAPH

    /// ⛔⛔ THE ONE TEST THAT ACTUALLY CATCHES `PlaybackGraph.swift`'s
    /// parameter-delivery branch, AND IT TOOK A PLANT TO FIND THAT OUT.
    ///
    /// Every other test in this file — including the mid-session one below —
    /// calls `DrumSynthInstrument.apply(params:)` DIRECTLY. Plant P10 (delete
    /// the `case let drums as DrumSynthInstrument` arm from
    /// `PlaybackGraph.applyParameters`) left all seven of them GREEN, because
    /// none of them goes through the graph. The instrument's own delivery was
    /// well covered; the graph's delivery TO the instrument was not covered at
    /// all, which is precisely the site the design flags as the
    /// highest-probability shipping defect.
    ///
    /// So this one drives the REAL `PlaybackGraph`: reconcile a drum track,
    /// publish an edited descriptor through `applyParameters`, and then render
    /// the instrument the graph was handed. If the graph never delivered the
    /// edit, the instrument still holds the factory kit and the measured decay
    /// is the default 0.62 s instead of 1.6 s.
    @Test("PlaybackGraph delivers a drum parameter edit to the live instrument")
    func graphDeliversParameterEdits() throws {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode

        // The instrument the graph will use, held so this test can render it.
        let drums = DrumSynthInstrument(params: DrumKitParams())
        graph.instrumentFactory = { _ in drums }

        var track = Track(name: "Drums", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .drumSynth))
        #expect(graph.reconcile(tracks: [track]))
        graph.applyParameters(tracks: [track])
        try engine.start()
        drums.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)

        // THE EDIT: a new descriptor, published through the graph's own
        // parameter pass — the same call the store's reconcile makes.
        var edited = DrumKitParams()
        edited.setValue(1.6, forParamName: "kick.decay")
        track.instrument = InstrumentDescriptor(kind: .drumSynth, drumKit: edited)
        graph.applyParameters(tracks: [track])

        let samples = try render(drums, events: [hit(.kick, at: 0, id: 1)],
                                 frames: Int(3.0 * Self.sampleRate))
        // −60 dB time, 20 ms hops (a 52 Hz kick has a 19.2 ms period).
        let size = Int(0.02 * Self.sampleRate)
        var hops: [Double] = []
        var index = 0
        while index + size <= samples.count {
            hops.append(rms(samples[index..<(index + size)]))
            index += size
        }
        let peak = try #require(hops.max())
        let crossing = try #require(hops.firstIndex { $0 < peak * 0.001 })
        let measured = Double(crossing) * 0.02
        #expect(measured > 1.2,
                Comment(rawValue: "the graph did not deliver the edit — measured decay "
                    + "\(measured) s, expected about 1.6 s (the factory default is 0.62 s)"))
        engine.stop()
    }

    /// ⭐ THE LIVE-GRAPH DELIVERY TEST. A kit is published MID-SESSION, while
    /// the instrument is already rendering, and the NEXT hit must hear it.
    ///
    /// ⚠️ This covers the INSTRUMENT's delivery path, not the graph's — see
    /// `graphDeliversParameterEdits` above for the site that is not
    /// compiler-forced.
    @Test("A parameter edit published mid-session reaches the next hit")
    func parameterEditReachesASoundingInstrument() throws {
        let frames = Int(2.0 * Self.sampleRate)
        var edited = DrumKitParams()
        edited.setValue(1.6, forParamName: "kick.decay")

        // Hit at 0 (before the edit), hit at 1.0 s (after it).
        let events = [hit(.kick, at: 0, id: 1),
                      hit(.kick, at: Int64(1.0 * Self.sampleRate), id: 2)]
        let control = try render(makeDrums(), events: events, frames: frames)
        let live = try render(makeDrums(), events: events, frames: frames,
                              applyAt: Int(0.5 * Self.sampleRate), apply: edited)

        // The FIRST hit is identical in both: it latched before the edit.
        #expect(Array(control[0..<Int(0.4 * Self.sampleRate)])
            == Array(live[0..<Int(0.4 * Self.sampleRate)]),
                "the edit reached back into a hit that had already started")

        // The SECOND hit must be longer. At 1.55 s the default 0.62 s kick is
        // ~53 dB down from its onset; the 1.6 s one is only ~21 dB down.
        let late = Int(1.50 * Self.sampleRate)..<Int(1.70 * Self.sampleRate)
        let controlTail = rms(control[late])
        let liveTail = rms(live[late])
        #expect(liveTail > controlTail * 4,
                Comment(rawValue: "the mid-session decay edit did not reach the next hit: "
                    + "control tail \(controlTail), live tail \(liveTail)"))
    }

    /// `level` and `pan` are the ONLY two parameters a SOUNDING voice re-reads.
    /// The contract says so; this measures it.
    @Test("level moves a sounding voice; decay does not")
    func outputStageMovesASoundingVoice() throws {
        let frames = Int(1.5 * Self.sampleRate)
        var quieter = DrumKitParams()
        quieter.setValue(0.05, forParamName: "cymbal.level")
        let events = [hit(.cymbal, at: 0, id: 1)]

        let control = try render(makeDrums(), events: events, frames: frames)
        let edited = try render(makeDrums(), events: events, frames: frames,
                                applyAt: Int(0.3 * Self.sampleRate), apply: quieter)
        let after = Int(0.5 * Self.sampleRate)..<Int(0.9 * Self.sampleRate)
        #expect(rms(edited[after]) < rms(control[after]) * 0.5,
                "level did not move a sounding voice")

        // And the invariance half: a LATCHED parameter must NOT move it.
        var longer = DrumKitParams()
        longer.setValue(3.5, forParamName: "cymbal.decay")
        let latched = try render(makeDrums(), events: events, frames: frames,
                                 applyAt: Int(0.3 * Self.sampleRate), apply: longer)
        #expect(latched == control,
                Comment(rawValue: "a decay edit changed a voice that had already started "
                    + "— one-shot parameters must latch at note-on"))
    }

    // MARK: - The spec-table-driven consumer test

    /// ⭐⭐ THE HIGHEST-VALUE TEST IN THE PLAN: every row of the table is driven
    /// from the TABLE, never from a hand-written list. A parameter that exists
    /// in the schema with no render-path consumer — the m39-e inert-LFO shape,
    /// generalised to all 75 at once — reddens here.
    ///
    /// ⚠️ It asserts each parameter CHANGES THE RENDER at the ends of its own
    /// range. That is a weaker claim than the per-voice physics rows above and
    /// it is deliberately kept weak: this row's job is COVERAGE (nothing is
    /// inert), and `DrumSynthTests`' job is CORRECTNESS (each axis does the
    /// right thing). Distinctness alone proves nothing about direction, which
    /// is exactly why both files exist.
    @Test("Every one of the 75 parameters reaches the render path")
    func everyParameterHasAConsumer() throws {
        let frames = Int(1.2 * Self.sampleRate)
        var inert: [String] = []

        for spec in DrumKitParams.paramSpecs {
            // `kit.*` parameters apply to every voice; a voice parameter is
            // heard on its own voice. Trigger a hit that can hear it.
            let voice = spec.voice ?? .snare
            // ⚠️ VELOCITY 110 IS A FIXTURE DECISION, NOT A DEFAULT. It sits
            // ABOVE the default `kit.accentThreshold` of 100, so an accent
            // actually fires — without which `kit.accentDepth` is multiplied
            // by zero and reads as inert when it is merely unreached. (It did:
            // at velocity 60 this test named `kit.accentDepth` among the dead
            // parameters, which would have been a false defect.) 110 still
            // leaves `accentThreshold` measurable, since sweeping it to 127
            // turns the accent off and to 1 turns it on.
            let events = [hit(voice, at: 0, velocity: 110, id: 1)]

            var low = DrumKitParams()
            low.setValue(spec.range.lowerBound, forParamName: spec.name)
            var high = DrumKitParams()
            high.setValue(spec.range.upperBound, forParamName: spec.name)

            let a = try render(makeDrums(low), events: events, frames: frames)
            let b = try render(makeDrums(high), events: events, frames: frames)
            if a == b { inert.append(spec.name) }
        }
        #expect(inert.isEmpty,
                Comment(rawValue: "these parameters are in the table but change NOTHING in "
                    + "the render: \(inert.joined(separator: ", "))"))
    }

    /// The control on the control: if the harness could not tell two renders
    /// apart at all, the row above would pass on a completely dead instrument.
    @Test("The coverage harness can tell two renders apart")
    func coverageHarnessHasAPositiveControl() throws {
        let frames = Int(0.5 * Self.sampleRate)
        let events = [hit(.kick, at: 0, id: 1)]
        var loud = DrumKitParams()
        loud.setValue(1.0, forParamName: "kick.level")
        var quiet = DrumKitParams()
        quiet.setValue(0.0, forParamName: "kick.level")
        let a = try render(makeDrums(loud), events: events, frames: frames)
        let b = try render(makeDrums(quiet), events: events, frames: frames)
        #expect(a != b)
        // And the same kit twice IS identical — so "different" means something.
        let c = try render(makeDrums(loud), events: events, frames: frames)
        #expect(a == c, "two renders of the same kit differ — the harness is not deterministic")
    }

    // MARK: - Modulation delivery

    /// A route on a drum parameter must actually reach the render thread.
    /// Before the `spec.code` refactor it was validated, accepted, and then
    /// dropped from the published snapshot — a success response and silence.
    @Test("A modulation route on a drum parameter changes the sound")
    func modulationRouteIsDelivered() throws {
        let frames = Int(1.0 * Self.sampleRate)
        let events = [hit(.kick, at: 0, id: 1)]

        let source = ModulationSource(kind: .macro,
            params: .macro(MacroSourceParams(value: 1.0)))
        let route = ModulationRoute(
            sourceID: source.id,
            target: .instrumentParam(paramName: "kick.tune"), depth: 1.0)
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(
                sources: [source], routes: [route],
                instrument: InstrumentDescriptor(kind: .drumSynth),
                isInstrumentTrack: true),
            generation: 1, timelineID: 1, sampleRate: Self.sampleRate,
            originSample: 0, positionValid: true))

        let plain = makeDrums()
        let control = try render(plain, events: events, frames: frames)

        let modulated = makeDrums()
        modulated.publishModulation(snapshot)
        let moved = try render(modulated, events: events, frames: frames)

        #expect(moved != control, "the modulation route was silently dropped")

        // ⭐ AND THE PHYSICS, because distinct bytes prove nothing: a route on
        // `tune` must move the kick's PITCH, not merely perturb it.
        func fundamental(_ samples: [Float]) -> Double {
            var best = 0.0, bestFrequency = 0.0
            var frequency = 20.0
            while frequency < 200 {
                let w = 2.0 * Double.pi * frequency / Self.sampleRate
                let coeff = 2.0 * cos(w)
                var s1 = 0.0, s2 = 0.0
                for index in Int(0.15 * Self.sampleRate)..<Int(0.45 * Self.sampleRate) {
                    let s0 = Double(samples[index]) + coeff * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                let magnitude = max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0).squareRoot()
                if magnitude > best { best = magnitude; bestFrequency = frequency }
                frequency *= 1.01
            }
            return bestFrequency
        }
        let controlPitch = fundamental(control)
        let movedPitch = fundamental(moved)
        #expect(abs(movedPitch - controlPitch) / controlPitch > 0.05,
                Comment(rawValue: "a full-depth tune route moved the fundamental from "
                    + "\(controlPitch) Hz only to \(movedPitch) Hz"))
    }

    /// Unpublishing a snapshot must restore the knob values — a route's REMOVAL
    /// is not proof it took, any more than a setter's return is.
    @Test("Removing a route restores the un-modulated sound")
    func unpublishingRestoresTheKnobs() throws {
        let frames = Int(0.8 * Self.sampleRate)
        let events = [hit(.kick, at: 0, id: 1)]
        let source = ModulationSource(kind: .macro,
            params: .macro(MacroSourceParams(value: 1.0)))
        let route = ModulationRoute(
            sourceID: source.id,
            target: .instrumentParam(paramName: "kick.tune"), depth: 1.0)
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(
                sources: [source], routes: [route],
                instrument: InstrumentDescriptor(kind: .drumSynth),
                isInstrumentTrack: true),
            generation: 1, timelineID: 1, sampleRate: Self.sampleRate,
            originSample: 0, positionValid: true))

        let control = try render(makeDrums(), events: events, frames: frames)
        let drums = makeDrums()
        drums.publishModulation(snapshot)
        _ = try render(drums, events: events, frames: frames)
        drums.publishModulation(nil)
        drums.reset()
        let restored = try render(drums, events: events, frames: frames)
        #expect(restored == control, "the last modulated value stuck after unpublishing")
    }

    /// ⭐ THE BYTE-IDENTITY ROW. A kit with NO routes must render
    /// bit-identically to one that never saw the modulation machinery at all —
    /// proof the stride branch cannot move a bit on an unmodulated patch.
    @Test("An unmodulated kit is bit-identical with and without an empty snapshot")
    func unmodulatedRenderIsUntouched() throws {
        let frames = Int(0.8 * Self.sampleRate)
        let events = [hit(.snare, at: 0, id: 1)]
        let plain = try render(makeDrums(), events: events, frames: frames)
        let drums = makeDrums()
        drums.publishModulation(nil)
        let withNil = try render(drums, events: events, frames: frames)
        #expect(plain == withNil)
    }
}
