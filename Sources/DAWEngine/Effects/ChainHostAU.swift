import AVFAudio
import AudioToolbox
import CAtomics
import Foundation

/// The per-strip insert point (M4 ii). AVAudioEngine has no processing-
/// callback node with an input, so the insert must be a real AU: this
/// `AUAudioUnit` subclass is registered IN-PROCESS via
/// `AUAudioUnit.registerSubclass` under the private component identity
/// `{type:'aufx', subType:'dwch', manufacturer:'DAWP'}` and instantiated
/// synchronously through `AVAudioUnitEffect(audioComponentDescription:)`
/// (v3-in-process units are v2-bridgeable in the registering process).
/// No app bundle, no entitlements, no Xcode — process-local runtime
/// registration only.
///
/// `internalRenderBlock` pulls input IN PLACE (passes the output ABL to
/// `pullInputBlock`) and walks this instance's `EffectChainProcessor`.
/// Empty chain = pull-through: zero added latency, no copy. Chain edits are
/// atomic snapshot publishes into the processor — the node itself is
/// PERMANENT per strip and graph topology never moves for a chain edit.
///
/// SIDECHAIN (m12-f S-2, design-m11f-sidechain §4-A, proven by the m12-a
/// spike `SidechainBusSpikeTests`): input bus 1 is the strip's KEY input —
/// a real graph edge from the key source's post-fader mixer, pulled
/// same-quantum into a preallocated key scratch and handed to the chain
/// walk, iff the atomic key-connected flag is armed. The key NEVER sums
/// into the audio path (analysis-only), a bus-1 pull error degrades to
/// self-keyed (the spike's clean −10876 shape, §6.2), and with the flag
/// down the render block never touches bus 1 — the pre-sidechain path,
/// bit-exact (condition 4).
final class ChainHostAU: AUAudioUnit {
    /// 'aufx' / 'dwch' / 'DAWP'.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6477_6368,       // 'dwch'
        componentManufacturer: 0x4441_5750,  // 'DAWP'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// One-time process-local registration (thread-safe static-let lazy init).
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(
            ChainHostAU.self,
            as: componentDescription,
            name: "DAWP: ChainHost",
            version: 1
        )
    }()

    /// This strip's chain walker. The render block captures ONLY this (plus
    /// the automation renderer and the scratch box) — no self, no graph state.
    let processor = EffectChainProcessor()

    /// This strip's automation read head: effect-param lanes store into the
    /// live units BEFORE the chain walk (M4 vii-c); volume/pan lanes apply
    /// at the END of the render block, AFTER the walk — the fader position
    /// (M4 vii-b). Schedules are published by `PlaybackGraph` from the main
    /// actor; both entry points are RT-safe no-ops while nothing is published.
    ///
    /// MASTER insert exception (m15-c): on the master chain host the volume
    /// stage runs BEFORE the walk instead — see `StagePlacementBox`.
    let automation = AutomationRenderer()

    /// Where this host's volume/pan automation stage sits relative to the
    /// chain walk (m15-c). Default `false` = post-walk — the STRIP fader
    /// position (inserts-then-fader, M4 vii-b), every existing host
    /// unchanged. The MASTER insert sets `true` at node creation: under the
    /// §1-B post-fader topology the master FADER is the mixer feeding this
    /// host, so the master volume lane must apply at the host's INPUT —
    /// pre-walk, the exact signal point `mixer.setMasterVolume` drives — and
    /// the chain (limiter) rides ABOVE the fade, the professionally-correct
    /// order (audit-m15 §m15-c).
    ///
    /// Write discipline = `PerformanceBox`: main actor, at node creation,
    /// BEFORE the engine ever renders; the render block only reads it.
    private final class StagePlacementBox: @unchecked Sendable {
        var volumePreChain = false
    }

    /// This strip's PDC compensation ring (M4 viii-b): applied between the
    /// chain walk and the vol/pan automation stage — upstream of the strip
    /// mixer's fan-out, so the dry feed and every send tap are aligned by the
    /// SAME delay. Target is an atomic scalar published from the main actor
    /// (bypassFlag pattern); rings are (de)allocated with render resources.
    let compensation = CompensationDelayState()

    /// Preallocated fallback output storage for hosts that pass null-mData
    /// output buffers (the AU must then supply its own). Allocated on the
    /// main thread in `allocateRenderResources`, read (pointers only) on the
    /// render thread.
    private final class Scratch: @unchecked Sendable {
        private(set) var data: UnsafeMutablePointer<Float>?
        private(set) var channelCount = 0
        private(set) var capacity = 0

        func allocate(channelCount: Int, capacity: Int) {
            release()
            let count = max(1, channelCount * capacity)
            data = .allocate(capacity: count)
            data?.initialize(repeating: 0, count: count)
            self.channelCount = channelCount
            self.capacity = capacity
        }

        func release() {
            data?.deallocate()
            data = nil
            channelCount = 0
            capacity = 0
        }

        deinit {
            data?.deallocate()
        }
    }

    /// Render-load telemetry wiring (M9 perf-b). The render block captures
    /// this box (never self); the box holds the context STRONGLY (lifetime:
    /// no callback can outlive it) plus the integer rate for the budget
    /// math. Both fields are written only on the control plane while the
    /// host guarantees no concurrent render — `setPerformanceContext` at
    /// node creation (before the engine ever renders) and
    /// `allocateRenderResources` — the exact `Scratch` write-window
    /// discipline. nil context = telemetry off (directly instantiated test
    /// units), a pure no-op.
    private final class PerformanceBox: @unchecked Sendable {
        var context: EnginePerformanceContext?
        var sampleRateHz: UInt64 = 48_000
    }

    /// Sidechain key-side render state (m12-f): the connected flag plus the
    /// preallocated scratch the bus-1 pull lands in. The flag is armed from
    /// the main actor by `PlaybackGraph` AFTER the key edge is physically
    /// wired (engine quiesced — the routing-rewire discipline) and cleared
    /// when it is severed; the render thread only ever loads it. Buffers are
    /// (de)allocated in the render-resources window (the `Scratch` rules);
    /// the flag pointer lives for the AU's whole life so a stale-window
    /// store can never touch freed memory.
    private final class KeyState: @unchecked Sendable {
        /// 1 = a key edge is wired into input bus 1; pull it this quantum.
        let connectedFlag: UnsafeMutablePointer<daw_atomic_u32>
        private(set) var data: UnsafeMutablePointer<Float>?
        private(set) var list: UnsafeMutableAudioBufferListPointer?
        private(set) var channelCount = 0
        private(set) var capacity = 0

        init() {
            connectedFlag = .allocate(capacity: 1)
            daw_atomic_u32_store(connectedFlag, 0)
        }

        func allocate(channelCount: Int, capacity: Int) {
            release()
            let count = max(1, channelCount * capacity)
            data = .allocate(capacity: count)
            data?.initialize(repeating: 0, count: count)
            list = AudioBufferList.allocate(maximumBuffers: max(1, channelCount))
            self.channelCount = channelCount
            self.capacity = capacity
        }

        func release() {
            data?.deallocate()
            data = nil
            if let list { free(list.unsafeMutablePointer) }
            list = nil
            channelCount = 0
            capacity = 0
        }

        deinit {
            release()
            connectedFlag.deallocate()
        }
    }

    private let performanceBox = PerformanceBox()
    private let stagePlacement = StagePlacementBox()
    private let scratch = Scratch()
    private let keyState = KeyState()
    private let inputBus: AUAudioUnitBus
    /// Sidechain key input (m12-f) — always declared (bus counts are static
    /// for the AU's life; the spike proved an unconnected second bus pulls a
    /// clean kAudioUnitErr_NoConnection and never disturbs the main path).
    private let keyInputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private lazy var _inputBusses = AUAudioUnitBusArray(
        audioUnit: self, busType: .input, busses: [inputBus, keyInputBus])
    private lazy var _outputBusses = AUAudioUnitBusArray(
        audioUnit: self, busType: .output, busses: [outputBus])

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // Default format only — the engine renegotiates via setFormat when it
        // connects at the graph rate.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw EngineError.renderFailed("no standard 48 kHz stereo format")
        }
        inputBus = try AUAudioUnitBus(format: format)
        keyInputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch.allocate(channelCount: Int(outputBus.format.channelCount),
                         capacity: Int(maximumFramesToRender))
        // Key scratch (m12-f): sized off the key bus's negotiated format —
        // AVAudioEngine renegotiates it when the key edge connects; the
        // unconnected default (48 kHz stereo) allocates harmlessly and is
        // never pulled (flag down).
        keyState.allocate(channelCount: Int(keyInputBus.format.channelCount),
                          capacity: Int(maximumFramesToRender))
        compensation.allocate(channelCount: Int(outputBus.format.channelCount))
        // Telemetry budget rate: the negotiated bus rate, guarded ≥ 1 so the
        // render-side divisor can never trap.
        let rate = outputBus.format.sampleRate
        performanceBox.sampleRateHz = rate >= 1 ? UInt64(rate.rounded()) : 1
    }

    override func deallocateRenderResources() {
        scratch.release()
        keyState.release()
        compensation.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture the walker + automation head + scratch/perf boxes, never
        // self (RT rule: the block must not touch the ObjC property surface).
        let processor = processor
        let automation = automation
        let compensation = compensation
        let scratch = scratch
        let keyState = keyState
        let performanceBox = performanceBox
        let stagePlacement = stagePlacement
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)

            // Host passed null output buffers → substitute our preallocated
            // scratch so the pull below has real memory to land in.
            if let first = buffers.first, first.mData == nil {
                guard let base = scratch.data,
                      frames <= scratch.capacity,
                      buffers.count <= scratch.channelCount else {
                    return kAudioUnitErr_TooManyFramesToProcess
                }
                for channel in 0..<buffers.count {
                    buffers[channel].mData =
                        UnsafeMutableRawPointer(base + channel * scratch.capacity)
                    buffers[channel].mDataByteSize =
                        UInt32(frames * MemoryLayout<Float>.stride)
                }
            }

            // Pull input IN PLACE: upstream renders straight into the output
            // ABL (or repoints it at upstream-owned memory — equally valid).
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            // Sidechain key pull (m12-f): iff a key edge is wired (atomic
            // flag), pull bus 1 into the preallocated key scratch — a real
            // graph edge, so the source rendered THIS quantum (same-quantum
            // determinism, spike-proven). The ABL is re-armed every quantum
            // (a pull may repoint mData at upstream-owned memory; sizes must
            // reset regardless). ANY failure — flag down, scratch missing,
            // oversized quantum, or a pull error (the spike's clean −10876
            // kAudioUnitErr_NoConnection shape) — leaves `keyList` nil and
            // the walk runs self-keyed: the main path NEVER fails (§6.2).
            var keyList: UnsafeMutableAudioBufferListPointer?
            if daw_atomic_u32_load(keyState.connectedFlag) == 1,
               let keyBase = keyState.data, let list = keyState.list,
               keyState.channelCount > 0, frames <= keyState.capacity {
                for channel in 0..<keyState.channelCount {
                    list[channel].mNumberChannels = 1
                    list[channel].mData =
                        UnsafeMutableRawPointer(keyBase + channel * keyState.capacity)
                    list[channel].mDataByteSize =
                        UInt32(frames * MemoryLayout<Float>.stride)
                }
                var keyFlags = AudioUnitRenderActionFlags()
                let keyStatus = pullInputBlock(&keyFlags, timestamp, frameCount, 1,
                                               list.unsafeMutablePointer)
                if keyStatus == noErr { keyList = list }
            }

            // Telemetry entry stamp (M9 perf-b) — AFTER the pulls, so nested
            // upstream renders (other strips' chain hosts, instrument source
            // nodes, the key source's subtree) are never double-counted: this
            // block's own DSP work (automation stores, chain walk, PDC ring,
            // fader stage) is what gets measured. Commpage read, not a
            // syscall.
            let perfEntryTicks = mach_absolute_time()

            // MASTER insert only (m15-c, `StagePlacementBox`): the volume
            // lane applies at the host's INPUT — the §1-B master-fader
            // position (the chain rides above the fade). Plain Bool read on
            // a captured box (the PerformanceBox discipline); RT-safe no-op
            // while nothing is published — the null path is untouched.
            if stagePlacement.volumePreChain {
                automation.apply(bufferList: outputData, frameCount: frames,
                                 timestamp: timestamp)
            }
            // Effect-param automation FIRST (M4 vii-c): quantum-start values
            // stored into the live units so the walk below renders with them.
            // No-op while no effect-param track is published.
            automation.storeEffectParams(chain: processor, frameCount: frames,
                                         timestamp: timestamp)
            // Walk the published chain in place, handing the key buffer (nil
            // = every unit self-keyed). Empty chain: no-op.
            processor.process(bufferList: outputData, frameCount: frames, key: keyList)
            // PDC compensation ring (M4 viii-b): post-chain, pre-fader —
            // aligns this strip's output (and every send tap downstream)
            // to the stage target. Bit-exact no-op at target 0.
            compensation.process(bufferList: outputData, frameCount: frames)
            // Volume/pan automation LAST — post-chain-walk is the fader
            // position (M4 vii-b). No-op while nothing is published (and
            // skipped entirely on the master insert, whose volume stage ran
            // pre-walk above).
            if !stagePlacement.volumePreChain {
                automation.apply(bufferList: outputData, frameCount: frames,
                                 timestamp: timestamp)
            }
            // Telemetry exit stamp: only completed DSP walks count (error
            // returns above did no strip work). nil context = no-op.
            if let performance = performanceBox.context {
                performance.record(entryTicks: perfEntryTicks,
                                   exitTicks: mach_absolute_time(),
                                   frames: frames,
                                   sampleRateHz: performanceBox.sampleRateHz)
            }
            return noErr
        }
    }

    // MARK: - Factory (main actor)

    /// Registers (once) and synchronously instantiates one chain-host node.
    /// The gating spike test proves this path in the bare-SPM environment;
    /// fallback A (async instantiate + invalidate-rebuild) only exists if
    /// this ever regresses.
    @MainActor
    static func makeChainHostNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    /// The chain walker inside a node made by `makeChainHostNode` — nil only
    /// if the node somehow wraps a foreign AU (never expected in-process).
    @MainActor
    static func chainProcessor(of node: AVAudioUnitEffect) -> EffectChainProcessor? {
        (node.auAudioUnit as? ChainHostAU)?.processor
    }

    /// The automation read head inside a node made by `makeChainHostNode` —
    /// same nil rule as `chainProcessor(of:)`.
    @MainActor
    static func automationRenderer(of node: AVAudioUnitEffect) -> AutomationRenderer? {
        (node.auAudioUnit as? ChainHostAU)?.automation
    }

    /// The compensation ring inside a node made by `makeChainHostNode` —
    /// same nil rule as `chainProcessor(of:)`.
    @MainActor
    static func compensationState(of node: AVAudioUnitEffect) -> CompensationDelayState? {
        (node.auAudioUnit as? ChainHostAU)?.compensation
    }

    /// Moves the host's volume-automation stage to PRE-chain (m15-c) — the
    /// master-insert fader position under §1-B. MUST be called at node
    /// creation, before the engine ever renders (the `setPerformanceContext`
    /// boundary discipline) — `PlaybackGraph.ensureMasterSandwich` does this.
    /// Foreign-AU nodes (never expected) no-op, same nil rule as
    /// `chainProcessor(of:)`.
    @MainActor
    static func setVolumeStagePreChain(_ preChain: Bool, of node: AVAudioUnitEffect) {
        (node.auAudioUnit as? ChainHostAU)?.stagePlacement.volumePreChain = preChain
    }

    /// The volume-stage placement flag (test seam, @testable).
    @MainActor
    static func isVolumeStagePreChain(of node: AVAudioUnitEffect) -> Bool {
        (node.auAudioUnit as? ChainHostAU)?.stagePlacement.volumePreChain ?? false
    }

    /// Arms/clears the sidechain key-connected flag (m12-f) — ONE atomic
    /// store. PlaybackGraph calls this at the tail of every reconcile so the
    /// flag always mirrors the physically wired key edges (set only after
    /// wiring lands, cleared when an edge is severed; the engine is quiesced
    /// across the wiring itself per the routing-rewire discipline). Foreign-
    /// AU nodes no-op, same nil rule as `chainProcessor(of:)`.
    @MainActor
    static func setKeyConnected(_ connected: Bool, of node: AVAudioUnitEffect) {
        guard let au = node.auAudioUnit as? ChainHostAU else { return }
        daw_atomic_u32_store(au.keyState.connectedFlag, connected ? 1 : 0)
    }

    /// The key-connected flag (test seam, @testable).
    @MainActor
    static func isKeyConnected(of node: AVAudioUnitEffect) -> Bool {
        guard let au = node.auAudioUnit as? ChainHostAU else { return false }
        return daw_atomic_u32_load(au.keyState.connectedFlag) == 1
    }

    /// Wires the render-load telemetry context (M9 perf-b) into a node made
    /// by `makeChainHostNode`. MUST be called at node creation, before the
    /// engine ever renders (the boundary discipline the PerformanceBox
    /// documents) — PlaybackGraph does this inside `makeStripSandwich`.
    /// Foreign-AU nodes (never expected) no-op, same nil rule as
    /// `chainProcessor(of:)`.
    @MainActor
    static func setPerformanceContext(_ context: EnginePerformanceContext,
                                      of node: AVAudioUnitEffect) {
        (node.auAudioUnit as? ChainHostAU)?.performanceBox.context = context
    }
}
