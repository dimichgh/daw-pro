import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Hosted-AU parameter surface (design-au-parameter-surface): describe/set
/// against REAL system AUs — AUDelay ('aufx dely appl') for the effect flavor,
/// DLSMusicDevice ('aumu dls appl') for the instrument flavor. Tree sizes and
/// addresses are MEASURED at test time, never assumed (the suite's stance);
/// the delay-move test asserts the AUDIBLE truth (the echo peak moves), not
/// just API truth. All control-plane: no hardware start, no render thread.
@MainActor
@Suite("Hosted-AU parameter surface", .serialized)
struct AUParameterSurfaceTests {
    private static let delay = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    /// An AudioEngine whose registry hosts one ready AUDelay insert.
    private func preparedDelay() async throws -> (engine: AudioEngine, effectID: UUID) {
        let engine = AudioEngine()
        let effectID = UUID()
        await engine.auRegistry.prepareEffect(
            effectID: effectID, config: AudioUnitConfig(component: Self.delay),
            sampleRate: 48_000)
        #expect(engine.auRegistry.effectStatus[effectID] == .ready)
        return (engine, effectID)
    }

    @Test("describe on AUDelay: real tree, decimal-string addresses, a writable seconds param")
    func describeDelayTree() async throws {
        let (engine, effectID) = try await preparedDelay()
        let page = try #require(try engine.describeHostedAUParameters(
            .effect(effectID: effectID), offset: 0, maxParams: 512, addresses: nil))
        print("[measured] AUDelay tree: totalCount \(page.totalCount) — "
              + page.parameters
                    .map { "\($0.identifier)=\($0.address) (\($0.unit))" }
                    .joined(separator: ", "))
        #expect(page.hasParameterTree)
        #expect(page.totalCount > 0)
        #expect(page.parameters.count == page.totalCount)  // 512 covers AUDelay
        #expect(!page.truncated)
        #expect(page.offset == 0)
        #expect(page.unknownAddresses.isEmpty)
        for info in page.parameters {
            #expect(UInt64(info.address) != nil,
                    "address '\(info.address)' is not a decimal UInt64 string")
        }
        // AUDelay's delay time: a real, writable seconds param with a sane range.
        let seconds = try #require(page.parameters.first { $0.unit == "seconds" })
        #expect(seconds.writable)
        #expect(seconds.readable)
        #expect(seconds.maxValue > seconds.minValue)
        #expect(seconds.value >= seconds.minValue && seconds.value <= seconds.maxValue)
    }

    @Test("set by address: read-back echo, describe agrees, out-of-range clamps both ways")
    func setReadBackAndClamp() async throws {
        let (engine, effectID) = try await preparedDelay()
        let target = HostedAUTarget.effect(effectID: effectID)
        let page = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 512, addresses: nil))
        let delayTime = try #require(page.parameters.first { $0.unit == "seconds" })

        let echoed = try engine.setHostedAUParameter(
            target, address: delayTime.address, value: 0.25)
        print("[measured] AUDelay \(delayTime.identifier) set 0.25 → read-back \(echoed.value)")
        #expect(abs(echoed.value - 0.25) < 1e-3)
        #expect(echoed.address == delayTime.address)

        // A fresh describe (exact-get filter) re-reads the live value.
        let after = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 512, addresses: [delayTime.address]))
        #expect(after.unknownAddresses.isEmpty)
        let refreshed = try #require(after.parameters.first)
        #expect(abs(refreshed.value - 0.25) < 1e-3)

        // Silent clamp: past max lands ON max, below min ON min — the echo is
        // the truth, never an error (fx.setParam precedent).
        let high = try engine.setHostedAUParameter(
            target, address: delayTime.address, value: 1e6)
        print("[measured] clamp high: 1e6 → \(high.value) (max \(delayTime.maxValue))")
        #expect(abs(high.value - delayTime.maxValue) < 1e-3)
        let low = try engine.setHostedAUParameter(
            target, address: delayTime.address, value: -1e6)
        print("[measured] clamp low: -1e6 → \(low.value) (min \(delayTime.minValue))")
        #expect(abs(low.value - delayTime.minValue) < 1e-3)
    }

    @Test("paging with maxParams:1 walks the whole tree in stable order with honest truncation")
    func pagingWalksTree() async throws {
        let (engine, effectID) = try await preparedDelay()
        let target = HostedAUTarget.effect(effectID: effectID)
        let full = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 4_096, addresses: nil))
        var walked: [String] = []
        var offset = 0
        while true {
            let page = try #require(try engine.describeHostedAUParameters(
                target, offset: offset, maxParams: 1, addresses: nil))
            #expect(page.totalCount == full.totalCount)
            #expect(page.offset == offset)
            if page.parameters.isEmpty { break }
            #expect(page.parameters.count == 1)
            #expect(page.truncated == (offset + 1 < full.totalCount),
                    "truncated must be honest at offset \(offset)")
            walked.append(page.parameters[0].address)
            offset += 1
            if !page.truncated { break }
        }
        print("[measured] paged walk collected \(walked.count) of \(full.totalCount) addresses")
        #expect(walked == full.parameters.map(\.address))  // same order, complete

        // Paging past the end: empty page, honest untruncated.
        let past = try #require(try engine.describeHostedAUParameters(
            target, offset: full.totalCount + 10, maxParams: 1, addresses: nil))
        #expect(past.parameters.isEmpty)
        #expect(!past.truncated)
    }

    @Test("addresses filter: hits return infos, misses land in unknownAddresses")
    func addressesFilter() async throws {
        let (engine, effectID) = try await preparedDelay()
        let target = HostedAUTarget.effect(effectID: effectID)
        let full = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 512, addresses: nil))
        let first = try #require(full.parameters.first)
        // A parseable-but-absent address AND an unparseable one both land in
        // unknownAddresses — reported, never an error.
        let page = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 512,
            addresses: [first.address, "18446744073709551615", "not-a-number"]))
        #expect(page.parameters.map(\.address) == [first.address])
        #expect(page.unknownAddresses == ["18446744073709551615", "not-a-number"])
        #expect(page.totalCount == full.totalCount)  // totalCount stays the tree size
    }

    @Test("set errors: unknown address, malformed address, non-finite value, no hosted AU")
    func setErrorTaxonomy() async throws {
        let (engine, effectID) = try await preparedDelay()
        let target = HostedAUTarget.effect(effectID: effectID)
        #expect(throws: HostedAUParameterError.unknownAddress("18446744073709551615")) {
            try engine.setHostedAUParameter(target, address: "18446744073709551615", value: 0)
        }
        #expect(throws: HostedAUParameterError.invalidAddress("nope")) {
            try engine.setHostedAUParameter(target, address: "nope", value: 0)
        }
        #expect(throws: HostedAUParameterError.nonFiniteValue) {
            try engine.setHostedAUParameter(target, address: "0", value: .nan)
        }
        // Unknown target: describe answers nil, set throws .noHostedAU.
        #expect(try engine.describeHostedAUParameters(
            .effect(effectID: UUID()), offset: 0, maxParams: 512, addresses: nil) == nil)
        #expect(throws: HostedAUParameterError.noHostedAU) {
            try engine.setHostedAUParameter(.effect(effectID: UUID()), address: "0", value: 0)
        }
    }

    @Test("audible truth: moving delayTime by address moves the impulse echo peak")
    func movedDelayTimeMovesEcho() async throws {
        let engine = AudioEngine()
        let effectID = UUID()
        let config = AudioUnitConfig(component: Self.delay)
        await engine.auRegistry.prepareEffect(
            effectID: effectID, config: config, sampleRate: 48_000)
        #expect(engine.auRegistry.effectStatus[effectID] == .ready)
        let target = HostedAUTarget.effect(effectID: effectID)

        let page = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 512, addresses: nil))
        let delayTime = try #require(page.parameters.first { $0.unit == "seconds" })
        let defaultSeconds = delayTime.value
        let defaultFrames = Int((defaultSeconds * 48_000).rounded())
        let movedSeconds = 0.3
        print("[measured] AUDelay default delayTime \(defaultSeconds) s — moving to \(movedSeconds) s")
        #expect(abs(defaultSeconds - movedSeconds) > 0.2)  // the move must be observable
        let echoed = try engine.setHostedAUParameter(
            target, address: delayTime.address, value: movedSeconds)
        #expect(abs(echoed.value - movedSeconds) < 1e-3)

        // Render an impulse through the chain hosting THIS live instance
        // (the AUEffectHostingTests harness) and find the delayed peak.
        let descriptor = EffectDescriptor(id: effectID, kind: .audioUnit, audioUnit: config)
        let processor = EffectChainProcessor()
        let chainState = EffectChainState(processor: processor)
        let registry = engine.auRegistry
        chainState.hostedEffectProvider = { registry.preparedEffect(forEffect: $0) }
        chainState.sync(descriptors: [descriptor], sampleRate: 48_000)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))

        let quantum = 4_096
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        let movedFrames = Int((movedSeconds * 48_000).rounded())
        let quanta = (movedFrames + 24_000 + quantum - 1) / quantum
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

        // The delayed peak, searched past the first quantum (dry region).
        var peakIndex = quantum
        var peakValue: Float = 0
        for frame in quantum..<output.count where abs(output[frame]) > peakValue {
            peakValue = abs(output[frame])
            peakIndex = frame
        }
        print("[measured] echo peak \(peakValue) at frame \(peakIndex) "
              + "(expected ≈ \(movedFrames), default would be \(defaultFrames))")
        #expect(peakValue > 0.1)
        #expect(abs(peakIndex - movedFrames) <= 240)      // within 5 ms of the SET time
        #expect(abs(peakIndex - defaultFrames) > 4_800)   // and clearly NOT at the default
    }

    @Test("instrument flavor: hosted DLSMusicDevice describes (and sets) by trackID target")
    func dlsInstrumentFlavor() async throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument,
                          instrument: InstrumentDescriptor(
                              kind: .audioUnit,
                              audioUnit: AudioUnitConfig(component: Self.dls)))
        await engine.auRegistry.prepare(track: track, sampleRate: 48_000)
        #expect(engine.auRegistry.status[track.id] == .ready)
        let target = HostedAUTarget.instrument(trackID: track.id)

        let page = try #require(try engine.describeHostedAUParameters(
            target, offset: 0, maxParams: 4_096, addresses: nil))
        print("[measured] DLSMusicDevice: hasParameterTree \(page.hasParameterTree), "
              + "totalCount \(page.totalCount)"
              + (page.parameters.isEmpty ? "" : " — "
                 + page.parameters.prefix(8)
                       .map { "\($0.identifier)=\($0.address) (\($0.unit))" }
                       .joined(separator: ", ")))
        // Never assume tree sizes (the suite's stance): a small — even empty —
        // tree is tolerated; the assertions below are structural.
        #expect(page.offset == 0)
        #expect(page.parameters.count == page.totalCount)
        #expect(!page.truncated)
        for info in page.parameters {
            #expect(UInt64(info.address) != nil)
        }
        // If any writable ranged param exists, a set round-trips within range.
        if let writable = page.parameters.first(where: { $0.writable && $0.maxValue > $0.minValue }) {
            let mid = (writable.minValue + writable.maxValue) / 2
            let echoed = try engine.setHostedAUParameter(
                target, address: writable.address, value: mid)
            print("[measured] DLS set \(writable.identifier) → \(echoed.value) (asked \(mid))")
            #expect(echoed.value >= writable.minValue && echoed.value <= writable.maxValue)
        }
    }
}
