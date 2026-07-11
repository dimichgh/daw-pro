import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (vi-b) plugin-window plumbing against REAL system AUs (DLSMusicDevice,
/// AUDelay — the same units the vi-a hosting suites instantiate headless): the
/// two `AudioEngine` accessors return the live instance by identity, and the
/// registry release callback fires with the right endpoint on real teardown,
/// never for no-ops, and NEVER across engine recovery (windows survive it).
@MainActor
@Suite("AU host accessors + release callback", .serialized)
struct AUHostAccessorReleaseTests {
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")
    private static let delay = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")

    private func dlsTrack() -> Track {
        Track(name: "Keys", kind: .instrument,
              instrument: InstrumentDescriptor(
                  kind: .audioUnit, audioUnit: AudioUnitConfig(component: Self.dls)))
    }

    // MARK: - 1. accessor identity

    @Test("hostedInstrumentAudioUnit returns the IDENTICAL live instance; nil before/unknown")
    func instrumentAccessorIdentity() async throws {
        let engine = AudioEngine()
        let track = dlsTrack()
        // Before prepare: nil.
        #expect(engine.hostedInstrumentAudioUnit(forTrack: track.id) == nil)

        await engine.auRegistry.prepare(track: track, sampleRate: 48_000)
        #expect(engine.auRegistry.status[track.id] == .ready)

        let viaRegistry = try #require(engine.auRegistry.preparedInstrument(forTrack: track.id)?.auAudioUnit)
        let viaAccessor = try #require(engine.hostedInstrumentAudioUnit(forTrack: track.id))
        #expect(viaAccessor === viaRegistry)   // the exact sounding object
        // Unknown id: nil.
        #expect(engine.hostedInstrumentAudioUnit(forTrack: UUID()) == nil)
    }

    @Test("hostedEffectAudioUnit returns the IDENTICAL live AUDelay; nil before/unknown")
    func effectAccessorIdentity() async throws {
        let engine = AudioEngine()
        let effectID = UUID()
        #expect(engine.hostedEffectAudioUnit(forEffect: effectID) == nil)

        await engine.auRegistry.prepareEffect(
            effectID: effectID, config: AudioUnitConfig(component: Self.delay), sampleRate: 48_000)
        #expect(engine.auRegistry.effectStatus[effectID] == .ready)

        let viaRegistry = try #require(engine.auRegistry.preparedEffect(forEffect: effectID)?.auAudioUnit)
        let viaAccessor = try #require(engine.hostedEffectAudioUnit(forEffect: effectID))
        #expect(viaAccessor === viaRegistry)
        #expect(engine.hostedEffectAudioUnit(forEffect: UUID()) == nil)
        // The effect-status mirror is live too.
        #expect(engine.audioUnitEffectStatus(forEffect: effectID) == .ready)
        #expect(engine.audioUnitEffectStatus(forEffect: UUID()) == nil)
    }

    // MARK: - 2. release callback fires (and doesn't)

    @Test("hostedAUReleased fires with the right endpoint on a real instrument release; not on a no-op")
    func instrumentReleaseFires() async throws {
        let engine = AudioEngine()
        var fired: [HostedAUEndpoint] = []
        engine.hostedAUReleased = { fired.append($0) }

        let track = dlsTrack()
        await engine.auRegistry.prepare(track: track, sampleRate: 48_000)
        #expect(fired.isEmpty)   // a first prepare releases nothing

        engine.auRegistry.releaseInstrument(forTrack: track.id)
        #expect(fired == [.instrument(trackID: track.id)])

        // A no-op release (nothing hosted for this id) fires NOTHING.
        engine.auRegistry.releaseInstrument(forTrack: UUID())
        engine.auRegistry.releaseInstrument(forTrack: track.id)   // already gone
        #expect(fired == [.instrument(trackID: track.id)])
    }

    @Test("hostedAUReleased fires for an effect release, and for a config-change re-prepare")
    func effectReleaseAndReprepareFire() async throws {
        let engine = AudioEngine()
        var fired: [HostedAUEndpoint] = []
        engine.hostedAUReleased = { fired.append($0) }

        let effectID = UUID()
        await engine.auRegistry.prepareEffect(
            effectID: effectID, config: AudioUnitConfig(component: Self.delay), sampleRate: 48_000)
        #expect(fired.isEmpty)

        // Config change (stateData identity changes) → the registry releases the
        // old instance BEFORE re-preparing (§4.3 lifecycle matrix).
        let state = try #require(engine.auRegistry.effectState(forEffect: effectID))
        await engine.auRegistry.prepareEffect(
            effectID: effectID,
            config: AudioUnitConfig(component: Self.delay, stateData: state), sampleRate: 48_000)
        #expect(fired == [.effect(effectID: effectID)])

        // Explicit release fires once more; a repeat no-op does not.
        engine.auRegistry.releaseEffect(forEffect: effectID)
        #expect(fired == [.effect(effectID: effectID), .effect(effectID: effectID)])
        engine.auRegistry.releaseEffect(forEffect: effectID)
        #expect(fired.count == 2)
    }

    @Test("tracksDidChange removing the model tracks releases the hosted instances (auto-close path)")
    func modelRemovalDrivesRelease() async throws {
        let engine = AudioEngine()
        var fired: [HostedAUEndpoint] = []
        engine.hostedAUReleased = { fired.append($0) }

        let track = dlsTrack()
        let effectID = UUID()
        await engine.auRegistry.prepare(track: track, sampleRate: 48_000)
        await engine.auRegistry.prepareEffect(
            effectID: effectID, config: AudioUnitConfig(component: Self.delay), sampleRate: 48_000)
        fired.removeAll()

        // No tracks host these instances any more → the sync passes release both
        // (the same path project.new/effect-removal takes).
        engine.tracksDidChange([])
        #expect(Set(fired) == [.instrument(trackID: track.id), .effect(effectID: effectID)])
    }

    // MARK: - 2b. windows survive engine recovery (ZERO callbacks)

    @Test("recoverEngine / watchdogRestart fire ZERO release callbacks — instance identity survives")
    func recoveryFiresNoReleaseCallbacks() async throws {
        let engine = AudioEngine()
        var fired: [HostedAUEndpoint] = []
        engine.hostedAUReleased = { fired.append($0) }

        let track = dlsTrack()
        await engine.auRegistry.prepare(track: track, sampleRate: 48_000)
        let before = try #require(engine.hostedInstrumentAudioUnit(forTrack: track.id))
        fired.removeAll()

        // Recovery restarts players/engine, never the registry (AudioEngine.swift
        // recovery path) — so a live plugin window survives it untouched.
        engine.recoverEngine()
        try? engine.watchdogRestart()
        #expect(fired.isEmpty)
        let after = try #require(engine.hostedInstrumentAudioUnit(forTrack: track.id))
        #expect(after === before)   // same instance, same stamp
        engine.shutdown()
    }
}
