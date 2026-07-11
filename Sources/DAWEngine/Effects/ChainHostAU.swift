import AVFAudio
import AudioToolbox
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
    let automation = AutomationRenderer()

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

    private let performanceBox = PerformanceBox()
    private let scratch = Scratch()
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private lazy var _inputBusses = AUAudioUnitBusArray(
        audioUnit: self, busType: .input, busses: [inputBus])
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
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch.allocate(channelCount: Int(outputBus.format.channelCount),
                         capacity: Int(maximumFramesToRender))
        compensation.allocate(channelCount: Int(outputBus.format.channelCount))
        // Telemetry budget rate: the negotiated bus rate, guarded ≥ 1 so the
        // render-side divisor can never trap.
        let rate = outputBus.format.sampleRate
        performanceBox.sampleRateHz = rate >= 1 ? UInt64(rate.rounded()) : 1
    }

    override func deallocateRenderResources() {
        scratch.release()
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
        let performanceBox = performanceBox
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

            // Telemetry entry stamp (M9 perf-b) — AFTER the pull, so nested
            // upstream renders (other strips' chain hosts, instrument source
            // nodes) are never double-counted: this block's own DSP work
            // (automation stores, chain walk, PDC ring, fader stage) is what
            // gets measured. Commpage read, not a syscall.
            let perfEntryTicks = mach_absolute_time()

            // Effect-param automation FIRST (M4 vii-c): quantum-start values
            // stored into the live units so the walk below renders with them.
            // No-op while no effect-param track is published.
            automation.storeEffectParams(chain: processor, frameCount: frames,
                                         timestamp: timestamp)
            // Walk the published chain in place. Empty chain: no-op.
            processor.process(bufferList: outputData, frameCount: frames)
            // PDC compensation ring (M4 viii-b): post-chain, pre-fader —
            // aligns this strip's output (and every send tap downstream)
            // to the stage target. Bit-exact no-op at target 0.
            compensation.process(bufferList: outputData, frameCount: frames)
            // Volume/pan automation LAST — post-chain-walk is the fader
            // position (M4 vii-b). No-op while nothing is published.
            automation.apply(bufferList: outputData, frameCount: frames,
                             timestamp: timestamp)
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
