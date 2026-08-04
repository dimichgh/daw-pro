import CoreAudio
import DAWCore
import Foundation

/// CoreAudio hardware enumeration for the CAPTURE side: which devices offer
/// input streams, and how a persisted device UID resolves back to a live
/// `AudioDeviceID`.
///
/// m20-j: every CoreAudio property read moved to `HardwareDevices`, the one
/// home shared with `OutputDevices`. This enum is now a direction-fixing
/// facade + the mapping into the domain's `AudioInputDevice` — behaviour is
/// unchanged (same walk, same skip-on-failed-read policy, same order).
enum InputDevices {
    /// Every hardware device currently offering at least one input stream, in
    /// CoreAudio's device-list order, with the system default input flagged.
    /// Devices with zero input channels (output-only interfaces, displays) are
    /// filtered out.
    static func enumerate() -> [AudioInputDevice] {
        HardwareDevices.enumerate(.input).map {
            AudioInputDevice(
                uid: $0.uid,
                name: $0.name,
                sampleRate: $0.sampleRate,
                channelCount: $0.channelCount,
                isDefault: $0.isDefault
            )
        }
    }

    /// Resolves a persisted device UID back to the live `AudioDeviceID`, or
    /// nil when no input-capable device carries that UID (unplugged, renamed
    /// system, agent typo).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        HardwareDevices.deviceID(forUID: uid, direction: .input)
    }

    /// The system default input device, or nil when none exists. Internal
    /// (not just file-private) because `InputCapture` compares a pin target
    /// against it: a fresh AVAudioEngine input already captures from the
    /// default, so pinning the default's own uid must be a no-op — the AUHAL's
    /// CurrentDevice property is useless for that comparison (it reports the
    /// engine's PRIVATE aggregate device, which never equals a raw hardware ID).
    ///
    /// ⚠️ That aggregate caveat is an INPUT-side fact and does NOT generalize:
    /// m20-j measured the OUTPUT AUHAL's CurrentDevice on this machine and it
    /// reports the raw hardware ID, which is why `OutputDevices`/`AudioEngine`
    /// can (and do) use a read-back comparison as a real verification.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        HardwareDevices.defaultDeviceID(.input)
    }
}
