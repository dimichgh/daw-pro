import Foundation
import Testing
@testable import DAWCore

/// m23-o1 Step 1 — the resolution ladder (design §3 / D2). Legs R1–R7 of
/// design §8.3, plus three Step-1 additions covering the two `Reason` cases
/// this implementation had to ADD because design §3's list did not cover states
/// the model can actually represent.
@Suite("Instrument family resolution ladder (m23-o1 Step 1)")
struct InstrumentFamilyResolutionTests {
    // MARK: - Helpers

    private static func gmMelodic(program: Int) -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: program,
            bankMSB: GMProgramCatalog.melodicBankMSB, bankLSB: 0,
            displayName: GMProgramCatalog.name(forProgram: program)))
    }

    private static func gmPercussion() -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: 0,
            bankMSB: GMProgramCatalog.percussionBankMSB, bankLSB: 0,
            displayName: "Standard Drum Kit"))
    }

    private static func resolvedFamily(_ result: InstrumentFamilyResolution)
        -> InstrumentFamily? {
        if case .resolved(let family, _) = result { return family }
        return nil
    }

    private static func reason(_ result: InstrumentFamilyResolution)
        -> InstrumentFamilyResolution.Reason? {
        if case .unresolved(let reason) = result { return reason }
        return nil
    }

    // MARK: - R1

    @Test("R1: an audio track resolves to the honest audioTrackHasNoInstrument")
    func audioTrackIsUnresolvedWithAReason() {
        let result = InstrumentFamilyResolver.resolve(
            trackKind: .audio, instrument: nil, percussionNote: nil)
        #expect(result == .unresolved(.audioTrackHasNoInstrument))
        // The failure is a case WITH A PAYLOAD — never empty, never zeros.
        let reason = Self.reason(result)
        #expect(reason?.rawValue == "audioTrackHasNoInstrument")
        #expect(reason?.explanation.isEmpty == false)
        #expect(reason?.remedy.isEmpty == false)
        // Audio is the COMMON case, not an edge — an audio track carrying a
        // stray descriptor still has no instrument identity.
        let strays = InstrumentFamilyResolver.resolve(
            trackKind: .audio, instrument: Self.gmMelodic(program: 33),
            percussionNote: nil)
        #expect(strays == .unresolved(.audioTrackHasNoInstrument))
    }

    // MARK: - R2

    @Test("R2: every instrument kind that carries no family says WHICH kind of nothing")
    func instrumentKindsWithoutAFamily() {
        // A sweep over the whole InstrumentDescriptor.Kind family, not a
        // hand-written site list: a NEW kind lands here as a compile-time hole
        // in the switch below rather than passing by omission.
        for kind in InstrumentDescriptor.Kind.allCases {
            let descriptor = InstrumentDescriptor(kind: kind)
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: descriptor, percussionNote: nil)
            let expected: InstrumentFamilyResolution.Reason
            switch kind {
            case .testTone, .polySynth, .sampler:
                expected = .instrumentKindCarriesNoFamily
            case .audioUnit:
                expected = .hostedAudioUnitIsOpaque
            case .soundBank:
                // kind == .soundBank with soundBank == nil is a LEGAL state
                // (the silent-placeholder rule), and it is not the same nothing.
                expected = .soundBankSelectionMissing
            }
            #expect(result == .unresolved(expected),
                    Comment(rawValue: "kind .\(kind.rawValue) resolved \(result), expected "
                        + ".unresolved(.\(expected.rawValue))"))
        }

        // An instrument track with NO descriptor at all — a state
        // `Track.instrument: InstrumentDescriptor?` makes representable and
        // which design §3's Reason list did not cover (see R-extra-1).
        let noDescriptor = InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: nil, percussionNote: nil)
        #expect(noDescriptor == .unresolved(.instrumentTrackHasNoInstrument))
    }

    // MARK: - R3

    @Test("R3: a covered GM melodic program resolves, and says it came from the program")
    func gmMelodicProgramResolves() {
        let bass = InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: Self.gmMelodic(program: 33),
            percussionNote: nil)
        #expect(bass == .resolved(.electricBass, source: .gmProgram))

        // Literal pins across the mapped runs, each stated as GM program →
        // family. RECOMPUTED at Step 2b: the orchestral, brass, flute and
        // electric-piano pins are gone because those families were deleted, and
        // their programs are now pinned nil in C9's sweep instead.
        let pins: [Int: InstrumentFamily] = [
            0: .piano, 2: .piano, 3: .piano,
            24: .acousticGuitar, 25: .acousticGuitar,
            26: .electricGuitar, 27: .electricGuitar, 30: .electricGuitar,
            32: .uprightBass, 43: .uprightBass,
            33: .electricBass, 37: .electricBass,
        ]
        for (program, family) in pins {
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: Self.gmMelodic(program: program),
                percussionNote: nil)
            #expect(result == .resolved(family, source: .gmProgram),
                    Comment(rawValue: "GM \(program) (\(GMProgramCatalog.name(forProgram: program))) "
                        + "resolved \(result)"))
        }

        // The ladder and the table agree for EVERY program, in both directions:
        // a mapped program resolves to exactly that family and an unmapped one
        // resolves to the honest nil. This is the leg that catches the resolver
        // reading a different array than `melodicProgramFamilies`.
        for program in 0...127 {
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: Self.gmMelodic(program: program),
                percussionNote: nil)
            if let family = InstrumentFamilyResolver.melodicProgramFamilies[program] {
                #expect(result == .resolved(family, source: .gmProgram))
                // Every resolvable family has a row — the ladder can never land
                // somewhere the table cannot answer.
                #expect(InstrumentFrequencyTable.reference(for: family).family == family)
            } else {
                #expect(result == .unresolved(.gmProgramNotCoveredInV1))
            }
        }
    }

    // MARK: - R4

    @Test("R4: an uncovered GM program is a NAMED gap, not silence")
    func gmMelodicProgramNotCovered() {
        // 48 String Ensemble 1 — one program spanning four families at once.
        // 96 FX 1 (rain) — a synth patch, out on principle.
        // 64 Soprano Sax — deferred for cost-of-confidence, not principle.
        for program in [48, 96, 64, 16, 127] {
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: Self.gmMelodic(program: program),
                percussionNote: nil)
            #expect(result == .unresolved(.gmProgramNotCoveredInV1),
                    "GM \(program) resolved \(result)")
        }
        let reason = InstrumentFamilyResolution.Reason.gmProgramNotCoveredInV1
        // "not covered yet", never "no data" (design FM8).
        #expect(reason.explanation.lowercased().contains("not covered"))
        #expect(reason.remedy.contains("family"))
    }

    // MARK: - R5

    @Test("R5: percussion — drumKit without a note, family with one, named gap otherwise")
    func gmPercussionLadder() {
        // No note: the payload NAMES what is covered, so "not covered yet" can
        // never read as "no data".
        let kit = InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: Self.gmPercussion(), percussionNote: nil)
        #expect(kit == .drumKit(coveredNotes: InstrumentFamilyResolver.coveredPercussionNotes))
        guard case .drumKit(let notes) = kit else {
            Issue.record("percussion bank without a note must resolve .drumKit")
            return
        }
        #expect(notes.count == 17)
        #expect(notes == notes.sorted())

        // With a covered note.
        let snare = InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: Self.gmPercussion(), percussionNote: 38)
        #expect(snare == .resolved(.snare, source: .gmPercussionNote))
        #expect(Self.resolvedFamily(snare) == .snare)

        // Every covered note resolves to its authored family, by the note rung.
        for entry in InstrumentFamilyResolver.percussionNotes {
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: Self.gmPercussion(),
                percussionNote: entry.note)
            #expect(result == .resolved(entry.family, source: .gmPercussionNote),
                    "note \(entry.note) (\(entry.gmName)) resolved \(result)")
        }

        // With an uncovered note: a NAMED gap. 54 is tambourine — the design's
        // worked example of a piece whose spectrum is genuinely different.
        for note in [37, 39, 52, 53, 54, 55, 56, 0, 127] {
            let result = InstrumentFamilyResolver.resolve(
                trackKind: .instrument, instrument: Self.gmPercussion(),
                percussionNote: note)
            #expect(result == .unresolved(.percussionNoteNotCoveredInV1),
                    "note \(note) resolved \(result)")
        }
        // Its remedy names coveredNotes, so the agent's next move needs no
        // extra round trip.
        let reason = InstrumentFamilyResolution.Reason.percussionNoteNotCoveredInV1
        #expect(reason.remedy.contains("coveredNotes"))
        #expect(reason.explanation.contains("not covered"))
    }

    // MARK: - R6

    @Test("R6: a bus has no instrument identity and says so")
    func busIsNotASourceTrack() {
        let result = InstrumentFamilyResolver.resolve(
            trackKind: .bus, instrument: nil, percussionNote: nil)
        #expect(result == .unresolved(.trackIsNotAnInstrumentOrAudioTrack))
        // Even a bus carrying an instrument descriptor (not a state the model
        // produces, but representable) stays a bus.
        let odd = InstrumentFamilyResolver.resolve(
            trackKind: .bus, instrument: Self.gmMelodic(program: 33), percussionNote: 38)
        #expect(odd == .unresolved(.trackIsNotAnInstrumentOrAudioTrack))
        // Every TrackKind is accounted for — a new kind cannot slip through
        // unresolved-by-accident.
        #expect(TrackKind.allCases.count == 3)
    }

    // MARK: - R7 — STRUCTURAL

    @Test("R7: resolve() has NO parameter capable of accepting a track name")
    func resolverCannotSeeATrackName() {
        // THE PROOF IS THE SIGNATURE, and this binding is a COMPILE-TIME pin:
        // Swift cannot form a function value that omits parameters, so adding a
        // `trackName:` argument — even one with a default — makes this line stop
        // compiling. The recorded law: a function that cannot accept the varying
        // input makes the property structural.
        let signature: (TrackKind, InstrumentDescriptor?, Int?) -> InstrumentFamilyResolution =
            InstrumentFamilyResolver.resolve
        #expect(signature(.audio, nil, nil) == .unresolved(.audioTrackHasNoInstrument))

        // The accompanying BEHAVIOURAL leg. It is near-tautological given the
        // structural pin above — with no name parameter there is nothing for a
        // heuristic to read — but it states the property in the terms a reader
        // of design §3 will look for, and it exercises the two names whose
        // ambiguity is the argument ("Bass" is as likely to mean a bass DRUM as
        // a bass GUITAR, and their corners differ by roughly an octave).
        let bassDI = Track(name: "Bass DI 01", kind: .audio)
        let leadVox = Track(name: "Lead Vox", kind: .audio)
        #expect(bassDI.name != leadVox.name)
        #expect(bassDI.kind == leadVox.kind)
        #expect(bassDI.instrument == leadVox.instrument)
        let a = InstrumentFamilyResolver.resolve(
            trackKind: bassDI.kind, instrument: bassDI.instrument, percussionNote: nil)
        let b = InstrumentFamilyResolver.resolve(
            trackKind: leadVox.kind, instrument: leadVox.instrument, percussionNote: nil)
        #expect(a == b)
        #expect(a == .unresolved(.audioTrackHasNoInstrument))

        // Same again on INSTRUMENT tracks, where a heuristic would be most
        // tempting because there is a real instrument to "confirm" the guess.
        let kickTrack = Track(name: "Kick In", kind: .instrument,
                              instrument: Self.gmMelodic(program: 33))
        let bassTrack = Track(name: "Bass Gtr", kind: .instrument,
                              instrument: Self.gmMelodic(program: 33))
        let kickResult = InstrumentFamilyResolver.resolve(
            trackKind: kickTrack.kind, instrument: kickTrack.instrument,
            percussionNote: nil)
        let bassResult = InstrumentFamilyResolver.resolve(
            trackKind: bassTrack.kind, instrument: bassTrack.instrument,
            percussionNote: nil)
        #expect(kickResult == bassResult)
        // Both follow the PROGRAM, not the name: a track called "Kick In" on GM
        // program 33 is an electric bass, and the DAW says so.
        #expect(kickResult == .resolved(.electricBass, source: .gmProgram))
    }

    // MARK: - Step-1 additions (NOT design §8.3 legs)

    @Test("R-extra-1: an imported (non-GM) bank carries no General MIDI semantics")
    func importedSoundBankIsNotResolvedByGMProgram() {
        // An SF2/DLS file's program number is THAT FILE's preset index. Applying
        // the GM program→family map to it would be the confident-wrong-answer
        // failure this item exists to prevent, and `gmProgramNotCoveredInV1`
        // would be a lie (it is not a GM program at all). Design §3 did not
        // cover this state; the Reason case was ADDED at Step 1.
        let imported = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .file(path: "/Library/Audio/Sounds/Banks/FluidR3_GM.sf2"),
            program: 33, bankMSB: GMProgramCatalog.melodicBankMSB))
        let result = InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: imported, percussionNote: nil)
        #expect(result == .unresolved(.soundBankIsNotGeneralMIDI))
        // The SAME program on the system GM bank DOES resolve — so this is a
        // statement about the bank, not about program 33.
        #expect(InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: Self.gmMelodic(program: 33),
            percussionNote: nil) == .resolved(.electricBass, source: .gmProgram))

        // A bank-select MSB outside GM's melodic 121 / percussion 120 takes the
        // same honest exit even on the system bank.
        let oddBank = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: 33, bankMSB: 5))
        #expect(InstrumentFamilyResolver.resolve(
            trackKind: .instrument, instrument: oddBank,
            percussionNote: nil) == .unresolved(.soundBankIsNotGeneralMIDI))
    }

    @Test("R-extra-2: every Reason carries an explanation and a remedy, and none says 'no data'")
    func everyReasonIsSelfRemedying() {
        // A sweep over the whole enum, so a Reason added later cannot ship with
        // an empty payload — the nil case is REPRESENTABLE, never empty.
        #expect(InstrumentFamilyResolution.Reason.allCases.count == 9)
        for reason in InstrumentFamilyResolution.Reason.allCases {
            #expect(!reason.rawValue.isEmpty)
            #expect(reason.explanation.count > 40,
                    ".\(reason.rawValue) has a stub explanation")
            #expect(reason.remedy.count > 20, ".\(reason.rawValue) has a stub remedy")
            // Design FM8: an agent must never read a gap as "these are all the
            // instruments that exist".
            let lowered = reason.explanation.lowercased()
            #expect(!lowered.contains("no data"),
                    ".\(reason.rawValue) says 'no data' — say 'not covered yet'")
            // Every remedy points at a next move the caller can actually make.
            #expect(reason.remedy.contains("frequency.reference"))
        }
        // Every rung has a wire name, including the one the resolver never
        // returns (rung 1 is handled above it, in the command handler).
        #expect(InstrumentFamilyResolution.Source.allCases.map(\.rawValue)
                    == ["argument", "gmProgram", "gmPercussionNote"])
    }

    @Test("R-extra-3: the ladder never lands on a family the table cannot answer")
    func everyResolvableFamilyHasARow() {
        // The two maps and the table are three authored surfaces; this is the
        // leg that catches one of them naming a family the others do not.
        var reachable: Set<InstrumentFamily> = []
        for family in InstrumentFamilyResolver.melodicProgramFamilies.compactMap({ $0 }) {
            reachable.insert(family)
        }
        for entry in InstrumentFamilyResolver.percussionNotes {
            reachable.insert(entry.family)
        }
        for family in reachable {
            #expect(InstrumentFrequencyTable.reference(for: family).family == family)
        }
        // Exactly the two vocal families are reachable ONLY by the `family`
        // argument (design §2 admission rule 1's second clause) — stated, so a
        // future map change that quietly makes them program-reachable is visible.
        let argumentOnly = Set(InstrumentFamily.allCases).subtracting(reachable)
        #expect(argumentOnly == [.maleVocal, .femaleVocal])
    }
}
