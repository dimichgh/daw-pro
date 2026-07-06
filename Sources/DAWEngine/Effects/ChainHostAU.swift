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
    }

    override func deallocateRenderResources() {
        scratch.release()
        compensation.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture the walker + automation head + scratch box, never self (RT
        // rule: the block must not touch the ObjC property surface).
        let processor = processor
        let automation = automation
        let compensation = compensation
        let scratch = scratch
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
}
