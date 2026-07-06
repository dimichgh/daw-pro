import CoreAudio
import DAWCore
import Foundation

/// CoreAudio hardware enumeration for the capture side: which devices offer
/// input streams, and how a persisted device UID resolves back to a live
/// `AudioDeviceID`. Pure property reads on the calling thread — no I/O is
/// started, nothing here touches the render path, and a device that fails any
/// property read is skipped with a stderr note rather than crashing the app.
enum InputDevices {
    /// Every hardware device currently offering at least one input stream,
    /// in CoreAudio's device-list order, with the system default input
    /// flagged. Devices with zero input channels (output-only interfaces,
    /// displays) are filtered out.
    static func enumerate() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()
        var devices: [AudioInputDevice] = []
        for deviceID in allDeviceIDs() {
            guard let channels = inputChannelCount(of: deviceID) else { continue }
            guard channels > 0 else { continue }  // no input streams — not an error
            guard let uid = stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(of: deviceID, selector: kAudioObjectPropertyName),
                  let sampleRate = nominalSampleRate(of: deviceID) else {
                continue  // the failed read already left a stderr note
            }
            devices.append(AudioInputDevice(
                uid: uid,
                name: name,
                sampleRate: sampleRate,
                channelCount: channels,
                isDefault: deviceID == defaultID
            ))
        }
        return devices
    }

    /// Resolves a persisted device UID back to the live `AudioDeviceID`, or
    /// nil when no input-capable device carries that UID (unplugged, renamed
    /// system, agent typo).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for deviceID in allDeviceIDs() {
            guard (inputChannelCount(of: deviceID) ?? 0) > 0 else { continue }
            if stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID) == uid {
                return deviceID
            }
        }
        return nil
    }

    // MARK: - Property reads

    private static func allDeviceIDs() -> [AudioDeviceID] {
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

    /// The system default input device, or nil when none exists. Internal
    /// (not just file-private) because `InputCapture` compares a pin target
    /// against it: a fresh AVAudioEngine input already captures from the
    /// default, so pinning the default's own uid must be a no-op — the AUHAL's
    /// CurrentDevice property is useless for that comparison (it reports the
    /// engine's PRIVATE aggregate device, which never equals a raw hardware ID).
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            if status != noErr { note("default input device query", status: status) }
            return nil
        }
        return deviceID
    }

    /// Input-scope channel count: sum of `mNumberChannels` across the input
    /// stream configuration's buffers. 0 = the device offers no input streams
    /// (normal, not an error); nil = the property read itself failed.
    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else {
            if status != noErr {
                note("input stream configuration size", device: deviceID, status: status)
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
            note("input stream configuration", device: deviceID, status: status)
            return nil
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
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

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
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

    private static func note(_ what: String, device: AudioDeviceID? = nil, status: OSStatus) {
        let target = device.map { " (device \($0))" } ?? ""
        FileHandle.standardError.write(Data(
            "InputDevices: \(what)\(target) failed — OSStatus \(status); skipping\n".utf8
        ))
    }

    private static func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let bytes = [
            UInt8((selector >> 24) & 0xFF), UInt8((selector >> 16) & 0xFF),
            UInt8((selector >> 8) & 0xFF), UInt8(selector & 0xFF),
        ]
        return bytes.allSatisfy { (0x20...0x7E).contains($0) }
            ? String(decoding: bytes, as: UTF8.self)
            : String(selector)
    }
}
