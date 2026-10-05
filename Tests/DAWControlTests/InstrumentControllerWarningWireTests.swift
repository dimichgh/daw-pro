import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m27-b on the wire — `track.setInstrument`'s two additive response fields.
///
///  · `warnings` — PLAIN SENTENCES for the controller lanes whose MEANING
///    changed, emitted ONLY when non-empty (the `remintedZoneIDs` idiom). The
///    element type matches every other `warnings` field on this wire, notably
///    clip.setControllerLane — this feature's complementary half. This is the reported
///    defect's fix: CC11 lanes authored under `polySynth` were inert data, a
///    `.soundBank` made them live, and nothing said so — a finished mix
///    regressed 1.25 LU.
///  · `honoredControllers` — always present, so a caller can learn which
///    controllers an instrument acts on BEFORE authoring lanes.
///
/// ⚠️ The noise half is tested here too, at the wire: a change that moves no
/// authored data must leave the response shape byte-identical to before m27-b.
/// A field that appears on every call is a field nobody reads.
@MainActor
@Suite("track.setInstrument controller warnings (m27-b)")
struct InstrumentControllerWarningWireTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// An instrument track (defaults to polySynth) carrying one MIDI clip.
    private func instrumentTrack(_ router: CommandRouter) async throws -> (String, String) {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func setLane(_ router: CommandRouter, clip: String,
                         controller: Int, values: [Int]) async throws {
        let points = values.enumerated().map { index, value in
            JSONValue.object(["beat": .number(Double(index)), "value": .number(Double(value))])
        }
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clip),
                "type": .string("cc"),
                "controller": .number(Double(controller)),
                "points": .array(points),
            ]))
        #expect(set.ok)
    }

    private func setInstrument(_ router: CommandRouter, track: String,
                               params extra: [String: JSONValue]) async -> ControlResponse {
        var params: [String: JSONValue] = ["trackId": .string(track)]
        for (key, value) in extra { params[key] = value }
        return await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument", params: params))
    }

    // MARK: - The reported defect

    @Test("MUST WARN: CC11 lanes + polySynth → soundBank warns, and names the 127 neutral")
    func warnsWhenExpressionGoesLive() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        try await setLane(router, clip: clipID, controller: 11, values: [106, 42, 110])

        let response = await setInstrument(router, track: trackID, params: [
            "soundBank": .object(["source": .string("gm")]),
        ])
        #expect(response.ok)
        let warnings = try #require(response.result?["warnings"]?.arrayValue,
                                    "no warnings array — the m27-b defect is back")
        #expect(warnings.count == 1)
        let message = try #require(warnings[0].stringValue)
        #expect(message.contains("CC11 (expression)"))
        #expect(message.contains("127"))
        #expect(message.lowercased().contains("attenuat"))

        // ⛔ AND THE DATA IS UNTOUCHED. Silently neutralising a
        // correct-but-newly-live lane would be a worse bug than the one fixed.
        let lane = try #require(store.tracks.first(where: { $0.id.uuidString == trackID })?
            .clips.first?.controllerLanes.first)
        #expect(lane.points.map(\.value) == [106, 42, 110])
    }

    @Test("the warning names the controller and the verb that removes the lane")
    func warningIdentifiesTheLaneActionably() async throws {
        // A sentence a reader can act on without opening source: WHICH lane,
        // and WHAT to call. Same `MIDIControllerRouting.describe` copy that
        // clip.setControllerLane's inert-lane warning uses, so the two halves
        // of this feature cannot call CC11 two different things.
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        try await setLane(router, clip: clipID, controller: 11, values: [90])
        let response = await setInstrument(router, track: trackID, params: [
            "soundBank": .object(["source": .string("gm")]),
        ])
        let warning = try #require(response.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(warning.contains(MIDIControllerRouting.describe(.cc(controller: 11))))
        #expect(warning.contains("clip.removeControllerLane"))
    }

    // MARK: - The noise half

    @Test("MUST NOT WARN: no controller lanes at all — no `warnings` key on the response")
    func silentWithoutLanes() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await instrumentTrack(router)
        let response = await setInstrument(router, track: trackID, params: [
            "soundBank": .object(["source": .string("gm")]),
        ])
        #expect(response.ok)
        #expect(response.result?["warnings"] == nil,
                "an always-present array reads as a field worth checking on every call")
    }

    @Test("MUST NOT WARN: a CC64 lane across polySynth → sampler — both honour it")
    func silentWhenBothHonorTheLane() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        try await setLane(router, clip: clipID, controller: 64, values: [127, 0])
        let response = await setInstrument(router, track: trackID, params: [
            "kind": .string("sampler"),
        ])
        #expect(response.ok)
        #expect(response.result?["warnings"] == nil)
    }

    @Test("MUST NOT WARN: tweaking one envelope value with CC11 lanes present")
    func silentOnUnrelatedParameterEdit() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        _ = await setInstrument(router, track: trackID, params: ["kind": .string("sampler")])
        try await setLane(router, clip: clipID, controller: 11, values: [80])
        let response = await setInstrument(router, track: trackID, params: [
            "sampler": .object(["release": .number(0.4)]),
        ])
        #expect(response.ok)
        #expect(response.result?["warnings"] == nil)
    }

    @Test("MUST WARN within one kind: raising expressionModDepth makes CC2 lanes live")
    func warnsOnSameKindDepthFlip() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        _ = await setInstrument(router, track: trackID, params: ["kind": .string("sampler")])
        try await setLane(router, clip: clipID, controller: 2, values: [30, 100])
        let response = await setInstrument(router, track: trackID, params: [
            "sampler": .object(["expressionModDepth": .number(0.6)]),
        ])
        #expect(response.ok)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.count == 1)
        let message = try #require(warnings[0].stringValue)
        #expect(message.contains("CC2 (breath)"))
        #expect(message.contains("acts on it"))
    }

    @Test("the mirror direction: leaving a soundBank for testTone reports becameInert")
    func warnsWhenDataGoesInert() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await instrumentTrack(router)
        _ = await setInstrument(router, track: trackID, params: [
            "soundBank": .object(["source": .string("gm")]),
        ])
        try await setLane(router, clip: clipID, controller: 11, values: [64])
        let response = await setInstrument(router, track: trackID, params: [
            "kind": .string("testTone"),
        ])
        #expect(response.ok)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.count == 1)
        let message = try #require(warnings[0].stringValue)
        #expect(message.contains("ignores it"))
        #expect(message.contains("untouched"), "the data must be described as intact")
    }

    // MARK: - honoredControllers (ⓑ)

    @Test("honoredControllers is always present and enumerates the built-ins' real sets")
    func honoredControllersEnumerated() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await instrumentTrack(router)

        let poly = await setInstrument(router, track: trackID,
                                       params: ["kind": .string("polySynth")])
        let polySupport = try #require(poly.result?["honoredControllers"])
        #expect(polySupport["all"]?.boolValue == false)
        #expect(polySupport["cc"]?.arrayValue?.compactMap(\.doubleValue) == [64])
        #expect(polySupport["pitchBend"]?.boolValue == true)
        #expect(polySupport["channelPressure"]?.boolValue == false)

        let sampler = await setInstrument(router, track: trackID,
                                          params: ["kind": .string("sampler")])
        let samplerSupport = try #require(sampler.result?["honoredControllers"])
        #expect(samplerSupport["cc"]?.arrayValue?.compactMap(\.doubleValue) == [11, 64])

        let tone = await setInstrument(router, track: trackID,
                                       params: ["kind": .string("testTone")])
        let toneSupport = try #require(tone.result?["honoredControllers"])
        #expect(toneSupport["cc"]?.arrayValue?.isEmpty == true)
        #expect(toneSupport["pitchBend"]?.boolValue == false)
    }

    @Test("honoredControllers reports `all` for a hosted sound bank, with no cc list")
    func honoredControllersAllForHostedKinds() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await instrumentTrack(router)
        let response = await setInstrument(router, track: trackID, params: [
            "soundBank": .object(["source": .string("gm")]),
        ])
        let support = try #require(response.result?["honoredControllers"])
        #expect(support["all"]?.boolValue == true)
        #expect(support["cc"]?.arrayValue?.isEmpty == true)
        #expect(support["channelPressure"]?.boolValue == true)
    }

    @Test("neutralDefaults teaches the three non-zero rests — CC11 127, CC7 100, CC10 64")
    func neutralDefaultsOnTheWire() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await instrumentTrack(router)
        let response = await setInstrument(router, track: trackID,
                                           params: ["kind": .string("polySynth")])
        let neutral = try #require(response.result?["honoredControllers"]?["neutralDefaults"])
        // ⚠️ CC7 is 100, NOT 127 — the roadmap sentence said otherwise.
        #expect(neutral["11"]?.doubleValue == 127)
        #expect(neutral["7"]?.doubleValue == 100)
        #expect(neutral["10"]?.doubleValue == 64)
        #expect(neutral["1"]?.doubleValue == 0)
        #expect(neutral["64"]?.doubleValue == 0)
    }

    @Test("project.snapshot carries honoredControllers too — readable without mutating")
    func snapshotCarriesHonoredControllers() async throws {
        // The "know BEFORE you author lanes" path: a caller reads the track's
        // instrument rather than having to set one to find out.
        let (router, _) = makeRouter()
        let (trackID, _) = try await instrumentTrack(router)
        _ = await setInstrument(router, track: trackID, params: ["kind": .string("sampler")])

        let snapshot = await router.handle(ControlRequest(
            id: "s", command: "project.snapshot", params: [:]))
        #expect(snapshot.ok)
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID }))
        let support = try #require(track["instrument"]?["honoredControllers"])
        #expect(support["cc"]?.arrayValue?.compactMap(\.doubleValue) == [11, 64])
    }
}
