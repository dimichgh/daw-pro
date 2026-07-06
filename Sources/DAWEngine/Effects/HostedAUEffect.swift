import AVFAudio
import AudioToolbox
import CAtomics
import DAWCore
import Foundation

/// Adapts one instantiated `AUAudioUnit` effect ('aufx') to `EffectRendering`,
/// hiding the AU pull model behind the chain's in-place seam: `process()`
/// stashes the caller's buffers, hands the AU a pull block that reads them,
/// renders into a preallocated scratch ABL, then copies scratch → in place.
///
/// RENDER-THREAD CONTRACT: `process()` may touch ONLY `renderBlock`,
/// `pullInput`, and preallocated memory (`inputStash`, `scratchABL`,
/// `scratchSamples`, `renderErrorSlot`, `hostSampleTime`). ANY other
/// `AUAudioUnit` member access is forbidden off the main actor — the ObjC
/// property surface can lock/allocate/message. The single sanctioned
/// exception is `reset()`'s `auAudioUnit.reset()` (M4 (v) design decision:
/// effects have no MIDI all-notes-off path; AudioUnitReset is the only
/// tail-clear, and it fires only at reset edges, never per quantum).
public final class HostedAUEffect: EffectRendering, @unchecked Sendable {
    /// MAIN-ACTOR-ONLY (except `reset()`, above): state capture
    /// (`fullStateForDocument`), teardown (`deallocateRenderResources`), rate
    /// renegotiation. Never dereferenced by `process()`.
    let auAudioUnit: AUAudioUnit

    private let renderBlock: AURenderBlock
    private let pullInput: AURenderPullInputBlock

    /// The caller's in-place buffers for the CURRENT `process()` call, read by
    /// `pullInput` during the same synchronous `renderBlock` invocation.
    /// `process()` is only ever called single-threaded on the render walk, so
    /// this needs no atomics.
    private final class InputStash: @unchecked Sendable {
        var bufferList: UnsafeMutablePointer<AudioBufferList>?
    }

    private let inputStash: InputStash
    /// Preallocated AU output target: `maxFrames × 2` Float32 samples,
    /// channel-contiguous. Rendering never targets the caller's buffers — the
    /// AU pulls input lazily mid-render, so in-place would alias.
    private let scratchABL: UnsafeMutableAudioBufferListPointer
    private let scratchSamples: UnsafeMutablePointer<Float>
    private let maxFrames: Int
    /// Monotonic fake timeline fed to the AU (never reset — resetting it makes
    /// some AUs drop state).
    private var hostSampleTime: Double = 0
    private let renderErrorSlot: UnsafeMutablePointer<daw_atomic_u32>

    /// Fixed algorithmic latency at the prepared rate, captured at prepare
    /// (`au.latency` seconds × rate). Main-actor read (per EffectRendering).
    private(set) var latencySamples: Int

    /// Sample rate the AU's render resources are currently allocated at.
    private var preparedSampleRate: Double

    @MainActor
    init(au: AUAudioUnit, sampleRate: Double, maxFrames: Int) {
        // Called AFTER allocateRenderResources — renderBlock is only valid then.
        auAudioUnit = au
        renderBlock = au.renderBlock
        self.maxFrames = maxFrames
        preparedSampleRate = sampleRate
        latencySamples = Int((au.latency * sampleRate).rounded())
        scratchSamples = .allocate(capacity: 2 * maxFrames)
        scratchSamples.initialize(repeating: 0, count: 2 * maxFrames)
        scratchABL = AudioBufferList.allocate(maximumBuffers: 2)
        renderErrorSlot = .allocate(capacity: 1)
        daw_atomic_u32_store(renderErrorSlot, 0)
        let stash = InputStash()
        inputStash = stash
        // Feeds the stashed in-place buffers to the AU: point the AU's ABL at
        // our samples when it passes nil mData, copy when it brings its own.
        pullInput = { @Sendable _, _, frameCount, _, inputData in
            guard let sourceList = stash.bufferList else {
                return kAudioUnitErr_NoConnection
            }
            let source = UnsafeMutableAudioBufferListPointer(sourceList)
            guard source.count > 0 else { return kAudioUnitErr_NoConnection }
            let destination = UnsafeMutableAudioBufferListPointer(inputData)
            let byteCount = Int(frameCount) * MemoryLayout<Float>.stride
            for channel in 0..<destination.count {
                let sourceChannel = min(channel, source.count - 1)
                guard let sourceData = source[sourceChannel].mData else { continue }
                if let destinationData = destination[channel].mData {
                    if destinationData != sourceData {
                        memcpy(destinationData, sourceData, byteCount)
                    }
                } else {
                    destination[channel].mData = sourceData
                }
                destination[channel].mDataByteSize = UInt32(byteCount)
            }
            return noErr
        }
    }

    deinit {
        free(scratchABL.unsafeMutablePointer)
        scratchSamples.deallocate()
        renderErrorSlot.deallocate()
    }

    /// Last non-noErr status the AU returned from a render, edge-triggered:
    /// reading it clears the slot. Main-actor diagnostics only.
    @MainActor
    var lastRenderError: OSStatus? {
        let raw = daw_atomic_u32_exchange(renderErrorSlot, 0)
        return raw == 0 ? nil : OSStatus(bitPattern: raw)
    }

    // MARK: - EffectRendering (main-actor setup)

    /// The registry prepares the AU at the graph rate before wrapping, so this
    /// is normally a no-op rate check. A rate mismatch renegotiates
    /// synchronously on the main actor (HostedAUInstrument pattern), setting
    /// BOTH bus formats — effects negotiate input and output.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        guard sampleRate != preparedSampleRate else { return }
        MainActor.assumeIsolated {
            do {
                auAudioUnit.deallocateRenderResources()
                auAudioUnit.maximumFramesToRender =
                    AUAudioFrameCount(min(maxFramesPerQuantum, maxFrames))
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: AVAudioChannelCount(channelCount)
                ) else {
                    throw EngineError.renderFailed("no standard format at \(sampleRate) Hz")
                }
                try auAudioUnit.inputBusses[0].setFormat(format)
                try auAudioUnit.outputBusses[0].setFormat(format)
                // v2-bridge input busses default to disabled (registry rule).
                auAudioUnit.inputBusses[0].isEnabled = true
                try auAudioUnit.allocateRenderResources()
                preparedSampleRate = sampleRate
                latencySamples = Int((auAudioUnit.latency * sampleRate).rounded())
                FileHandle.standardError.write(Data(
                    "HostedAUEffect: renegotiated render format to \(sampleRate) Hz\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "HostedAUEffect: rate renegotiation to \(sampleRate) Hz failed: \(error) — effect may pass dry\n".utf8))
            }
        }
    }

    // MARK: - EffectRendering (render thread)

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let channelCount = min(buffers.count, 2)
        guard channelCount > 0, frameCount <= maxFrames else { return }
        let byteCount = frameCount * MemoryLayout<Float>.stride

        // 1. Expose the caller's buffers to the pull block.
        inputStash.bufferList = buffers.unsafeMutablePointer

        // 2. Point the scratch ABL at preallocated output memory.
        scratchABL.count = channelCount
        for channel in 0..<channelCount {
            scratchABL[channel].mData =
                UnsafeMutableRawPointer(scratchSamples + channel * maxFrames)
            scratchABL[channel].mDataByteSize = UInt32(byteCount)
            scratchABL[channel].mNumberChannels = 1
        }

        // 3. Pull-render on the monotonic fake timeline; advance it
        // unconditionally so the AU always sees contiguous time.
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = hostSampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let status = renderBlock(&flags, &timestamp, AUAudioFrameCount(frameCount), 0,
                                 scratchABL.unsafeMutablePointer, pullInput)
        hostSampleTime += Double(frameCount)
        inputStash.bufferList = nil

        // 4. Render failure → dry passthrough (caller's buffers untouched) +
        // error breadcrumb; never trap or log on the render thread.
        if status != noErr {
            daw_atomic_u32_store(renderErrorSlot, UInt32(bitPattern: status))
            return
        }

        // 5. Copy rendered samples back in place. Read via the scratch ABL —
        // the AU may have substituted its own buffers.
        for channel in 0..<channelCount {
            if let source = scratchABL[channel].mData,
               let destination = buffers[channel].mData,
               source != destination {
                memcpy(destination, source, byteCount)
            }
        }
    }

    /// Tail clear via `AudioUnitReset` (see class doc for why this one ObjC
    /// message is sanctioned on the render thread at reset edges).
    func reset() {
        auAudioUnit.reset()
    }
}
