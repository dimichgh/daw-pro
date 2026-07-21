import Foundation
import Testing
@testable import DAWCore

/// m22-f delay tempo sync — the DAWCore half: the `NoteDivision` division→ms
/// math (unit-pinned across tempos, the roadmap gate), `DelayParams`'
/// additive `sync`/`division` semantics, the `DelayTempoSync` control-plane
/// resolver (substitution + idempotency), legacy-decode byte compatibility,
/// and the store's param/automation surfaces.
@MainActor
@Suite("Delay tempo sync — core math, params, persistence")
struct DelayTempoSyncTests {

    // MARK: - Division → ms math (the gate's pinned values)

    @Test("division→ms is unit-pinned across tempos (500/375/333.3 @120; 666.7 @90)")
    func divisionMsMathPinned() {
        // The gate triple at 120 BPM.
        #expect(NoteDivision.quarter.milliseconds(atBPM: 120) == 500)
        #expect(NoteDivision.eighthDotted.milliseconds(atBPM: 120) == 375)
        #expect(abs(NoteDivision.quarterTriplet.milliseconds(atBPM: 120) - 1_000.0 / 3) < 1e-9)
        // A second tempo (90 BPM).
        #expect(abs(NoteDivision.quarter.milliseconds(atBPM: 90) - 2_000.0 / 3) < 1e-9)
        #expect(abs(NoteDivision.eighth.milliseconds(atBPM: 90) - 1_000.0 / 3) < 1e-9)
        #expect(NoteDivision.half.milliseconds(atBPM: 90) == 4_000.0 / 3)
        // Spot values across the size range.
        #expect(NoteDivision.whole.milliseconds(atBPM: 120) == 2_000)
        #expect(NoteDivision.sixteenth.milliseconds(atBPM: 120) == 125)
        #expect(abs(NoteDivision.thirtySecondTriplet.milliseconds(atBPM: 120)
                    - 125.0 / 3) < 1e-9)
        // Degenerate tempo answers NaN honestly (callers guard).
        #expect(NoteDivision.quarter.milliseconds(atBPM: 0).isNaN)
        #expect(NoteDivision.quarter.milliseconds(atBPM: .infinity).isNaN)
    }

    @Test("the 18-division table: beats values, token round-trips, declared order")
    func divisionTable() {
        #expect(NoteDivision.allCases.count == 18)
        let expected: [(NoteDivision, String, Double)] = [
            (.whole, "1/1", 4), (.wholeDotted, "1/1d", 6), (.wholeTriplet, "1/1t", 8.0 / 3),
            (.half, "1/2", 2), (.halfDotted, "1/2d", 3), (.halfTriplet, "1/2t", 4.0 / 3),
            (.quarter, "1/4", 1), (.quarterDotted, "1/4d", 1.5),
            (.quarterTriplet, "1/4t", 2.0 / 3),
            (.eighth, "1/8", 0.5), (.eighthDotted, "1/8d", 0.75),
            (.eighthTriplet, "1/8t", 1.0 / 3),
            (.sixteenth, "1/16", 0.25), (.sixteenthDotted, "1/16d", 0.375),
            (.sixteenthTriplet, "1/16t", 1.0 / 6),
            (.thirtySecond, "1/32", 0.125), (.thirtySecondDotted, "1/32d", 0.1875),
            (.thirtySecondTriplet, "1/32t", 1.0 / 12),
        ]
        #expect(NoteDivision.allCases == expected.map(\.0))  // picker order pinned
        for (division, token, beats) in expected {
            #expect(division.rawValue == token)
            #expect(NoteDivision(rawValue: token) == division)
            #expect(abs(division.beats - beats) < 1e-12, "\(token) beats")
        }
    }

    @Test("nearest(toBeats:) snaps exactly, between neighbors, and on garbage")
    func nearestSnapping() {
        // Exact hits.
        for division in NoteDivision.allCases {
            #expect(NoteDivision.nearest(toBeats: division.beats) == division)
        }
        // Between neighbors: 0.7 is closer to 1/4t (0.667) than 1/8d (0.75).
        #expect(NoteDivision.nearest(toBeats: 0.7) == .quarterTriplet)
        #expect(NoteDivision.nearest(toBeats: 0.72) == .eighthDotted)
        // Clamped ends.
        #expect(NoteDivision.nearest(toBeats: 100) == .wholeDotted)
        #expect(NoteDivision.nearest(toBeats: 0) == .thirtySecondTriplet)
        // Non-finite input falls back to the quarter default, never traps.
        #expect(NoteDivision.nearest(toBeats: .nan) == .quarter)
    }

    // MARK: - DelayParams semantics

    @Test("effectiveTimeMs: unsynced = stored timeMs; synced = division at tempo, clamped")
    func effectiveTimeMsSemantics() {
        // sync absent (legacy) and sync false both free-run on timeMs.
        #expect(DelayParams(timeMs: 350).effectiveTimeMs(atTempoBPM: 120) == 350)
        #expect(DelayParams(timeMs: 350, sync: false).effectiveTimeMs(atTempoBPM: 90) == 350)
        // Synced: division at tempo; division nil resolves to 1/4.
        #expect(DelayParams(timeMs: 350, sync: true).effectiveTimeMs(atTempoBPM: 120) == 500)
        #expect(DelayParams(timeMs: 350, sync: true, division: .eighthDotted)
            .effectiveTimeMs(atTempoBPM: 120) == 375)
        #expect(abs(DelayParams(timeMs: 350, sync: true, division: .quarterTriplet)
            .effectiveTimeMs(atTempoBPM: 120) - 1_000.0 / 3) < 1e-9)
        // Tempo change moves the derived time; timeMs stays stored untouched.
        let synced = DelayParams(timeMs: 350, sync: true, division: .quarter)
        #expect(abs(synced.effectiveTimeMs(atTempoBPM: 90) - 2_000.0 / 3) < 1e-9)
        #expect(synced.timeMs == 350)
        // Clamped to the param range (the delay line is preallocated for 2 s):
        // 1/1d at 30 BPM is 12 000 ms of music — pins at 2 000.
        #expect(DelayParams(sync: true, division: .wholeDotted)
            .effectiveTimeMs(atTempoBPM: 30) == 2_000)
        // A degenerate tempo falls back to the stored time, never NaN.
        #expect(DelayParams(timeMs: 350, sync: true).effectiveTimeMs(atTempoBPM: .nan) == 350)
    }

    // MARK: - The control-plane resolver

    @Test("DelayTempoSync substitutes synced delays only, idempotently, preserving fields")
    func resolverSubstitution() {
        let synced = EffectDescriptor(
            kind: .delay,
            delay: DelayParams(timeMs: 350, sync: true, division: .quarter))
        let freeRunning = EffectDescriptor(kind: .delay, delay: DelayParams(timeMs: 350))
        let eq = EffectDescriptor(kind: .eq)
        var track = Track(name: "Wet", kind: .audio)
        track.effects = [synced, freeRunning, eq]

        let at120 = DelayTempoSync.resolved(tracks: [track], tempoBPM: 120)
        #expect(at120[0].effects[0].delay?.timeMs == 500)
        // sync/division ride along (re-resolution needs them).
        #expect(at120[0].effects[0].delay?.sync == true)
        #expect(at120[0].effects[0].delay?.division == .quarter)
        // The free-running delay and the non-delay are byte-untouched.
        #expect(at120[0].effects[1] == freeRunning)
        #expect(at120[0].effects[2] == eq)

        // IDEMPOTENT recompute: re-resolving the ALREADY-resolved list at a
        // new tempo is exactly the tempo-change recompute.
        let at90 = DelayTempoSync.resolved(tracks: at120, tempoBPM: 90)
        #expect(abs((at90[0].effects[0].delay?.timeMs ?? 0) - 2_000.0 / 3) < 1e-9)
        let back = DelayTempoSync.resolved(tracks: at90, tempoBPM: 120)
        #expect(back[0].effects[0].delay?.timeMs == 500)

        // Nothing synced → the input comes back unchanged (and the detector
        // says so).
        var dry = track
        dry.effects = [freeRunning, eq]
        #expect(!DelayTempoSync.containsSyncedDelay(tracks: [dry]))
        #expect(DelayTempoSync.resolved(tracks: [dry], tempoBPM: 90) == [dry])

        // The master-chain variant behaves identically.
        #expect(DelayTempoSync.containsSyncedDelay(effects: [synced]))
        let master = DelayTempoSync.resolved(effects: [synced, eq], tempoBPM: 90)
        #expect(abs((master[0].delay?.timeMs ?? 0) - 2_000.0 / 3) < 1e-9)
        #expect(master[1] == eq)
    }

    // MARK: - Persistence (additive optional keys)

    @Test("legacy delay JSON decodes to nil sync/division and re-encodes without the keys")
    func legacyDecodeByteCompatible() throws {
        let legacyJSON = Data("""
        {"timeMs":350,"feedback":0.35,"mix":0.3,"pingPong":0,"highCutHz":8000}
        """.utf8)
        let decoded = try JSONDecoder().decode(DelayParams.self, from: legacyJSON)
        #expect(decoded.sync == nil)
        #expect(decoded.division == nil)
        #expect(!decoded.resolvedSync)                 // legacy behavior exactly
        #expect(decoded.resolvedDivision == .quarter)  // resolved default only
        #expect(decoded == DelayParams())              // == a fresh default too

        // Re-encoding OMITS the nil keys (the sidechainSourceTrackID disk
        // rule) — a legacy project never grows new bytes from a round-trip.
        let reEncoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reEncoded.contains("sync"))
        #expect(!reEncoded.contains("division"))
    }

    @Test("synced params round-trip as the token string; unknown tokens decode tolerant")
    func syncedRoundTripAndTolerantDecode() throws {
        let params = DelayParams(timeMs: 350, sync: true, division: .eighthTriplet)
        let data = try JSONEncoder().encode(params)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""division":"1\/8t""#) || json.contains(#""division":"1/8t""#))
        #expect(json.contains(#""sync":true"#))
        let decoded = try JSONDecoder().decode(DelayParams.self, from: data)
        #expect(decoded == params)

        // A FUTURE division token decodes as nil (resolved 1/4) rather than
        // failing the whole project.
        let futureJSON = Data(#"{"timeMs":350,"sync":true,"division":"1/64q"}"#.utf8)
        let tolerant = try JSONDecoder().decode(DelayParams.self, from: futureJSON)
        #expect(tolerant.sync == true)
        #expect(tolerant.division == nil)
        #expect(tolerant.resolvedDivision == .quarter)
    }

    @Test("a full project save/open carries sync + division through the store")
    func projectRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delay-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        let track = store.addTrack(name: "Echo", kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .delay)
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id, name: "sync", value: 1)
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                     name: "division", value: 0.75)
        let path = dir.appendingPathComponent("Sync").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let delay = try #require(
            reopened.tracks.first { $0.name == "Echo" }?.effects.first?.resolvedDelay)
        #expect(delay.resolvedSync)
        #expect(delay.resolvedDivision == .eighthDotted)
        #expect(delay.timeMs == 350)  // the stored fallback never moved
    }

    // MARK: - Store param surface

    @Test("setEffectParam: sync is binary, division snaps to the nearest note value")
    func storeParamPath() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .delay)

        var updated = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                               name: "sync", value: 0.9)
        #expect(updated.resolvedDelay.sync == true)
        updated = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                           name: "division", value: 0.7)
        #expect(updated.resolvedDelay.division == .quarterTriplet)

        // A pingPong write rebuilds through the clamping init — it must
        // CARRY the m22-f fields, never drop them.
        updated = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                           name: "pingPong", value: 1)
        #expect(updated.resolvedDelay.pingPong == 1)
        #expect(updated.resolvedDelay.sync == true)
        #expect(updated.resolvedDelay.division == .quarterTriplet)

        // sync 0 turns it back off; the division choice survives.
        updated = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                           name: "sync", value: 0)
        #expect(updated.resolvedDelay.sync == false)
        #expect(updated.resolvedDelay.division == .quarterTriplet)
    }

    @Test("automation lanes on sync/division are refused (control-plane-only params)")
    func automationRefusesSyncDivision() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .delay)
        for name in ["sync", "division"] {
            #expect(throws: ProjectError.self) {
                try store.addAutomationLane(
                    trackID: track.id,
                    target: .effectParam(effectID: fx.id, paramName: name))
            }
        }
        // The five render-path params stay automatable — the slot indices
        // never moved (spec order 0…4).
        _ = try store.addAutomationLane(
            trackID: track.id, target: .effectParam(effectID: fx.id, paramName: "timeMs"))
        _ = try store.addAutomationLane(
            trackID: track.id, target: .effectParam(effectID: fx.id, paramName: "highCutHz"))
    }
}
