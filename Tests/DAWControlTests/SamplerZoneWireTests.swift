import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m19-b wire ride-along: the ten per-zone playback-scalar keys on
/// `track.setInstrument`'s sampler object (tuneCents/pan/ampVelTrack/oneShot/
/// startFrame/endFrame/attack/decay/sustain/release) — set → readback,
/// non-nil-only emission (the A-imp-1 idiom), field-path error shapes, and
/// the A5 zone-gain relax to 2.0. Reuses `FakeMedia` from ControlTests.swift
/// (same target; readability always passes).
@MainActor
@Suite("Sampler zone playback scalars — control protocol (m19-b)")
struct SamplerZoneWireTests {
    private static let pingPath = "/System/Library/Sounds/Ping.aiff"

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("the ten m19-b zone keys round-trip through set → echo → snapshot")
    func playbackScalarsRoundTrip() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.pingPath),
                            "gain": .number(2.0),            // A5: +6 dB is now legal
                            "tuneCents": .number(-150),
                            "pan": .number(0.5),
                            "ampVelTrack": .number(0.25),
                            "oneShot": .bool(true),
                            "startFrame": .number(100),
                            "endFrame": .number(2_000),
                            "attack": .number(0.01),
                            "decay": .number(0.5),
                            "sustain": .number(0.6),
                            "release": .number(0.2),
                        ]),
                    ]),
                ]),
            ]
        ))
        #expect(response.ok)
        let zone = try #require(response.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(zone["gain"]?.doubleValue == 2.0)
        #expect(zone["tuneCents"]?.doubleValue == -150)
        #expect(zone["pan"]?.doubleValue == 0.5)
        #expect(zone["ampVelTrack"]?.doubleValue == 0.25)
        #expect(zone["oneShot"]?.boolValue == true)
        #expect(zone["startFrame"]?.doubleValue == 100)
        #expect(zone["endFrame"]?.doubleValue == 2_000)
        #expect(zone["attack"]?.doubleValue == 0.01)
        #expect(zone["decay"]?.doubleValue == 0.5)
        #expect(zone["sustain"]?.doubleValue == 0.6)
        #expect(zone["release"]?.doubleValue == 0.2)

        // The live model stored the same values (the wire → model contract).
        let stored = try #require(store.tracks[0].instrument?.sampler?.zones.first)
        #expect(stored.gain == 2.0)
        #expect(stored.tuneCents == -150)
        #expect(stored.pan == 0.5)
        #expect(stored.ampVelTrack == 0.25)
        #expect(stored.oneShot == true)
        #expect(stored.startFrame == 100)
        #expect(stored.endFrame == 2_000)
        #expect(stored.attack == 0.01)
        #expect(stored.decay == 0.5)
        #expect(stored.sustain == 0.6)
        #expect(stored.release == 0.2)

        // project.snapshot reads the same keys back.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snapshot.ok)
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let snapZone = try #require(
            tracks[0]["instrument"]?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(snapZone["tuneCents"]?.doubleValue == -150)
        #expect(snapZone["pan"]?.doubleValue == 0.5)
        #expect(snapZone["ampVelTrack"]?.doubleValue == 0.25)
        #expect(snapZone["oneShot"]?.boolValue == true)
        #expect(snapZone["startFrame"]?.doubleValue == 100)
        #expect(snapZone["endFrame"]?.doubleValue == 2_000)
        #expect(snapZone["attack"]?.doubleValue == 0.01)
        #expect(snapZone["decay"]?.doubleValue == 0.5)
        #expect(snapZone["sustain"]?.doubleValue == 0.6)
        #expect(snapZone["release"]?.doubleValue == 0.2)
    }

    @Test("a legacy zone emits NONE of the ten m19-b keys — wire shape stays byte-identical")
    func legacyZoneOmitsNewKeys() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([.object(["path": .string(Self.pingPath)])]),
                ]),
            ]
        ))
        #expect(response.ok)
        let zone = try #require(response.result?["sampler"]?["zones"]?.arrayValue?.first)
        for key in ["tuneCents", "pan", "ampVelTrack", "oneShot", "startFrame",
                    "endFrame", "attack", "decay", "sustain", "release",
                    "loopMode", "loopStart", "loopEnd"] {         // + m20-g
            #expect(zone[key] == nil, "legacy zone must not emit '\(key)'")
        }
    }

    // m20-g: the three loop keys ride the same wire idiom.
    @Test("the m20-g loop fields round-trip set → echo → model; bad loopMode gets the teaching error")
    func loopFieldsRoundTrip() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.pingPath),
                            "loopMode": .string("sustain"),
                            "loopStart": .number(4_410),
                            "loopEnd": .number(48_510),
                        ]),
                    ]),
                ]),
            ]
        ))
        #expect(response.ok)
        let zone = try #require(response.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(zone["loopMode"]?.stringValue == "sustain")
        #expect(zone["loopStart"]?.doubleValue == 4_410)
        #expect(zone["loopEnd"]?.doubleValue == 48_510)
        let stored = try #require(store.tracks[0].instrument?.sampler?.zones.first)
        #expect(stored.loopMode == .sustain)
        #expect(stored.loopStart == 4_410)
        #expect(stored.loopEnd == 48_510)

        // Teaching error: anything but "sustain"/"continuous" refuses with
        // the exact field-path message; nothing lands.
        let bad = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "sampler": .object([
                    "zones": .array([
                        .object(["path": .string(Self.pingPath),
                                 "loopMode": .string("bidirectional")]),
                    ]),
                ]),
            ]
        ))
        #expect(bad.error == "sampler.zones[0].loopMode must be \"sustain\" or \"continuous\"")
        #expect(store.tracks[0].instrument?.sampler?.zones.first?.loopMode == .sustain)

        // Clamp through the model init: loopEnd ≤ loopStart raises (never swaps).
        let clamped = await router.handle(ControlRequest(
            id: "3", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "sampler": .object([
                    "zones": .array([
                        .object(["path": .string(Self.pingPath),
                                 "loopMode": .string("continuous"),
                                 "loopStart": .number(1_000),
                                 "loopEnd": .number(500)]),
                    ]),
                ]),
            ]
        ))
        #expect(clamped.ok)
        let clampedZone = try #require(
            clamped.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(clampedZone["loopMode"]?.stringValue == "continuous")
        #expect(clampedZone["loopStart"]?.doubleValue == 1_000)
        #expect(clampedZone["loopEnd"]?.doubleValue == 1_001)   // raised, not swapped
    }

    @Test("malformed m19-b zone fields report field-path errors and land nothing")
    func playbackScalarFieldErrors() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        func set(_ zone: [String: JSONValue]) async -> ControlResponse {
            var full = zone
            full["path"] = .string(Self.pingPath)
            return await router.handle(ControlRequest(
                id: "x", command: "track.setInstrument",
                params: ["trackId": .string(instID),
                         "sampler": .object(["zones": .array([.object(full)])])]))
        }

        let badTune = await set(["tuneCents": .string("down a bit")])
        #expect(badTune.error == "sampler.zones[0].tuneCents must be a number")

        let badOneShot = await set(["oneShot": .number(1)])
        #expect(badOneShot.error == "sampler.zones[0].oneShot must be a boolean")

        let badStart = await set(["startFrame": .number(1.5)])
        #expect(badStart.error == "sampler.zones[0].startFrame must be an integer")

        let badEnd = await set(["endFrame": .string("no")])
        #expect(badEnd.error == "sampler.zones[0].endFrame must be an integer")

        let badSustain = await set(["sustain": .bool(true)])
        #expect(badSustain.error == "sampler.zones[0].sustain must be a number")

        #expect(store.tracks[0].instrument == nil)  // nothing landed
    }

    @Test("wire values clamp through the model init: gain caps at 2, endFrame raises above startFrame")
    func wireValuesClampThroughModel() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.pingPath),
                            "gain": .number(5),              // → 2 (A5 ceiling)
                            "tuneCents": .number(99_999),    // → 4800
                            "pan": .number(-7),              // → −1
                            "startFrame": .number(10),
                            "endFrame": .number(3),          // → 11 (raised, not swapped)
                            "decay": .number(0),             // present-0 stays legal
                        ]),
                    ]),
                ]),
            ]
        ))
        #expect(response.ok)
        let zone = try #require(response.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(zone["gain"]?.doubleValue == 2)
        #expect(zone["tuneCents"]?.doubleValue == 4_800)
        #expect(zone["pan"]?.doubleValue == -1)
        #expect(zone["startFrame"]?.doubleValue == 10)
        #expect(zone["endFrame"]?.doubleValue == 11)
        #expect(zone["decay"]?.doubleValue == 0)
        #expect(store.tracks[0].instrument?.sampler?.zones.first?.endFrame == 11)
    }
}
