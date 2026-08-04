import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Real CoreAudio enumeration and real output-AUHAL pinning (m20-j) — the
/// output twin of `InputDeviceTests`.
///
/// Property reads plus, in two tests, a property WRITE to this process's own
/// `AVAudioEngine` output unit. Nothing here starts the hardware
/// (`engine.start()` is never called), no tap is installed, and no TCC prompt
/// can fire, so the suite cannot hang.
///
/// ⚠️ SAFETY, and it is the point of the whole item: the only thing ever
/// written is `kAudioOutputUnitProperty_CurrentDevice` on an AUHAL this
/// process owns. `kAudioHardwarePropertyDefaultOutputDevice` is READ (twice,
/// as an assertion) and never written — a user picking an output inside DAW
/// Pro must not move their Mac's default. `defaultOutputUntouched…` below
/// proves that behaviourally, and `noHardwarePropertyWritesInEngineSources`
/// proves it structurally for every path in DAWEngine, not just these tests.
@Suite("Output devices — CoreAudio enumeration and app-local pinning (m20-j)")
struct OutputDeviceTests {

    /// Reads `kAudioHardwarePropertyDefaultOutputDevice`. A READ helper; there
    /// is deliberately no setter anywhere in this project.
    private static func systemDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return deviceID
    }

    @Test("every Mac reports at least one sane output device, one flagged default")
    func enumerateBasics() {
        let devices = OutputDevices.enumerate()
        #expect(!devices.isEmpty)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(device.sampleRate > 8_000)
            #expect(device.channelCount >= 1)
            // No selection passed ⇒ nothing may claim to be selected.
            #expect(!device.isSelected)
        }
        #expect(devices.contains { $0.isDefault })
    }

    @Test("enumerate(selectedUID:) stamps isSelected on exactly that device, and nil stamps none")
    func selectionStamping() throws {
        let baseline = OutputDevices.enumerate()
        let target = try #require(baseline.first, "no output devices on this machine")

        let stamped = OutputDevices.enumerate(selectedUID: target.uid)
        #expect(stamped.filter(\.isSelected).map(\.uid) == [target.uid])
        // isDefault is untouched by the stamping — the two flags are independent.
        #expect(stamped.map(\.isDefault) == baseline.map(\.isDefault))

        // A uid that resolves to nothing selects nothing (rather than, say,
        // falling back to the first device).
        #expect(OutputDevices.enumerate(selectedUID: "nope").allSatisfy { !$0.isSelected })
        #expect(OutputDevices.enumerate(selectedUID: nil).allSatisfy { !$0.isSelected })
    }

    @Test("deviceID(forUID:) resolves the default's uid and rejects nonsense")
    func uidResolution() throws {
        let defaultDevice = try #require(
            OutputDevices.enumerate().first { $0.isDefault },
            "no default output device on this machine"
        )
        #expect(OutputDevices.deviceID(forUID: defaultDevice.uid) != nil)
        #expect(OutputDevices.deviceID(forUID: "nope") == nil)
    }

    /// Input-only devices must not appear in the output list and vice versa —
    /// the scope parameter is the whole difference between the two facades, so
    /// a copy/paste of the wrong scope has to redden something.
    @Test("the input and output enumerations really are scoped differently")
    func scopesAreDistinct() {
        let outputs = Set(OutputDevices.enumerate().map(\.uid))
        let inputs = Set(InputDevices.enumerate().map(\.uid))
        #expect(!outputs.isEmpty)
        #expect(!inputs.isEmpty)
        // The system default OUTPUT is an output; the system default INPUT is
        // an input. On a laptop those are different devices (speakers vs mic),
        // which is what makes this discriminating rather than tautological.
        let defaultOut = OutputDevices.enumerate().first { $0.isDefault }?.uid
        let defaultIn = InputDevices.enumerate().first { $0.isDefault }?.uid
        if let defaultOut { #expect(outputs.contains(defaultOut)) }
        if let defaultIn { #expect(inputs.contains(defaultIn)) }
    }

    @MainActor
    @Test("AudioEngine.setOutputDevice validates the uid; nil always succeeds")
    func engineSelectionValidation() throws {
        let engine = AudioEngine()  // never prepared — no hardware started
        #expect {
            try engine.setOutputDevice(uid: "nope")
        } throws: { error in
            (error as? LocalizedError)?.errorDescription?.contains("no output device") == true
        }
        try engine.setOutputDevice(uid: nil)  // follow the system default: always valid

        // ANTI-VACUITY: `availableOutputDevices()` has an optional-capability
        // DEFAULT on AudioEngineControlling that returns []. If AudioEngine
        // ever lost its override, every other test here would still pass while
        // the app silently reported no output devices. This is the assertion
        // that would redden (the InputDeviceTests:46 precedent).
        #expect(engine.availableOutputDevices().map(\.uid)
                == OutputDevices.enumerate().map(\.uid))
        #expect(!engine.availableOutputDevices().isEmpty)
    }

    /// THE hazard m20-b paid for: `AudioUnitSetProperty` returns `noErr` on a
    /// write the unit DISCARDED, so the read-back is the only proof the pin
    /// landed. This drives the real engine's real AUHAL and then reads the
    /// property back independently of the engine's own code.
    @MainActor
    @Test("pinning a real output device lands on the AUHAL and reads back")
    func pinReadsBack() throws {
        let devices = OutputDevices.enumerate()
        let defaultBefore = Self.systemDefaultOutputDeviceID()

        // Prefer a NON-default device — pinning the device the engine is
        // already sitting on could not distinguish "the write took" from
        // "nothing happened". Skip cleanly on a single-output machine.
        guard let target = devices.first(where: { !$0.isDefault }) else {
            withKnownIssue("only one output device on this machine — no non-default target") {
                Issue.record("skipped: needs a second output device")
            }
            return
        }
        let targetID = try #require(OutputDevices.deviceID(forUID: target.uid))

        let engine = AudioEngine()  // never prepared — no hardware started
        try engine.setOutputDevice(uid: target.uid)

        // Read the property back from the AUHAL directly, not through the
        // engine's own accessor, so this is an independent witness.
        let audioUnit = try #require(engine.outputNodeAudioUnitForTesting)
        var readBack = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &readBack, &dataSize)
        #expect(status == noErr)
        #expect(readBack == targetID)
        #expect(readBack != defaultBefore, "the pin must have MOVED the AUHAL off the default")

        // The selection is reflected in the reported list.
        let listed = engine.availableOutputDevices()
        #expect(listed.filter(\.isSelected).map(\.uid) == [target.uid])
        #expect(listed.filter(\.isDefault).map(\.uid) != [target.uid],
                "the fixture picked a non-default device, so the flags must differ")

        // ⚠️ THE WHOLE POINT: the app pinned its own output and the Mac's
        // default output did not move.
        #expect(Self.systemDefaultOutputDeviceID() == defaultBefore)
    }

    /// Resetting to nil must return the engine to FOLLOWING the system default
    /// — and must still not touch the system default itself.
    @MainActor
    @Test("resetting to nil clears the pin without touching the system default")
    func resetClearsPin() throws {
        let devices = OutputDevices.enumerate()
        let defaultBefore = Self.systemDefaultOutputDeviceID()
        // Same anti-vacuity treatment as `pinReadsBack`: a bare `return` here
        // would let a single-output machine PASS this test having executed no
        // assertion at all, which is indistinguishable from a real pass.
        #expect(!devices.isEmpty, "no output devices enumerated — the fixture itself is missing")
        guard let target = devices.first(where: { !$0.isDefault }) else {
            withKnownIssue("only one output device on this machine — no non-default target") {
                Issue.record("skipped: needs a second output device")
            }
            return
        }

        let engine = AudioEngine()
        try engine.setOutputDevice(uid: target.uid)
        #expect(engine.availableOutputDevices().contains { $0.isSelected })

        try engine.setOutputDevice(uid: nil)
        #expect(engine.availableOutputDevices().allSatisfy { !$0.isSelected })
        // A fresh engine follows the system default by definition, so the
        // AUHAL is back on it.
        let audioUnit = try #require(engine.outputNodeAudioUnitForTesting)
        var readBack = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        #expect(AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &readBack, &dataSize) == noErr)
        #expect(readBack == defaultBefore)

        #expect(Self.systemDefaultOutputDeviceID() == defaultBefore)
    }

    /// A rejected selection must not become state — neither in the engine's
    /// reported list nor on the AUHAL.
    @MainActor
    @Test("a rejected uid leaves the previous pin in place")
    func rejectionKeepsPreviousPin() throws {
        let devices = OutputDevices.enumerate()
        #expect(!devices.isEmpty, "no output devices enumerated — the fixture itself is missing")
        guard let target = devices.first(where: { !$0.isDefault }) else {
            withKnownIssue("only one output device on this machine — no non-default target") {
                Issue.record("skipped: needs a second output device")
            }
            return
        }
        let engine = AudioEngine()
        try engine.setOutputDevice(uid: target.uid)

        #expect(throws: (any Error).self) { try engine.setOutputDevice(uid: "ghost") }
        #expect(engine.availableOutputDevices().filter(\.isSelected).map(\.uid) == [target.uid])
    }

    /// The behavioural half of the safety claim, stated as its own test so it
    /// reddens on its own terms: run every output-device operation this module
    /// exposes and assert the system default output is bit-identical after.
    @MainActor
    @Test("the system default output is unchanged across every output-device operation")
    func defaultOutputUntouchedAcrossOperations() throws {
        let before = Self.systemDefaultOutputDeviceID()
        #expect(before != AudioDeviceID(kAudioObjectUnknown),
                "no system default output — this test would be vacuous")

        let engine = AudioEngine()
        _ = OutputDevices.enumerate()
        _ = OutputDevices.defaultOutputDeviceID()
        _ = engine.availableOutputDevices()
        for device in OutputDevices.enumerate() {
            try engine.setOutputDevice(uid: device.uid)
            _ = engine.availableOutputDevices()
        }
        try engine.setOutputDevice(uid: nil)
        #expect(throws: (any Error).self) { try engine.setOutputDevice(uid: "ghost") }

        #expect(Self.systemDefaultOutputDeviceID() == before)
    }

    /// The STRUCTURAL half, which the behavioural test above cannot give:
    /// read-before/read-after only proves THAT test didn't move the default.
    /// This proves no code path in the whole engine module can, because the
    /// only CoreAudio call that could — `AudioObjectSetPropertyData` — does not
    /// appear in DAWEngine at all. (`AudioUnitSetProperty` is a different API:
    /// it writes to an AudioUnit this process owns, never to the HAL's global
    /// state.)
    @Test("no DAWEngine source writes a CoreAudio hardware property")
    func noHardwarePropertyWritesInEngineSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DAWEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/DAWEngine")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        var defaultDeviceSelectorMentions: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if text.contains("AudioObjectSetPropertyData") {
                offenders.append(url.lastPathComponent)
            }
            // The default-device selectors may only ever be READ. Any file
            // mentioning one is listed so a future writer has to look here.
            if text.contains("kAudioHardwarePropertyDefaultOutputDevice")
                || text.contains("kAudioHardwarePropertyDefaultInputDevice") {
                defaultDeviceSelectorMentions.append(url.lastPathComponent)
            }
        }
        // Anti-vacuity: a scan that found no files would report "no offenders".
        #expect(scanned > 10, "the source scan itself must find files, or this test is vacuous")
        #expect(offenders.isEmpty,
                "DAWEngine must never write a CoreAudio hardware property: \(offenders)")
        // The selectors ARE used (read) — if this went empty the scan is
        // pointed at the wrong tree.
        #expect(defaultDeviceSelectorMentions.contains("HardwareDevices.swift"))
    }
}
