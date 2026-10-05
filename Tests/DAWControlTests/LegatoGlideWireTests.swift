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

    // MARK: - m34-w: glideMode, what the glideTime NUMBER means

    @Test("m34-w wire: glideMode 'constantRate' is accepted, stored, and echoed back")
    func glideModeRoundTrips() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await glideSetSampler(
            router, trackID,
            ["voiceMode": .string("legato"), "glideTime": .number(0.12),
             "glideMode": .string("constantRate")])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.tracks[0].instrument?.sampler?.glideMode == .constantRate)
        let sampler = try glideNested(try glideInstrumentObject(response), "sampler")
        #expect(sampler["glideMode"]?.stringValue == "constantRate")
    }

    @Test("m34-w wire: an omitted glideMode keeps the one the track already had")
    func glideOmittedGlideModeKeepsTheCurrentOne() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        await glideSetSampler(router, trackID,
                              ["voiceMode": .string("legato"),
                               "glideMode": .string("constantRate")])
        #expect(store.tracks[0].instrument?.sampler?.glideMode == .constantRate)

        // A later call that says nothing about the mode must not silently
        // revert it to constant time — which would be inaudible on a whole
        // tone and obvious on an octave, the worst possible failure shape.
        let second = await glideSetSampler(router, trackID,
                                           ["glideTime": .number(0.2)], id: "2")
        #expect(second.ok, "\(second.error ?? "")")
        #expect(store.tracks[0].instrument?.sampler?.glideMode == .constantRate,
                "an omitted glideMode silently reverted the track to constantTime")
        #expect(store.tracks[0].instrument?.sampler?.glideTime == 0.2,
                "control failed: the call that omitted the mode did not take effect at all")
    }

    @Test("m34-w wire: an unset glideMode emits no key — the pre-m34-w wire shape is unchanged")
    func glideUnsetGlideModeEmitsNoKey() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await glideSetSampler(router, trackID, ["glideTime": .number(0.2)])
        let sampler = try glideNested(try glideInstrumentObject(response), "sampler")
        #expect(sampler["glideMode"] == nil,
                "an untouched glideMode must not add a key to every sampler response")
        // CONTROL: the key DOES appear when it is set, so `nil` above is an
        // absence rather than an echo path that never emits it.
        let set = try glideNested(
            try glideInstrumentObject(
                await glideSetSampler(router, trackID,
                                      ["glideMode": .string("constantRate")], id: "2")),
            "sampler")
        #expect(set["glideMode"]?.stringValue == "constantRate",
                "control failed: a SET glide mode is not echoed")
    }

    /// A typo must not land as `constantTime`. A silently-wrong MODE is worse
    /// than a silently-wrong number here: the sampler still glides, still lands
    /// on the right pitch, and only the DURATION is wrong — nothing an agent
    /// reads back would show it.
    @Test("m34-w wire: an unknown or non-string glideMode is REFUSED, and the message names both modes")
    func glideModeRefusesBadValues() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let bad = await glideSetSampler(router, trackID,
                                        ["glideMode": .string("constantSpeed")])
        #expect(!bad.ok, "an unrecognised glide mode must be refused, not silently ignored")
        let message = bad.error ?? ""
        print("[measured] unknown glideMode refusal: \(message)")
        #expect(message.contains("constantTime"))
        #expect(message.contains("constantRate"),
                "the refusal must name the mode that scales with distance: \(message)")
        #expect(store.tracks[0].instrument?.sampler == nil,
                "a refused call must not have half-applied")

        let wrongType = await glideSetSampler(router, trackID,
                                              ["glideMode": .number(2)], id: "2")
        #expect(!wrongType.ok, "a numeric glideMode must be refused")
        #expect((wrongType.error ?? "").contains("glideMode"),
                "the refusal must name the field: \(wrongType.error ?? "")")

        // CONTROL: a LEGAL value on the same path is accepted, so the two
        // refusals above are about the values and not about the path.
        let good = await glideSetSampler(router, trackID,
                                         ["glideMode": .string("constantTime")], id: "3")
        #expect(good.ok, "control failed: a legal glideMode was refused too: \(good.error ?? "")")
    }

    /// ⭐ `glideMode: "constantRate"` alone does not tell a caller what the
    /// number now BUYS, so describeSampler publishes the reference interval
    /// straight from the engine's own constant. And a mode set with no time is
    /// stored-but-inert — the honest-light rule this verb exists for.
    @Test("m34-w wire: describeSampler reports glideMode with its UNIT, and warns when it scales nothing")
    func glideModeDescribeCarriesTheUnitAndWarnsWhenInert() async throws {
        let (router, store) = glideMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        // ① A rate mode WITH a time: read back, with the unit alongside it.
        await glideSetSampler(router, trackID,
                              ["voiceMode": .string("legato"), "glideTime": .number(0.12),
                               "glideMode": .string("constantRate")])
        let live = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d1", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID)])))
        #expect(live["glideMode"]?.stringValue == "constantRate")
        #expect(live["glideRateReferenceSemitones"]?.doubleValue
                == SamplerParams.glideRateReferenceSemitones,
                "the unit must come from the engine's own constant, never from prose")
        #expect(live["glideRateReferenceSemitones"]?.doubleValue == 2,
                "…and that constant is 2 semitones — the calibration the user's 0.12 rests on")
        #expect(live["glideEffective"]?.boolValue == true,
                "mode is orthogonal to effectiveness: a legato rate glide is still effective")

        // ② A rate mode with NO time: accepted, stored, and scaling nothing.
        let inertTrackID = store.addTrack(kind: .instrument).id.uuidString
        await glideSetSampler(router, inertTrackID,
                              ["voiceMode": .string("legato"),
                               "glideMode": .string("constantRate")], id: "2")
        let inert = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d2", command: "instrument.describeSampler",
            params: ["trackId": .string(inertTrackID)])))
        guard case .array(let warnings)? = inert["warnings"] else {
            Issue.record("describeSampler emitted no warning for a rate mode with no glide time")
            return
        }
        let text = warnings.compactMap(\.stringValue).joined(separator: " | ")
        print("[measured] rate-mode-without-a-time warning: \(text)")
        #expect(text.contains("constantRate"))
        #expect(text.contains("glideTime"), "the warning must name the fix: \(text)")

        // ③ A sampler that never chose a mode carries NEITHER key — the
        // pre-m34-w describe shape, byte-for-byte.
        let bareTrackID = store.addTrack(kind: .instrument).id.uuidString
        await glideSetSampler(router, bareTrackID,
                              ["voiceMode": .string("legato"), "glideTime": .number(0.12)],
                              id: "3")
        let bare = try glideInstrumentObject(await router.handle(ControlRequest(
            id: "d3", command: "instrument.describeSampler",
            params: ["trackId": .string(bareTrackID)])))
        #expect(bare["glideMode"] == nil)
        #expect(bare["glideRateReferenceSemitones"] == nil,
                "an unset mode must not add the unit key to every describeSampler response")
        #expect(bare["glideTime"]?.doubleValue == 0.12, "control: the glide IS read back")
        if case .array(let bareWarnings)? = bare["warnings"] {
            let bareText = bareWarnings.compactMap(\.stringValue).joined(separator: " | ")
            #expect(!bareText.contains("constantRate"),
                    "a sampler that never chose a mode must not be warned about one: \(bareText)")
        }
    }
}
