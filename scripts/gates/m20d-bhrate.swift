// m20d-bhrate — read or set the BlackHole loopback's nominal sample rate.
//
// Exists because the m20-d gate has to put a real output device at a rate the
// project rate is NOT, and there is no wire verb for that (deliberately —
// nothing user-facing should move a device's nominal rate).
//
// ⚠️ WHY THIS CANNOT REACH THE USER'S REAL DEVICES. `TARGET_UID` is a
// compile-time constant and the only device this program ever resolves. There
// is no argument, environment variable or default that selects a different
// one — passing a rate to a machine without BlackHole exits 2 having written
// nothing. That restriction is STRUCTURAL, not a policy the caller has to
// remember, which is the same reason `ArrangeDropSnap`'s init is fileprivate.
//
// ⚠️ THE READ-BACK IS THE RESULT, NOT THE STATUS CODE. The HAL applies a
// nominal-rate write ASYNCHRONOUSLY: `AudioObjectSetPropertyData` returns
// noErr long before the device has moved, so both branches below print the
// read-back and the caller asserts on THAT. m20-b learned the same lesson on
// the output AUHAL ("AudioUnitSetProperty returns noErr on writes the unit
// discards").
//
// Build (the binary is a build artifact and is not committed):
//   swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate
// Use:
//   ./scripts/gates/m20d-bhrate            -> print the current rate
//   ./scripts/gates/m20d-bhrate 44100      -> set it, then print the READ-BACK
import CoreAudio
import Foundation

let TARGET_UID = "BlackHole2ch_UID"

func devices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func uidOf(_ id: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == noErr,
          let v = s?.takeRetainedValue() else { return "" }
    return v as String
}

func nominalRate(_ id: AudioDeviceID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var r: Float64 = 0
    var sz = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &r) == noErr else { return -1 }
    return r
}

// Resolve by UID, never by device ID: the ID changes on every coreaudiod
// restart (measured 2026-07-30), so an ID cached anywhere is a live hazard.
guard let device = devices().first(where: { uidOf($0) == TARGET_UID }) else {
    FileHandle.standardError.write(Data("no device with uid \(TARGET_UID)\n".utf8))
    exit(2)
}

if CommandLine.arguments.count > 1 {
    guard let want = Double(CommandLine.arguments[1]), want > 0 else {
        FileHandle.standardError.write(Data("bad rate '\(CommandLine.arguments[1])'\n".utf8))
        exit(2)
    }
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var r = Float64(want)
    let st = AudioObjectSetPropertyData(device, &a, 0, nil,
                                        UInt32(MemoryLayout<Float64>.size), &r)
    for _ in 0..<60 {  // asynchronous apply — poll the read-back, up to ~3 s
        if abs(nominalRate(device) - want) < 0.5 { break }
        usleep(50_000)
    }
    print("set status=\(st)  read-back=\(nominalRate(device))")
} else {
    print("id=\(device)  read-back=\(nominalRate(device))")
}
