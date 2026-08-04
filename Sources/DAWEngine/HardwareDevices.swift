import CoreAudio
import Foundation

/// THE one home for CoreAudio hardware-device property reads (m20-j).
///
/// `InputDevices` (capture) and `OutputDevices` (playback) are thin,
/// scope-specific facades over this enum — the device-list walk, the UID/name
/// string reads, the nominal-rate read, the stream-configuration channel count
/// and the default-device query exist HERE exactly once. Before m20-j they
/// lived privately inside `InputDevices`; adding the output side by copying
/// them would have created a second computation of "what devices exist", which
/// is precisely the divergence this project's one-home rule exists to prevent.
///
/// Everything here is a pure property read on the calling thread. No I/O is
/// started, nothing touches the render path, and a device that fails any
/// property read is skipped with a stderr note rather than crashing the app.
///
/// ⚠️ `system_profiler SPAudioDataType` is NOT authoritative for virtual
/// devices (m20-b, measured) — `kAudioHardwarePropertyDevices` is, and it is
/// what this enum walks.
enum HardwareDevices {
    /// Which side of a device we care about. CoreAudio models input and output
    /// as scopes on the SAME `AudioDeviceID`, so a loopback device like
    /// BlackHole appears in both enumerations with the same UID.
    enum Direction {
        case input
        case output

        var scope: AudioObjectPropertyScope {
            switch self {
            case .input: kAudioDevicePropertyScopeInput
            case .output: kAudioDevicePropertyScopeOutput
            }
        }

        /// The system-default selector for this direction. READ ONLY — nothing
        /// in DAW Pro ever writes a default-device property (m20-j: pinning is
        /// APP-LOCAL, the user's Mac-wide default is never read-modify-written).
        var defaultDeviceSelector: AudioObjectPropertySelector {
            switch self {
            case .input: kAudioHardwarePropertyDefaultInputDevice
            case .output: kAudioHardwarePropertyDefaultOutputDevice
            }
        }

        /// Used in the teaching text of skip notes.
        var label: String {
            switch self {
            case .input: "input"
            case .output: "output"
            }
        }
    }

    /// One device as CoreAudio describes it, direction-neutral. The domain
    /// types (`AudioInputDevice` / `AudioOutputDevice`) are mapped from this by
    /// the facades — this struct never leaves DAWEngine.
    struct Described {
        var deviceID: AudioDeviceID
        var uid: String
        var name: String
        var sampleRate: Double
        var channelCount: Int
        var isDefault: Bool
    }

    /// Every hardware device currently offering at least one stream in
    /// `direction`, in CoreAudio's device-list order, with the system default
    /// for that direction flagged. Devices with zero channels in the direction
    /// (an output-only interface asked for inputs, a display asked for
    /// outputs) are filtered out — that is normal, not an error.
    static func enumerate(_ direction: Direction) -> [Described] {
        let defaultID = defaultDeviceID(direction)
        var devices: [Described] = []
        for deviceID in allDeviceIDs() {
            guard let channels = channelCount(of: deviceID, direction: direction) else { continue }
            guard channels > 0 else { continue }  // no streams this way — not an error
            guard let uid = stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: deviceID, selector: kAudioObjectPropertyName),
                  let sampleRate = nominalSampleRate(of: deviceID) else {
                continue  // the failed read already left a stderr note
            }
            devices.append(Described(
                deviceID: deviceID,
                uid: uid,
                name: name,
                sampleRate: sampleRate,
                channelCount: channels,
                isDefault: deviceID == defaultID
            ))
        }
        return devices
    }

    /// Resolves a persisted device UID back to the live `AudioDeviceID`, or nil
    /// when no device carries that UID in this direction (unplugged, renamed
    /// system, agent typo).
    ///
    /// ⚠️ UID IS THE ONLY STABLE KEY (m20-b, paid for the hard way): an
    /// `AudioDeviceID` changes on every `coreaudiod` restart — BlackHole's
    /// moved 121 → 89 inside a single m20-b session. Never persist or compare
    /// raw IDs across time; resolve from the UID at the moment of use.
    static func deviceID(forUID uid: String, direction: Direction) -> AudioDeviceID? {
        for deviceID in allDeviceIDs() {
            guard (channelCount(of: deviceID, direction: direction) ?? 0) > 0 else { continue }
            if stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
                return deviceID
            }
        }
        return nil
    }

    /// The system default device for `direction`, or nil when none exists.
    /// A READ. There is deliberately no setter anywhere in this project.
    static func defaultDeviceID(_ direction: Direction) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            if status != noErr {
                note("default \(direction.label) device query", status: status)
            }
            return nil
        }
        return deviceID
    }

    // MARK: - Property reads

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            if status != noErr { note("device list size query", status: status) }
            return []
        }
        var deviceIDs = [AudioDeviceID](
            repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else {
            note("device list query", status: status)
            return []
        }
        return deviceIDs
    }

    /// Channel count in `direction`: sum of `mNumberChannels` across that
    /// scope's stream configuration buffers. 0 = the device offers no streams
    /// that way (normal, not an error); nil = the property read itself failed.
    static func channelCount(of deviceID: AudioDeviceID, direction: Direction) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else {
            if status != noErr {
                note("\(direction.label) stream configuration size",
                     device: deviceID, status: status)
                return nil
            }
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw)
        guard status == noErr else {
            note("\(direction.label) stream configuration", device: deviceID, status: status)
            return nil
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(
        of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a CFString at +1 — Unmanaged + takeRetained
        // balances it exactly once.
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else {
            note("string property '\(fourCC(selector))'", device: deviceID, status: status)
            return nil
        }
        return value.takeRetainedValue() as String
    }

    static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr else {
            note("nominal sample rate", device: deviceID, status: status)
            return nil
        }
        return sampleRate
    }

    // MARK: - Diagnostics (main/control thread only — never the render path)

    static func note(_ what: String, device: AudioDeviceID? = nil, status: OSStatus) {
        let target = device.map { " (device \($0))" } ?? ""
        FileHandle.standardError.write(Data(
            "HardwareDevices: \(what)\(target) failed — OSStatus \(status); skipping\n".utf8
        ))
    }

    static func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let bytes = [
            UInt8((selector >> 24) & 0xFF), UInt8((selector >> 16) & 0xFF),
            UInt8((selector >> 8) & 0xFF), UInt8(selector & 0xFF),
        ]
        return bytes.allSatisfy { (0x20...0x7E).contains($0) }
            ? String(decoding: bytes, as: UTF8.self)
            : String(selector)
    }
}
