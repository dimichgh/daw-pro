import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (v) Audio Unit EFFECT hosting, headless: Apple's stock 'aufx' units
/// (AUDelay 'dely', AUPeakLimiter 'lmtr', AULowpass 'lpas' — all v2, hostable
/// from SPM) as inserts in the existing chain. AU output is NEVER
/// bit-exact/null-tested — assertions are peak-position/RMS/latency facts.
/// Defaults (AUDelay's delayTime) are read from the live parameter tree at
/// test time, never assumed. 48 kHz stereo throughout.
@MainActor
@Suite("AU effect hosting", .serialized)
struct AUEffectHostingTests {
    private static let delay = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")
    private static let limiter = AudioUnitComponentID(
        type: "aufx", subType: "lmtr", manufacturer: "appl")
    private static let lowpass = AudioUnitComponentID(
        type: "aufx", subType: "lpas", manufacturer: "appl")

    /// A synced single-effect chain whose `.audioUnit` unit resolves from the
    /// given registry (nil registry → the passthrough placeholder path).
    private func makeChain(descriptor: EffectDescriptor, registry: AUHostRegistry?)
        -> (EffectChainProcessor, EffectChainState) {
        let processor = EffectChainProcessor()
        let chainState = EffectChainState(processor: processor)
        if let registry {
            chainState.hostedEffectProvider = { registry.preparedEffect(forEffect: $0) }
        }
        chainState.sync(descriptors: [descriptor], sampleRate: 48_000)
        return (processor, chainState)
    }

    @Test("registry lists Apple's stock 'aufx' effects (AUDelay, AUPeakLimiter, AULowpass)")
    func listsAppleEffectComponents() {
        let effects = AUHostRegistry.listEffectComponents()
        print("[measured] \(effects.count) installed effect components: "
              + effects.prefix(12)
                       .map { "\($0.name) (\($0.component.subType)/\($0.component.manufacturer))" }
                       .joined(separator: ", ") + " …")
        #expect(effects.contains { $0.component == Self.delay })
        #expect(effects.contains { $0.component == Self.limiter })
        #expect(effects.contains { $0.component == Self.lowpass })
        #expect(effects.allSatisfy { $0.component.type == "aufx" })
    }

    @Test("hosted AUDelay delays an impulse by its default delayTime through the chain walk")
    func hostedDelayDelaysImpulse() async throws {
        let registry = AUHostRegistry()
        let effectID = UUID()
        let config = AudioUnitConfig(component: Self.delay)
        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 48_000)
        #expect(registry.effectStatus[effectID] == .ready)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))

        // Default delayTime from the live tree — never assumed.
        let delayParam = try #require(
            hosted.auAudioUnit.parameterTree?.allParameters.first { $0.unit == .seconds })
        let delaySeconds = Double(delayParam.value)
        let delayFrames = Int((delaySeconds * 48_000).rounded())
        print("[measured] AUDelay default delayTime \(delaySeconds) s "
              + "→ expected echo at frame \(delayFrames)")
        #expect(delaySeconds > 0.2)  // a real delay, well past 200 ms

        let descriptor = EffectDescriptor(id: effectID, kind: .audioUnit, audioUnit: config)
        let (processor, _) = makeChain(descriptor: descriptor, registry: registry)

        let quantum = 4_096
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]

        let quanta = (delayFrames + 24_000 + quantum - 1) / quantum
        var output: [Float] = []
        output.reserveCapacity(quanta * quantum)
        for index in 0..<quanta {
            memset(left, 0, quantum * MemoryLayout<Float>.stride)
            memset(right, 0, quantum * MemoryLayout<Float>.stride)
            if index == 0 { left[0] = 1; right[0] = 1 }  // unit impulse at frame 0
            processor.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
            output.append(contentsOf: UnsafeBufferPointer(start: left, count: quantum))
        }
        #expect(hosted.lastRenderError == nil)

        // Dry half of the default wet/dry mix passes at frame 0.
        print("[measured] dry impulse passthrough at frame 0: \(output[0])")
        #expect(abs(output[0]) > 0.25)

        // The delayed peak, searched past the first quantum (dry region).
        var peakIndex = quantum
        var peakValue: Float = 0
        for frame in quantum..<output.count where abs(output[frame]) > peakValue {
            peakValue = abs(output[frame])
            peakIndex = frame
        }
        print("[measured] delayed peak \(peakValue) at frame \(peakIndex) "
              + "(expected ≈ \(delayFrames), Δ = \(peakIndex - delayFrames))")
        #expect(peakValue > 0.1)
        #expect(abs(peakIndex - delayFrames) <= 240)  // within 5 ms of default delayTime
        #expect(peakIndex > 9_600)                    // cross-check: past 200 ms
    }

    @Test("offline render: an AUDelay insert on an instrument strip echoes a short note")
    func offlineRenderDelayEchoesNote() async throws {
        let effect = EffectDescriptor(kind: .audioUnit,
                                      audioUnit: AudioUnitConfig(component: Self.delay))
        let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 69, velocity: 127, startBeat: 0, lengthBeats: 1),
        ])
        var track = Track(name: "T", kind: .instrument, clips: [clip],
                          instrument: InstrumentDescriptor(kind: .testTone))
        track.effects = [effect]

        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        #expect(renderer.auRegistry.effectStatus[effect.id] == .ready)
        let hosted = try #require(renderer.auRegistry.preparedEffect(forEffect: effect.id))
        let delaySeconds = Double(try #require(
            hosted.auAudioUnit.parameterTree?.allParameters.first { $0.unit == .seconds }).value)
        print("[measured] AUDelay default delayTime (offline registry): \(delaySeconds) s")
        #expect(delaySeconds > 0.75)  // window math below assumes the stock ~1 s default

        // Note @ 120 BPM occupies 0–0.5 s; its wet echo starts at delayTime.
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: delaySeconds + 1.0)
        let leftChannel = audio.channelData[0]
        let gap = 33_600..<Int(48_000 * (delaySeconds - 0.05))
        let echoStart = Int(48_000 * (delaySeconds + 0.1))
        let echo = echoStart..<(echoStart + 14_400)
        let gapRMS = TestSignals.rms(leftChannel, in: gap)
        let echoRMS = TestSignals.rms(leftChannel, in: echo)
        print("[measured] offline echo: gap RMS \(gapRMS), echo-window RMS \(echoRMS)")
        #expect(echoRMS > 0.02)             // the echo audibly exists
        #expect(gapRMS < 0.1 * echoRMS)     // and only AFTER delayTime, not before
    }

    @Test("AUPeakLimiter reports nonzero latency, flowing into the chain's per-effect latency")
    func peakLimiterLatencyFlowsThroughChain() async throws {
        let registry = AUHostRegistry()
        let effectID = UUID()
        let config = AudioUnitConfig(component: Self.limiter)
        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 48_000)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))
        print("[measured] AUPeakLimiter latencySamples @ 48 kHz: \(hosted.latencySamples)")
        #expect(hosted.latencySamples > 0)

        let descriptor = EffectDescriptor(id: effectID, kind: .audioUnit, audioUnit: config)
        let (_, chainState) = makeChain(descriptor: descriptor, registry: registry)
        #expect(chainState.latencySamples(forEffect: effectID) == hosted.latencySamples)
        #expect(chainState.latencySamples == hosted.latencySamples)
    }

    @Test("fullState round-trips: a tree-set parameter restores into a re-hosted AULowpass")
    func fullStateRoundTripRestoresParameter() async throws {
        let registry = AUHostRegistry()
        let effectID = UUID()
        await registry.prepareEffect(effectID: effectID,
                                     config: AudioUnitConfig(component: Self.lowpass),
                                     sampleRate: 48_000)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))
        let cutoff = try #require(
            hosted.auAudioUnit.parameterTree?.allParameters.first { $0.unit == .hertz })
        print("[measured] AULowpass cutoff default \(cutoff.value) Hz — setting 1234 Hz")
        #expect(cutoff.value != 1_234)  // the restore below must be observable
        cutoff.value = 1_234
        let state = try #require(registry.effectState(forEffect: effectID))
        print("[measured] AULowpass fullStateForDocument: \(state.count) bytes (binary plist)")

        registry.releaseEffect(forEffect: effectID)
        #expect(registry.preparedEffect(forEffect: effectID) == nil)

        await registry.prepareEffect(
            effectID: effectID,
            config: AudioUnitConfig(component: Self.lowpass, stateData: state),
            sampleRate: 48_000)
        #expect(registry.effectStatus[effectID] == .ready)
        let rehosted = try #require(registry.preparedEffect(forEffect: effectID))
        let restored = try #require(
            rehosted.auAudioUnit.parameterTree?.allParameters.first { $0.unit == .hertz })
        print("[measured] restored cutoff \(restored.value) Hz")
        #expect(abs(restored.value - 1_234) < 1)
    }

    @Test("a bogus component reports .missing; a componentless insert is rejected at the store")
    func bogusComponentAndStoreValidation() async throws {
        let registry = AUHostRegistry()
        let effectID = UUID()
        await registry.prepareEffect(
            effectID: effectID,
            config: AudioUnitConfig(component: AudioUnitComponentID(
                type: "aufx", subType: "zzzz", manufacturer: "zzzz")),
            sampleRate: 48_000)
        #expect(registry.effectStatus[effectID] == .missing)
        #expect(registry.preparedEffect(forEffect: effectID) == nil)

        // kind == .audioUnit && audioUnit == nil is invalid at the store
        // boundary (unlike the instrument rule).
        let store = ProjectStore()
        let trackID = store.addTrack(kind: .audio).id
        do {
            _ = try store.addEffect(toTrack: trackID, kind: .audioUnit)
            Issue.record("expected audioUnitEffectRequiresComponent")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("requires a component selection") == true)
        }
        #expect(store.tracks[0].effects.isEmpty)
    }

    @Test("an unprepared audioUnit insert is a bit-exact passthrough with zero latency")
    func placeholderPassthroughIsBitExact() throws {
        // No provider wired → the factory's PassthroughEffect placeholder.
        let descriptor = EffectDescriptor(kind: .audioUnit,
                                          audioUnit: AudioUnitConfig(component: Self.delay))
        let (processor, chainState) = makeChain(descriptor: descriptor, registry: nil)
        #expect(chainState.unit(forEffect: descriptor.id)?.instance is PassthroughEffect)
        #expect(chainState.latencySamples(forEffect: descriptor.id) == 0)

        let quantum = 4_096
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for frame in 0..<quantum {
            left[frame] = sinf(Float(frame) * 0.01)
            right[frame] = cosf(Float(frame) * 0.013)
        }
        let expectedLeft = Array(UnsafeBufferPointer(start: left, count: quantum))
        let expectedRight = Array(UnsafeBufferPointer(start: right, count: quantum))
        processor.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
        #expect(Array(UnsafeBufferPointer(start: left, count: quantum)) == expectedLeft)
        #expect(Array(UnsafeBufferPointer(start: right, count: quantum)) == expectedRight)
    }
}
