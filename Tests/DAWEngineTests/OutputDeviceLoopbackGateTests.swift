import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// m20-j LIVE GATE — the audible-path proof: does pinning an output device
/// actually make DAW Pro's sound ARRIVE at that device?
///
/// Every other m20-j test verifies the pin at the PROPERTY level (the AUHAL
/// reports the device we asked for). That is necessary and not sufficient: a
/// property can read back correctly while no audio reaches the hardware. This
/// gate drives the SHIPPED code — `AudioEngine.setOutputDevice` followed by
/// `AudioEngine.startTestTone` — into a loopback device and asserts the
/// captured spectrum.
///
/// OPT-IN, and deliberately so. It is skipped unless
/// `DAWPRO_LIVE_OUTPUT_LOOPBACK=1`, because it (a) starts real audio hardware,
/// (b) needs a loopback device (BlackHole 2ch class) installed, and (c) needs
/// microphone/TCC permission for the capture side — three machine facts that
/// have nothing to do with whether the code is correct. A normal
/// `./scripts/test.sh` run skips it and costs nothing.
///
///     DAWPRO_LIVE_OUTPUT_LOOPBACK=1 ./scripts/test.sh --filter OutputDeviceLoopback
///
/// SAFETY: the system default output is read before and after and NEVER
/// written. ⚠️ Be accurate about the speakers: the legs that deliberately run
/// UNPINNED (the LEG 3 discriminator, and phase 1 of the mid-playback test)
/// play through whatever the system default is, because "the sound goes
/// somewhere else when nothing is pinned" is the whole point of those legs and
/// cannot be shown without it. They are short and the mid-playback phase uses a
/// low amplitude. An earlier version of this comment claimed nothing ever
/// reaches the speakers; that was wrong, and a safety note that overstates its
/// own guarantee is worse than none.
///
/// ⚠️ READING A FAILURE: zero captured frames is NOT evidence of a routing
/// failure. m20-b recorded BlackHole WEDGING — accepting `AudioDeviceStart`,
/// reporting `IsRunning`, and delivering zero IOProc callbacks, which is
/// indistinguishable from a broken converter. Missing TCC permission looks the
/// same. The assertions below separate "captured nothing" from "captured the
/// wrong thing" so the two failures cannot be confused.
/// ⚠️ `.serialized` IS LOAD-BEARING, NOT TIDINESS. Swift Testing runs a suite's
/// tests in PARALLEL by default, and the first run of the mid-playback test
/// proved what that costs here: the transcript showed the second test starting
/// while the first was still rolling, so two engines were driving the SAME
/// loopback at once — while both tests assert that the loopback is QUIET at
/// certain moments. A silence assertion polluted by another test's tone can
/// pass or fail by timing luck, and it passed, which is exactly the sort of
/// green that means nothing. There is one physical loopback device; access to
/// it has to be serial.
@Suite("Output device loopback — audible path (m20-j live gate)", .serialized)
struct OutputDeviceLoopbackGateTests {

    static let isEnabled = ProcessInfo.processInfo
        .environment["DAWPRO_LIVE_OUTPUT_LOOPBACK"] == "1"

    /// Loopback UIDs this gate knows how to use, in preference order.
    static let loopbackUIDs = ["BlackHole2ch_UID", "BlackHole16ch_UID"]

    private static func systemDefaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return deviceID
    }

    /// Dominant frequency of `samples` by FFT peak with parabolic
    /// interpolation. Returns 0 when there are too few samples.
    private static func peakFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        let n = 32_768
        guard samples.count >= n, sampleRate > 0 else { return 0 }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        let slice = Array(samples[(samples.count - n)...])
        vDSP_vmul(slice, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        var maxIndex = 1
        for i in 2..<(n / 2) where magnitudes[i] > magnitudes[maxIndex] { maxIndex = i }
        let a = Double(magnitudes[max(1, maxIndex - 1)])
        let b = Double(magnitudes[maxIndex])
        let c = Double(magnitudes[min(n / 2 - 1, maxIndex + 1)])
        let denom = a - 2 * b + c
        let delta = denom == 0 ? 0 : 0.5 * (a - c) / denom
        return (Double(maxIndex) + delta) * (sampleRate / Double(n))
    }

    /// Captured audio from the loopback device's INPUT side.
    private struct Capture {
        var samples: [Float]
        var sampleRate: Double
        var rms: Double {
            guard !samples.isEmpty else { return 0 }
            var acc: Float = 0
            vDSP_measqv(samples, 1, &acc, vDSP_Length(samples.count))
            return sqrt(Double(acc))
        }
    }

    /// Runs the SHIPPED path: pin the engine's output to `uid`, sound
    /// `frequency` through `startTestTone`, and capture the loopback's input.
    @MainActor
    private static func captureShippedTestTone(
        pinTo uid: String?, loopbackID: AudioDeviceID, frequency: Double, seconds: Double = 1.5
    ) throws -> Capture {
        // Capture engine: its own AVAudioEngine, input pinned to the loopback.
        let capture = AVAudioEngine()
        let input = capture.inputNode
        if input.audioUnit == nil { capture.prepare() }
        if let au = input.audioUnit {
            var device = loopbackID
            _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &device,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let captureFormat = input.outputFormat(forBus: 0)

        let box = SampleBox()
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            box.append(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        // THE SHIPPED PATH.
        let engine = AudioEngine()
        try engine.setOutputDevice(uid: uid)
        try capture.start()
        try engine.startTestTone(frequency: frequency, amplitude: 0.25)
        Thread.sleep(forTimeInterval: seconds)
        engine.stopTestTone()
        engine.shutdown()

        input.removeTap(onBus: 0)
        capture.stop()
        return Capture(samples: box.drain(), sampleRate: captureFormat.sampleRate)
    }

    /// Tiny lock box — the tap closure is `@Sendable` and runs off the main
    /// actor, so the accumulator cannot be a captured local.
    private final class SampleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ buffer: UnsafeBufferPointer<Float>) {
            lock.lock(); samples.append(contentsOf: buffer); lock.unlock()
        }
        func drain() -> [Float] {
            lock.lock(); defer { lock.unlock() }; return samples
        }
        /// Returns everything captured SINCE THE LAST CALL and resets. Lets one
        /// continuous capture be cut into before/after windows around a live
        /// device change, which is the only way to observe a re-point without
        /// tearing the capture down (a teardown would confound "the sound
        /// moved" with "the capture restarted").
        func takeAll() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            let taken = samples
            samples.removeAll(keepingCapacity: true)
            return taken
        }
    }

    @MainActor
    @Test("the shipped setOutputDevice + test tone lands on the pinned device, and only there",
          .enabled(if: OutputDeviceLoopbackGateTests.isEnabled))
    func toneArrivesAtPinnedDevice() throws {
        let loopback = try #require(
            OutputDevices.enumerate().first { Self.loopbackUIDs.contains($0.uid) },
            "no loopback output device installed — this gate needs BlackHole 2ch")
        let loopbackID = try #require(OutputDevices.deviceID(forUID: loopback.uid))
        let defaultBefore = Self.systemDefaultOutputDeviceID()
        #expect(!loopback.isDefault,
                "the loopback must NOT be the system default, or this gate proves nothing")

        // LEG 1 — pinned: a 997 Hz tone must arrive at the loopback.
        let pinned = try Self.captureShippedTestTone(
            pinTo: loopback.uid, loopbackID: loopbackID, frequency: 997)
        try #require(!pinned.samples.isEmpty, """
            captured ZERO frames. This is NOT a routing failure on its own — \
            the loopback device may be wedged (m20-b: accepts start, delivers \
            no IOProc callbacks; recovery is `sudo killall coreaudiod`, the \
            USER's call) or this process may lack microphone/TCC permission.
            """)
        let pinnedPeak = Self.peakFrequency(pinned.samples, sampleRate: pinned.sampleRate)
        #expect(abs(pinnedPeak - 997) < 2.0,
                "expected ~997 Hz at the pinned device, got \(pinnedPeak) Hz")
        #expect(pinned.rms > 0.01, "the pinned device received signal, not silence")

        // LEG 2 — falsifiability sibling. Five byte-identical runs look exactly
        // like a probe printing a constant; a DIFFERENT tone must read back as
        // a different number through the same path.
        let sibling = try Self.captureShippedTestTone(
            pinTo: loopback.uid, loopbackID: loopbackID, frequency: 440)
        let siblingPeak = Self.peakFrequency(sibling.samples, sampleRate: sibling.sampleRate)
        #expect(abs(siblingPeak - 440) < 2.0,
                "the 440 Hz control must read 440, not \(siblingPeak) — a fixed number here would mean the capture is not measuring the tone")

        // LEG 3 — the discriminator. WITHOUT the pin the engine follows the
        // system default, so the loopback must capture (near) silence. This is
        // what makes LEG 1 evidence about the PIN rather than about the tone.
        let unpinned = try Self.captureShippedTestTone(
            pinTo: nil, loopbackID: loopbackID, frequency: 997)
        #expect(unpinned.rms < pinned.rms / 50,
                "unpinned playback must not reach the loopback (rms \(unpinned.rms) vs pinned \(pinned.rms))")

        // And the whole point of the item.
        #expect(Self.systemDefaultOutputDeviceID() == defaultBefore,
                "the system default output must not have moved")
    }

    // MARK: - Changing the device WHILE audio is rolling

    /// THE PRIMARY USER FLOW, and the one every other m20-j test misses: a user
    /// switches output device while sound is already playing.
    ///
    /// Everything else in this item pins a STOPPED, never-started engine and
    /// then starts the tone. That is the cold path. Warm is different and
    /// strictly harder:
    ///
    ///  * pinning live writes the AUHAL property on a RUNNING unit, which
    ///    raises an AVAudioEngine configuration change (`recoverEngine`), and
    ///  * unpinning live runs `rebuildEngine` — the heaviest operation in the
    ///    item — from a call site nothing else reaches warm.
    ///
    /// One continuous capture is cut into windows around each change, so the
    /// evidence is "the sound moved" rather than "a second capture also
    /// worked".
    ///
    /// ⚠️ Phase 1 plays through the SYSTEM DEFAULT (that is what makes the
    /// later windows evidence about the pin), at amplitude 0.05 for well under
    /// a second.
    @MainActor
    @Test("changing the output device WHILE audio is rolling re-points the live engine",
          .enabled(if: OutputDeviceLoopbackGateTests.isEnabled))
    func devicePinChangesWhileAudioIsRolling() throws {
        let loopback = try #require(
            OutputDevices.enumerate().first { Self.loopbackUIDs.contains($0.uid) },
            "no loopback output device installed — this gate needs BlackHole 2ch")
        let loopbackID = try #require(OutputDevices.deviceID(forUID: loopback.uid))
        let defaultBefore = Self.systemDefaultOutputDeviceID()
        #expect(!loopback.isDefault,
                "the loopback must NOT be the system default, or this gate proves nothing")

        // One capture engine, running for the whole test.
        let capture = AVAudioEngine()
        let input = capture.inputNode
        if input.audioUnit == nil { capture.prepare() }
        if let au = input.audioUnit {
            var device = loopbackID
            _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &device,
                                     UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let captureRate = input.outputFormat(forBus: 0).sampleRate
        let box = SampleBox()
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { @Sendable buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            box.append(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        defer { input.removeTap(onBus: 0); capture.stop() }

        let engine = AudioEngine()
        defer { engine.shutdown() }

        // PHASE 1 — rolling, UNPINNED. Sound goes to the system default, so the
        // loopback should hear (near) nothing.
        try engine.startTestTone(frequency: 997, amplitude: 0.05)
        try capture.start()
        Thread.sleep(forTimeInterval: 0.9)
        let unpinnedWindow = Capture(samples: box.takeAll(), sampleRate: captureRate)
        try #require(!unpinnedWindow.samples.isEmpty, """
            captured ZERO frames in the very first window. This is NOT a routing \
            result — the loopback may be wedged (m20-b: accepts start, delivers \
            no IOProc callbacks) or this process may lack microphone/TCC \
            permission. Nothing below would mean anything.
            """)

        // PHASE 2 — THE LIVE RE-POINT. Same engine, still rolling.
        try engine.setOutputDevice(uid: loopback.uid)
        Thread.sleep(forTimeInterval: 1.5)
        let pinnedWindow = Capture(samples: box.takeAll(), sampleRate: captureRate)
        let pinnedPeak = Self.peakFrequency(pinnedWindow.samples, sampleRate: captureRate)

        #expect(pinnedWindow.rms > 0.005,
                "after pinning a LIVE engine the tone must arrive at the loopback (rms \(pinnedWindow.rms))")
        #expect(abs(pinnedPeak - 997) < 2.0,
                "expected ~997 Hz at the newly pinned device, got \(pinnedPeak) Hz")
        // The discriminator: the SAME capture heard (near) nothing a moment
        // earlier, so this is evidence about the re-point and not about the
        // tone merely existing.
        #expect(unpinnedWindow.rms < pinnedWindow.rms / 20,
                "before the pin the loopback should have been quiet (rms \(unpinnedWindow.rms) vs \(pinnedWindow.rms) after)")
        // And the AUHAL agrees with the audio.
        #expect(engine.availableOutputDevices().filter(\.isSelected).map(\.uid) == [loopback.uid])

        // PHASE 3 — THE LIVE UNPIN, which runs `rebuildEngine` warm.
        // `rebuildEngine` stops the test tone and detaches the tone player by
        // design, so the tone STOPS: assert the engine SURVIVED, not that the
        // tone continued.
        try engine.setOutputDevice(uid: nil)
        Thread.sleep(forTimeInterval: 1.0)
        _ = box.takeAll()  // discard the transition itself
        Thread.sleep(forTimeInterval: 0.6)
        let afterUnpin = Capture(samples: box.takeAll(), sampleRate: captureRate)
        #expect(afterUnpin.rms < pinnedWindow.rms / 20,
                "after unpinning, the loopback must stop receiving (rms \(afterUnpin.rms))")
        #expect(engine.availableOutputDevices().allSatisfy { !$0.isSelected })

        // The engine survived the warm rebuild: it can still be pinned and can
        // still make sound. This is the real assertion of phase 3 — a rebuild
        // that bricked the engine would look identical to a clean unpin in the
        // silence check above.
        try engine.setOutputDevice(uid: loopback.uid)
        try engine.startTestTone(frequency: 440, amplitude: 0.2)
        Thread.sleep(forTimeInterval: 1.5)
        let revived = Capture(samples: box.takeAll(), sampleRate: captureRate)
        let revivedPeak = Self.peakFrequency(revived.samples, sampleRate: captureRate)
        #expect(revived.rms > 0.005,
                "the engine did not survive the warm rebuild — no audio after re-pinning (rms \(revived.rms))")
        #expect(abs(revivedPeak - 440) < 2.0,
                "expected ~440 Hz after the warm rebuild, got \(revivedPeak) Hz — a stuck 997 would mean the old graph never went away")
        engine.stopTestTone()

        #expect(Self.systemDefaultOutputDeviceID() == defaultBefore,
                "the system default output must not have moved")
    }

    // MARK: - Rate-flip survival

    private static func nominalRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return rate
    }

    @discardableResult
    private static func setNominalRate(_ device: AudioDeviceID, _ rate: Double) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// The roadmap's "pin survives a rate flip" criterion, measured rather than
    /// argued. Changing a device's nominal rate raises an AVAudioEngine
    /// configuration change (m20-b saw it 10/10), which lands on
    /// `recoverEngine`. ⚠️ The rest of this paragraph USED to argue that
    /// `recoverEngine` restarts the same engine object so the AUHAL should keep
    /// its device, and that "should" was the reason this test existed. Both
    /// halves are now stale: this test never reaches the restart (see the next
    /// paragraph), and the restart claim has since been MEASURED TRUE by a
    /// different gate — `RecoveryOutputPinGateTests` (m23-bt). What this test
    /// actually covers is the rate flip itself.
    ///
    /// ⚠️ THIS TEST DOES NOT COVER "the pin survives an engine RESTART", even
    /// though its name and the paragraph above read as if it does (m23-bt found
    /// this). The setup is `startTestTone`, which never sets `currentAnchor` —
    /// and `recoverEngine()` early-returns at `guard let anchor = currentAnchor`.
    /// So the configuration change this test raises lands on the EARLY-OUT and
    /// the `if !engine.isRunning { prepare(); start() }` restart block is never
    /// reached. What is actually asserted here is that the pin survives a rate
    /// flip WHEN RECOVERY DOES NOTHING — which is worth having, but is a
    /// strictly weaker claim. The restart question is measured by
    /// `RecoveryOutputPinGateTests` (`DAWPRO_LIVE_RECOVERY_PIN=1`), which rolls
    /// a REAL anchor and asserts the restart branch executed before trusting
    /// its read-back.
    ///
    /// ⚠️ THIS ONE WRITES A DEVICE SETTING — the loopback's nominal sample
    /// rate, the same surface m20-b used, restored in a `defer` on every exit
    /// path and re-asserted at the end. It is gated behind its own env var,
    /// separate from the loopback gate, so it can never run by accident. It
    /// touches the LOOPBACK only; a real device's settings are never written.
    @MainActor
    @Test("the output pin survives a device nominal-rate flip",
          .enabled(if: ProcessInfo.processInfo
                       .environment["DAWPRO_LIVE_OUTPUT_RATEFLIP"] == "1"))
    func pinSurvivesRateFlip() throws {
        let loopback = try #require(
            OutputDevices.enumerate().first { Self.loopbackUIDs.contains($0.uid) },
            "no loopback output device installed")
        let loopbackID = try #require(OutputDevices.deviceID(forUID: loopback.uid))
        #expect(!loopback.isDefault, "never flip the rate of the system default device")

        let entryRate = Self.nominalRate(loopbackID)
        try #require(entryRate > 0, "could not read the loopback's entry rate — refusing to write one")
        defer {
            Self.setNominalRate(loopbackID, entryRate)
        }

        let engine = AudioEngine()
        try engine.setOutputDevice(uid: loopback.uid)
        try engine.startTestTone(frequency: 997, amplitude: 0.1)
        defer { engine.shutdown() }

        // Pinned before the flip — read straight off the AUHAL.
        var before = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let unit = try #require(engine.outputNodeAudioUnitForTesting)
        #expect(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &before, &size) == noErr)
        #expect(before == loopbackID)

        // FLIP. Pick a rate that is actually different from the entry rate.
        let flipped = entryRate == 44_100 ? 48_000.0 : 44_100.0
        let status = Self.setNominalRate(loopbackID, flipped)
        try #require(status == noErr, "the loopback refused the rate write (OSStatus \(status))")
        // Let the HAL settle and the configuration-change notification land.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(Self.nominalRate(loopbackID) == flipped, "the flip did not take — nothing to test")

        // THE ASSERTION: the AUHAL is still pointed at the pinned device, and
        // the engine still reports it as the selection.
        var after = AudioDeviceID(0)
        var afterSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let unitAfter = try #require(engine.outputNodeAudioUnitForTesting)
        #expect(AudioUnitGetProperty(unitAfter, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &after, &afterSize) == noErr)
        #expect(after == loopbackID,
                "the pin was lost across the rate flip (was \(before), now \(after))")
        #expect(engine.availableOutputDevices().filter(\.isSelected).map(\.uid) == [loopback.uid])
    }
}
