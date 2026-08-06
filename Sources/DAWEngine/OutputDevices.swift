import CoreAudio
import DAWCore
import Foundation

/// CoreAudio hardware enumeration for the PLAYBACK side (m20-j): which devices
/// offer output streams, and how a persisted device UID resolves back to a live
/// `AudioDeviceID`. The output twin of `InputDevices`; both are thin facades
/// over `HardwareDevices`, which owns every property read exactly once.
///
/// Nothing here writes anything. In particular the system default output
/// device is only ever READ (to flag `isDefault`) — DAW Pro pins its own
/// output AUHAL and never moves the user's Mac-wide default.
enum OutputDevices {
    /// Every hardware device currently offering at least one output stream, in
    /// CoreAudio's device-list order.
    ///
    /// `selectedUID` is the app's OWN pin (`AudioEngine.setOutputDevice`), and
    /// stamping it here is the single home of the `isSelected` computation.
    /// The two flags answer genuinely different questions and are deliberately
    /// independent:
    ///
    /// - `isDefault` — this is the device the SYSTEM currently sends audio to.
    /// - `isSelected` — this is the device DAW PRO has explicitly pinned.
    ///
    /// When `selectedUID` is nil (follow the system default) NO device reports
    /// `isSelected`, which is what distinguishes "following the default, and
    /// will move when the user changes it" from "explicitly pinned to the
    /// device that happens to be the default right now". Those are different
    /// states and a picker that conflates them lies to the user.
    static func enumerate(selectedUID: String? = nil) -> [AudioOutputDevice] {
        stamp(HardwareDevices.enumerate(.output), selectedUID: selectedUID)
    }

    /// Maps one hardware-enumeration snapshot into `[AudioOutputDevice]`,
    /// stamping `isSelected` against `selectedUID`. This is the single home of
    /// the `isSelected` computation — `enumerate(selectedUID:)` above is its
    /// only caller — split out so the STAMPING RULE can be exercised against a
    /// fixed, already-captured `[HardwareDevices.Described]` snapshot instead
    /// of a fresh hardware walk.
    ///
    /// Why this exists: two calls to `enumerate(selectedUID:)` are two
    /// INDEPENDENT live CoreAudio enumerations, and a device appearing or
    /// vanishing between them changes array length/order, which broke
    /// `OutputDeviceTests.selectionStamping`'s positional comparison (m23-bo).
    /// Comparing `stamp(snapshot, ...)` against `stamp(snapshot, ...)` for the
    /// SAME in-memory `snapshot` can never differ in length, by construction.
    static func stamp(
        _ devices: [HardwareDevices.Described], selectedUID: String?
    ) -> [AudioOutputDevice] {
        devices.map {
            AudioOutputDevice(
                uid: $0.uid,
                name: $0.name,
                sampleRate: $0.sampleRate,
                channelCount: $0.channelCount,
                isDefault: $0.isDefault,
                isSelected: selectedUID != nil && $0.uid == selectedUID
            )
        }
    }

    /// Resolves a persisted device UID back to the live `AudioDeviceID`, or nil
    /// when no output-capable device carries that UID.
    ///
    /// ⚠️ Always resolve at the moment of use: `AudioDeviceID`s are not stable
    /// across a `coreaudiod` restart (m20-b measured BlackHole moving 121 → 89
    /// mid-session). The UID is the key; the ID is a transient handle.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        HardwareDevices.deviceID(forUID: uid, direction: .output)
    }

    /// The system default output device, or nil when none exists. READ ONLY —
    /// used to flag `isDefault` and to report the fallback target in
    /// diagnostics. There is no setter, by design.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        HardwareDevices.defaultDeviceID(.output)
    }
}
