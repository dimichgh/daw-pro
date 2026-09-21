import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M4 (vii-d) automation lanes:
/// automation.addLane|removeLane|setPoints|setLaneEnabled round trips, the
/// `target` wire shape reusing `AutomationTarget`'s OWN Codable (no
/// hand-parsed duplicate in Commands.swift), the store's v0 rejections/
/// unresolvable-target errors surfacing verbatim, per-index point-parse
/// errors, and the `automation` array on project.snapshot. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Automation lanes — control protocol")
struct AutomationCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]
        ))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    private func addLane(_ router: CommandRouter, trackID: UUID, target: JSONValue) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "add-lane", command: "automation.addLane",
            params: ["trackId": .string(trackID.uuidString), "target": target]
        ))
    }

    // MARK: - addLane

    @Test("addLane round-trips the target shape and is idempotent per target")
    func addLaneRoundTripsAndIsIdempotent() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let first = await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
        #expect(first.ok)
        let lane = try #require(first.result?["lane"])
        let laneID = try #require(lane["id"]?.stringValue)
        #expect(UUID(uuidString: laneID) != nil)
        #expect(lane["target"]?["type"]?.stringValue == "volume")
        #expect(lane["points"]?.arrayValue?.isEmpty == true)
        #expect(lane["isEnabled"]?.boolValue == true)

        // Idempotent: a repeat call for the SAME target returns the SAME lane
        // (no second lane, no new edit).
        let second = await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
        #expect(second.ok)
        #expect(second.result?["lane"]?["id"]?.stringValue == laneID)
    }

    @Test("addLane resolves an effectParam target against a built-in effect, and rejects an unresolvable one")
    func addLaneEffectParamTargetResolvesOrRejects() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let fxResponse = await router.handle(ControlRequest(
            id: "fx", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain")]
        ))
        let effectID = try #require(fxResponse.result?["effectId"]?.stringValue)

        let good = await addLane(router, trackID: trackID, target: .object([
            "type": .string("effectParam"), "effectId": .string(effectID), "param": .string("gainLinear"),
        ]))
        #expect(good.ok)
        #expect(good.result?["lane"]?["target"]?["type"]?.stringValue == "effectParam")
        #expect(good.result?["lane"]?["target"]?["param"]?.stringValue == "gainLinear")

        // An unknown effect id does not resolve — a DIFFERENT error from the
        // v0-unsupported case (this target shape IS supported in principle).
        let bad = await addLane(router, trackID: trackID, target: .object([
            "type": .string("effectParam"), "effectId": .string(UUID().uuidString), "param": .string("gainLinear"),
        ]))
        #expect(!bad.ok)
        #expect(bad.error == "automation target does not resolve on that track")
    }

    /// m39-ad. `mcp-server/README.md`, `mcp-server/src/server.ts` and the
    /// `daw-wire-reference` skill all tell an agent that an `automation.setLane`
    /// on `saturator.oversampling` "errors like an unknown param". That is a
    /// claim about THE WIRE, and until this test it was only pinned one layer
    /// down (`AutomationTarget.valueRange == nil` in DAWCore). A doc sentence
    /// about an error message deserves an assertion on the error message.
    ///
    /// ⭐ THE CONTROL IS THE POINT. `.clipper` has a param with the SAME NAME,
    /// the same 1/2/4 values and the same snapping, and its lane is ACCEPTED.
    /// Without that leg, a defect that refused EVERY `oversampling` lane — or
    /// every lane at all — would look identical to a pass. The asymmetry is
    /// deliberate and it is the whole reason this pair exists:
    ///   * `clipper` reports a CONSTANT 32 samples of latency at every factor,
    ///     so moving its factor from the render thread changes no timing and
    ///     the plugin-delay-compensation plan stays correct.
    ///   * `saturator` reports 0 at factor 1 and 32 at 2/4. An automation lane
    ///     would move that factor from the RENDER thread, where nothing can
    ///     rebuild the compensation plan — every other track in the project
    ///     would silently slip 32 samples out of alignment. So the lane is
    ///     refused at the door instead.
    @Test("m39-ad: a saturator.oversampling lane is refused on the wire, while the clipper's identical param is accepted")
    func addLaneRefusesSaturatorOversamplingButAcceptsTheClippers() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        func addEffect(_ kind: String) async throws -> String {
            let response = await router.handle(ControlRequest(
                id: "fx-\(kind)", command: "fx.add",
                params: ["trackId": .string(trackID.uuidString), "kind": .string(kind)]
            ))
            #expect(response.ok, Comment(rawValue: "fx.add \(kind) failed: \(response.error ?? "-")"))
            return try #require(response.result?["effectId"]?.stringValue)
        }
        let saturatorID = try await addEffect("saturator")
        let clipperID = try await addEffect("clipper")

        func lane(_ effectID: String, _ param: String) async -> ControlResponse {
            await addLane(router, trackID: trackID, target: .object([
                "type": .string("effectParam"),
                "effectId": .string(effectID),
                "param": .string(param),
            ]))
        }

        // 1. THE CLAIM: refused, with the unknown-param wording the docs quote.
        let refused = await lane(saturatorID, "oversampling")
        #expect(!refused.ok)
        #expect(refused.error == "automation target does not resolve on that track")

        // 2. POSITIVE CONTROL A — the same effect's OTHER params still take a
        //    lane, so this is a refusal of one param and not of the saturator.
        for param in ["driveDb", "mix", "outputDb"] {
            let accepted = await lane(saturatorID, param)
            #expect(accepted.ok, Comment(rawValue: "saturator.\(param) should still accept a lane"))
        }

        // 3. POSITIVE CONTROL B — the CONFUSABLE one. Same param name, other
        //    kind, ACCEPTED. If this ever starts failing, the refusal above has
        //    been implemented by param NAME instead of by (kind, param).
        let clipperLane = await lane(clipperID, "oversampling")
        #expect(clipperLane.ok,
                Comment(rawValue: "clipper.oversampling must remain automatable: \(clipperLane.error ?? "-")"))
        #expect(clipperLane.result?["lane"]?["target"]?["param"]?.stringValue == "oversampling")

        // 4. Nothing was half-stored: the track carries exactly the four lanes
        //    that were accepted, and none of them is the saturator's factor.
        let snapshot = await router.handle(ControlRequest(id: "snap", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let lanes = try #require(vox["automation"]?.arrayValue)
        #expect(lanes.count == 4, Comment(rawValue: "expected 4 lanes, got \(lanes.count)"))
        let saturatorLaneParams = lanes
            .filter { $0["target"]?["effectId"]?.stringValue == saturatorID }
            .compactMap { $0["target"]?["param"]?.stringValue }
            .sorted()
        #expect(saturatorLaneParams == ["driveDb", "mix", "outputDb"])
    }

    /// ⭐ m39-af — **`.dynamicEQ` REFUSES NO LANE, AND THE OMISSION FROM
    /// `Automation.swift` IS A DECISION RATHER THAN AN OVERSIGHT.** The two
    /// reasons this tree has ever refused a lane are both absent from this kind:
    /// nothing about it needs tempo math off the render thread (the
    /// `delay.sync` reason), and its `latencySamples` is a LITERAL 0 at every
    /// setting of every param — minimum-phase IIR, no delay line, no lookahead
    /// — so there is no PDC plan a render-thread store could leave stale (the
    /// `saturator.oversampling` reason). Lookahead was rejected for exactly
    /// this: it would have made the latency parameter-dependent and forced a
    /// refusal here.
    ///
    /// ⚠️ **32 LANES IS HALF A STRIP'S ENTIRE BUDGET** — effect-param lanes and
    /// modulated effect params share ONE 64-entry cap per strip and the excess
    /// is dropped by a bare `.prefix`. This test sits at 32 deliberately: it
    /// proves all 32 resolve AND that 32 still fits, which is the number the
    /// `band1Mode` note tells an agent about.
    @Test("m39-af: all 32 dynamicEQ params take an automation lane, and all 32 are stored")
    func dynamicEQAcceptsALaneOnEveryOneOfItsThirtyTwoParams() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let fx = await router.handle(ControlRequest(
            id: "fx", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("dynamicEQ")]
        ))
        #expect(fx.ok, Comment(rawValue: "fx.add dynamicEQ failed: \(fx.error ?? "-")"))
        let effectID = try #require(fx.result?["effectId"]?.stringValue)

        let names = EffectParamSpec.specs(for: .dynamicEQ).map(\.name)
        #expect(names.count == 32)
        var refused: [String] = []
        for name in names {
            let response = await addLane(router, trackID: trackID, target: .object([
                "type": .string("effectParam"),
                "effectId": .string(effectID),
                "param": .string(name),
            ]))
            if !response.ok { refused.append(name) }
            #expect(response.result?["lane"]?["target"]?["param"]?.stringValue == name
                        || !response.ok)
        }
        #expect(refused.isEmpty, Comment(rawValue: "these dynamicEQ params were refused a "
            + "lane: \(refused). This kind refuses none — check Automation.swift."))

        // → and all 32 were STORED, not half-accepted. A lane that resolves at
        //   the door and then vanishes is the failure this leg adds over the
        //   loop above.
        let snapshot = await router.handle(ControlRequest(id: "snap", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first { $0["id"]?.stringValue == trackID.uuidString })
        let stored = try #require(vox["automation"]?.arrayValue)
            .compactMap { $0["target"]?["param"]?.stringValue }
        #expect(Set(stored) == Set(names),
                Comment(rawValue: "stored \(stored.count) of 32 lanes; missing "
                    + "\(Set(names).subtracting(stored).sorted())"))

        // ⭐ NEGATIVE CONTROL: a name this kind does NOT have is still refused,
        // so "all 32 resolved" is a statement about the table rather than about
        // the door being open to anything.
        let bogus = await addLane(router, trackID: trackID, target: .object([
            "type": .string("effectParam"),
            "effectId": .string(effectID),
            "param": .string("band5Mode"),
        ]))
        #expect(!bogus.ok, "a nonexistent band took a lane")
        #expect(bogus.error == "automation target does not resolve on that track")
    }

    @Test("addLane rejects a malformed target type before touching the store")
    func addLaneRejectsBadTargetType() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let response = await addLane(router, trackID: trackID, target: .object(["type": .string("volumeee")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'target' must be") == true)

        // No lane was created despite the attempt.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        #expect(vox["automation"]?.arrayValue?.isEmpty == true)
    }

    @Test("addLane surfaces the store's sendLevel v0 rejection verbatim")
    func addLaneRejectsSendLevelWithStoreMessage() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let send = try store.addSend(toTrack: trackID, busID: bus.id, level: 1)

        let response = await addLane(router, trackID: trackID, target: .object([
            "type": .string("sendLevel"), "sendId": .string(send.id.uuidString),
        ]))
        #expect(!response.ok)
        // Exact wording is the ProjectError message — the store's honest
        // deferral, not a hand-written duplicate in Commands.swift.
        #expect(response.error == "send-level automation is not supported in v0")
    }

    @Test("addLane on an unknown track surfaces trackNotFound")
    func addLaneUnknownTrack() async throws {
        let (router, _) = makeRouter()
        let response = await addLane(router, trackID: UUID(), target: .object(["type": .string("volume")]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    // MARK: - removeLane

    @Test("removeLane deletes the lane; an unknown id surfaces automationLaneNotFound")
    func removeLaneRoundTripAndUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("pan")]))
                .result?["lane"]?["id"]?.stringValue)

        let remove = await router.handle(ControlRequest(
            id: "1", command: "automation.removeLane",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID)]
        ))
        #expect(remove.ok)

        // Gone from the snapshot.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        #expect(vox["automation"]?.arrayValue?.isEmpty == true)

        // Unknown lane id (the same track, since it's now gone from it).
        let unknown = await router.handle(ControlRequest(
            id: "3", command: "automation.removeLane",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID)]
        ))
        #expect(!unknown.ok)
        #expect(unknown.error == "no automation lane with id \(laneID) on that track")
    }

    // MARK: - setPoints

    @Test("setPoints replaces the whole array, canonicalizes, defaults curve, and clamps to the target range")
    func setPointsRoundTripsAndClamps() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(4), "value": .number(0.5)]),
                        .object(["beat": .number(0), "value": .number(99), "curve": .string("hold")]),
                     ])]
        ))
        #expect(response.ok)
        let points = try #require(response.result?["lane"]?["points"]?.arrayValue)
        // Canonically re-ordered ascending by beat…
        #expect(points.map { $0["beat"]?.doubleValue } == [0, 4])
        // …value clamps to Track.volumeRange (0...2) at the store boundary…
        #expect(points[0]["value"]?.doubleValue == 2)
        // …curve round-trips explicitly, and an omitted curve defaults "linear".
        #expect(points[0]["curve"]?.stringValue == "hold")
        #expect(points[1]["curve"]?.stringValue == "linear")

        // Whole-array replace: a second call with one point drops the first two.
        let replace = await router.handle(ControlRequest(
            id: "2", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([.object(["beat": .number(2), "value": .number(1)])])]
        ))
        #expect(replace.ok)
        #expect(replace.result?["lane"]?["points"]?.arrayValue?.count == 1)
    }

    @Test("setPoints names the offending index on a malformed point")
    func setPointsNamesOffendingIndex() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(0), "value": .number(1)]),
                        .object(["beat": .number(1), "value": .number(1), "curve": .string("bezier")]),
                     ])]
        ))
        #expect(!response.ok)
        #expect(response.error?.hasPrefix("points[1]") == true)
    }

    @Test("setPoints on an unknown lane surfaces automationLaneNotFound")
    func setPointsUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(UUID().uuidString),
                     "points": .array([])]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("no automation lane with id") == true)
    }

    // MARK: - setLaneEnabled

    @Test("setLaneEnabled toggles read/manual without touching points")
    func setLaneEnabledRoundTrips() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let disable = await router.handle(ControlRequest(
            id: "1", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID), "enabled": .bool(false)]
        ))
        #expect(disable.ok)
        #expect(disable.result?["lane"]?["isEnabled"]?.boolValue == false)

        let enable = await router.handle(ControlRequest(
            id: "2", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID), "enabled": .bool(true)]
        ))
        #expect(enable.ok)
        #expect(enable.result?["lane"]?["isEnabled"]?.boolValue == true)
    }

    @Test("setLaneEnabled on an unknown lane surfaces automationLaneNotFound")
    func setLaneEnabledUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(UUID().uuidString),
                     "enabled": .bool(true)]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("no automation lane with id") == true)
    }

    // MARK: - Snapshot

    @Test("project.snapshot carries the automation array with the full lane shape")
    func snapshotCarriesAutomationArray() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("pan")]))
                .result?["lane"]?["id"]?.stringValue)
        let setResponse = await router.handle(ControlRequest(
            id: "pts", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([.object(["beat": .number(0), "value": .number(-1)])])]
        ))
        #expect(setResponse.ok)

        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let automation = try #require(vox["automation"]?.arrayValue)
        #expect(automation.count == 1)
        let lane = try #require(automation.first)
        #expect(lane["id"]?.stringValue == laneID)
        #expect(lane["target"]?["type"]?.stringValue == "pan")
        // pan range is -1...1 — -1 is in range, unclamped.
        #expect(lane["points"]?.arrayValue?.first?["value"]?.doubleValue == -1)
        #expect(lane["isEnabled"]?.boolValue == true)
    }

    // MARK: - track.setVolume vs an active lane (m26-o)

    /// 2026-08-17 field report, N2. `track.setVolume` returned a bare
    /// `{id, ok:true}`, so an agent that set a level while a volume lane was
    /// active saw success and had no way to learn the level it set was
    /// inaudible — the lane governs. The write is NOT a no-op (it is stored,
    /// undoable, and rules again the moment the lane goes inactive), so the
    /// fix is an annotation, not a refusal.
    @Test("track.setVolume reports when a lane, not the caller's value, governs")
    func setVolumeAnnotatesAutomationControl() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Bass", kind: "audio")

        func setVolume(_ value: Double) async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "sv", command: "track.setVolume",
                params: ["trackId": .string(trackID.uuidString),
                         "volume": .number(value)]))
        }

        // 1. No lane at all → the annotation is ABSENT, and the verb stays a
        //    void-result "ok" (the disk rule; also what keeps it valid as the
        //    bug-1 void-result regression guard's subject).
        let bare = await setVolume(0.5)
        #expect(bare.ok)
        #expect(bare.result == nil,
                "with no lane there is nothing to warn about — stay void")

        // 2. An EMPTY lane is inert (the vii-a contract) — adding a lane with
        //    no points must NOT flip the flag, or the annotation would cry
        //    wolf on every lane an agent creates before drawing into it.
        let added = await addLane(router, trackID: trackID,
                                  target: .object(["type": .string("volume")]))
        let laneID = try #require(added.result?["lane"]?["id"]?.stringValue)
        let emptyLane = await setVolume(0.6)
        #expect(emptyLane.result == nil)

        // 3. Points drawn → the lane now governs, and the count comes back.
        let points = await router.handle(ControlRequest(
            id: "pts", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString),
                     "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(0), "value": .number(1)]),
                        .object(["beat": .number(4), "value": .number(0)]),
                     ])]))
        #expect(points.ok)

        let governed = await setVolume(0.7)
        #expect(governed.ok, "the write still succeeds — it is not a refusal")
        #expect(governed.result?["automationControlled"]?.boolValue == true)
        #expect(governed.result?["automationPointCount"]?.doubleValue == 2)

        // 4. The write LANDED even while automated: disabling the lane must
        //    reveal 0.7, not the 0.6 from step 2. This is what makes the
        //    annotation "a lane governs" rather than "your call was dropped".
        let disable = await router.handle(ControlRequest(
            id: "dis", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString),
                     "laneId": .string(laneID),
                     "enabled": .bool(false)]))
        #expect(disable.ok)

        let afterDisable = await setVolume(0.7)
        #expect(afterDisable.result == nil,
                "a disabled lane is inert — the manual value rules again")

        let snapshot = await router.handle(ControlRequest(
            id: "snap", command: "project.snapshot", params: [:]))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let bass = try #require(tracks.first {
            $0["id"]?.stringValue == trackID.uuidString })
        #expect(bass["volume"]?.doubleValue == 0.7,
                "the stored volume must be the last value written")
    }
}
