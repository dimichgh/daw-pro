import AVFAudio
import AudioToolbox
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (vi-b-2) `AUViewProbe.cocoaViewInfo` against REAL system v2 units — the
/// step-2 leg of the view-resolution ladder, exercised headless. Per the design
/// §12 addendum machine inventory: AUDelay and DLSMusicDevice DO publish a custom
/// Cocoa view (`kAudioUnitProperty_CocoaUI`) while AUMatrixReverb does not — so
/// both ladder branches are provable here (non-nil advertisement vs the nil that
/// falls through to the generic body). Running the probe twice smoke-tests the
/// Get-rule CF ownership: an over-release would crash or corrupt on the repeat.
@MainActor
@Suite("AU Cocoa-view probe", .serialized)
struct AUViewProbeTests {
    private static let delay = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")
    private static let matrixReverb = AudioUnitComponentID(
        type: "aufx", subType: "mrev", manufacturer: "appl")
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    /// The raw v2 `AudioUnit` handle behind a freshly prepared effect.
    private func v2EffectHandle(_ config: AudioUnitConfig,
                                registry: AUHostRegistry) async throws -> AudioUnit {
        let effectID = UUID()
        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 48_000)
        #expect(registry.effectStatus[effectID] == .ready)
        let hosted = try #require(registry.preparedEffect(forEffect: effectID))
        // Every stock 'aufx' unit instantiates as the v2 bridge (§3.1).
        let bridge = try #require(hosted.auAudioUnit as? AUAudioUnitV2Bridge)
        return bridge.audioUnit
    }

    @Test("AUDelay advertises a custom Cocoa view — non-nil, bundle on disk, class named; idempotent")
    func delayHasCocoaView() async throws {
        let registry = AUHostRegistry()
        let handle = try await v2EffectHandle(
            AudioUnitConfig(component: Self.delay), registry: registry)

        let info = try #require(AUViewProbe.cocoaViewInfo(handle))
        print("[measured] AUDelay CocoaUI → class '\(info.className)', bundle \(info.bundleURL.path)")
        #expect(!info.className.isEmpty)
        #expect(FileManager.default.fileExists(atPath: info.bundleURL.path))

        // Second probe: balanced Get-rule ownership → identical advertisement, no leak/crash.
        let again = try #require(AUViewProbe.cocoaViewInfo(handle))
        #expect(again.className == info.className)
        #expect(again.bundleURL == info.bundleURL)
    }

    @Test("AUMatrixReverb has NO custom Cocoa view — nil (the generic-fallback branch)")
    func matrixReverbHasNoCocoaView() async throws {
        let registry = AUHostRegistry()
        let handle = try await v2EffectHandle(
            AudioUnitConfig(component: Self.matrixReverb), registry: registry)
        #expect(AUViewProbe.cocoaViewInfo(handle) == nil)
    }

    @Test("DLSMusicDevice (instrument) advertises a custom Cocoa view — non-nil")
    func dlsInstrumentHasCocoaView() async throws {
        let registry = AUHostRegistry()
        let track = Track(name: "Keys", kind: .instrument,
                          instrument: InstrumentDescriptor(
                              kind: .audioUnit, audioUnit: AudioUnitConfig(component: Self.dls)))
        await registry.prepare(track: track, sampleRate: 48_000)
        #expect(registry.status[track.id] == .ready)
        let hosted = try #require(registry.preparedInstrument(forTrack: track.id))
        let bridge = try #require(hosted.auAudioUnit as? AUAudioUnitV2Bridge)

        let info = try #require(AUViewProbe.cocoaViewInfo(bridge.audioUnit))
        print("[measured] DLSMusicDevice CocoaUI → class '\(info.className)'")
        #expect(!info.className.isEmpty)
        #expect(FileManager.default.fileExists(atPath: info.bundleURL.path))
    }
}
