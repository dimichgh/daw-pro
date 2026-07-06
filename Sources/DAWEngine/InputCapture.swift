import AudioToolbox
import AVFAudio
import Foundation

/// Owns a SEPARATE input-only AVAudioEngine whose inputNode tap feeds a
/// `RecordingWriter`. Never touches this engine's outputNode or
/// mainMixerNode — pulling those in would wire an input→output monitor path.
/// Capture runs at the device-native format (nil tap format); the playback
/// engine and its clock are entirely independent.
///
/// Two-phase start: `prepare()` resolves and pins the selected device and
/// returns the post-pin native format (the writer must be sized from THAT —
/// the pinned device's rate/channels can differ from the system default's),
/// then `start(writer:)` installs the tap and starts I/O.
@MainActor
final class InputCapture {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var configObserver: (any NSObjectProtocol)?

    /// Device-native input format, read at init (the system default device);
    /// re-read by the pin when a UID selects a different device.
    /// nil when no usable input device exists (zero channels / zero rate).
    private(set) var inputFormat: AVAudioFormat?

    /// UID of the hardware device to capture from; nil = follow the system
    /// default. Set by the owner before `prepare()`/`start(writer:)`.
    var deviceUID: String?
    private var devicePinned = false

    /// Fired on the main actor when a configuration change on THIS engine
    /// actually killed capture (engine no longer running: device unplugged,
    /// rate change). The owner uses it to end the take cleanly. NOT fired for
    /// the benign reconfigure notification that pinning a device provokes —
    /// see `handleConfigurationChange()`.
    var configurationChangeHandler: (() -> Void)?

    init() {
        let format = engine.inputNode.outputFormat(forBus: 0)
        if format.channelCount > 0, format.sampleRate > 0 {
            inputFormat = format
        }
    }

    /// Phase 1: resolves `deviceUID`, pins the capture AUHAL when the uid
    /// names a non-default device, and returns the (possibly changed) native
    /// input format so the owner can size the take writer before phase 2.
    /// Idempotent. Throws when the UID no longer resolves to a usable input
    /// device, or when no input device exists at all.
    func prepare() throws -> AVAudioFormat {
        try pinSelectedDevice()
        guard let inputFormat else {
            throw EngineError.recordingFailed("no audio input device available")
        }
        return inputFormat
    }

    /// Resolves `deviceUID` and pins THIS capture engine's input unit to that
    /// hardware device (kAudioOutputUnitProperty_CurrentDevice on the AUHAL),
    /// then re-reads `inputFormat`. No-op when `deviceUID` is nil, when the
    /// pin already landed, or — critically — when the UID resolves to the
    /// CURRENT SYSTEM DEFAULT input device: a fresh AVAudioEngine input
    /// already captures from the default (through the engine's own private
    /// aggregate device), so a redundant SetProperty only forces a same-device
    /// I/O rebuild. The AUHAL's CurrentDevice property cannot make that call —
    /// it reports the private aggregate's ID, which never equals any raw
    /// hardware ID (the old read-and-compare guard therefore never skipped,
    /// which is how "pin the default's own uid" broke live).
    private func pinSelectedDevice() throws {
        guard let deviceUID, !devicePinned else { return }
        guard var deviceID = InputDevices.deviceID(forUID: deviceUID) else {
            throw EngineError.recordingFailed("input device unavailable: \(deviceUID)")
        }
        if InputDevices.defaultInputDeviceID() != deviceID {
            if engine.inputNode.audioUnit == nil {
                engine.prepare()  // materializes the AUHAL without starting I/O
            }
            guard let audioUnit = engine.inputNode.audioUnit else {
                throw EngineError.recordingFailed("input device unavailable: \(deviceUID)")
            }
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                FileHandle.standardError.write(Data(
                    "InputCapture: pinning '\(deviceUID)' failed — OSStatus \(status)\n".utf8
                ))
                throw EngineError.recordingFailed("input device unavailable: \(deviceUID)")
            }
        }
        devicePinned = true
        // The pinned device's native format replaces the default device's.
        let format = engine.inputNode.outputFormat(forBus: 0)
        inputFormat = (format.channelCount > 0 && format.sampleRate > 0) ? format : nil
        guard inputFormat != nil else {
            throw EngineError.recordingFailed("input device unavailable: \(deviceUID)")
        }
    }

    /// Phase 2: installs the tap (device-native format, 4096-frame buffers)
    /// and starts the input engine. When `deviceUID` is set, the device is
    /// pinned BEFORE the tap lands and the engine starts (idempotent — a
    /// prior `prepare()` already pinned). The tap closure is @Sendable and
    /// captures ONLY the writer — it runs on AVFoundation's tap queue (not
    /// the render thread), where handing the owned buffer to the writer's
    /// queue is legal.
    func start(writer: RecordingWriter) throws {
        try pinSelectedDevice()
        guard inputFormat != nil else {
            throw EngineError.recordingFailed("no audio input device available")
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable buffer, when in
            writer.append(buffer, at: when)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
        // Observer on ITS OWN engine (the output engine has its own).
        // @Sendable is load-bearing: the notification fires on a non-main
        // thread; hop to the main actor before touching any state.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.handleConfigurationChange()
                }
            }
        }
    }

    /// Benign-vs-fatal triage for THIS engine's configuration changes.
    ///
    /// Pinning a capture device makes AVFoundation post a configuration-change
    /// notification on this engine ~65 ms after `start()` — with the engine
    /// still running and the tap still delivering (measured live; see the
    /// 2026-07-05 pinned-device empty-take bug: treating that notification as
    /// fatal stopped the take and finalized the writer before the first
    /// buffer arrived, and every later tap delivery was silently dropped by
    /// the writer's post-finalize guard — hence zero frames AND zero stderr).
    ///
    /// Discriminator: a change that actually killed capture (device unplugged,
    /// rate change) leaves the engine STOPPED. Engine still running → note it
    /// and keep rolling; the owner's first-buffer watchdog backstops the case
    /// where a "benign" reconfigure silently killed delivery anyway.
    private func handleConfigurationChange() {
        guard tapInstalled else { return }  // not capturing — nothing to protect
        if engine.isRunning {
            FileHandle.standardError.write(Data(
                "InputCapture: benign configuration change (engine still running) — take continues\n".utf8
            ))
            return
        }
        configurationChangeHandler?()
    }

    /// Removes the tap and stops the input engine. Idempotent.
    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }
}
