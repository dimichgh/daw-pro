import CoreAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Real CoreAudio enumeration — property reads only. No capture starts, no
/// tap installs, no engine.start(), no TCC prompt: these calls return
/// immediately whatever the hardware situation, so the suite cannot hang.
@Suite("Input devices — CoreAudio enumeration")
struct InputDeviceTests {
    @Test("every Mac reports at least one sane input device, one flagged default")
    func enumerateBasics() {
        let devices = InputDevices.enumerate()
        #expect(!devices.isEmpty)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(device.sampleRate > 8_000)
            #expect(device.channelCount >= 1)
        }
        #expect(devices.contains { $0.isDefault })
    }

    @Test("deviceID(forUID:) resolves the default's uid and rejects nonsense")
    func uidResolution() throws {
        let defaultDevice = try #require(
            InputDevices.enumerate().first { $0.isDefault },
            "no default input device on this machine"
        )
        #expect(InputDevices.deviceID(forUID: defaultDevice.uid) != nil)
        #expect(InputDevices.deviceID(forUID: "nope") == nil)
    }

    @MainActor
    @Test("AudioEngine.setInputDevice validates the uid; nil always succeeds")
    func engineSelection() throws {
        let engine = AudioEngine()  // never prepared — no hardware started
        #expect {
            try engine.setInputDevice(uid: "nope")
        } throws: { error in
            (error as? LocalizedError)?.errorDescription?.contains("no input device") == true
        }
        try engine.setInputDevice(uid: nil)  // system default is always valid
        // The protocol surface reports the same list as the enumerator.
        #expect(engine.availableInputDevices().map(\.uid)
                == InputDevices.enumerate().map(\.uid))
    }
}
