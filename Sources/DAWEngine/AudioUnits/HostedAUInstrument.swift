import AVFAudio
import AudioToolbox
import CAtomics
import DAWCore
import Foundation

/// Adapts one instantiated `AUAudioUnit` music device to `InstrumentRendering`.
/// Our `InstrumentSourceNode` clock stays the only clock; scheduled events
/// reach the AU via its `scheduleMIDIEventBlock` at in-quantum sample offsets
/// immediately before we invoke its captured `renderBlock`.
///
/// RENDER-THREAD CONTRACT: `render()` and `reset()` may touch ONLY the two
/// block `let`s captured at init (`renderBlock`, `scheduleMIDI`) plus
/// preallocated memory (`shadowABL`, `midiBytes`, `renderErrorSlot`,
/// `hostSampleTime`). ANY other `AUAudioUnit` member access is forbidden off
/// the main actor — the ObjC property surface can lock/allocate/message.
public final class HostedAUInstrument: InstrumentRendering, @unchecked Sendable {
    enum HostingError: Error, LocalizedError {
        case notAMusicDevice

        var errorDescription: String? {
            switch self {
            case .notAMusicDevice:
                return "component exposes no scheduleMIDIEventBlock — not a music device"
            }
        }
    }

    /// MAIN-ACTOR-ONLY: state capture (`fullStateForDocument`), teardown
    /// (`deallocateRenderResources`/`reset`), and rate renegotiation. Never
    /// dereferenced by `render()`/`reset()`.
    let auAudioUnit: AUAudioUnit

    /// MAIN-ACTOR-ONLY (set once by the registry right after wrapping, read
    /// only inside `prepare`'s renegotiation block): re-applies per-instance
    /// AU state that `deallocateRenderResources` destroys. m10-n R7: T6
    /// MEASURED that AUSampler's loaded bank does NOT survive the
    /// dealloc/realloc cycle (the sampler reverts to its factory default
    /// sine preset), so the registry installs a synchronous bank re-load
    /// here for `.soundBank` instruments. nil for every other kind.
    var reloadAfterRenegotiation: ((AUAudioUnit) -> Void)?

    // The only two AU-derived values the render thread may touch.
    private let renderBlock: AURenderBlock
    private let scheduleMIDI: AUScheduleMIDIEventBlock

    // Render-thread state, preallocated at init. `hostSampleTime` is a
    // monotonic fake timeline fed to the AU (never reset — resetting it makes
    // some AUs drop state). `renderErrorSlot` carries the last non-noErr
    // render status to the main actor without logging on the render thread.
    private let shadowABL: UnsafeMutableAudioBufferListPointer
    private let midiBytes: UnsafeMutablePointer<UInt8>
    private var hostSampleTime: Double = 0
    private let renderErrorSlot: UnsafeMutablePointer<daw_atomic_u32>

    /// Sample rate the AU's render resources are currently allocated at.
    private var preparedSampleRate: Double

    @MainActor
    init(au: AUAudioUnit, sampleRate: Double) throws {
        // Called AFTER allocateRenderResources — renderBlock is only valid then.
        guard let schedule = au.scheduleMIDIEventBlock else {
            throw HostingError.notAMusicDevice
        }
        auAudioUnit = au
        renderBlock = au.renderBlock
        scheduleMIDI = schedule
        preparedSampleRate = sampleRate
        shadowABL = AudioBufferList.allocate(maximumBuffers: 2)
        midiBytes = .allocate(capacity: 3)
        renderErrorSlot = .allocate(capacity: 1)
        daw_atomic_u32_store(renderErrorSlot, 0)
    }

    deinit {
        free(shadowABL.unsafeMutablePointer)
        midiBytes.deallocate()
        renderErrorSlot.deallocate()
    }

    /// Last non-noErr status the AU returned from a render, edge-triggered:
    /// reading it clears the slot. Main-actor diagnostics only.
    @MainActor
    var lastRenderError: OSStatus? {
        let raw = daw_atomic_u32_exchange(renderErrorSlot, 0)
        return raw == 0 ? nil : OSStatus(bitPattern: raw)
    }

    // MARK: - InstrumentRendering (main-actor setup)

    /// The registry prepares the AU at the graph rate before wrapping, so this
    /// is normally a no-op rate check. A graph-rate mismatch (registry rate ≠
    /// the rate the node connects at) renegotiates synchronously on the main
    /// actor — bounded (one dealloc/setFormat/alloc round trip) and logged.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        guard sampleRate != preparedSampleRate else { return }
        MainActor.assumeIsolated {
            do {
                auAudioUnit.deallocateRenderResources()
                auAudioUnit.maximumFramesToRender = AUAudioFrameCount(maxFramesPerQuantum)
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: AVAudioChannelCount(channelCount)
                ) else {
                    throw EngineError.renderFailed("no standard format at \(sampleRate) Hz")
                }
                try auAudioUnit.outputBusses[0].setFormat(format)
                try auAudioUnit.allocateRenderResources()
                // Reallocation destroys per-instance sampler state (measured,
                // m10-n T6) — restore it BEFORE the next render pull. The AU
                // is initialized here, so the re-load is synchronous on this
                // (main) actor — bounded like the renegotiation itself.
                reloadAfterRenegotiation?(auAudioUnit)
                preparedSampleRate = sampleRate
                FileHandle.standardError.write(Data(
                    "HostedAUInstrument: renegotiated render format to \(sampleRate) Hz\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "HostedAUInstrument: rate renegotiation to \(sampleRate) Hz failed: \(error) — instrument may render silence\n".utf8))
            }
        }
    }

    // MARK: - InstrumentRendering (render thread)

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        // 1. Deliver every event BEFORE the render call, at its in-quantum
        // offset. Events arrive sorted with off-before-on ties; the schedule
        // block's FIFO preserves that ordering at equal offsets.
        for event in events {
            let offset = max(0, Int(event.sampleTime - renderStart))
            if event.kind == ScheduledMIDIEvent.noteOn {
                midiBytes[0] = 0x90
                midiBytes[1] = event.pitch
                midiBytes[2] = event.velocity
            } else {
                midiBytes[0] = 0x80
                midiBytes[1] = event.pitch
                midiBytes[2] = 0
            }
            scheduleMIDI(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, 3, midiBytes)
        }

        // 2. Point the preallocated shadow ABL at the caller's output buffers.
        // The AU may render in place or substitute its own buffers (step 5).
        let channelCount = min(output.count, 2)
        shadowABL.count = channelCount
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for channel in 0..<channelCount {
            shadowABL[channel].mData = output[channel].mData
            shadowABL[channel].mDataByteSize = UInt32(byteCount)
            shadowABL[channel].mNumberChannels = 1
        }

        // 3. Local timestamp on the monotonic fake timeline; advance it
        // unconditionally so the AU always sees contiguous time.
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = hostSampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let status = renderBlock(&flags, &timestamp,
                                 AUAudioFrameCount(frameCount), 0,
                                 shadowABL.unsafeMutablePointer, nil)
        hostSampleTime += Double(frameCount)

        // 4. Render failure → exact silence + error breadcrumb; never trap or
        // log on the render thread.
        if status != noErr {
            for channel in 0..<output.count {
                if let data = output[channel].mData { memset(data, 0, byteCount) }
            }
            daw_atomic_u32_store(renderErrorSlot, UInt32(bitPattern: status))
            return
        }

        // 5. If the AU substituted its own buffers, copy back into the caller's.
        for channel in 0..<channelCount {
            if let source = shadowABL[channel].mData,
               let destination = output[channel].mData,
               source != destination {
                memcpy(destination, source, byteCount)
            }
        }
    }

    /// All-notes-off: CC 123 (all notes off) then CC 120 (all sound off) on
    /// channel 0, scheduled immediately. Do NOT call `AUAudioUnit.reset()`
    /// here — that is an ObjC main-actor call; external silence is already
    /// enforced by `InstrumentRenderer.renderQuantum`, and the CCs kill
    /// internal voices before the next schedule renders.
    func reset() {
        midiBytes[0] = 0xB0
        midiBytes[1] = 123
        midiBytes[2] = 0
        scheduleMIDI(AUEventSampleTimeImmediate, 0, 3, midiBytes)
        midiBytes[1] = 120
        scheduleMIDI(AUEventSampleTimeImmediate, 0, 3, midiBytes)
    }
}
