import AVFAudio
import AudioToolbox
import Foundation
import Testing

// THE m12-a (S-0) GATING SPIKE for sidechain routing
// (docs/research/design-m11f-sidechain.md §9 S-0; kept like the M4-ii
// ChainHostAU registration spike, ChainHostAUTests.swift).
//
// Question under measurement — condition zero for the whole feature:
// can AVAudioEngine feed INPUT BUS 1 of an effect node (a ChainHostAU-style
// AUAudioUnit subclass hosted via AVAudioUnitEffect) with a second source
// node, such that the render block's pullInputBlock(bus 1) delivers that
// node's samples SAME-QUANTUM?
//
// The suite measures, with exact-value assertions:
//   1. connection: `connect(_:to:fromBus:0 toBus:1 format:)` with bus 0
//      already occupied — and the AU/node bus counts that gate it;
//   2. delivery + alignment: two distinguishable analytic ramps, bit-exact
//      sample-index equality on BOTH busses (key frame j arrives at exactly
//      main frame j — the == discipline);
//   3. disconnected-bus behavior: the exact OSStatus a bus-1 pull returns
//      with nothing connected (production degrades to self-keyed on it);
//   4. reconfig survival (M9 crash-a discipline): disconnect/reconnect with
//      stop/start between mutations, then full teardown (detach the key
//      node) plus a further graph mutation — no UpdateGraphAfterReconfig
//      explosion, no stale samples, delivery resumes;
//   5. determinism: two consecutive full offline renders byte-identical
//      (the §4-A same-quantum determinism claim).
//
// TEST-ONLY: the AU below is registered from this test process under its own
// component identity 'aufx'/'dwsk'/'DAWP' — production 'dwch' is untouched.

// MARK: - Analytic test signals

/// Main-path ramp (player A → bus 0): strictly positive, unique per frame
/// index at Float precision over the test lengths (ulp at 0.25 ≈ 3e-8).
private func rampA(_ frame: Int) -> Float { 0.25 + Float(frame) * 1e-6 }

/// Key-path ramp (player B → bus 1): strictly negative — a silent-zero or
/// cross-wired bus 1 cannot masquerade as delivery at ANY frame.
private func rampB(_ frame: Int) -> Float { -0.5 - Float(frame) * 1e-6 }

/// Stereo deinterleaved Float32 buffer with `value(frame)` on both channels.
/// The checker calls the SAME function, so equality is bit-exact by
/// construction.
private func makeRamp(format: AVAudioFormat, frames: Int,
                      value: (Int) -> Float) throws -> AVAudioPCMBuffer {
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<frames {
        let sample = value(frame)
        for channel in 0..<Int(format.channelCount) {
            channels[channel][frame] = sample
        }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
}

/// Sentinel recorded when the render block never attempted the bus-1 pull
/// (scratch unallocated). Positive on purpose: no AudioUnit error is > 0.
private let keyPullNotAttempted: OSStatus = 1

// MARK: - The spike AU (test-local, ChainHostAU pattern)

/// Two-input-bus effect AU: bus 0 = main (pulled IN PLACE, passthrough to
/// output — the ChainHostAU render shape), bus 1 = key (pulled into a
/// preallocated scratch, recorded per quantum into a test-inspectable tape).
/// Registered in-process exactly like ChainHostAU (registerSubclass + sync
/// `AVAudioUnitEffect(audioComponentDescription:)`), under a spike-only
/// component identity.
private final class SidechainSpikeAU: AUAudioUnit {
    /// 'aufx' / 'dwsk' / 'DAWP' — distinct from production 'dwch'.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6477_736B,       // 'dwsk'
        componentManufacturer: 0x4441_5750,  // 'DAWP'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(
            SidechainSpikeAU.self,
            as: componentDescription,
            name: "DAWP: SidechainSpike",
            version: 1
        )
    }()

    /// Test-inspectable recording of everything the render block observed.
    /// Allocation happens ONLY in `allocateRenderResources` (grow-once, never
    /// freed on deallocate so the test can read it after `engine.stop()`;
    /// freed in deinit). Render thread only writes through preallocated
    /// pointers; the test reads/resets on the main actor while the engine is
    /// stopped — the production Scratch write-window discipline.
    final class Tape: @unchecked Sendable {
        let quantumCapacity = 8_192
        private(set) var frameCapacity = 0
        private(set) var framesWritten = 0
        private(set) var quantaWritten = 0
        private var mainStore: UnsafeMutablePointer<Float>?   // 2 ch × frameCapacity
        private var keyStore: UnsafeMutablePointer<Float>?    // 2 ch × frameCapacity
        private var timeStore: UnsafeMutablePointer<Double>?
        private var frameStore: UnsafeMutablePointer<Int32>?
        private var status0Store: UnsafeMutablePointer<OSStatus>?
        private var status1Store: UnsafeMutablePointer<OSStatus>?

        /// Main thread, inside the allocate-render-resources window.
        func allocate(frameCapacity: Int) {
            guard mainStore == nil else { return }  // grow-once; capacity fixed
            let sampleCount = 2 * frameCapacity
            mainStore = .allocate(capacity: sampleCount)
            mainStore?.initialize(repeating: 0, count: sampleCount)
            keyStore = .allocate(capacity: sampleCount)
            keyStore?.initialize(repeating: 0, count: sampleCount)
            timeStore = .allocate(capacity: quantumCapacity)
            timeStore?.initialize(repeating: 0, count: quantumCapacity)
            frameStore = .allocate(capacity: quantumCapacity)
            frameStore?.initialize(repeating: 0, count: quantumCapacity)
            status0Store = .allocate(capacity: quantumCapacity)
            status0Store?.initialize(repeating: 0, count: quantumCapacity)
            status1Store = .allocate(capacity: quantumCapacity)
            status1Store?.initialize(repeating: 0, count: quantumCapacity)
            self.frameCapacity = frameCapacity
        }

        /// Main thread, engine stopped (no concurrent render by contract).
        func reset() {
            framesWritten = 0
            quantaWritten = 0
        }

        /// RENDER THREAD. No allocation, no locks — memcpy/memset into the
        /// preallocated stores only. Key/main tapes stay index-aligned: both
        /// advance by `frameCount` every quantum regardless of pull status
        /// (failed pulls record zeros), so tape frame j IS output frame j.
        func record(time: Double, frameCount: Int,
                    status0: OSStatus, status1: OSStatus,
                    out: UnsafeMutableAudioBufferListPointer,
                    keyList: UnsafeMutableAudioBufferListPointer?) {
            guard let mainStore, let keyStore, let timeStore, let frameStore,
                  let status0Store, let status1Store,
                  quantaWritten < quantumCapacity,
                  framesWritten + frameCount <= frameCapacity else { return }
            timeStore[quantaWritten] = time
            frameStore[quantaWritten] = Int32(frameCount)
            status0Store[quantaWritten] = status0
            status1Store[quantaWritten] = status1
            quantaWritten += 1
            let byteCount = frameCount * MemoryLayout<Float>.stride
            for channel in 0..<2 {
                let mainDst = mainStore + channel * frameCapacity + framesWritten
                if status0 == noErr, channel < out.count, let src = out[channel].mData {
                    memcpy(mainDst, src, byteCount)
                } else {
                    memset(mainDst, 0, byteCount)
                }
                let keyDst = keyStore + channel * frameCapacity + framesWritten
                if status1 == noErr, let keyList, channel < keyList.count,
                   let src = keyList[channel].mData {
                    memcpy(keyDst, src, byteCount)
                } else {
                    memset(keyDst, 0, byteCount)
                }
            }
            framesWritten += frameCount
        }

        // Main-thread accessors (engine stopped).
        func time(_ quantum: Int) -> Double {
            guard let timeStore, quantum < quantaWritten else { return .nan }
            return timeStore[quantum]
        }
        func frameCount(_ quantum: Int) -> Int {
            guard let frameStore, quantum < quantaWritten else { return -1 }
            return Int(frameStore[quantum])
        }
        func bus0Status(_ quantum: Int) -> OSStatus {
            guard let status0Store, quantum < quantaWritten else { return keyPullNotAttempted }
            return status0Store[quantum]
        }
        func bus1Status(_ quantum: Int) -> OSStatus {
            guard let status1Store, quantum < quantaWritten else { return keyPullNotAttempted }
            return status1Store[quantum]
        }
        func mainSample(channel: Int, frame: Int) -> Float {
            guard let mainStore, channel < 2, frame < framesWritten else { return .nan }
            return mainStore[channel * frameCapacity + frame]
        }
        func keySample(channel: Int, frame: Int) -> Float {
            guard let keyStore, channel < 2, frame < framesWritten else { return .nan }
            return keyStore[channel * frameCapacity + frame]
        }
        func keyChannel(_ channel: Int) -> [Float] {
            guard let keyStore, channel < 2 else { return [] }
            return Array(UnsafeBufferPointer(
                start: keyStore + channel * frameCapacity, count: framesWritten))
        }

        deinit {
            mainStore?.deallocate()
            keyStore?.deallocate()
            timeStore?.deallocate()
            frameStore?.deallocate()
            status0Store?.deallocate()
            status1Store?.deallocate()
        }
    }

    /// Preallocated render-side storage: main-bus fallback for null-mData
    /// output ABLs (the ChainHostAU substitution path) + the key scratch ABL
    /// the bus-1 pull lands in. (De)allocated only in the render-resources
    /// window / deinit.
    private final class Scratch: @unchecked Sendable {
        private(set) var mainData: UnsafeMutablePointer<Float>?
        private(set) var keyData: UnsafeMutablePointer<Float>?
        private(set) var keyList: UnsafeMutableAudioBufferListPointer?
        private(set) var frameCapacity = 0

        func allocate(frameCapacity: Int) {
            guard mainData == nil || frameCapacity > self.frameCapacity else { return }
            release()
            let sampleCount = 2 * frameCapacity
            mainData = .allocate(capacity: sampleCount)
            mainData?.initialize(repeating: 0, count: sampleCount)
            keyData = .allocate(capacity: sampleCount)
            keyData?.initialize(repeating: 0, count: sampleCount)
            keyList = AudioBufferList.allocate(maximumBuffers: 2)
            self.frameCapacity = frameCapacity
        }

        func release() {
            mainData?.deallocate()
            mainData = nil
            keyData?.deallocate()
            keyData = nil
            if let keyList { free(keyList.unsafeMutablePointer) }
            keyList = nil
            frameCapacity = 0
        }

        deinit { release() }
    }

    let tape = Tape()
    private let scratch = Scratch()
    private let mainInputBus: AUAudioUnitBus
    private let keyInputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private lazy var _inputBusses = AUAudioUnitBusArray(
        audioUnit: self, busType: .input, busses: [mainInputBus, keyInputBus])
    private lazy var _outputBusses = AUAudioUnitBusArray(
        audioUnit: self, busType: .output, busses: [outputBus])

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: "SidechainBusSpike", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no standard 48 kHz stereo format"])
        }
        mainInputBus = try AUAudioUnitBus(format: format)
        keyInputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch.allocate(frameCapacity: max(4_096, Int(maximumFramesToRender)))
        tape.allocate(frameCapacity: 4 * 48_000)
    }

    override func deallocateRenderResources() {
        // Tape and scratch survive deallocate on purpose: the test inspects
        // the tape AFTER engine.stop(), and reconfig phases re-allocate.
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Captures the two boxes only, never self (the ChainHostAU RT rule).
        let tape = tape
        let scratch = scratch
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            let out = UnsafeMutableAudioBufferListPointer(outputData)

            // Null-mData output ABL → substitute preallocated scratch
            // (ChainHostAU.swift:158–170 verbatim discipline).
            if let first = out.first, first.mData == nil {
                guard let base = scratch.mainData,
                      frames <= scratch.frameCapacity,
                      out.count <= 2 else {
                    return kAudioUnitErr_TooManyFramesToProcess
                }
                for channel in 0..<out.count {
                    out[channel].mData =
                        UnsafeMutableRawPointer(base + channel * scratch.frameCapacity)
                    out[channel].mDataByteSize =
                        UInt32(frames * MemoryLayout<Float>.stride)
                }
            }

            // (a) Pull bus 0 IN PLACE — the production main-path shape.
            var pullFlags = AudioUnitRenderActionFlags()
            let status0 = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)

            // (b) Pull bus 1 into the preallocated key scratch. The ABL is
            // re-armed every quantum (a pull may repoint mData at
            // upstream-owned memory; sizes must be reset regardless).
            var status1 = keyPullNotAttempted
            if let keyBase = scratch.keyData, let keyList = scratch.keyList,
               frames <= scratch.frameCapacity {
                for channel in 0..<2 {
                    keyList[channel].mNumberChannels = 1
                    keyList[channel].mData =
                        UnsafeMutableRawPointer(keyBase + channel * scratch.frameCapacity)
                    keyList[channel].mDataByteSize =
                        UInt32(frames * MemoryLayout<Float>.stride)
                }
                var keyFlags = AudioUnitRenderActionFlags()
                status1 = pullInputBlock(&keyFlags, timestamp, frameCount, 1,
                                         keyList.unsafeMutablePointer)
            }

            // (c) Record what both busses delivered, same-quantum.
            tape.record(time: timestamp.pointee.mSampleTime, frameCount: frames,
                        status0: status0, status1: status1,
                        out: out, keyList: scratch.keyList)

            // Bus-1 status NEVER fails the main path (the production
            // degrade-to-self-keyed contract, design §6.2).
            return status0 == noErr ? noErr : status0
        }
    }

    // MARK: Factory (main actor, ChainHostAU pattern)

    @MainActor
    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }
}

// MARK: - Offline rig

/// Manual-rendering harness: playerA → spike bus 0, [playerB → spike bus 1],
/// spike → mainMixer, 48 kHz stereo, 512-frame quanta (the existing
/// DAWEngineTests offline shape).
@MainActor
private final class SpikeRig {
    let engine = AVAudioEngine()
    let playerA = AVAudioPlayerNode()
    let playerB = AVAudioPlayerNode()
    let node: AVAudioUnitEffect
    let au: SidechainSpikeAU
    let format: AVAudioFormat
    private let renderBuffer: AVAudioPCMBuffer

    init() throws {
        format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        node = SidechainSpikeAU.makeNode()
        au = try #require(node.auAudioUnit as? SidechainSpikeAU)
        renderBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(node)
    }

    func connectMainPath() {
        engine.connect(playerA, to: node, fromBus: 0, toBus: 0, format: format)
        engine.connect(node, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: format)
    }

    func connectKey(from player: AVAudioPlayerNode? = nil) {
        engine.connect(player ?? playerB, to: node, fromBus: 0, toBus: 1, format: format)
    }

    func disconnectKey() {
        engine.disconnectNodeInput(node, bus: 1)
    }

    func scheduleAndPlay(_ player: AVAudioPlayerNode, frames: Int,
                         value: (Int) -> Float) throws {
        player.stop()
        let buffer = try makeRamp(format: format, frames: frames, value: value)
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    func render(quanta: Int, quantumFrames: Int = 512) throws -> [[Float]] {
        var output: [[Float]] = [[], []]
        for _ in 0..<quanta {
            let status = try engine.renderOffline(
                AVAudioFrameCount(quantumFrames), to: renderBuffer)
            try #require(status == .success)
            let data = try #require(renderBuffer.floatChannelData)
            let count = Int(renderBuffer.frameLength)
            for channel in 0..<2 {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: count))
            }
        }
        return output
    }
}

/// Frames of a channel-pair array (both channels) not bit-equal to `value`.
/// Returns (mismatchCount, firstMismatchDescription).
private func mismatches(_ channels: [[Float]], frames: Int,
                        against value: (Int) -> Float) -> (count: Int, first: String) {
    var count = 0
    var first = "none"
    for frame in 0..<frames {
        let expected = value(frame)
        for channel in 0..<2 where channels[channel][frame] != expected {
            if count == 0 {
                first = "frame \(frame) ch \(channel): "
                    + "got \(channels[channel][frame]), want \(expected)"
            }
            count += 1
        }
    }
    return (count, first)
}

/// Same, reading the AU tape (main or key side).
private func tapeMismatches(_ tape: SidechainSpikeAU.Tape, key: Bool, frames: Int,
                            against value: (Int) -> Float) -> (count: Int, first: String) {
    var count = 0
    var first = "none"
    for frame in 0..<frames {
        let expected = value(frame)
        for channel in 0..<2 {
            let got = key ? tape.keySample(channel: channel, frame: frame)
                          : tape.mainSample(channel: channel, frame: frame)
            if got != expected {
                if count == 0 {
                    first = "frame \(frame) ch \(channel): got \(got), want \(expected)"
                }
                count += 1
            }
        }
    }
    return (count, first)
}

// MARK: - The spike suite

@MainActor
@Suite("Sidechain bus spike — engine-fed effect input bus 1 (m12-a S-0)", .serialized)
struct SidechainBusSpikeTests {
    @Test("two input busses are reported and connect(toBus:1) succeeds with bus 0 occupied")
    func connectionToKeyBusSucceeds() throws {
        let rig = try SpikeRig()
        // The AU itself reports both busses after sync instantiation…
        #expect(rig.au.inputBusses.count == 2)
        // …and the AVAudioNode surface must agree, else connect(toBus:1)
        // raises NSException before anything renders.
        try #require(rig.node.numberOfInputs == 2)

        rig.connectMainPath()
        rig.connectKey()  // no throw, no crash = the measurement
        let point = rig.engine.inputConnectionPoint(for: rig.node, inputBus: 1)
        #expect(point?.node === rig.playerB)

        try rig.engine.start()
        #expect(rig.au.inputBusses[0].format.sampleRate == 48_000)
        #expect(rig.au.inputBusses[1].format.sampleRate == 48_000)
        _ = try rig.render(quanta: 1)  // graph renders with both edges live
        rig.engine.stop()
        print("[measured] S-0 connection: au busses \(rig.au.inputBusses.count), "
              + "node inputs \(rig.node.numberOfInputs), "
              + "bus-1 point \(point?.node === rig.playerB ? "playerB" : "WRONG"), "
              + "bus-1 format \(rig.au.inputBusses[1].format.sampleRate) Hz")
    }

    @Test("bus-1 pull delivers the key node's samples same-quantum, bit-exact")
    func keyBusDeliversSameQuantumSamples() throws {
        let rig = try SpikeRig()
        try #require(rig.node.numberOfInputs == 2)
        rig.connectMainPath()
        rig.connectKey()
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        try rig.scheduleAndPlay(rig.playerB, frames: 48_000, value: rampB)
        let quanta = 24
        let frames = quanta * 512
        let output = try rig.render(quanta: quanta)
        rig.engine.stop()

        let tape = rig.au.tape
        #expect(tape.framesWritten == frames)
        #expect(tape.quantaWritten == quanta)
        var pullStatusesClean = true
        var timesAligned = true
        for quantum in 0..<tape.quantaWritten {
            if tape.bus0Status(quantum) != noErr { pullStatusesClean = false }
            if tape.bus1Status(quantum) != noErr { pullStatusesClean = false }
            if tape.frameCount(quantum) != 512 { timesAligned = false }
            if tape.time(quantum) != Double(quantum * 512) { timesAligned = false }
        }
        #expect(pullStatusesClean)
        #expect(timesAligned)

        // Main path: bus 0 in place → output, bit-exact (mixer unity is
        // bit-exact per the ChainHostAU spike precedent).
        let outMain = mismatches(output, frames: frames, against: rampA)
        let tapeMain = tapeMismatches(tape, key: false, frames: frames, against: rampA)
        // KEY path: tape frame j must hold player B's frame j — bit-exact
        // sample-index equality IS the same-quantum alignment proof (a
        // one-quantum lag would shift every sample by 512).
        let tapeKey = tapeMismatches(tape, key: true, frames: frames, against: rampB)
        print("[measured] S-0 delivery over \(frames) frames: "
              + "output-vs-rampA mismatches \(outMain.count) (first \(outMain.first)); "
              + "tape-main mismatches \(tapeMain.count) (first \(tapeMain.first)); "
              + "tape-key-vs-rampB mismatches \(tapeKey.count) (first \(tapeKey.first)); "
              + "quantum times aligned \(timesAligned)")
        #expect(outMain.count == 0)
        #expect(tapeMain.count == 0)
        #expect(tapeKey.count == 0)
    }

    @Test("pulling an unconnected bus 1 errors cleanly and never disturbs the main path")
    func unconnectedKeyBusPullErrorsCleanly() throws {
        let rig = try SpikeRig()
        try #require(rig.node.numberOfInputs == 2)
        rig.connectMainPath()  // bus 1 left unconnected on purpose
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        let quanta = 8
        let frames = quanta * 512
        let output = try rig.render(quanta: quanta)
        rig.engine.stop()

        let tape = rig.au.tape
        try #require(tape.quantaWritten == quanta)
        var statuses = Set<OSStatus>()
        for quantum in 0..<tape.quantaWritten {
            statuses.insert(tape.bus1Status(quantum))
        }
        try #require(statuses.count == 1)
        let status = try #require(statuses.first)
        // Distinguish error-vs-silent-zero precisely (report requirement):
        // if the pull claimed success, record what it actually delivered.
        var keyPeak: Float = 0
        for frame in 0..<frames {
            for channel in 0..<2 {
                keyPeak = max(keyPeak, abs(tape.keySample(channel: channel, frame: frame)))
            }
        }
        let outMain = mismatches(output, frames: frames, against: rampA)
        print("[measured] S-0 unconnected bus-1 pull: status \(status) "
              + "(kAudioUnitErr_NoConnection = \(kAudioUnitErr_NoConnection)), "
              + "key tape peak \(keyPeak), main-path mismatches \(outMain.count)")
        // Measured 2026-07-11 (macOS 26 / Darwin 25.4): the pull fails
        // cleanly with kAudioUnitErr_NoConnection — the exact status the
        // production degrade-to-self-keyed guard keys on.
        #expect(status == kAudioUnitErr_NoConnection)
        #expect(keyPeak == 0)          // failed pull recorded as zeros, never garbage
        #expect(outMain.count == 0)    // main path untouched by the bus-1 failure
    }

    @Test("key edge survives disconnect/reconnect/stop-start and teardown + further mutation")
    func keyEdgeSurvivesReconfigCycles() throws {
        let rig = try SpikeRig()
        try #require(rig.node.numberOfInputs == 2)
        rig.connectMainPath()
        rig.connectKey()
        let quanta = 8
        let frames = quanta * 512

        // Phase 1: both connected — baseline delivery.
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        try rig.scheduleAndPlay(rig.playerB, frames: 48_000, value: rampB)
        _ = try rig.render(quanta: quanta)
        rig.engine.stop()
        let phase1 = tapeMismatches(rig.au.tape, key: true, frames: frames, against: rampB)
        #expect(phase1.count == 0)

        // Phase 2: disconnect the key edge (engine stopped — the production
        // quiesce discipline), render main-only.
        rig.disconnectKey()
        rig.au.tape.reset()
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        let output2 = try rig.render(quanta: quanta)
        rig.engine.stop()
        var phase2Statuses = Set<OSStatus>()
        for quantum in 0..<rig.au.tape.quantaWritten {
            phase2Statuses.insert(rig.au.tape.bus1Status(quantum))
        }
        let phase2Main = mismatches(output2, frames: frames, against: rampA)
        #expect(phase2Main.count == 0)

        // Phase 3: reconnect, render — delivery resumes from the NEW
        // buffer's frame 0 (any stale phase-1 sample would mismatch: the
        // tape was reset, rampB re-starts at -0.5).
        rig.connectKey()
        rig.au.tape.reset()
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        try rig.scheduleAndPlay(rig.playerB, frames: 48_000, value: rampB)
        _ = try rig.render(quanta: quanta)
        rig.engine.stop()
        let phase3 = tapeMismatches(rig.au.tape, key: true, frames: frames, against: rampB)
        #expect(phase3.count == 0)

        // Phase 4: FULL teardown of the key source (detach) + a further
        // graph mutation (fresh node onto bus 1) + render — the M9 crash-a
        // UpdateGraphAfterReconfig shape. Surviving this without a crash and
        // with exact delivery is the measurement.
        rig.disconnectKey()
        rig.engine.detach(rig.playerB)
        let playerC = AVAudioPlayerNode()
        rig.engine.attach(playerC)
        rig.connectKey(from: playerC)
        rig.au.tape.reset()
        try rig.engine.start()
        try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
        try rig.scheduleAndPlay(playerC, frames: 48_000, value: rampB)
        _ = try rig.render(quanta: quanta)
        rig.engine.stop()
        let phase4 = tapeMismatches(rig.au.tape, key: true, frames: frames, against: rampB)
        print("[measured] S-0 reconfig: phase1 key mismatches \(phase1.count); "
              + "phase2 (disconnected) statuses \(phase2Statuses.sorted()), "
              + "main mismatches \(phase2Main.count); "
              + "phase3 (reconnected) key mismatches \(phase3.count) (first \(phase3.first)); "
              + "phase4 (teardown+new node) key mismatches \(phase4.count) (first \(phase4.first))")
        #expect(phase4.count == 0)
        #expect(phase2Statuses == [kAudioUnitErr_NoConnection])
    }

    @Test("two consecutive full offline renders are byte-identical (pull-order determinism)")
    func consecutiveRendersAreByteIdentical() throws {
        func renderOnce() throws -> (output: [[Float]], key: [[Float]]) {
            let rig = try SpikeRig()
            try #require(rig.node.numberOfInputs == 2)
            rig.connectMainPath()
            rig.connectKey()
            try rig.engine.start()
            try rig.scheduleAndPlay(rig.playerA, frames: 48_000, value: rampA)
            try rig.scheduleAndPlay(rig.playerB, frames: 48_000, value: rampB)
            let output = try rig.render(quanta: 24)
            rig.engine.stop()
            return (output, [rig.au.tape.keyChannel(0), rig.au.tape.keyChannel(1)])
        }
        let first = try renderOnce()
        let second = try renderOnce()
        #expect(first.output == second.output)
        #expect(first.key == second.key)
        print("[measured] S-0 determinism: outputs identical \(first.output == second.output), "
              + "key tapes identical \(first.key == second.key) "
              + "(\(first.key[0].count) key frames compared)")
    }
}
