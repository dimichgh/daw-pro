import DAWCore
import Foundation
import Testing

/// m39-dm step 1 — the drum kit MODEL: the 75-name table, name-addressed
/// access, range clamping, the preset set, and the two decode guards.
///
/// ⛔⛔ THE TWO-GUARD RULE IS WHY HALF THIS FILE EXISTS. A byte gate over
/// renders is PROVABLY blind to a `Codable` decode default: the render is
/// identical precisely because the default restored the old behaviour, so the
/// gate is green whether the key is handled correctly, handled wrongly, or not
/// handled at all. Only a JSON fixture that OMITS THE KEY can tell those apart,
/// and an initialiser default is not such a fixture — it exercises the
/// initialiser, not the decoder.
@Suite("Drum kit — model, table and persistence")
struct DrumKitTests {

    // MARK: - The table

    /// The per-scope counts from the design's §3.5 table, written out by hand.
    /// Deriving them from `paramSpecs` would make this assertion agree with
    /// whatever the table happens to contain.
    private static let expectedCounts: [String: Int] = [
        "kick": 10, "snare": 10, "closedHat": 8, "openHat": 8,
        "clap": 9, "tom": 9, "rim": 8, "cymbal": 9, "kit": 4,
    ]

    @Test("The table carries exactly 75 names, in the designed per-scope split")
    func tableIsSeventyFiveNames() {
        #expect(DrumKitParams.paramSpecs.count == 75)
        #expect(Self.expectedCounts.values.reduce(0, +) == 75)
        for (scope, expected) in Self.expectedCounts {
            let actual = DrumKitParams.paramSpecs.filter {
                ($0.voice?.rawValue ?? "kit") == scope
            }.count
            #expect(actual == expected, "\(scope) has \(actual) names, expected \(expected)")
        }
    }

    @Test("Every name and every render code is unique")
    func namesAndCodesAreUnique() {
        let names = DrumKitParams.paramSpecs.map(\.name)
        #expect(Set(names).count == names.count)
        let codes = DrumKitParams.paramSpecs.map(\.code)
        #expect(Set(codes).count == codes.count)
    }

    /// ⭐ The bias that keeps drum codes disjoint from `InstrumentParamID.code`
    /// (0…6). The two can never share a snapshot today, but a lookup that is
    /// correct only because of an invariant in another file is this tree's
    /// characteristic failure shape.
    @Test("Drum render codes cannot collide with polySynth param codes")
    func drumCodesAreDisjointFromPolySynthCodes() {
        let polySynth = Set(InstrumentParamID.allCases.map(\.code))
        let drum = Set(DrumKitParams.paramSpecs.map(\.code))
        #expect(polySynth.isDisjoint(with: drum))
        #expect(drum.allSatisfy { $0 >= 0x1000 })
    }

    @Test("Every dotted name parses as scope + leaf and matches its spec")
    func namesAreWellFormed() {
        for spec in DrumKitParams.paramSpecs {
            let parts = spec.name.split(separator: ".", maxSplits: 1)
            #expect(parts.count == 2, "\(spec.name) is not dotted")
            #expect(String(parts[0]) == (spec.voice?.rawValue ?? "kit"))
            #expect(String(parts[1]) == spec.leaf.rawValue)
        }
    }

    @Test("Every default sits inside its own range, and a fresh kit reads it back")
    func defaultsAreInRangeAndLive() {
        let kit = DrumKitParams()
        for spec in DrumKitParams.paramSpecs {
            #expect(spec.range.contains(spec.defaultValue),
                    "\(spec.name) default \(spec.defaultValue) outside \(spec.range)")
            let live = kit.value(forParamName: spec.name)
            #expect(live == spec.defaultValue,
                    "\(spec.name) reads \(String(describing: live)), table says \(spec.defaultValue)")
            // A logarithmic curve divides by log(lo); lo <= 0 poisons it.
            if spec.curve == .logarithmic {
                #expect(spec.range.lowerBound > 0,
                        "\(spec.name) is logarithmic with lowerBound \(spec.range.lowerBound)")
            }
        }
    }

    /// ⭐ The one-shot contract: everything latches at note-on EXCEPT the two
    /// output-stage parameters. Stated as a count as well as a predicate, so
    /// adding a third continuous parameter has to come here and say so.
    @Test("Exactly level and pan are continuous; the other 59 voice names latch")
    func latchingContractHolds() {
        let continuous = DrumKitParams.paramSpecs.filter { !$0.appliesAtNextNoteOn }
        #expect(continuous.count == 16)  // 8 voices × (level, pan)
        #expect(continuous.allSatisfy { $0.leaf == .level || $0.leaf == .pan })
        #expect(DrumKitParams.paramSpecs.filter { $0.leaf == .level }.count == 8)
        #expect(DrumKitParams.paramSpecs.filter { $0.leaf == .pan }.count == 8)
    }

    /// Every voice's `snap` carries its OWN meaning line. The design accepts one
    /// polysemous name only because `note` exists to disambiguate it — so an
    /// empty or duplicated note is a real defect, not a cosmetic one.
    @Test("Each voice's snap carries a distinct teaching note")
    func snapNotesAreDistinctPerVoice() {
        let snapNotes = DrumKitParams.paramSpecs
            .filter { $0.leaf == .snap }
            .map { $0.note ?? "" }
        #expect(snapNotes.count == 8)
        #expect(snapNotes.allSatisfy { !$0.isEmpty })
        #expect(Set(snapNotes).count == 8, "two voices share a snap note")
    }

    // MARK: - Name-addressed access

    @Test("setValue clamps to the spec range and refuses an unknown name")
    func setValueClampsAndRefuses() {
        var kit = DrumKitParams()
        let high = kit.setValue(500, forParamName: "kick.tune")
        #expect(high)
        #expect(kit.kick.tune == DrumKitParams.kickTuneRange.upperBound)
        let low = kit.setValue(-99, forParamName: "kick.tune")
        #expect(low)
        #expect(kit.kick.tune == DrumKitParams.kickTuneRange.lowerBound)

        let before = kit
        let typo = kit.setValue(1, forParamName: "kik.tune")
        let scopeOnly = kit.setValue(1, forParamName: "kick")
        let empty = kit.setValue(1, forParamName: "")
        #expect(typo == false)
        #expect(scopeOnly == false)
        #expect(empty == false)
        #expect(kit == before, "a refused name still mutated the kit")
    }

    /// ⛔ NaN survives `min`/`max` unchanged — every comparison against NaN is
    /// false — so clamping CANNOT stop it, and the render thread turns several
    /// of these into sample counts with `Int(...)`, which TRAPS. Refusal is the
    /// only correct answer.
    @Test("A non-finite value is refused outright, not clamped")
    func nonFiniteIsRefused() {
        var kit = DrumKitParams()
        let before = kit
        let nan = kit.setValue(.nan, forParamName: "kick.decay")
        let posInf = kit.setValue(.infinity, forParamName: "clap.spread")
        let negInf = kit.setValue(-.infinity, forParamName: "kit.gain")
        #expect(nan == false)
        #expect(posInf == false)
        #expect(negInf == false)
        #expect(kit == before)
        #expect(kit.kick.decay.isFinite)
        // The control: a finite value on the same names IS accepted.
        let finite = kit.setValue(0.5, forParamName: "kick.decay")
        #expect(finite)
        #expect(kit.kick.decay == 0.5)
    }

    /// The uniform `DrumVoiceParams` struct carries fields that only some
    /// voices use. They must be unreachable BY NAME — `kick.band` is not a
    /// parameter, and no amount of struct layout may make it one.
    @Test("Only table names are addressable — inert struct fields stay unreachable")
    func onlyTableNamesAreAddressable() {
        var kit = DrumKitParams()
        for bogus in ["kick.band", "kick.spread", "rim.noiseTone",
                      "closedHat.pitchAmount", "cymbal.partial2Ratio",
                      "kit.tune", "kick.gain", "kick.chokeGroup",
                      "tom.pitchDecay"] {
            #expect(kit.value(forParamName: bogus) == nil, "\(bogus) resolved")
            let took = kit.setValue(1, forParamName: bogus)
            #expect(took == false, "\(bogus) was settable")
        }
        // Positive control: names that ARE in the table resolve.
        for real in ["kick.pitchDecay", "cymbal.band", "clap.spread",
                     "snare.noiseTone", "tom.pitchAmount", "kit.gain"] {
            #expect(kit.value(forParamName: real) != nil, "\(real) did NOT resolve")
        }
    }

    // MARK: - Persistence (the two-guard rule)

    /// GUARD 1 — the full round trip. Whole-struct equality, never
    /// field-by-field: the `richnessSurvivesAnUnrelatedKnobEdit` rule.
    @Test("All 75 names survive a save/open round trip, whole-struct")
    func everyNameRoundTrips() throws {
        var kit = DrumKitParams()
        // Move EVERY name off its default, to a value inside its own range.
        for spec in DrumKitParams.paramSpecs {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            var target = lo + (hi - lo) * 0.37
            if abs(target - spec.defaultValue) < 1e-9 { target = lo + (hi - lo) * 0.63 }
            let took = kit.setValue(target, forParamName: spec.name)
            #expect(took, "\(spec.name) refused an in-range value")
        }
        kit.closedHat.chokeGroup = 7
        kit.openHat.chokeGroup = 7
        kit.tom.chokeGroup = 12

        let data = try JSONEncoder().encode(kit)
        let reopened = try JSONDecoder().decode(DrumKitParams.self, from: data)
        #expect(reopened == kit)

        // And every name individually differs from its default, so the round
        // trip above was actually carrying information.
        for spec in DrumKitParams.paramSpecs {
            #expect(reopened.value(forParamName: spec.name) != spec.defaultValue,
                    "\(spec.name) came back at its default — nothing was tested")
        }
    }

    /// ⛔ GUARD 2 — A FIXTURE THAT OMITS KEYS. This is the half a byte gate over
    /// renders cannot see. A project saved before a parameter existed has no
    /// key for it, and must decode to that parameter's default, which IS the
    /// old behaviour.
    @Test("A kit JSON that omits almost every key decodes to the defaults")
    func omittedKeysDecodeToDefaults() throws {
        // Two keys present, seventy-three absent. Note there is no `kit` block,
        // no `cymbal` block, and no `chokeGroup` anywhere.
        let json = #"{"kick":{"tune":40},"snare":{"decay":0.5}}"#
        let kit = try JSONDecoder().decode(DrumKitParams.self,
                                           from: Data(json.utf8))
        #expect(kit.kick.tune == 40)
        #expect(kit.snare.decay == 0.5)
        // Everything else at its default — checked through the table, so a 76th
        // parameter is covered the day it is added.
        for spec in DrumKitParams.paramSpecs
        where spec.name != "kick.tune" && spec.name != "snare.decay" {
            #expect(kit.value(forParamName: spec.name) == spec.defaultValue,
                    "\(spec.name) did not decode to its default")
        }
    }

    /// ⛔⛔ THE CHOKE-GROUP ASYMMETRY, AND IT IS THE LANDMINE IN THIS FILE.
    /// The hats DEFAULT to group 0. If an omitted `chokeGroup` fell back to the
    /// default the way every numeric parameter does, then a user who
    /// deliberately CLEARS the hat choke would store nil, `encodeIfPresent`
    /// would omit the key, and the loader would silently restore the choke on
    /// every reopen — the user's edit undone with no error anywhere.
    /// An initialiser default cannot pin this. Only this fixture can.
    @Test("A cleared choke group stays cleared across a reopen")
    func clearedChokeGroupSurvivesAReopen() throws {
        var kit = DrumKitParams()
        #expect(kit.closedHat.chokeGroup == 0, "the hats must ship chocked")
        #expect(kit.openHat.chokeGroup == 0)

        kit.closedHat.chokeGroup = nil
        kit.openHat.chokeGroup = nil
        let data = try JSONEncoder().encode(kit)
        // The key is genuinely absent from the bytes — not merely written null.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("chokeGroup") == false,
                "chokeGroup was still encoded after being cleared")

        let reopened = try JSONDecoder().decode(DrumKitParams.self, from: data)
        #expect(reopened.closedHat.chokeGroup == nil,
                "the loader resurrected a choke the user cleared")
        #expect(reopened.openHat.chokeGroup == nil)
        #expect(reopened == kit)

        // Positive control on the same path: a SET group does round trip.
        var chocked = DrumKitParams()
        chocked.rim.chokeGroup = 5
        let back = try JSONDecoder().decode(
            DrumKitParams.self, from: try JSONEncoder().encode(chocked))
        #expect(back.rim.chokeGroup == 5)
    }

    /// The hand-written fixture form of the same guard: a `closedHat` block
    /// that carries params but NO `chokeGroup` key at all.
    @Test("A voice block with no chokeGroup key decodes to nil, not to 0")
    func absentChokeGroupKeyDecodesToNil() throws {
        let json = #"{"closedHat":{"tune":1.0,"decay":0.05}}"#
        let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(json.utf8))
        #expect(kit.closedHat.chokeGroup == nil)
        // Control: the same fixture WITH the key decodes to the key's value.
        let json2 = #"{"closedHat":{"tune":1.0,"chokeGroup":3}}"#
        let kit2 = try JSONDecoder().decode(DrumKitParams.self, from: Data(json2.utf8))
        #expect(kit2.closedHat.chokeGroup == 3)
    }

    @Test("Decode re-clamps an out-of-range or non-finite payload")
    func decodeReclamps() throws {
        let json = #"{"kick":{"tune":99999,"decay":-5},"closedHat":{"chokeGroup":900}}"#
        let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(json.utf8))
        #expect(kit.kick.tune == DrumKitParams.kickTuneRange.upperBound)
        #expect(kit.kick.decay == DrumKitParams.kickDecayRange.lowerBound)
        #expect(kit.closedHat.chokeGroup == 63)
    }

    // MARK: - Voices, notes and presets

    @Test("The eight voices map one-to-one onto pad-grid notes 36…43")
    func voiceNoteMapping() {
        #expect(DrumVoice.allCases.count == 8)
        #expect(Set(DrumVoice.allCases.map(\.note)) == Set(36...43).map { UInt8($0) }.reduce(into: Set<UInt8>()) { $0.insert($1) })
        for voice in DrumVoice.allCases {
            #expect(DrumVoice.voice(forNote: voice.note) == voice)
        }
        #expect(DrumVoice.voice(forNote: 35) == nil)
        #expect(DrumVoice.voice(forNote: 44) == nil)
        #expect(Set(DrumVoice.allCases.map(\.slot)) == Set<Int32>(0...7))
    }

    @Test("Every preset is in range, round trips, and actually differs")
    func presetsAreValid() throws {
        #expect(DrumKitParams.presets.count == 5)
        #expect(Set(DrumKitParams.presets.map(\.name))
            == ["808", "909", "acoustic", "lofi", "trap"])
        let defaults = DrumKitParams()
        for preset in DrumKitParams.presets {
            for spec in DrumKitParams.paramSpecs {
                let value = try #require(preset.params.value(forParamName: spec.name))
                #expect(spec.range.contains(value),
                        "\(preset.name)/\(spec.name) = \(value) outside \(spec.range)")
            }
            let back = try JSONDecoder().decode(
                DrumKitParams.self, from: try JSONEncoder().encode(preset.params))
            #expect(back == preset.params, "\(preset.name) did not round trip")
            if preset.name != "808" {
                #expect(preset.params != defaults,
                        "\(preset.name) is byte-identical to the defaults")
            }
            #expect(preset.summary.isEmpty == false)
        }
        #expect(DrumKitParams.preset(named: "909") != nil)
        #expect(DrumKitParams.preset(named: "9O9") == nil)
    }

    /// The 909 is the 808 with different NUMBERS, and the numbers the design
    /// names are the ones that make it a 909: a deeper, faster sweep and a
    /// much shorter body.
    @Test("The 909 preset differs from the 808 on the axes the design names")
    func nineOhNineDiffersOnTheRightAxes() throws {
        let eight = DrumKitParams()
        let nine = try #require(DrumKitParams.preset(named: "909")).params
        #expect(nine.kick.decay < eight.kick.decay * 0.6)
        #expect(nine.kick.pitchAmount > eight.kick.pitchAmount * 2)
        #expect(nine.kick.pitchDecay < eight.kick.pitchDecay * 0.5)
        #expect(nine.kick.snap > eight.kick.snap * 2)
        #expect(nine.closedHat.decay < eight.closedHat.decay)
    }

    @Test("A choke group resolves to a shift-safe -1…63")
    func chokeGroupResolvesSafely() {
        var v = DrumVoiceParams()
        #expect(v.resolvedChokeGroup == -1)
        v.chokeGroup = 0
        #expect(v.resolvedChokeGroup == 0)
        v = DrumVoiceParams(chokeGroup: 4000)
        #expect(v.resolvedChokeGroup == 63)
        v = DrumVoiceParams(chokeGroup: -7)
        #expect(v.resolvedChokeGroup == 0)
        // ONE HOME for the number: the sampler's range is the drum range.
        #expect(SamplerZone.chokeGroupRange == 0...63)
    }

    @Test("The tom's derived pitch decay resolves the design's own contradiction")
    func tomPitchDecayIsDerived() {
        let tom = DrumKitParams.tomDefault
        let derived = DrumKitParams.tomPitchDecay(forDecay: tom.decay)
        #expect(abs(derived - 0.0684) < 1e-9)
        // It is NOT addressable — that is what holds the tom at nine names.
        #expect(DrumKitParams.spec(forParamName: "tom.pitchDecay") == nil)
        #expect(DrumKitParams.paramSpecs.filter { $0.voice == .tom }.count == 9)
    }
}
