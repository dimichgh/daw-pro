import Foundation
import Testing
@testable import DAWCore

// m34-q — THE PEDAL HOLD LIMIT'S PERSISTENCE PIN.
// m34-s — AND, SINCE 2026-08-31, THE SAVE-FORMAT PIN FOR THE OTHER THIRTEEN
// SAMPLER GLOBALS (Leg F + the spy gate at Leg E). The pedal cap was threaded
// through `SamplerDocument` correctly the first time; four fields that shipped
// BEFORE it — `decay`, `sustain`, `bendRangeSemitones`, `voiceMode` — were not,
// and the spy gate below is what found them.
//
// The item's brief said to CONFIRM, not assume, `decodeIfPresent` semantics for
// old files. Assuming is how a "the absent key decodes to nil" claim becomes a
// comment nobody ever ran. So every claim below is measured in both directions,
// and every absence assertion carries a POSITIVE CONTROL — the same probe, run
// against a value that IS there, shown to come back non-nil. A test that says
// "the key is absent" and would say the same thing if the encoder were broken
// is not evidence of anything.
//
// ⚠️ The interesting fact this suite pins is that `SamplerParams` does NOT
// persist through its own `Codable`. `SamplerDocument` (ProjectDocument.swift)
// is the save format, and a global missing from ITS CodingKeys is silently
// reset the next time the project opens — which is why the document leg here
// matters more than the params leg.
@Suite("Pedal hold limit — Codable + save format (m34-q)")
struct PedalHoldLimitCodableTests {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static func keys(of value: some Encodable) throws -> Set<String> {
        let data = try encoder.encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    /// Re-encode a value's JSON with one key deleted — the honest way to build
    /// "a project saved before this field existed" without hand-typing a
    /// literal that drifts the moment any other field changes.
    private static func jsonWithoutKey(_ key: String, from value: some Encodable) throws -> Data {
        let data = try encoder.encode(value)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Leg A — nil never encodes (with the control that proves the probe works)

    @Test("A default SamplerParams emits no pedalHoldLimit key; a set one does")
    func nilCapIsAbsentFromSamplerParamsJSON() throws {
        let unset = try Self.keys(of: SamplerParams())
        #expect(!unset.contains("pedalHoldLimit"),
                "nil must not encode — a pre-m34-q project's JSON has to stay byte-identical")

        // POSITIVE CONTROL: the same probe, same type, cap set. If this does
        // not fire, the assertion above is measuring nothing.
        let set = try Self.keys(of: SamplerParams(pedalHoldLimit: 6))
        #expect(set.contains("pedalHoldLimit"),
                "control failed: a SET cap must appear, or the absence above proves nothing")
        #expect(set.subtracting(unset) == ["pedalHoldLimit"],
                "the cap must be the ONLY key that appears — additive means additive")
    }

    @Test("A default PolySynthParams emits no pedalHoldLimit key; a set one does")
    func nilCapIsAbsentFromPolySynthParamsJSON() throws {
        let unset = try Self.keys(of: PolySynthParams())
        #expect(!unset.contains("pedalHoldLimit"),
                """
                nil must not encode. This type had never carried an optional before m34-q, \
                so this is the assertion that its fixed key set survived the change.
                """)
        let set = try Self.keys(of: PolySynthParams(pedalHoldLimit: 3))
        #expect(set.contains("pedalHoldLimit"), "control failed: a SET cap must appear")
        #expect(set.subtracting(unset) == ["pedalHoldLimit"])
    }

    @Test("A default SamplerDocument emits no pedalHoldLimit key; a set one does")
    func nilCapIsAbsentFromSamplerDocumentJSON() throws {
        let unset = try Self.keys(of: SamplerDocument(from: SamplerParams(), mediaRefs: [:]))
        #expect(!unset.contains("pedalHoldLimit"),
                "the SAVE FORMAT must stay byte-identical for a project with no cap")
        let set = try Self.keys(of: SamplerDocument(from: SamplerParams(pedalHoldLimit: 12),
                                                    mediaRefs: [:]))
        #expect(set.contains("pedalHoldLimit"), "control failed: a SET cap must be saved")
        #expect(set.subtracting(unset) == ["pedalHoldLimit"])
    }

    // MARK: - Leg B — an absent key decodes to nil (the "old file" direction)

    @Test("A pre-m34-q sampler document — key deleted — decodes with an unlimited cap")
    func absentKeyDecodesAsUnlimitedSamplerDocument() throws {
        let saved = SamplerDocument(from: SamplerParams(attack: 0.02, release: 0.3, gain: 0.55,
                                                        pedalHoldLimit: 9),
                                    mediaRefs: [:])
        let legacy = try Self.jsonWithoutKey("pedalHoldLimit", from: saved)
        let reopened = try JSONDecoder().decode(SamplerDocument.self, from: legacy)
        #expect(reopened.pedalHoldLimit == nil,
                "an absent key must mean UNLIMITED, never 0 and never a crash")
        // The neighbours have to survive the deletion, or this test is really
        // measuring a decoder that gave up.
        #expect(reopened.attack == 0.02)
        #expect(reopened.release == 0.3)
        #expect(reopened.gain == 0.55)

        // POSITIVE CONTROL: the SAME bytes minus the deletion still carry 9.
        let intact = try JSONDecoder().decode(SamplerDocument.self,
                                              from: Self.encoder.encode(saved))
        #expect(intact.pedalHoldLimit == 9,
                "control failed: if the intact document loses the cap too, the nil above is noise")
    }

    @Test("A pre-m34-q poly synth — key deleted — decodes with an unlimited cap")
    func absentKeyDecodesAsUnlimitedPolySynth() throws {
        let saved = PolySynthParams(waveform: .square, attack: 0.01, cutoffHz: 3_000,
                                    pedalHoldLimit: 5)
        let legacy = try Self.jsonWithoutKey("pedalHoldLimit", from: saved)
        let reopened = try JSONDecoder().decode(PolySynthParams.self, from: legacy)
        #expect(reopened.pedalHoldLimit == nil)
        #expect(reopened.waveform == .square)
        #expect(reopened.cutoffHz == 3_000)

        let intact = try JSONDecoder().decode(PolySynthParams.self,
                                              from: Self.encoder.encode(saved))
        #expect(intact.pedalHoldLimit == 5, "control failed")
    }

    @Test("A pre-m34-q sampler params blob — key deleted — decodes with an unlimited cap")
    func absentKeyDecodesAsUnlimitedSamplerParams() throws {
        let saved = SamplerParams(pedalHoldLimit: 40)
        let legacy = try Self.jsonWithoutKey("pedalHoldLimit", from: saved)
        let reopened = try JSONDecoder().decode(SamplerParams.self, from: legacy)
        #expect(reopened.pedalHoldLimit == nil)

        let intact = try JSONDecoder().decode(SamplerParams.self,
                                              from: Self.encoder.encode(saved))
        #expect(intact.pedalHoldLimit == 40, "control failed")
    }

    // MARK: - Leg C — the save→open round trip that is the whole point

    @Test("A sampler cap survives SamplerParams → document → JSON → document → SamplerParams")
    func capSurvivesTheFullSaveOpenRoundTrip() throws {
        let original = SamplerParams(oneShot: false, attack: 0.03, release: 0.6, gain: 0.7,
                                     pedalHoldLimit: 4)
        let data = try Self.encoder.encode(SamplerDocument(from: original, mediaRefs: [:]))
        let reopened = try JSONDecoder().decode(SamplerDocument.self, from: data)
        // The last hop is `instrumentDescriptor`'s reconstruction — rebuilt
        // here field-for-field, because that is the hop where a global gets
        // silently dropped (four of this type's globals are dropped there
        // TODAY; see the m34-q report).
        let restored = SamplerParams(oneShot: reopened.oneShot, attack: reopened.attack,
                                     release: reopened.release, gain: reopened.gain,
                                     pedalHoldLimit: reopened.pedalHoldLimit)
        #expect(restored.pedalHoldLimit == 4,
                "a cap that does not survive a save is not a setting")
        #expect(restored.effectivePedalHoldLimit == 4)
    }

    @Test("A poly-synth cap survives an encode/decode round trip")
    func polySynthCapSurvivesRoundTrip() throws {
        let original = PolySynthParams(waveform: .triangle, release: 0.9, pedalHoldLimit: 7)
        let restored = try JSONDecoder().decode(PolySynthParams.self,
                                                from: Self.encoder.encode(original))
        #expect(restored.pedalHoldLimit == 7)
        #expect(restored.waveform == .triangle)
        #expect(restored.effectivePedalHoldLimit == 7)
    }

    // MARK: - Leg D — nil resolves to unlimited, and the range clamps

    @Test("nil resolves to Int.max on both instruments — the ONE place nil is interpreted")
    func nilResolvesToUnlimited() {
        #expect(SamplerParams().effectivePedalHoldLimit == Int.max)
        #expect(PolySynthParams().effectivePedalHoldLimit == Int.max)
        // The engine's arm condition is `limit <= voiceCount`; Int.max can
        // never satisfy it, which is what makes "unlimited" cost nothing.
        #expect(SamplerParams().effectivePedalHoldLimit > 64)
        #expect(PolySynthParams().effectivePedalHoldLimit > 16)
    }

    @Test("Out-of-range caps clamp rather than throw, and nil stays nil")
    func capClampsToItsRange() {
        #expect(SamplerParams.pedalHoldLimitRange == 1...128)
        // ONE home for the domain: the synth aliases the sampler's range.
        #expect(PolySynthParams.pedalHoldLimitRange == SamplerParams.pedalHoldLimitRange)

        #expect(SamplerParams(pedalHoldLimit: 0).pedalHoldLimit == 1,
                "0 must clamp to 1 — a cap of 0 would silently disable CC 64 entirely")
        #expect(SamplerParams(pedalHoldLimit: -5).pedalHoldLimit == 1)
        #expect(SamplerParams(pedalHoldLimit: 9_999).pedalHoldLimit == 128)
        #expect(SamplerParams(pedalHoldLimit: nil).pedalHoldLimit == nil,
                "nil is not a number to clamp — it must pass through untouched")

        #expect(PolySynthParams(pedalHoldLimit: 0).pedalHoldLimit == 1)
        #expect(PolySynthParams(pedalHoldLimit: 9_999).pedalHoldLimit == 128)
        #expect(PolySynthParams(pedalHoldLimit: nil).pedalHoldLimit == nil)
    }

    // MARK: - Leg E — the SPY gate: drive the REAL save/open path and see what survives

    /// ⭐ Not a source-shape check. This sets every Sampler global to a
    /// non-default, runs the ACTUAL persistence path — `InstrumentDocument` →
    /// JSON → `InstrumentDocument` → `instrumentDescriptor(bundleURL:warn:)` —
    /// and reports which globals came back. It is the pin that would have
    /// caught `pedalHoldLimit` being forgotten in the save format.
    ///
    /// ⚠️ CORRECTION 2026-08-31 (m34-s), the earlier wording kept because the
    /// measurement it records is the reason this test exists: when this gate
    /// was first written it reported FOUR globals that did NOT survive —
    /// `decay`, `sustain`, `bendRangeSemitones`, `voiceMode` were absent from
    /// `SamplerDocument`'s CodingKeys, so a project that set them reopened
    /// without them. That was a PRE-EXISTING defect (measured while threading
    /// `pedalHoldLimit` for m34-q, deliberately not side-fixed there) and it is
    /// FIXED as of m34-s: all four are now threaded through the save format and
    /// have moved from `knownDropped` into `mustSurvive` below, which is
    /// exactly the green-by-shrinking this comment used to prescribe.
    ///
    /// ⭐ WHY IT MATTERED MORE THAN A MISSING FIELD: a nil `decay`/`sustain`
    /// resolves to the pair (0, 1) — hold at peak forever — so losing them on
    /// save brought back the user's ORIGINAL m34-o report ("the note keeps
    /// playing") after any save and reopen.
    ///
    /// ⛔ `knownDropped` is deliberately gone rather than left empty: a
    /// FIFTEENTH global added tomorrow must fail the classification assertion
    /// at the end and force a decision, not slide into a tolerated list.
    @Test("The real save/open path: which Sampler globals survive, measured end to end")
    func samplerGlobalsThatSurviveTheRealSaveOpenPath() throws {
        let configured = SamplerParams(
            oneShot: true, attack: 0.031, release: 0.61, gain: 0.53,
            sourcePath: "/tmp/none.sfz", displayName: "Test Patch",
            expressionModDepth: 0.42, expressionFilterDepth: 0.37, expressionFilterCC: 2,
            bendRangeSemitones: 6, voiceMode: .mono, decay: 1.7, sustain: 0.23,
            pedalHoldLimit: 5)
        let descriptor = InstrumentDescriptor(kind: .sampler, sampler: configured)

        let data = try Self.encoder.encode(InstrumentDocument(from: descriptor, mediaRefs: [:]))
        let reopened = try JSONDecoder().decode(InstrumentDocument.self, from: data)
        var warnings: [String] = []
        let restored = try #require(
            reopened.instrumentDescriptor(bundleURL: URL(fileURLWithPath: "/tmp"),
                                          warn: { warnings.append($0) }).sampler)

        // Name → (survived?) for every global the type carries.
        let survived: [String: Bool] = [
            "oneShot": restored.oneShot == configured.oneShot,
            "attack": restored.attack == configured.attack,
            "release": restored.release == configured.release,
            "gain": restored.gain == configured.gain,
            "sourcePath": restored.sourcePath == configured.sourcePath,
            "displayName": restored.displayName == configured.displayName,
            "expressionModDepth": restored.expressionModDepth == configured.expressionModDepth,
            "expressionFilterDepth":
                restored.expressionFilterDepth == configured.expressionFilterDepth,
            "expressionFilterCC": restored.expressionFilterCC == configured.expressionFilterCC,
            "pedalHoldLimit": restored.pedalHoldLimit == configured.pedalHoldLimit,
            "decay": restored.decay == configured.decay,
            "sustain": restored.sustain == configured.sustain,
            "bendRangeSemitones": restored.bendRangeSemitones == configured.bendRangeSemitones,
            "voiceMode": restored.voiceMode == configured.voiceMode,
        ]
        print("[measured] sampler globals surviving save/open: "
              + survived.keys.sorted().map { "\($0)=\(survived[$0]! ? "yes" : "NO")" }
                  .joined(separator: " "))

        // m34-s: ALL FOURTEEN globals must survive. The last four were the
        // defect — absent from SamplerDocument's CodingKeys until 2026-08-31.
        let mustSurvive = ["oneShot", "attack", "release", "gain", "sourcePath", "displayName",
                           "expressionModDepth", "expressionFilterDepth", "expressionFilterCC",
                           "pedalHoldLimit",
                           "decay", "sustain", "bendRangeSemitones", "voiceMode"]
        for name in mustSurvive {
            #expect(survived[name] == true,
                    """
                    \(name) did not survive a save/open. A sampler global absent from                     SamplerDocument's CodingKeys is silently reset the next time the project                     opens — see ROADMAP m34-s.
                    """)
        }

        #expect(Set(mustSurvive) == Set(survived.keys),
                "every global this type carries must be classified — a new one must be added here")
        #expect(warnings.isEmpty, "a zone-less round trip must not warn: \(warnings)")
    }

    @Test("A cap above the voice pool is reachable and means unlimited in practice")
    func capAboveThePoolIsLegalAndInert() {
        // 128 > 64 sampler voices > 16 synth voices, so the ceiling of the
        // range is itself an "unlimited" value — the reason the ceiling is 128
        // and not, say, 64.
        let sampler = SamplerParams(pedalHoldLimit: 128)
        #expect(sampler.effectivePedalHoldLimit == 128)
        #expect(sampler.effectivePedalHoldLimit > 64)
        let synth = PolySynthParams(pedalHoldLimit: 128)
        #expect(synth.effectivePedalHoldLimit > 16)
    }

    // MARK: - Leg F — m34-s: the four globals that a save used to throw away

    /// The REAL save/open path in one place, so no test here can accidentally
    /// measure `SamplerParams`' own `Codable` — which round-trips all fifteen
    /// fields and therefore says NOTHING about whether a project keeps them.
    /// `SamplerDocument` is the save format; this is the hop that lost four.
    ///
    /// `droppingSamplerKey` deletes one key from the SAVED JSON, which is the
    /// honest way to build "a project written before this field existed";
    /// `overridingSamplerKey` writes a value this build may not know, which is
    /// the shape a project written by a FUTURE build has.
    private static func reopen(_ params: SamplerParams,
                               droppingSamplerKey drop: String? = nil,
                               overridingSamplerKey override: (key: String, value: Any)? = nil)
        throws -> SamplerParams {
        let descriptor = InstrumentDescriptor(kind: .sampler, sampler: params)
        var data = try encoder.encode(InstrumentDocument(from: descriptor, mediaRefs: [:]))
        if drop != nil || override != nil {
            var object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var sampler = try #require(object["sampler"] as? [String: Any])
            if let drop {
                // CONTROL ON THE DELETION ITSELF: deleting a key that was never
                // written proves nothing, and would make every "absent decodes
                // to nil" assertion below pass for the wrong reason.
                #expect(sampler[drop] != nil,
                        "control failed: \(drop) was not in the saved JSON, so deleting it is a no-op")
                sampler.removeValue(forKey: drop)
            }
            if let override { sampler[override.key] = override.value }
            object["sampler"] = sampler
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let reopened = try JSONDecoder().decode(InstrumentDocument.self, from: data)
        var warnings: [String] = []
        let restored = try #require(
            reopened.instrumentDescriptor(bundleURL: URL(fileURLWithPath: "/tmp"),
                                          warn: { warnings.append($0) }).sampler)
        #expect(warnings.isEmpty, "a zone-less round trip must not warn: \(warnings)")
        return restored
    }

    /// ⭐ THE BYTE-COMPAT PIN, and the reason all nine additive globals are
    /// Optional rather than plain: a sampler that sets nothing must keep
    /// emitting EXACTLY the five keys it emitted before any of them existed.
    /// ⚠️ This assertion passes both before and after m34-s — it guards the
    /// fix, it does not demonstrate it.
    @Test("m34-s: a default SamplerDocument still emits exactly its five legacy keys")
    func defaultSamplerDocumentKeySetIsUnchanged() throws {
        let keys = try Self.keys(of: SamplerDocument(from: SamplerParams(), mediaRefs: [:]))
        #expect(keys == ["zones", "oneShot", "attack", "release", "gain"],
                """
                the save format grew a key for a sampler that set NOTHING (got \(keys.sorted())). \
                Every additive global must encode only when set, or every project already on \
                disk changes shape the next time it is saved.
                """)
    }

    /// Each of the four must be emitted ONLY when set, and must add ONLY
    /// itself — the `pedalHoldLimit` discipline applied to the fields that
    /// were forgotten.
    @Test("m34-s: each recovered global encodes only when set, and adds only its own key")
    func recoveredGlobalsEncodeOnlyWhenSet() throws {
        let unset = try Self.keys(of: SamplerDocument(from: SamplerParams(), mediaRefs: [:]))
        let cases: [(name: String, params: SamplerParams)] = [
            ("decay", SamplerParams(decay: 1.7)),
            ("sustain", SamplerParams(sustain: 0.23)),
            ("bendRangeSemitones", SamplerParams(bendRangeSemitones: 6)),
            ("voiceMode", SamplerParams(voiceMode: .mono)),
        ]
        for (name, params) in cases {
            let keys = try Self.keys(of: SamplerDocument(from: params, mediaRefs: [:]))
            #expect(keys.contains(name),
                    """
                    \(name) is SET on the params but absent from the save format — a setting \
                    that is not written is silently reset on the next open. ROADMAP m34-s.
                    """)
            #expect(keys.subtracting(unset) == [name],
                    "setting \(name) must add exactly one key; it added \(keys.subtracting(unset))")
        }
    }

    /// The global decay half of m34-o. ⭐ THE USER-FACING STAKE: nil `decay`
    /// resolves to `defaultDecay` = 0, which with sustain 1 is "hold at peak
    /// forever" — so losing this key on save brought back the exact report
    /// m34-o closed ("the note keeps playing") after any save and reopen.
    @Test("m34-s: a global decay survives the real save/open path; absent still means the legacy 0")
    func globalDecaySurvivesTheSaveOpenPath() throws {
        let configured = SamplerParams(decay: 1.7, sustain: 0.23)
        let restored = try Self.reopen(configured)
        #expect(restored.decay == 1.7, "a decay that does not survive a save is not a setting")
        #expect(restored.effectiveDecay == 1.7)

        // The old-file direction, with the neighbour as the positive control:
        // if `sustain` came back too, then `decay == nil` is a MISSING KEY and
        // not a decoder that gave up on the whole document.
        let legacy = try Self.reopen(configured, droppingSamplerKey: "decay")
        #expect(legacy.decay == nil, "an absent key must decode as nil, never as a stored 0")
        #expect(legacy.effectiveDecay == SamplerParams.defaultDecay)
        #expect(legacy.effectiveDecay == 0, "the documented legacy default, stated as a number")
        #expect(legacy.sustain == 0.23, "control failed: the neighbour must survive the deletion")
    }

    @Test("m34-s: a global sustain survives the real save/open path; absent still means the legacy 1")
    func globalSustainSurvivesTheSaveOpenPath() throws {
        let configured = SamplerParams(decay: 1.7, sustain: 0.23)
        let restored = try Self.reopen(configured)
        #expect(restored.sustain == 0.23)
        #expect(restored.effectiveSustain == 0.23)

        let legacy = try Self.reopen(configured, droppingSamplerKey: "sustain")
        #expect(legacy.sustain == nil)
        #expect(legacy.effectiveSustain == SamplerParams.defaultSustain)
        #expect(legacy.effectiveSustain == 1)
        #expect(legacy.decay == 1.7, "control failed: the neighbour must survive the deletion")
    }

    /// ⚠️ THE DEFAULT STAYS 2.0 AND THE ABSENT-KEY LEG IS WHAT PINS IT: every
    /// bend lane already authored in every existing project was written
    /// against ±2, so an absent key resolving to anything else would rescale
    /// all of them silently on load.
    @Test("m34-s: bendRangeSemitones survives the real save/open path; absent still means 2.0")
    func bendRangeSurvivesTheSaveOpenPath() throws {
        let configured = SamplerParams(bendRangeSemitones: 6, voiceMode: .mono)
        let restored = try Self.reopen(configured)
        #expect(restored.bendRangeSemitones == 6)
        #expect(restored.effectiveBendRangeSemitones == 6)

        let legacy = try Self.reopen(configured, droppingSamplerKey: "bendRangeSemitones")
        #expect(legacy.bendRangeSemitones == nil)
        #expect(legacy.effectiveBendRangeSemitones == SamplerParams.defaultBendRangeSemitones)
        #expect(legacy.effectiveBendRangeSemitones == 2, "the GM default, stated as a number")
        #expect(legacy.voiceMode == .mono, "control failed: the neighbour must survive the deletion")
    }

    @Test("m34-s: voiceMode survives the real save/open path; absent still means poly")
    func voiceModeSurvivesTheSaveOpenPath() throws {
        let configured = SamplerParams(bendRangeSemitones: 6, voiceMode: .mono)
        let restored = try Self.reopen(configured)
        #expect(restored.voiceMode == .mono, "a mono patch that reopens as poly is a changed sound")
        #expect(restored.effectiveVoiceMode == .mono)

        let legacy = try Self.reopen(configured, droppingSamplerKey: "voiceMode")
        #expect(legacy.voiceMode == nil)
        #expect(legacy.effectiveVoiceMode == .poly)
        #expect(legacy.bendRangeSemitones == 6,
                "control failed: the neighbour must survive the deletion")
    }

    /// ⛔ WHY `voiceMode` PERSISTS AS ITS RAW STRING AND IS RESOLVED WITH
    /// `flatMap(init(rawValue:))`, following `SamplerZoneDocument.loopMode`
    /// (m20-g) rather than `pedalHoldLimit`: a strict enum decode THROWS on an
    /// unknown rawValue, and this decoder sits inside the project open. A
    /// third case added by a later build would make every such project
    /// unopenable in this one — the whole document, not just the field.
    @Test("m34-s: an unknown voiceMode rawValue decodes to poly rather than failing the open")
    func unknownVoiceModeIsToleratedRatherThanFailingTheOpen() throws {
        let configured = SamplerParams(gain: 0.53, bendRangeSemitones: 6, voiceMode: .mono)
        let future = try Self.reopen(configured,
                                     overridingSamplerKey: (key: "voiceMode",
                                                             value: "legatoFromTheFuture"))
        #expect(future.voiceMode == nil, "an unknown mode must resolve to nil, never throw")
        #expect(future.effectiveVoiceMode == .poly)
        // The rest of the document must be INTACT — a tolerant decode that
        // quietly dropped its neighbours would be a worse defect than a throw.
        #expect(future.gain == 0.53)
        #expect(future.bendRangeSemitones == 6)

        // POSITIVE CONTROL: the same path with a rawValue this build DOES know
        // must produce `.mono`. Without it, "resolves to nil" is also what a
        // completely broken decode looks like.
        let known = try Self.reopen(configured,
                                    overridingSamplerKey: (key: "voiceMode", value: "mono"))
        #expect(known.voiceMode == .mono, "control failed: a KNOWN rawValue must still resolve")
    }
}
