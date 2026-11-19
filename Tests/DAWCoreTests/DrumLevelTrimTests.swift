import DAWCore
import Foundation
import Testing

/// W8-HAT (m39 wave 4, `dm-hat-gain`) — the drum machine's two appended level
/// trims, `kit.hatsLevelDb` and `kit.cymbalsLevelDb`: the MODEL half.
///
/// ⛔⛔ THE SHIPPED-TONE LAW, AND WHY THIS FILE DECODES JSON RATHER THAN
/// CONSTRUCTING KITS. A saved project with the trims ABSENT must decode to
/// exactly today's sound. A byte gate over renders is provably blind to a
/// `Codable` decode default (measured in this tree): the render is identical
/// precisely because the default restored the old behaviour, so it is green
/// whether the key is handled right, wrong, or not at all. Only a fixture that
/// OMITS THE KEYS can tell those apart.
///
/// ⭐ THE NEUTRAL IS NOT THE NEW-KIT DEFAULT. Today both are 0 dB, so every
/// assertion below compares against `savedKitLevelTrimDb` — the value that
/// must hold for an old file FOREVER — and never against `DrumKitParams()`,
/// whose trims the user's pick will raise. A test written against
/// `DrumKitParams()` would pass today and silently follow the pick.
///
/// Deliberately NOT `@MainActor`: everything here is a pure value type.
@Suite("Drum kit — W8-HAT level trims (model, decode, tripwire)")
struct DrumLevelTrimTests {

    private static let trimKeys = ["hatsLevelDb", "cymbalsLevelDb"]

    // MARK: - The decode half of the shipped-tone law

    /// ⛔ BYTES WRITTEN BEFORE THE TRIMS EXISTED: the two pre-TPL-0 fixtures
    /// `DrumKitNoteLayoutTests` already freezes (the factory kit, and the
    /// `lofi` preset with its hat chokes cleared, the rim in group 5 and
    /// `kick.decay` 1.3). Neither carries a trim key.
    @Test("A kit saved before the trims decodes to the saved-kit neutral and re-saves byte for byte")
    func oldKitDecodesToTheSavedNeutral() throws {
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys]
        for (name, old) in [("default", DrumKitNoteLayoutTests.preTPL0DefaultKitCompact),
                            ("custom", DrumKitNoteLayoutTests.preTPL0CustomKitCompact)] {
            for key in Self.trimKeys {
                #expect(old.contains(key) == false, "the \(name) fixture already carries \(key)")
            }
            let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(old.utf8))
            #expect(kit.hatsLevelDb == DrumKitParams.savedKitLevelTrimDb,
                    "an old \(name) kit decoded hats \(kit.hatsLevelDb) dB")
            #expect(kit.cymbalsLevelDb == DrumKitParams.savedKitLevelTrimDb,
                    "an old \(name) kit decoded cymbals \(kit.cymbalsLevelDb) dB")
            let again = String(decoding: try compact.encode(kit), as: UTF8.self)
            #expect(again == old, "the \(name) kit's saved bytes changed")
        }
        // The custom fixture really is the non-default kit it says it is.
        let custom = try JSONDecoder().decode(
            DrumKitParams.self, from: Data(DrumKitNoteLayoutTests.preTPL0CustomKitCompact.utf8))
        #expect(custom.kick.decay == 1.3)
    }

    /// The saved-kit neutral is 0 dB and multiplies by EXACTLY 1.0. If anyone
    /// ever edits the constant, this — and every saved kit — notices.
    @Test("The saved-kit neutral is 0 dB, unity gain")
    func savedNeutralIsUnity() {
        #expect(DrumKitParams.savedKitLevelTrimDb == 0)
        #expect(DrumKitParams.levelTrimGain(dB: DrumKitParams.savedKitLevelTrimDb) == 1.0)
    }

    @Test("A kit with non-neutral trims saves both keys and reopens whole")
    func trimsRoundTrip() throws {
        var kit = DrumKitParams()
        kit.noteLayout = .gm
        // A mutating call cannot sit inside `#expect` (the macro hands the
        // receiver over as an immutable `$0`), so each result is taken first.
        let tookHats = kit.setValue(23.4, forParamName: "kit.hatsLevelDb")
        let tookCymbals = kit.setValue(5.7, forParamName: "kit.cymbalsLevelDb")
        #expect(tookHats && tookCymbals)
        let data = try JSONEncoder().encode(kit)
        let text = String(decoding: data, as: UTF8.self)
        for key in Self.trimKeys { #expect(text.contains("\"\(key)\""), "\(key) was not saved") }
        let reopened = try JSONDecoder().decode(DrumKitParams.self, from: data)
        #expect(reopened == kit, "whole-struct round trip lost something")
        #expect(reopened.hatsLevelDb == 23.4 && reopened.cymbalsLevelDb == 5.7)
    }

    /// The encode half of "a kit saved today re-saves byte for byte": a trim at
    /// the saved-kit neutral is OMITTED. Positive control: a non-neutral trim
    /// IS written, so the omission is the rule, not a broken encoder.
    @Test("A trim at the saved-kit neutral is not written; any other value is")
    func neutralTrimsAreOmitted() throws {
        var neutral = DrumKitParams()
        neutral.hatsLevelDb = DrumKitParams.savedKitLevelTrimDb
        neutral.cymbalsLevelDb = DrumKitParams.savedKitLevelTrimDb
        let neutralText = String(decoding: try JSONEncoder().encode(neutral), as: UTF8.self)
        for key in Self.trimKeys {
            #expect(neutralText.contains(key) == false, "\(key) written at the neutral")
        }
        var moved = neutral
        moved.hatsLevelDb = -3
        let movedText = String(decoding: try JSONEncoder().encode(moved), as: UTF8.self)
        #expect(movedText.contains("\"hatsLevelDb\""))
        #expect(movedText.contains("cymbalsLevelDb") == false)
    }

    // MARK: - ⛔ THE TRIPWIRE FOR THE PICK

    /// ⛔⛔ A DRUM MACHINE THAT WAS NEVER EDITED IS SAVED WITH NO KIT AT ALL.
    /// `track.setInstrument` with only `kind: drumSynth` (the picker's path)
    /// leaves `drumKit` nil, and `resolvedDrumKit` turns nil into
    /// `DrumKitParams()` — the NEW-kit default. So the decode test above stays
    /// green while raising `newKitHatsLevelDb` would change every such saved
    /// project. This passes today (both are 0 dB) and goes RED the moment the
    /// pick raises a new-kit constant without first making the nil path
    /// resolve to the saved-kit neutral (`Model.swift`'s `resolvedDrumKit`,
    /// and the `kit ?? DrumKitParams()` overlay in `ProjectStore.setInstrument`).
    @Test("TRIPWIRE: a never-edited drum machine keeps today's trims")
    func aNeverEditedDrumMachineKeepsTodaysTrims() {
        let neverEdited = InstrumentDescriptor(kind: .drumSynth)
        #expect(neverEdited.drumKit == nil, "the scenario needs a nil kit")
        #expect(neverEdited.resolvedDrumKit.hatsLevelDb == DrumKitParams.savedKitLevelTrimDb,
                "a saved drum machine with no kit would play its hats at a NEW level")
        #expect(neverEdited.resolvedDrumKit.cymbalsLevelDb == DrumKitParams.savedKitLevelTrimDb,
                "a saved drum machine with no kit would play its cymbals at a NEW level")
    }

    // MARK: - Which drums a trim reaches

    @Test("The hats trim reaches the two hats, the cymbals trim the cymbal, nothing else")
    func trimsReachOnlyTheirVoices() {
        for voice in DrumVoice.allCases {
            let leaf = DrumKitParams.levelTrimLeaf(for: voice)
            switch voice {
            case .closedHat, .openHat: #expect(leaf == .hatsLevelDb, "\(voice)")
            case .cymbal: #expect(leaf == .cymbalsLevelDb, "\(voice)")
            default: #expect(leaf == nil, "\(voice) is reached by a trim")
            }
        }
        // In General MIDI terms: closed, pedal and open hat; every crash/ride.
        let hats = DrumNoteLayout.generalMIDIPercussionNotes.filter {
            DrumVoice.voice(forNote: $0, layout: .gm).flatMap(DrumKitParams.levelTrimLeaf(for:))
                == .hatsLevelDb
        }
        #expect(hats == [42, 44, 46])
        let cymbals = DrumNoteLayout.generalMIDIPercussionNotes.filter {
            DrumVoice.voice(forNote: $0, layout: .gm).flatMap(DrumKitParams.levelTrimLeaf(for:))
                == .cymbalsLevelDb
        }
        #expect(cymbals == [49, 51, 52, 53, 55, 57, 59])
        // The stored value each voice reads is its own trim's.
        var kit = DrumKitParams()
        kit.hatsLevelDb = 7
        kit.cymbalsLevelDb = -5
        #expect(kit.levelTrimDb(for: .openHat) == 7)
        #expect(kit.levelTrimDb(for: .cymbal) == -5)
        #expect(kit.levelTrimDb(for: .snare) == 0)
    }

    // MARK: - The two spec rows

    @Test("Both trims are appended kit rows: dB, linear, latched, modulatable, clamped")
    func trimRowsAreWellFormed() throws {
        let names = DrumKitParams.paramSpecs.map(\.name)
        #expect(Array(names.suffix(2)) == ["kit.hatsLevelDb", "kit.cymbalsLevelDb"],
                "the trims must be APPENDED, after every m39-dm row")
        let rows: [(String, ClosedRange<Double>, Double)] = [
            ("kit.hatsLevelDb", DrumKitParams.hatsLevelDbRange, DrumKitParams.newKitHatsLevelDb),
            ("kit.cymbalsLevelDb", DrumKitParams.cymbalsLevelDbRange,
             DrumKitParams.newKitCymbalsLevelDb),
        ]
        let instrumentSpecs = InstrumentParamSpec.specs(for: .drumSynth)
        for (name, range, newKitDefault) in rows {
            let spec = try #require(DrumKitParams.paramSpecs.first { $0.name == name })
            #expect(spec.voice == nil)
            #expect(spec.unit == "dB")
            #expect(spec.curve == .linear)
            #expect(spec.range == range)
            #expect(spec.range.contains(DrumKitParams.savedKitLevelTrimDb))
            #expect(spec.defaultValue == newKitDefault)
            #expect(spec.appliesAtNextNoteOn)
            #expect(spec.note?.isEmpty == false)
            let instrumentSpec = try #require(instrumentSpecs.first { $0.name == name })
            #expect(instrumentSpec.modulatable == .yes)

            var kit = DrumKitParams()
            let tookHigh = kit.setValue(1_000, forParamName: name)
            #expect(tookHigh && kit.value(forParamName: name) == range.upperBound)
            let tookLow = kit.setValue(-1_000, forParamName: name)
            #expect(tookLow && kit.value(forParamName: name) == range.lowerBound)
            let tookNaN = kit.setValue(.nan, forParamName: name)
            #expect(tookNaN == false, "NaN must be refused")
            #expect(kit.value(forParamName: name) == range.lowerBound)
        }
    }

    // MARK: - dB to gain

    @Test("levelTrimGain is exactly unity at 0 dB and 20·log10 everywhere else")
    func levelTrimGainIsExact() {
        #expect(DrumKitParams.levelTrimGain(dB: 0) == 1.0)
        #expect(DrumKitParams.levelTrimGain(dB: -0.0) == 1.0)
        #expect(DrumKitParams.levelTrimGain(dB: .nan) == 1.0)
        #expect(DrumKitParams.levelTrimGain(dB: .infinity) == 1.0)
        for dB in [-24.0, -6, 5.7, 6, 23.4, 36] {
            let gain = DrumKitParams.levelTrimGain(dB: dB)
            #expect(abs(20 * log10(gain) - dB) < 1e-9, "\(dB) dB gave \(gain)")
        }
        // Beyond the widest range it holds at the bound rather than running away.
        #expect(DrumKitParams.levelTrimGain(dB: 120) == DrumKitParams.levelTrimGain(dB: 36))
    }
}
