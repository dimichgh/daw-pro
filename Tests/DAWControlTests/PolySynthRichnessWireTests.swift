import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m39-g (the fifteen richness parameters on `track.setInstrument`) and m39-f
/// (`instrument.describeSynth`) as a wire contract.
///
/// The three things this pins, in one sentence each:
///   ① a richness value written here SURVIVES an unrelated knob edit — the
///     data-loss trap that making these fields settable would otherwise have
///     activated (`InstrumentStoreTests.richnessSurvivesAnUnrelatedKnobEdit` is
///     the store-level twin, and it was watched to FAIL before the fix);
///   ② an out-of-range value is REFUSED, never clamped — the m34-q rule, since
///     an agent that asked for 20 unison voices and silently got 8 has no way
///     to find out;
///   ③ everything settable is READABLE, with its range, unit, default and
///     nil-resolution, from the running app rather than from a doc.
///
/// Reuses `FakeMedia` from ControlTests.swift (same target).
///
/// ⚠️ AN EXTENSION ON `CommandRouterTests`, NOT A NEW `@Suite` — the
/// `PedalHoldLimitWireTests` precedent, and for the same measured reason.
/// `MainActorOccupancySiteTests` Leg C caps `@MainActor`-isolated suites at
/// **380** as a review cadence and the tree measures **379** — one slot, and
/// the last three bumps (375 → 377 → 380) all shipped UNBACKED because the
/// validating campaign needs a ≤ 248 s full-suite wall time and this machine
/// runs ~276 s. A fourth unbacked bump for a verb that belongs to
/// `CommandRouter` anyway would be silencing the instrument, not reducing the
/// occupancy. Helpers carry a `synth` prefix so they cannot collide with the
/// suite's own.
extension CommandRouterTests {
    private func synthMakeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func synthObject(_ response: ControlResponse) throws -> [String: JSONValue] {
        let result = try #require(response.result)
        guard case .object(let root) = result else {
            Issue.record("response result was not an object"); throw ControlError("shape")
        }
        return root
    }

    private func synthNested(_ object: [String: JSONValue], _ key: String) throws
        -> [String: JSONValue] {
        guard case .object(let nested)? = object[key] else {
            Issue.record("payload carried no \(key) object"); throw ControlError("shape")
        }
        return nested
    }

    /// Every richness key with a legal, non-neutral value — one place, so a
    /// sixteenth field is added once.
    private var synthAllRichness: [String: JSONValue] {
        ["unisonVoices": .number(5), "unisonDetuneCents": .number(18),
         "unisonStereoSpread": .number(0.8), "subLevel": .number(0.4),
         "subOctave": .number(-2), "subWaveform": .string("square"),
         "noiseLevel": .number(0.2), "noiseColor": .number(0.9),
         "drift": .number(0.35), "resonanceBoost": .number(0.7),
         "drive": .number(0.45), "velocityToCutoff": .number(0.6),
         "keyToCutoff": .number(0.25), "voiceJitter": .number(0.15),
         "envelopeCurve": .number(-0.5)]
    }

    // MARK: - track.setInstrument: the fifteen go in and come back

    @Test("m39-g: all fifteen richness parameters round-trip through track.setInstrument")
    func synthRichnessRoundTrips() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        var params = synthAllRichness
        params["trackId"] = .string(trackID)
        params["kind"] = .string("polySynth")
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument", params: params))
        #expect(response.ok, "\(response.error ?? "")")

        // Stored on the model…
        let poly = try #require(store.tracks[0].instrument?.polySynth)
        #expect(poly.unisonVoices == 5)
        #expect(poly.unisonDetuneCents == 18)
        #expect(poly.unisonStereoSpread == 0.8)
        #expect(poly.subLevel == 0.4)
        #expect(poly.subOctave == -2)
        #expect(poly.subWaveform == .square)
        #expect(poly.noiseLevel == 0.2)
        #expect(poly.noiseColor == 0.9)
        #expect(poly.drift == 0.35)
        #expect(poly.resonanceBoost == 0.7)
        #expect(poly.drive == 0.45)
        #expect(poly.velocityToCutoff == 0.6)
        #expect(poly.keyToCutoff == 0.25)
        #expect(poly.voiceJitter == 0.15)
        #expect(poly.envelopeCurve == -0.5)

        // …and echoed on the wire, so a caller can read back what it wrote
        // without a second call. A setter's return is not proof it took, and a
        // store that took it is not proof the wire says so.
        let echoed = try synthNested(try synthObject(response), "polySynth")
        for (key, value) in synthAllRichness {
            #expect(echoed[key] == value, "\(key) was not echoed as sent")
        }
    }

    /// ⛔⛔ THE DATA-LOSS TRAP, AT THE WIRE. The store-level pin is
    /// `InstrumentStoreTests.richnessSurvivesAnUnrelatedKnobEdit`; this is the
    /// same failure as a user would actually meet it — two ordinary calls, the
    /// second one about something else entirely.
    @Test("m39-g: a later one-knob edit does NOT wipe richness set earlier (wire)")
    func synthRichnessSurvivesALaterKnobEdit() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        var params = synthAllRichness
        params["trackId"] = .string(trackID)
        params["kind"] = .string("polySynth")
        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument", params: params))
        #expect(store.tracks[0].instrument?.polySynth.unisonVoices == 5, "precondition")

        // The user brightens the filter. That is the whole second call.
        let tweak = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "cutoffHz": .number(12_000)]))
        #expect(tweak.ok, "\(tweak.error ?? "")")

        #expect(store.tracks[0].instrument?.polySynth.cutoffHz == 12_000,
                "control: the edit that WAS sent landed")
        let echoed = try synthNested(try synthObject(tweak), "polySynth")
        for (key, value) in synthAllRichness {
            #expect(echoed[key] == value,
                    "\(key) was DESTROYED by an unrelated knob edit — the m39-g trap")
        }
    }

    @Test("m39-g: an untouched synth emits no richness keys — the pre-m39-g wire shape survives")
    func synthUnsetRichnessEmitsNoKeys() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let plain = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth")]))
        #expect(plain.ok, "\(plain.error ?? "")")
        let bare = try synthNested(try synthObject(plain), "polySynth")
        for key in synthAllRichness.keys {
            #expect(bare[key] == nil, "an untouched synth must not grow a \(key) key")
        }
        // The eight keys this object has always carried are all still there —
        // "additive" has to mean the OLD shape survived, not merely that the
        // new keys are absent.
        for key in ["waveform", "attack", "decay", "sustain",
                    "release", "cutoffHz", "resonance", "gain"] {
            #expect(bare[key] != nil, "the pre-m39-g key \(key) must still be emitted")
        }

        // POSITIVE CONTROL: the same probe, same keys, values set. Without it
        // the fifteen absences above could be a mis-shaped lookup rather than a
        // measurement.
        var params = synthAllRichness
        params["trackId"] = .string(trackID)
        let set = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument", params: params))
        let filled = try synthNested(try synthObject(set), "polySynth")
        for key in synthAllRichness.keys {
            #expect(filled[key] != nil,
                    "control failed: a SET \(key) does not appear either, so the absence above")
        }
    }

    // MARK: - Refuse, never clamp

    @Test("m39-g: an out-of-range richness value is REFUSED, not clamped, and changes nothing")
    func synthRichnessRefusesOutOfRange() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "unisonVoices": .number(4), "noiseColor": .number(0.25)]))

        // (key, illegal value, the range wording the error must state)
        let bad: [(String, JSONValue, String)] = [
            ("unisonVoices", .number(0), "between 1 and 8"),
            ("unisonVoices", .number(9), "between 1 and 8"),
            ("unisonDetuneCents", .number(51), "between 0.0 and 50.0"),
            ("unisonStereoSpread", .number(1.5), "between 0.0 and 1.0"),
            ("subLevel", .number(-0.1), "between 0.0 and 1.0"),
            ("subOctave", .number(0), "between -2 and -1"),
            ("subOctave", .number(-3), "between -2 and -1"),
            ("noiseLevel", .number(2), "between 0.0 and 1.0"),
            ("noiseColor", .number(-1), "between 0.0 and 1.0"),
            ("drift", .number(1.01), "between 0.0 and 1.0"),
            ("resonanceBoost", .number(3), "between 0.0 and 1.0"),
            ("drive", .number(-2), "between 0.0 and 1.0"),
            ("velocityToCutoff", .number(1.2), "between 0.0 and 1.0"),
            ("keyToCutoff", .number(-0.5), "between 0.0 and 1.0"),
            ("voiceJitter", .number(4), "between 0.0 and 1.0"),
            ("envelopeCurve", .number(1.5), "between -1.0 and 1.0"),
            ("envelopeCurve", .number(-1.5), "between -1.0 and 1.0"),
        ]
        for (key, value, range) in bad {
            let response = await router.handle(ControlRequest(
                id: "x", command: "track.setInstrument",
                params: ["trackId": .string(trackID), key: value]))
            #expect(!response.ok, "\(key) = \(value) must be refused, never clamped")
            let message = response.error ?? ""
            #expect(message.contains(key),
                    "the error must NAME the field so a caller knows where to look: \(message)")
            #expect(message.contains(range), "the error must state the range: \(message)")
        }
        // A refused write leaves the stored patch exactly as it was.
        #expect(store.tracks[0].instrument?.polySynth.unisonVoices == 4)
        #expect(store.tracks[0].instrument?.polySynth.noiseColor == 0.25)
    }

    /// `Int(2.5)` is 2, silently. The integer helper refuses instead — the
    /// m23-aj-2 finding, and the reason `unisonVoices` does not ride the same
    /// path as the thirteen Doubles.
    @Test("m39-g: a FRACTIONAL unisonVoices or subOctave is refused, not truncated")
    func synthIntegerRichnessRefusesFractions() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        for (key, value) in [("unisonVoices", 2.5), ("subOctave", -1.5)] {
            let response = await router.handle(ControlRequest(
                id: "1", command: "track.setInstrument",
                params: ["trackId": .string(trackID), key: .number(value)]))
            #expect(!response.ok, "\(key) = \(value) must be refused")
            #expect(response.error?.contains("whole number") == true, "\(response.error ?? "")")
        }
        #expect(store.tracks[0].instrument?.polySynth.unisonVoices == nil,
                "a refused write must store nothing")
    }

    @Test("m39-g: a bad subWaveform names subWaveform, and the legacy waveform error is unchanged")
    func synthSubWaveformErrorsNameTheRightField() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let badSub = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "subWaveform": .string("sawtooth")]))
        #expect(!badSub.ok)
        let subMessage = badSub.error ?? ""
        #expect(subMessage.hasPrefix("subWaveform must be one of"),
                "a bad subWaveform must not send a caller to the 'waveform' key: \(subMessage)")
        #expect(subMessage.contains("SUB-oscillator"),
                "the error teaches which oscillator this is: \(subMessage)")

        // A non-string is refused too — a new field starts strict, because a
        // setting accepted and silently dropped is the failure this whole item
        // exists to end.
        let nonString = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "subWaveform": .number(3)]))
        #expect(!nonString.ok, "subWaveform: 3 must not be silently ignored")
        #expect(nonString.error?.contains("subWaveform must be a string") == true,
                "\(nonString.error ?? "")")

        // ⛔ THE LEGACY STRING IS A LIVE CONTRACT, pinned verbatim in
        // ControlTests. Refactoring the parser must not have moved one byte.
        let badMain = await router.handle(ControlRequest(
            id: "3", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "waveform": .string("sawtooth")]))
        #expect(badMain.error == "waveform must be one of saw|square|triangle|sine")

        // CONTROL: the legal value on the same field IS accepted.
        let good = await router.handle(ControlRequest(
            id: "4", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "subWaveform": .string("triangle")]))
        #expect(good.ok, "\(good.error ?? "")")
        #expect(store.tracks[0].instrument?.polySynth.subWaveform == .triangle)
    }

    @Test("m39-g: adding fifteen keys did not open track.setInstrument's allow-list to neighbours")
    func synthAllowListStayedClosed() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let typo = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "unisonVoice": .number(4)]))
        #expect(!typo.ok, "a near-miss key must still be refused")
        #expect(typo.error?.contains("unisonVoice") == true, "\(typo.error ?? "")")

        // CONTROL: the correctly-spelled key on the same call IS accepted.
        let good = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "unisonVoices": .number(4)]))
        #expect(good.ok, "\(good.error ?? "")")
    }

    // MARK: - instrument.describeSynth

    private func synthDescribe(
        _ router: CommandRouter, _ trackID: String
    ) async throws -> [String: JSONValue] {
        let response = await router.handle(ControlRequest(
            id: "d", command: "instrument.describeSynth",
            params: ["trackId": .string(trackID)]))
        #expect(response.ok, "\(response.error ?? "")")
        return try synthObject(response)
    }

    @Test("m39-f: describeSynth reports range, unit, meaning and default for every parameter")
    func synthDescribeDescribesEveryParameterFully() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let payload = try await synthDescribe(router, trackID)

        #expect(payload["parameterCount"]?.doubleValue == 24,
                "8 legacy + pedalHoldLimit + 15 richness")
        guard case .array(let order)? = payload["order"] else {
            Issue.record("no order array"); return
        }
        #expect(order.count == 24)
        let parameters = try synthNested(payload, "parameters")
        #expect(parameters.count == 24)

        for entry in order {
            let name = try #require(entry.stringValue)
            guard case .object(let spec)? = parameters[name] else {
                Issue.record("order names \(name) but parameters has no such entry"); continue
            }
            // Every parameter answers all four of the questions this verb
            // exists to answer. An entry that silently lacks one is exactly the
            // "looks like a valid answer" failure the verb is meant to end.
            #expect(spec["effective"] != nil, "\(name) has no effective value")
            #expect(spec["default"] != nil, "\(name) has no default")
            #expect(spec["unit"]?.stringValue?.isEmpty == false, "\(name) has no unit")
            #expect(spec["meaning"]?.stringValue?.isEmpty == false, "\(name) has no meaning")
            #expect(spec["optional"] != nil || name == "waveform", "\(name) has no optional flag")
            if spec["optional"]?.boolValue == true {
                #expect(spec["nilResolvesTo"] != nil,
                        "\(name) is optional and must say what nil resolves to")
            }
        }
    }

    /// The ranges are the MODEL's, read at runtime — that is the whole point of
    /// asking the app instead of a doc. A literal here would only pin this test
    /// to a number, not the verb to the model.
    @Test("m39-f: describeSynth's ranges and constants come from PolySynthParams, not from prose")
    func synthDescribeRangesMatchTheModel() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let parameters = try synthNested(try await synthDescribe(router, trackID), "parameters")

        func bounds(_ name: String) throws -> (Double, Double) {
            let spec = try synthNested(parameters, name)
            return (try #require(spec["min"]?.doubleValue),
                    try #require(spec["max"]?.doubleValue))
        }
        #expect(try bounds("unisonVoices")
            == (Double(PolySynthParams.unisonVoicesRange.lowerBound),
                Double(PolySynthParams.unisonVoicesRange.upperBound)))
        #expect(try bounds("unisonDetuneCents")
            == (PolySynthParams.unisonDetuneCentsRange.lowerBound,
                PolySynthParams.unisonDetuneCentsRange.upperBound))
        #expect(try bounds("subOctave")
            == (Double(PolySynthParams.subOctaveRange.lowerBound),
                Double(PolySynthParams.subOctaveRange.upperBound)))
        #expect(try bounds("envelopeCurve")
            == (PolySynthParams.envelopeCurveRange.lowerBound,
                PolySynthParams.envelopeCurveRange.upperBound))
        #expect(try bounds("cutoffHz")
            == (PolySynthParams.cutoffRange.lowerBound,
                PolySynthParams.cutoffRange.upperBound))

        let constants = try synthNested(
            try await synthDescribe(router, trackID), "constants")
        #expect(constants["maxUnisonVoices"]?.doubleValue
            == Double(PolySynthParams.maxUnisonVoices))
        #expect(constants["driftMaxCents"]?.doubleValue == PolySynthParams.driftMaxCents)
        #expect(constants["cutoffTrackMaxOctaves"]?.doubleValue
            == PolySynthParams.cutoffTrackMaxOctaves)
        #expect(constants["keyTrackCenterPitch"]?.doubleValue
            == PolySynthParams.keyTrackCenterPitch)
        #expect(constants["maxBoostedQ"]?.doubleValue == PolySynthParams.maxBoostedQ)
    }

    /// ⚠️ THE TWO THAT DO NOT RESOLVE TO ZERO. Thirteen of the fifteen are
    /// neutral at 0; `noiseColor` is neutral at 0.5 (white) and `subOctave` at
    /// -1. A caller who assumes "unset means zero" gets those two wrong, which
    /// is precisely why this verb publishes the resolution instead of implying
    /// it.
    @Test("m39-f: describeSynth's nilResolvesTo is right for the two fields that are not 0")
    func synthDescribeNilResolutionsAreExact() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let parameters = try synthNested(try await synthDescribe(router, trackID), "parameters")

        let noiseColor = try synthNested(parameters, "noiseColor")
        #expect(noiseColor["nilResolvesTo"]?.doubleValue == 0.5)
        #expect(noiseColor["effective"]?.doubleValue == 0.5)
        #expect(noiseColor["isSet"]?.boolValue == false)
        #expect(noiseColor["value"] == nil, "an unset field has no stored value to report")

        let subOctave = try synthNested(parameters, "subOctave")
        #expect(subOctave["nilResolvesTo"]?.doubleValue == -1)
        #expect(subOctave["effective"]?.doubleValue == -1)

        let subWaveform = try synthNested(parameters, "subWaveform")
        #expect(subWaveform["nilResolvesTo"]?.stringValue == "sine")

        // And a spot-check that the other thirteen really are 0, so the two
        // above are a distinction rather than an accident.
        for name in ["unisonDetuneCents", "subLevel", "noiseLevel", "drift",
                     "resonanceBoost", "drive", "velocityToCutoff", "keyToCutoff",
                     "voiceJitter", "envelopeCurve"] {
            let spec = try synthNested(parameters, name)
            #expect(spec["nilResolvesTo"]?.doubleValue == 0, "\(name) should be neutral at 0")
        }
        #expect(try synthNested(parameters, "unisonVoices")["nilResolvesTo"]?.doubleValue == 1)

        // m34-q's field is the one whose nil is not a NUMBER at all.
        let pedal = try synthNested(parameters, "pedalHoldLimit")
        #expect(pedal["nilResolvesTo"]?.stringValue == "unlimited")
        #expect(pedal["effective"]?.stringValue == "unlimited")
    }

    @Test("m39-f: describeSynth reports the engine-applied value, not just the stored one")
    func synthDescribeReportsEffectiveValues() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        var params = synthAllRichness
        params["trackId"] = .string(trackID)
        params["kind"] = .string("polySynth")
        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument", params: params))

        let payload = try await synthDescribe(router, trackID)
        let parameters = try synthNested(payload, "parameters")
        // Settable ⇒ readable. A value written through one verb and invisible
        // through the other is the settable-but-unreadable shape this family of
        // describe verbs exists to end.
        for (key, value) in synthAllRichness {
            let spec = try synthNested(parameters, key)
            #expect(spec["value"] == value, "\(key): describeSynth did not read back what was set")
            #expect(spec["isSet"]?.boolValue == true, "\(key) is set and must say so")
        }

        let derived = try synthNested(payload, "derived")
        #expect(derived["unisonIsEffective"]?.boolValue == true, "5 voices")
        #expect(derived["subIsEffective"]?.boolValue == true, "subLevel 0.4")
        #expect(derived["noiseIsEffective"]?.boolValue == true, "noiseLevel 0.2")
        #expect(derived["driveIsEffective"]?.boolValue == true, "drive 0.45")
        #expect(derived["cutoffIsPerVoice"]?.boolValue == true, "velocity + key tracking")
        // effectiveQ must reflect the BOOST, not the legacy mapping alone —
        // the number a caller would otherwise re-derive wrongly.
        let q = try #require(derived["effectiveQ"]?.doubleValue)
        #expect(q > 0.5 + 0.1 * 9.5, "resonanceBoost 0.7 must push Q above the legacy ceiling")
    }

    /// ⛔ THE VERB'S REASON FOR EXISTING. Four settings are gated by a SECOND
    /// setting and do nothing alone. Accepted, stored, echoed back, silent — the
    /// shape `instrument.describeSampler` grew its glide warnings for.
    @Test("m39-f: describeSynth WARNS about settings that are stored but inert")
    func synthDescribeWarnsAboutInertSettings() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        // Detune + spread with one voice; octave + shape with no sub; colour
        // with no noise. Every one of these is a legal, accepted write.
        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "unisonDetuneCents": .number(20), "unisonStereoSpread": .number(0.5),
                     "subOctave": .number(-2), "subWaveform": .string("square"),
                     "noiseColor": .number(0.9)]))

        let payload = try await synthDescribe(router, trackID)
        guard case .array(let warnings)? = payload["warnings"] else {
            Issue.record("no warnings array on a patch with four inert settings"); return
        }
        let text = warnings.compactMap(\.stringValue).joined(separator: "\n")
        #expect(text.contains("unisonDetuneCents"), "\(text)")
        #expect(text.contains("unisonStereoSpread"), "\(text)")
        #expect(text.contains("subOctave"), "\(text)")
        #expect(text.contains("noiseColor"), "\(text)")
        // Each warning says how to make it audible, not just that it is not.
        #expect(text.contains("Raise unisonVoices"), "\(text)")
        #expect(text.contains("Raise subLevel"), "\(text)")

        // NEGATIVE CONTROL: the same probe on a patch where nothing is inert
        // must produce NO warnings key at all. Without this, "warnings present"
        // could just mean "this verb always warns".
        let (router2, store2) = synthMakeRouter()
        let clean = store2.addTrack(kind: .instrument).id.uuidString
        _ = await router2.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(clean), "kind": .string("polySynth"),
                     "unisonVoices": .number(4), "unisonDetuneCents": .number(20),
                     "subLevel": .number(0.4), "subOctave": .number(-2),
                     "noiseLevel": .number(0.3), "noiseColor": .number(0.9)]))
        let cleanPayload = try await synthDescribe(router2, clean)
        #expect(cleanPayload["warnings"] == nil,
                "nothing is inert here — an always-present warnings key is noise")
    }

    @Test("m39-f: describeSynth says when the synth is not the instrument actually sounding")
    func synthDescribeFlagsAnInactiveSynth() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        _ = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth"),
                     "unisonVoices": .number(4)]))
        let active = try await synthDescribe(router, trackID)
        #expect(active["isActiveInstrument"]?.boolValue == true)
        #expect(active["warnings"] == nil, "control: an active synth gets no kind warning")

        // Switch the track to the Sampler. The synth patch SURVIVES (settings
        // are carried across kind switches) but nothing of it is sounding.
        _ = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler")]))
        let inactive = try await synthDescribe(router, trackID)
        #expect(inactive["isActiveInstrument"]?.boolValue == false)
        #expect(inactive["kind"]?.stringValue == "sampler")
        // The patch is still described, and still intact.
        let parameters = try synthNested(inactive, "parameters")
        #expect(try synthNested(parameters, "unisonVoices")["value"]?.doubleValue == 4)
        guard case .array(let warnings)? = inactive["warnings"] else {
            Issue.record("a non-sounding synth must say so"); return
        }
        #expect(warnings.compactMap(\.stringValue).joined().contains("not sounding") == true
                || warnings.compactMap(\.stringValue).joined().contains("NONE of") == true,
                "\(warnings)")
    }

    @Test("m39-f: describeSynth answers for a never-configured track with the defaults")
    func synthDescribeAnswersForAnUntouchedTrack() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(store.tracks[0].instrument == nil, "precondition: never configured")

        // Deliberately NOT a refusal: unlike a sampler (whose zones can
        // genuinely be absent), every instrument track HAS a poly synth — the
        // default one — and that is exactly the patch track.setInstrument would
        // overlay onto.
        let payload = try await synthDescribe(router, trackID)
        #expect(payload["kind"]?.stringValue == "polySynth")
        let parameters = try synthNested(payload, "parameters")
        let fresh = PolySynthParams()
        #expect(try synthNested(parameters, "cutoffHz")["value"]?.doubleValue == fresh.cutoffHz)
        #expect(try synthNested(parameters, "waveform")["value"]?.stringValue
                == fresh.waveform.rawValue)
    }

    @Test("m39-f: describeSynth's refusals mirror track.setInstrument's own")
    func synthDescribeRefusals() async throws {
        let (router, store) = synthMakeRouter()
        let audioID = store.addTrack(kind: .audio).id.uuidString

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "instrument.describeSynth",
            params: ["trackId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)

        let onAudio = await router.handle(ControlRequest(
            id: "2", command: "instrument.describeSynth",
            params: ["trackId": .string(audioID)]))
        #expect(!onAudio.ok)
        #expect(onAudio.error == "track kind 'audio' cannot host an instrument — only instrument "
                + "tracks carry an instrument (add one with track.add kind=instrument)",
                "the wording is the one track.setInstrument throws: \(onAudio.error ?? "")")

        let instID = store.addTrack(kind: .instrument).id.uuidString
        let badKey = await router.handle(ControlRequest(
            id: "3", command: "instrument.describeSynth",
            params: ["trackId": .string(instID), "verbose": .bool(true)]))
        #expect(!badKey.ok, "a read-only verb is not exempt from the unknown-key guard")
        #expect(badKey.error?.contains("verbose") == true, "\(badKey.error ?? "")")
    }

    /// ⭐⭐ THE BIJECTION, MEASURED AGAINST THE VERB'S OWN SELF-DESCRIPTION
    /// RATHER THAN A SECOND HAND-WRITTEN LIST. `rejectUnknownKeys` prints every
    /// valid key when it refuses one, so the set `track.setInstrument` really
    /// accepts can be read out of the running router. If someone adds a 25th
    /// poly-synth parameter and forgets `instrument.describeSynth`, THIS fails
    /// — which a hard-coded expected list could never do.
    @Test("m39-f: describeSynth lists exactly the poly-synth parameters setInstrument accepts")
    func synthDescribeListsEverySettableParameter() async throws {
        let (router, store) = synthMakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let refusal = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "zzNotAKey": .number(1)]))
        #expect(!refusal.ok)
        let message = try #require(refusal.error)
        let marker = "valid keys are "
        guard let range = message.range(of: marker) else {
            Issue.record("the refusal no longer lists valid keys: \(message)"); return
        }
        let advertised = Set(message[range.upperBound...]
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "' .")) })
        // POSITIVE CONTROL on the parse itself: a key everybody knows is there.
        #expect(advertised.contains("cutoffHz"),
                "the allow-list parse is broken, so any comparison below is meaningless")

        // The keys that are NOT poly-synth parameters: the track selector, the
        // kind switch, and the FOUR wholesale instrument configs — `drumKit`
        // joined at m39-dm and belongs here for the same reason `sampler` does:
        // it configures a different instrument wholesale, so `describeSynth`
        // must not be expected to list it as a poly-synth parameter.
        let nonParameters: Set<String> = [
            "trackId", "kind", "sampler", "audioUnit", "soundBank", "drumKit",
        ]
        let settableParameters = advertised.subtracting(nonParameters)

        let parameters = try synthNested(try await synthDescribe(router, trackID), "parameters")
        let described = Set(parameters.keys)

        let undescribed = settableParameters.subtracting(described).sorted()
        let unsettable = described.subtracting(settableParameters).sorted()
        #expect(described == settableParameters, """
            instrument.describeSynth and track.setInstrument disagree about the Poly Synth's \
            parameters. Settable but undescribed: \(undescribed). \
            Described but not settable: \(unsettable).
            """)
    }

    /// The prose has ONE home (`PolySynthDescription.meanings`), shared by this
    /// verb and by `track.setInstrument`'s range errors. A parameter added to
    /// `order` without a meaning would otherwise ship an error that trails off.
    @Test("m39-f: every described parameter carries a non-empty meaning and unit")
    func synthEveryParameterCarriesMeaningAndUnit() {
        for name in PolySynthDescription.order {
            #expect(PolySynthDescription.meanings[name]?.isEmpty == false,
                    "\(name) has no entry in PolySynthDescription.meanings")
            #expect(PolySynthDescription.units[name]?.isEmpty == false,
                    "\(name) has no entry in PolySynthDescription.units")
        }
        // And nothing is documented that is not described — a stale entry left
        // behind by a renamed field would otherwise sit here unnoticed.
        #expect(Set(PolySynthDescription.meanings.keys) == Set(PolySynthDescription.order))
        #expect(Set(PolySynthDescription.units.keys) == Set(PolySynthDescription.order))
    }
}
