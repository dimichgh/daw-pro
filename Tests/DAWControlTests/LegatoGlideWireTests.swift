import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m34-t wire surface: the new `legato` voice mode and the `glideTime` global,
/// both inside `track.setInstrument`'s `sampler` object, plus what
/// `instrument.describeSampler` reads back about them.
///
/// The contract this pins, in one sentence: `legato` is accepted alongside
/// `poly`/`mono` and an unknown mode is still REFUSED with a message that lists
/// the legal set, an out-of-range `glideTime` is REFUSED rather than clamped
/// (the `bendRangeSemitones` rule — an agent that asked for 30 s and silently
/// got 4 has no way to find out), an omitted value keeps whatever the track
/// already had, and an UNSET `glideTime` emits no key at all so a project that
/// never touched this feature keeps its pre-m34-t wire shape byte-for-byte.
///
/// ⭐ AND ONE THING NEITHER m34-q NOR m34-s NEEDED: `glideEffective`. A glide
/// set on a POLY sampler is silently inert, which is this tree's characteristic
/// failure shape (the record says X, the sound says Y, and nothing compares
/// them). `describeSampler` publishes the COMPARISON, and a warning names it in
/// prose — both are pinned below.
///
/// Reuses `FakeMedia` from ControlTests.swift (same target).
///
/// ⚠️ AN EXTENSION ON `CommandRouterTests`, NOT A NEW `@Suite` — deliberate,
/// and for the reason `PedalHoldLimitWireTests` states at length:
/// `MainActorOccupancySiteTests` Leg C caps `@MainActor`-isolated suites at 375
/// and the tree sits exactly there. Helpers carry a `glide` prefix so they
/// cannot collide with the suite's own.
private let glidePingPath = "/System/Library/Sounds/Ping.aiff"

extension CommandRouterTests {
    private func glideMakeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func glideInstrumentObject(_ response: ControlResponse) throws
        -> [String: JSONValue] {
        let result = try #require(response.result)
        guard case .object(let root) = result else {
            Issue.record("response result was not an object"); throw ControlError("shape")
        }
        return root
    }

    private func glideNested(_ instrument: [String: JSONValue], _ key: String) throws
        -> [String: JSONValue] {
        guard case .object(let obj)? = instrument[key] else {
            Issue.record("instrument carried no \(key) object"); throw ControlError("shape")
        }
        return obj
    }

    /// Builds a sampler track carrying one zone plus whatever globals are given.
    @discardableResult
    private func glideSetSampler(_ router: CommandRouter, _ trackID: String,
                                 _ globals: [String: JSONValue],
                                 id: String = "1") async -> ControlResponse {
        var sampler: [String: JSONValue] = [
            "zones": .array([.object(["path": .string(glidePingPath)])]),
        ]
        for (key, value) in globals { sampler[key] = value }
        return await router.handle(ControlRequest(
            id: id, command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(sampler)]))
    }

    // MARK: - The new voice mode

    @Test("m34-t wire: voiceMode 'legato' is accepted, stored, and echoed back")
    func glideLegatoVoiceModeRoundTrips() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await glideSetSampler(router, trackID,
                                             ["voiceMode": .string("legato")])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.tracks[0].instrument?.sampler?.voiceMode == .legato)
        let sampler = try glideNested(try glideInstrumentObject(response), "sampler")
        #expect(sampler["voiceMode"]?.stringValue == "legato")
    }

    /// The refusal must still happen, and it must now NAME legato — an agent
    /// told only "poly or mono" cannot discover the mode that does what it
    /// asked for. The message is derived from the enum, so this also pins that
    /// derivation rather than a re-typed literal.
    @Test("m34-t wire: an unknown voiceMode is still REFUSED, and the message lists all three")
    func glideUnknownVoiceModeIsRefusedAndNamesLegato() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await glideSetSampler(router, trackID,
                                             ["voiceMode": .string("portamento")])
        #expect(!response.ok, "an unrecognised voice mode must be refused, not silently ignored")
        let message = response.error ?? ""
        print("[measured] unknown voiceMode refusal: \(message)")
        #expect(message.contains("poly"))
        #expect(message.contains("mono"))
        #expect(message.contains("legato"),
                "the refusal does not name the mode that actually slurs: \(message)")
        #expect(store.tracks[0].instrument?.sampler == nil,
                "a refused call must not have half-applied")
    }

    // MARK: - glideTime

    @Test("m34-t wire: a glideTime is accepted, stored, and echoed back")
    func glideTimeRoundTrips() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await glideSetSampler(
            router, trackID,
            ["voiceMode": .string("legato"), "glideTime": .number(0.35)])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.tracks[0].instrument?.sampler?.glideTime == 0.35)
        let sampler = try glideNested(try glideInstrumentObject(response), "sampler")
        #expect(sampler["glideTime"]?.doubleValue == 0.35)
    }

    @Test("m34-t wire: an omitted glideTime keeps the one the track already had")
    func glideOmittedGlideTimeKeepsTheCurrentOne() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        await glideSetSampler(router, trackID,
                              ["voiceMode": .string("legato"), "glideTime": .number(0.25)])
        #expect(store.tracks[0].instrument?.sampler?.glideTime == 0.25)

        // A one-knob partial edit that says nothing about the glide.
        let tweak = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "sampler": .object(["release": .number(0.4)])]))
        #expect(tweak.ok)
        #expect(store.tracks[0].instrument?.sampler?.glideTime == 0.25,
                "a partial edit must not silently drop the glide")
        #expect(store.tracks[0].instrument?.sampler?.voiceMode == .legato,
                "a partial edit must not silently drop the voice mode either")
        #expect(store.tracks[0].instrument?.sampler?.release == 0.4,
                "control: the edit that WAS sent landed")
    }

    @Test("m34-t wire: an unset glideTime emits no key — the pre-m34-t wire shape is unchanged")
    func glideUnsetGlideTimeEmitsNoKey() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await glideSetSampler(router, trackID, [:])
        #expect(response.ok, "\(response.error ?? "")")
        let sampler = try glideNested(try glideInstrumentObject(response), "sampler")
        #expect(sampler["glideTime"] == nil,
                "a sampler that never set a glide grew a key: \(sampler.keys.sorted())")
        // Positive control: the same shape WITH a glide does carry the key, so
        // "absent" above is a fact about the default and not about the reader.
        let set = try glideNested(
            try glideInstrumentObject(
                await glideSetSampler(router, trackID, ["glideTime": .number(0.2)], id: "2")),
            "sampler")
        #expect(set["glideTime"]?.doubleValue == 0.2, "control failed: a SET glide is not echoed")
    }

    @Test("m34-t wire: an out-of-range or non-numeric glideTime is REFUSED, not clamped")
    func glideTimeRefusesBadValues() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        for bad in [JSONValue.number(-1), .number(30), .string("fast"), .bool(true)] {
            let response = await glideSetSampler(router, trackID, ["glideTime": bad])
            #expect(!response.ok, "glideTime \(bad) must be refused, not clamped")
            #expect(store.tracks[0].instrument?.sampler == nil,
                    "a refused glideTime must not have half-applied")
        }
        // The boundaries ARE legal — a refusal test that rejected everything
        // would pass while the field was unusable.
        for good in [0.0, SamplerParams.glideTimeRange.upperBound] {
            let response = await glideSetSampler(router, trackID, ["glideTime": .number(good)],
                                                 id: "ok-\(good)")
            #expect(response.ok,
                    """
                    glideTime \(good) is in range and must be accepted: \(response.error ?? "")
                    """)
            #expect(store.tracks[0].instrument?.sampler?.glideTime == good)
        }
    }

    // MARK: - describeSampler: read-back AND the inert-glide warning

    /// ⛔ THE SETTABLE-BUT-INVISIBLE SHAPE, CLOSED. `glideTime` alone cannot
    /// tell a caller whether the slide will happen — it needs a monophonic
    /// voiceMode too — so `describeSampler` publishes `glideEffective`, the
    /// COMPARISON, and a prose warning when the answer is no.
    @Test("m34-t wire: describeSampler reports glideEffective, and warns when a glide is inert")
    func glideDescribeSamplerReportsEffectiveness() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        // ① A glide on a POLY sampler: stored, echoed, and flagged INERT.
        await glideSetSampler(router, trackID, ["glideTime": .number(0.3)])
        let inert = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d1", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID)])))
        #expect(inert["glideTime"]?.doubleValue == 0.3)
        #expect(inert["glideEffective"]?.boolValue == false,
                "a glide on a poly sampler is inert and must say so")
        guard case .array(let warnings)? = inert["warnings"] else {
            Issue.record("describeSampler emitted no warnings for an inert glide")
            return
        }
        let text = warnings.compactMap(\.stringValue).joined(separator: " | ")
        print("[measured] inert-glide warning: \(text)")
        #expect(text.contains("glideTime"))
        #expect(text.contains("legato"), "the warning must name the fix: \(text)")

        // ② The same glide with a monophonic mode: EFFECTIVE, and no warning
        // about it. This is the control — without it, `false` above is also what
        // a field that is always false looks like.
        await glideSetSampler(router, trackID,
                              ["voiceMode": .string("legato"), "glideTime": .number(0.3)],
                              id: "2")
        let live = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d2", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID)])))
        #expect(live["glideEffective"]?.boolValue == true,
                "control failed: a legato glide is still reported inert")
        if case .array(let liveWarnings)? = live["warnings"] {
            let liveText = liveWarnings.compactMap(\.stringValue).joined(separator: " | ")
            #expect(!liveText.contains("GLIDE IS"), "a working glide must not warn: \(liveText)")
        }

        // ③ A sampler with NO glide carries neither key — the pre-m34-t shape.
        // ⚠️ ON A FRESH TRACK, and that is not incidental: `track.setInstrument`'s
        // `sampler` object is a partial OVERLAY onto the track's current config
        // (the m23 finding-12 fix), so re-sending it without `glideTime` on the
        // track above would KEEP the 0.3 s set in ① — which is exactly what
        // `glideOmittedGlideTimeKeepsTheCurrentOne` pins. Reusing the track here
        // measured `glideTime` still present and read as a product defect; it is
        // the merge working correctly.
        let bareTrackID = store.addTrack(kind: .instrument).id.uuidString
        await glideSetSampler(router, bareTrackID, ["voiceMode": .string("mono")], id: "3")
        let bare = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d3", command: "instrument.describeSampler",
            params: ["trackId": .string(bareTrackID)])))
        #expect(bare["glideTime"] == nil)
        #expect(bare["glideEffective"] == nil,
                "an unset glide must not add a key to every describeSampler response")
        #expect(bare["voiceMode"]?.stringValue == "mono", "control: the mode IS read back")
    }
}
