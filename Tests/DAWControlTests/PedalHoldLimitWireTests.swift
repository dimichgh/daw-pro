import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m34-q wire surface: `pedalHoldLimit` on `track.setInstrument` at BOTH
/// levels — top level for the built-in Poly Synth, inside the `sampler` object
/// for the built-in Sampler.
///
/// The contract this pins, in one sentence: an out-of-range or fractional cap
/// is REFUSED with a readable error rather than clamped (the
/// `bendRangeSemitones` rule — an agent that asked for 300 and silently got
/// 128 has no way to find out), an omitted cap keeps whatever the track
/// already had, and an UNSET cap emits no key at all, so a project that never
/// touched this feature keeps its pre-m34-q wire shape byte-for-byte.
///
/// Reuses `FakeMedia` from ControlTests.swift (same target).
///
/// ⚠️ AN EXTENSION ON `CommandRouterTests`, NOT A NEW `@Suite` — deliberate.
/// `MainActorOccupancySiteTests` Leg C caps `@MainActor`-isolated suites at
/// 375 as a REVIEW CADENCE, and the tree measured exactly 375 before this
/// item. A new suite here would have tripped that gate, and the only
/// legitimate way to raise it is a fresh `m23aw-prepare-headroom.mjs`
/// campaign — which is roadmap blocker A, human-gated on an idle machine.
/// These tests belong to the same subject (`CommandRouter` verbs) either way,
/// so an extension is the honest home rather than a dodge. Helpers carry a
/// `pedal` prefix so they cannot collide with the suite's own.
private let pedalPingPath = "/System/Library/Sounds/Ping.aiff"

extension CommandRouterTests {
    private func pedalMakeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// `track.setInstrument` returns the resolved instrument object AS the
    /// result — not wrapped under an `instrument` key.
    private func pedalInstrumentObject(_ response: ControlResponse) throws -> [String: JSONValue] {
        let result = try #require(response.result)
        guard case .object(let root) = result else {
            Issue.record("response result was not an object"); throw ControlError("shape")
        }
        return root
    }

    private func pedalNested(_ instrument: [String: JSONValue], _ key: String) throws
        -> [String: JSONValue] {
        guard case .object(let obj)? = instrument[key] else {
            Issue.record("instrument carried no \(key) object"); throw ControlError("shape")
        }
        return obj
    }

    // MARK: - Sampler (inside the `sampler` object)

    @Test("m34-q: a sampler cap is accepted, stored, and echoed back")
    func pedalSamplerCapRoundTrips() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])]),
                        "pedalHoldLimit": .number(6),
                     ])]))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == 6)

        let sampler = try pedalNested(try pedalInstrumentObject(response), "sampler")
        #expect(sampler["pedalHoldLimit"]?.doubleValue == 6)
    }

    @Test("m34-q: an omitted sampler cap keeps the one the track already had")
    func pedalOmittedSamplerCapKeepsTheCurrentOne() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])]),
                        "pedalHoldLimit": .number(5),
                     ])]))
        #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == 5)

        // A one-knob partial edit that says nothing about the cap.
        let tweak = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "sampler": .object(["release": .number(0.4)])]))
        #expect(tweak.ok)
        #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == 5,
                "a partial edit must not silently drop the cap")
        #expect(store.tracks[0].instrument?.sampler?.release == 0.4,
                "control: the edit that WAS sent landed")
    }

    @Test("m34-q: an unset sampler cap emits no key at all — the pre-m34-q wire shape is unchanged")
    func pedalUnsetSamplerCapEmitsNoKey() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let plain = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])]),
                     ])]))
        #expect(plain.ok)
        let samplerNoCap = try pedalNested(try pedalInstrumentObject(plain), "sampler")
        #expect(samplerNoCap["pedalHoldLimit"] == nil,
                "an untouched sampler's wire object must not grow a key")

        // POSITIVE CONTROL: the same probe on the same field, cap set.
        let capped = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "sampler": .object(["pedalHoldLimit": .number(9)])]))
        #expect(capped.ok)
        let samplerCapped = try pedalNested(try pedalInstrumentObject(capped), "sampler")
        #expect(samplerCapped["pedalHoldLimit"]?.doubleValue == 9,
                "control failed: if a SET cap does not appear either, the absence above is noise")
    }

    @Test("m34-q: an out-of-range or fractional sampler cap is REFUSED, not clamped, and changes nothing")
    func pedalSamplerCapRefusesBadValues() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])]),
                        "pedalHoldLimit": .number(4),
                     ])]))
        #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == 4)

        for bad in [JSONValue.number(0), .number(-1), .number(129), .number(300), .number(4.5)] {
            let response = await router.handle(ControlRequest(
                id: "x", command: "track.setInstrument",
                params: ["trackId": .string(trackID),
                         "sampler": .object(["pedalHoldLimit": bad])]))
            #expect(!response.ok, "\(bad) must be refused, never clamped")
            let message = response.error ?? ""
            #expect(message.contains("sampler.pedalHoldLimit"),
                    "the error must name the FIELD PATH so a caller knows where to look: \(message)")
            #expect(message.contains("between 1 and 128"),
                    "the error must state the range: \(message)")
        }
        #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == 4,
                "a refused write must leave the stored cap alone")
    }

    @Test("m34-q: the sampler cap's boundary values 1 and 128 are accepted")
    func pedalSamplerCapBoundariesAreLegal() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])])])]))

        for legal in [1, 128] {
            let response = await router.handle(ControlRequest(
                id: "b", command: "track.setInstrument",
                params: ["trackId": .string(trackID),
                         "sampler": .object(["pedalHoldLimit": .number(Double(legal))])]))
            #expect(response.ok, "\(legal) is inside the range: \(response.error ?? "")")
            #expect(store.tracks[0].instrument?.sampler?.pedalHoldLimit == legal)
        }
    }

    // MARK: - Poly synth (top level)

    @Test("m34-q: a poly-synth cap is accepted, stored, and echoed back")
    func pedalPolySynthCapRoundTrips() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "pedalHoldLimit": .number(3)]))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.tracks[0].instrument?.polySynth.pedalHoldLimit == 3)

        let poly = try pedalNested(try pedalInstrumentObject(response), "polySynth")
        #expect(poly["pedalHoldLimit"]?.doubleValue == 3)
    }

    @Test("m34-q: an omitted poly-synth cap keeps the one the track already had")
    func pedalOmittedPolySynthCapKeepsTheCurrentOne() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "pedalHoldLimit": .number(7)]))
        #expect(store.tracks[0].instrument?.polySynth.pedalHoldLimit == 7)

        let tweak = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "release": .number(0.9)]))
        #expect(tweak.ok)
        #expect(store.tracks[0].instrument?.polySynth.pedalHoldLimit == 7,
                "a partial edit must not silently drop the cap")
        #expect(store.tracks[0].instrument?.polySynth.release == 0.9, "control: the edit landed")
    }

    @Test("m34-q: an unset poly-synth cap emits no key — its FIRST only-when-set key behaves like the sampler's")
    func pedalUnsetPolySynthCapEmitsNoKey() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let plain = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth")]))
        #expect(plain.ok)
        let polyNoCap = try pedalNested(try pedalInstrumentObject(plain), "polySynth")
        #expect(polyNoCap["pedalHoldLimit"] == nil)
        // The eight keys this object has always carried must all still be there
        // — "additive" has to mean the old shape survived, not just that the
        // new key is absent.
        for key in ["waveform", "attack", "decay", "sustain",
                    "release", "cutoffHz", "resonance", "gain"] {
            #expect(polyNoCap[key] != nil, "the pre-m34-q key \(key) must still be emitted")
        }

        let capped = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "pedalHoldLimit": .number(12)]))
        #expect(capped.ok)
        let polyCapped = try pedalNested(try pedalInstrumentObject(capped), "polySynth")
        #expect(polyCapped["pedalHoldLimit"]?.doubleValue == 12, "control failed")
    }

    @Test("m34-q: an out-of-range or fractional poly-synth cap is REFUSED, not clamped")
    func pedalPolySynthCapRefusesBadValues() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "pedalHoldLimit": .number(8)]))

        for bad in [JSONValue.number(0), .number(-2), .number(129), .number(2.5)] {
            let response = await router.handle(ControlRequest(
                id: "x", command: "track.setInstrument",
                params: ["trackId": .string(trackID), "pedalHoldLimit": bad]))
            #expect(!response.ok, "\(bad) must be refused")
            let message = response.error ?? ""
            #expect(message.contains("pedalHoldLimit"), "\(message)")
            #expect(message.contains("between 1 and 128"), "\(message)")
        }
        #expect(store.tracks[0].instrument?.polySynth.pedalHoldLimit == 8,
                "a refused write must leave the stored cap alone")
    }

    // MARK: - The dedicated READ-BACK verb

    /// ⭐ `instrument.describeSampler` is the one place an agent LOOKS to find
    /// out what a sampler is set to. A cap that can be written through
    /// `track.setInstrument` but does not appear here would be
    /// settable-but-unreadable — the exact shape the m27 round and the
    /// bend-range/voice-mode legs before it exist to end, and the reason those
    /// two are emitted from this verb at all.
    @Test("m34-q: instrument.describeSampler reads the cap back, and omits the key when unset")
    func pedalDescribeSamplerReadsTheCapBack() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                        "zones": .array([.object(["path": .string(pedalPingPath)])])])]))

        // Unset first — the key must be absent, not 0 and not 128.
        let bare = await router.handle(ControlRequest(
            id: "1", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID)]))
        #expect(bare.ok, "\(bare.error ?? "")")
        guard case .object(let bareResult)? = bare.result else {
            Issue.record("describeSampler result was not an object"); return
        }
        #expect(bareResult["pedalHoldLimit"] == nil,
                "an untouched sampler's describe payload must not grow a key")
        // The probe can see this verb's OTHER keys, so the absence above is a
        // measurement rather than a mis-shaped lookup.
        #expect(bareResult["gain"] != nil, "control: the payload really is the describe result")

        _ = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "sampler": .object(["pedalHoldLimit": .number(7)])]))

        let described = await router.handle(ControlRequest(
            id: "3", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID)]))
        #expect(described.ok, "\(described.error ?? "")")
        guard case .object(let result)? = described.result else {
            Issue.record("describeSampler result was not an object"); return
        }
        #expect(result["pedalHoldLimit"]?.doubleValue == 7,
                "a cap set through track.setInstrument must be readable through the describe verb")
    }

    // MARK: - The allow-list did not go loose

    @Test("m34-q: a typo'd cap key is still refused by track.setInstrument's unknown-key guard")
    func pedalTypoedCapKeyIsRefused() async throws {
        let (router, store) = pedalMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "pedalHoldLimitt": .number(4)]))
        #expect(!response.ok, "adding one key to the allow-list must not open it to neighbours")
        #expect(response.error?.contains("pedalHoldLimitt") == true,
                "\(response.error ?? "")")

        // CONTROL: the correctly-spelled key on the same call IS accepted.
        let good = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "pedalHoldLimit": .number(4)]))
        #expect(good.ok, "\(good.error ?? "")")
    }
}
