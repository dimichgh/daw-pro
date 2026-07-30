import Foundation
import Testing
@testable import DAWCore

/// m23-o1 Step 1 — the SHAPE of the instrument frequency reference, gated
/// BEFORE any content exists. Legs C1, C2, C9, C10, C11 of design §8.3, plus
/// two Step-1 additions (the placeholder-sentinel pin and the validator
/// exercise) that exist so the scaffolding cannot ship as real data.
///
/// **C3–C8 (validator rules V1–V8, one leg per rule) deliberately DO NOT live
/// here — they land at Step 2 with the real content**, because the placeholder
/// rows are not real recommendations and asserting they satisfy V2a/V3 would
/// pin scaffolding as if it were guidance.
///
/// **C12 is NOT here and cannot be**: it pins
/// `MasterMixAnalyzer.bandIndex(containing:)`, and `Package.swift` declares
/// `DAWCoreTests` with `dependencies: ["DAWCore"]` — no DAWEngine. It lands in
/// `Tests/DAWControlTests/` at Step 3.
@Suite("Instrument frequency reference — shape (m23-o1 Step 1)")
struct InstrumentFrequencyReferenceTests {
    // MARK: - C1

    @Test("C1: 13 families, and every row's family field matches its key")
    func familyAxisIsTotalAndSelfConsistent() {
        // MOVED 20 → 13 AT STEP 2b, DELIBERATELY. The research pass deleted
        // electricPiano, violin, viola, cello, trumpet, trombone and flute
        // because their fields could not be cited (design §7 rule 3). This
        // literal moving is the pin working, not a break — but it must move only
        // alongside a recorded deletion, never to make a red test green.
        #expect(InstrumentFamily.allCases.count == 13)
        // The deleted seven, pinned by ABSENCE so a future cycle cannot quietly
        // restore one from the design sketch without redoing the citation work.
        let names = Set(InstrumentFamily.allCases.map(\.rawValue))
        for gone in ["electricPiano", "violin", "viola", "cello",
                     "trumpet", "trombone", "flute"] {
            #expect(!names.contains(gone),
                    Comment(rawValue: "\(gone) was deleted by the research pass — "
                        + "restoring it needs cited fields, not a sketch"))
        }

        // Raw values are wire strings and are permanent — pin them against
        // literals, never against the source's own `allCases` order.
        #expect(InstrumentFamily.kick.rawValue == "kick")
        #expect(InstrumentFamily.electricBass.rawValue == "electricBass")
        #expect(InstrumentFamily.hiHat.rawValue == "hiHat")

        // The copy-paste catcher: a row returned for one key that carries
        // another key's family field.
        for family in InstrumentFamily.allCases {
            let row = InstrumentFrequencyTable.reference(for: family)
            #expect(row.family == family,
                    Comment(rawValue: "reference(for: .\(family.rawValue)) returned a row whose "
                        + "family field is .\(row.family.rawValue)"))
            #expect(!row.displayName.isEmpty,
                    "\(family.rawValue) has an empty displayName")
        }

        // Every family is reachable and distinct: 13 keys must produce 13
        // distinct rows, so no two cases can be aliases of one row.
        let displayNames = Set(InstrumentFamily.allCases.map {
            InstrumentFrequencyTable.reference(for: $0).displayName
        })
        #expect(displayNames.count == InstrumentFamily.allCases.count)
    }

    @Test("C1b: the .inharmonic/.pitched split is design §1 F3's finding, not placeholder")
    func inharmonicFamiliesCarryNoFundamental() {
        // Hi-hats, ride and crash are inharmonic — there is no fundamental to
        // store and a plausible-looking one is the exact confabulation this item
        // guards against. Kick/snare/tom DO have a published tuning range.
        let inharmonic: Set<InstrumentFamily> = [.hiHat, .rideCymbal, .crashCymbal]
        for family in InstrumentFamily.allCases {
            let row = InstrumentFrequencyTable.reference(for: family)
            switch row.fundamental {
            case .inharmonic(let reason):
                #expect(inharmonic.contains(family),
                        Comment(rawValue: "\(family.rawValue) is .inharmonic but is not one of the "
                            + "three families design §1 F3 names"))
                #expect(!reason.isEmpty)
                #expect(row.fundamental.lowestHz == nil)
                #expect(row.fundamental.highestHz == nil)
            case .pitched:
                #expect(!inharmonic.contains(family),
                        "\(family.rawValue) must be .inharmonic per design §1 F3")
                #expect(row.fundamental.lowestHz != nil)
            }
        }
    }

    // MARK: - C2

    @Test("C2: Fundamental.hz is 440 · 2^((n−69)/12), pinned against literals")
    func fundamentalHzArithmetic() {
        // Literals, not a re-derivation from the source expression.
        #expect(abs(Fundamental.hz(midiNote: 69) - 440.0) < 1e-3)
        #expect(abs(Fundamental.hz(midiNote: 60) - 261.6256) < 1e-3)
        #expect(abs(Fundamental.hz(midiNote: 28) - 41.2034) < 1e-3)
        // A5 = 880: catches an inverted or halved exponent that a single
        // octave-symmetric pin could miss.
        #expect(abs(Fundamental.hz(midiNote: 81) - 880.0) < 1e-3)
        #expect(abs(Fundamental.hz(midiNote: 57) - 220.0) < 1e-3)
        // 30.8677 Hz is a 5-string bass's low B — the figure design §1 F1's
        // observability argument turns on.
        #expect(abs(Fundamental.hz(midiNote: 23) - 30.8677) < 1e-3)

        // The derived accessors read through the same one home.
        let pitched = Fundamental.pitched(lowestMIDINote: 28, highestMIDINote: 69)
        #expect(abs((pitched.lowestHz ?? 0) - 41.2034) < 1e-3)
        #expect(abs((pitched.highestHz ?? 0) - 440.0) < 1e-3)
    }

    // MARK: - C9

    @Test("C9: melodicProgramFamilies is 128 long, authored, and category-consistent")
    func melodicProgramMapping() {
        let map = InstrumentFamilyResolver.melodicProgramFamilies
        #expect(map.count == 128)

        // Index pins against literals (design §8.3 C9).
        #expect(map[33] == .electricBass)
        #expect(map[43] == .uprightBass)
        #expect(map[48] == nil)
        #expect(map[96] == nil)
        // Two more that bracket the run edges an off-by-one moves first.
        #expect(map[32] == .uprightBass)
        #expect(map[0] == .piano)
        #expect(map[26] == .electricGuitar)
        // The DELETED families' former slots, pinned nil at Step 2b. 40 was
        // violin and 73 was flute; a cycle that "restores" either without doing
        // the citation work reddens here first.
        #expect(map[40] == nil)
        #expect(map[41] == nil)
        #expect(map[42] == nil)
        #expect(map[56] == nil)
        #expect(map[57] == nil)
        #expect(map[59] == nil)
        #expect(map[73] == nil)
        // 2 "Electric Grand Piano" IS .piano (a strung, hammered piano), while
        // 4/5 "Electric Piano 1/2" are nil — mechanism decides membership, not
        // the marketing name. These two lines sit next to each other on purpose:
        // they are the pair a reader will otherwise think contradicts itself.
        #expect(map[2] == .piano)
        #expect(map[4] == nil)
        #expect(map[5] == nil)

        // THE SHIFT CATCHER, authored HERE rather than derived from the source:
        // the exact set of programs that carry a family. Any insertion,
        // deletion or reordering in the source array changes this set even when
        // it preserves the count and stays inside one GM category.
        //
        // RECOMPUTED at Step 2b from the research table's §5 mapping — not
        // adjusted by feel from the old set. 18 non-nil, 110 nil.
        let expectedMappedPrograms: Set<Int> = [
            0, 1, 2, 3,             // piano (incl. 2 Electric Grand)
            24, 25,                 // acousticGuitar
            26, 27, 28, 29, 30,     // electricGuitar
            32,                     // uprightBass (Acoustic Bass)
            33, 34, 35, 36, 37,     // electricBass
            43,                     // uprightBass (Contrabass)
        ]
        let actualMapped = Set(map.indices.filter { map[$0] != nil })
        #expect(actualMapped == expectedMappedPrograms,
                Comment(rawValue: "mapped programs drifted: unexpected "
                    + "\(actualMapped.subtracting(expectedMappedPrograms).sorted()), "
                    + "missing \(expectedMappedPrograms.subtracting(actualMapped).sorted())"))
        #expect(expectedMappedPrograms.count == 18)
        #expect(map.filter { $0 == nil }.count == 110)

        // Category-consistency sweep. Its real discrimination is a CROSS-CATEGORY
        // mis-assignment, NOT an off-by-one.
        //
        // MEASURED at Step 1, because the design implies otherwise: inserting one
        // `nil` at index 0 (design §8.3 C9's briefed mutation) reddened the count
        // pin, six index pins, the `expectedMappedPrograms` set and the synth-
        // exclusion pin — and left THIS SWEEP GREEN. No mapped program sits at an
        // index ≡ 7 (mod 8), so a one-place shift never crosses a GM bucket
        // boundary. A second, COUNT-PRESERVING shift (nil at 0, last entry
        // dropped) also left it green while the index pins and the set caught it.
        // The sweep was reddened on its own by mapping GM 29 (Overdriven Guitar,
        // "Guitar") to .cello (allowed: "Strings") — an edit no index pin and no
        // set membership can see. Keep BOTH mechanisms: they catch different bugs.
        // (`.cello` no longer exists at Step 2b; the equivalent mutation now is
        // GM 29 → `.uprightBass`, whose allowed set is ["Bass", "Strings"] and
        // excludes "Guitar".)
        //
        // THE EMPTY ALLOWED SET IS MEANINGFUL, NOT A GAP. Most admitted
        // families have no GM melodic program at all (every percussion family
        // and both vocals), and for those `allowedGMCategories` returns []. The
        // intended semantics, stated so nobody "fixes" it into a catch-all:
        //
        //   allowedGMCategories(for: F).isEmpty  ⟺  no program maps to F
        //
        // Read left-to-right it says an empty set means UNREACHABLE BY PROGRAM.
        // Read right-to-left it says a family that IS program-reachable must
        // declare its categories. The sweep below enforces the forward half the
        // hard way — `[].contains(category)` is always false, so a program that
        // maps to an empty-set family FAILS rather than skips. The equivalence
        // leg after it enforces both halves, and is derived over `allCases`
        // rather than listing families by hand (a hand-written list passes by
        // omission the moment the family set changes).
        var sweptPrograms = 0
        for program in map.indices {
            guard let family = map[program] else { continue }
            sweptPrograms += 1
            let category = GMProgramCatalog.category(forProgram: program)
            let allowed = InstrumentFamilyResolver.allowedGMCategories(for: family)
            #expect(allowed.contains(category),
                    Comment(rawValue: "GM program \(program) "
                        + "(\(GMProgramCatalog.name(forProgram: program))) maps to "
                        + ".\(family.rawValue), whose allowed categories are "
                        + "\(allowed.sorted()) — but it sits in \"\(category)\""))
        }
        // ANTI-VACUITY: the sweep is a `guard ... else { continue }` over a
        // mostly-nil array, so "every iteration skipped" would look identical
        // to "every iteration passed". Pin the number of iterations that
        // actually reached an assertion.
        #expect(sweptPrograms == expectedMappedPrograms.count,
                Comment(rawValue: "the category sweep asserted on \(sweptPrograms) "
                    + "programs, expected \(expectedMappedPrograms.count) — a sweep "
                    + "that skips every iteration passes vacuously"))

        // The equivalence, both directions, over EVERY family.
        for family in InstrumentFamily.allCases {
            let allowed = InstrumentFamilyResolver.allowedGMCategories(for: family)
            let reachable = map.contains(family)
            #expect(allowed.isEmpty == !reachable,
                    Comment(rawValue: ".\(family.rawValue) is "
                        + "\(reachable ? "reachable" : "unreachable") by GM program but its "
                        + "allowed categories are \(allowed.sorted()) — an empty set must "
                        + "mean exactly 'no program maps here'"))
        }
        // Synth programs are out on principle (design §2 rule 3).
        for program in [38, 39] + Array(80...103) {
            #expect(map[program] == nil,
                    Comment(rawValue: "GM \(program) (\(GMProgramCatalog.name(forProgram: program))) "
                        + "must not carry a family — a patch's range is a property "
                        + "of the patch"))
        }
        // Organ, ensembles and choirs, all excluded for stated reasons.
        for program in Array(16...23) + Array(48...55) {
            #expect(map[program] == nil)
        }
    }

    // MARK: - C10

    @Test("C10: 17 covered GM percussion notes across 6 families, exclusions explicit")
    func percussionNoteMapping() {
        let covered = InstrumentFamilyResolver.coveredPercussionNotes
        #expect(covered.count == 17)
        #expect(InstrumentFamilyResolver.percussionNotes.count == 17)
        #expect(covered == covered.sorted())
        #expect(Set(covered).count == 17, "a note is listed twice")
        for note in covered {
            #expect((35...59).contains(note), "note \(note) is outside 35…59")
        }

        // The authored set, as a literal.
        #expect(Set(covered) == [35, 36, 38, 40, 41, 42, 43, 44, 45, 46, 47, 48,
                                 49, 50, 51, 57, 59])

        // Family assignment pins (design §4's table).
        #expect(InstrumentFamilyResolver.percussionNote(36)?.family == .kick)
        #expect(InstrumentFamilyResolver.percussionNote(38)?.family == .snare)
        #expect(InstrumentFamilyResolver.percussionNote(42)?.family == .hiHat)
        #expect(InstrumentFamilyResolver.percussionNote(47)?.family == .tom)
        #expect(InstrumentFamilyResolver.percussionNote(51)?.family == .rideCymbal)
        #expect(InstrumentFamilyResolver.percussionNote(49)?.family == .crashCymbal)

        // The DELIBERATE exclusions — each has a genuinely different spectrum,
        // so folding it into a neighbour is the confident-wrong-answer failure.
        for note in [37, 39, 52, 53, 54, 55, 56] {
            let resolvedTo = InstrumentFamilyResolver.percussionNote(note)?
                .family.rawValue ?? "?"
            #expect(InstrumentFamilyResolver.percussionNote(note) == nil,
                    "note \(note) is excluded from v1 but resolved to .\(resolvedTo)")
        }

        // Per-family grouping — the `notes` field of design §6's family index.
        #expect(InstrumentFamilyResolver.percussionNotes(for: .kick) == [35, 36])
        #expect(InstrumentFamilyResolver.percussionNotes(for: .snare) == [38, 40])
        #expect(InstrumentFamilyResolver.percussionNotes(for: .hiHat) == [42, 44, 46])
        #expect(InstrumentFamilyResolver.percussionNotes(for: .tom)
                    == [41, 43, 45, 47, 48, 50])
        #expect(InstrumentFamilyResolver.percussionNotes(for: .rideCymbal) == [51, 59])
        #expect(InstrumentFamilyResolver.percussionNotes(for: .crashCymbal) == [49, 57])
        // Exactly six families are note-keyed; every other family has none.
        let noteKeyed = InstrumentFamily.allCases.filter {
            !InstrumentFamilyResolver.percussionNotes(for: $0).isEmpty
        }
        #expect(Set(noteKeyed) == [.kick, .snare, .hiHat, .tom, .rideCymbal, .crashCymbal])

        // Covered notes ship their GM spec name; uncovered notes ship none.
        #expect(InstrumentFamilyResolver.percussionNote(38)?.gmName == "Acoustic Snare")
        #expect(InstrumentFamilyResolver.percussionNote(36)?.gmName == "Bass Drum 1")
        for entry in InstrumentFamilyResolver.percussionNotes {
            #expect(!entry.gmName.isEmpty)
        }
    }

    // MARK: - C11

    @Test("C11: note names derive through KeyEstimate.pitchClassesSharp, the ONE home")
    func noteNamesUseTheSolePitchClassArray() {
        // Literal pins first (MIDI 60 = C4, 69 = A4 — every schema in the repo).
        #expect(Fundamental.noteName(midiNote: 28) == "E1")
        #expect(Fundamental.noteName(midiNote: 60) == "C4")
        #expect(Fundamental.noteName(midiNote: 69) == "A4")
        // Sharps are canonical: a flats table would pass the three pins above
        // (C, E and A are spelled the same either way) and fail here.
        #expect(Fundamental.noteName(midiNote: 61) == "C#4")
        #expect(Fundamental.noteName(midiNote: 34) == "A#1")
        // Octave boundaries, where an off-by-one in n/12 − 1 shows up.
        #expect(Fundamental.noteName(midiNote: 0) == "C-1")
        #expect(Fundamental.noteName(midiNote: 59) == "B3")
        #expect(Fundamental.noteName(midiNote: 127) == "G9")

        // THE ONE-HOME SWEEP: every MIDI note agrees with a name built from
        // `KeyEstimate.pitchClassesSharp`. Introducing a SECOND pitch-class
        // array in InstrumentFrequencyReference.swift breaks this for every note
        // whose spelling differs, so the divergence cannot land quietly.
        #expect(KeyEstimate.pitchClassesSharp.count == 12)
        for note in 0...127 {
            let expected = KeyEstimate.pitchClassesSharp[note % 12] + String(note / 12 - 1)
            #expect(Fundamental.noteName(midiNote: note) == expected,
                    Comment(rawValue: "MIDI \(note): got \(Fundamental.noteName(midiNote: note)), "
                        + "expected \(expected) via KeyEstimate.pitchClassesSharp"))
        }
    }

    // MARK: - Step-1/2b additions (NOT design §8.3 legs)

    // This leg is Step 1's sentinel legs INVERTED. Step 1 counted scaffolding
    // and asserted a floor of 2; Step 2b deleted the scaffolding, so the floor
    // is now ZERO and the assertion is "none of it survives". That inversion
    // retired two mutation specs permanently — SENT-A (move the placeholder
    // URL) and SENT-B (make `isPlaceholder` always false) — because the code
    // they mutate no longer exists. They were NOT re-anchored: there is nothing
    // left to point them at, and re-pointing them at the real citations would
    // make them duplicates of the checks below. Recorded here so a later reader
    // finds a reason rather than a gap.
    //
    // Note the checks are against LITERALS, not against constants. Asserting
    // `url != placeholderURL` would have been self-referential; asserting
    // against the literal string means the pin survives the constant's death.
    @Test("Step 2b: no placeholder scaffolding survives anywhere in the table")
    func nothingShipsAsScaffolding() {
        // The INVERSE of Step 1's sentinel leg. Step 1's machinery
        // (`placeholderSourcePrefix`, `placeholderURL`, `isPlaceholder`, V9) is
        // deleted, so the sentinel can no longer be checked through a constant —
        // it is checked against the LITERALS instead, which is what a close-out
        // grep would look for and is exactly as strong.
        for family in InstrumentFamily.allCases {
            let row = InstrumentFrequencyTable.reference(for: family)
            #expect(row.allCitations.count >= 3,
                    Comment(rawValue: "\(family.rawValue) carries only \(row.allCitations.count) "
                        + "citations; design V8 requires at least 3 per row"))
            for citation in row.allCitations {
                #expect(!citation.source.hasPrefix("PLACEHOLDER m23-o1"),
                        Comment(rawValue: "\(family.rawValue) still carries a sentinel source"))
                #expect(citation.url != "https://example.invalid/placeholder",
                        Comment(rawValue: "\(family.rawValue) still carries the sentinel URL"))
                // Every shipped citation resolves to a real host and carries the
                // research pass's retrieval date.
                #expect(citation.url.hasPrefix("https://"))
                #expect(citation.retrieved == "2026-07-28")
                #expect(!citation.quote.isEmpty)
            }
        }
    }

    @Test("Step 2b: validate() returns EMPTY — the whole gate, in one line")
    func validatorFindsNothing() {
        // This REPLACES Step 1's "exactly 20 V9 findings" leg. Every rule
        // V1–V8 holds against the transcribed table, including the four fields
        // that sit at EXACT EQUALITY against V3/V5 (snare HP, femaleVocal HP,
        // hiHat HP, acousticGuitar air) — a strict `<` in any of those
        // comparisons reddens here, which is the cheapest possible detection of
        // the single most likely transcription failure.
        let problems = InstrumentFrequencyTable.validate()
        let listed = problems.joined(separator: "\n")
        #expect(problems.isEmpty,
                Comment(rawValue: "validate() reported \(problems.count) "
                    + "problem(s):\n\(listed)"))
    }

    @Test("Step 1: the validator's V8 counters cannot fail open")
    func validatorCountersAreLoadBearing() {
        // A validator over optional fields can legitimately check nothing and
        // return []. V8 exists to make that impossible; prove the counters are
        // wired by checking the arithmetic they assert against.
        let rows = InstrumentFamily.allCases.map(InstrumentFrequencyTable.reference(for:))
        #expect(rows.count == 13)
        // Every row's HP is REQUIRED to be a .corner — the largest fail-open
        // path, removed at the type level and re-asserted here.
        for row in rows {
            #expect(row.recommendedHighPass.cornerHz != nil,
                    "\(row.family.rawValue)'s high pass is not a .corner")
            #expect(row.recommendedHighPass.slopeDbPerOct != nil)
        }
        let totalCitations = rows.reduce(0) { $0 + $1.allCitations.count }
        #expect(totalCitations >= 3 * rows.count,
                Comment(rawValue: "\(totalCitations) citations across \(rows.count) rows is below "
                    + "V8's 3-per-row floor"))
        // The floor above encodes V8's RULE; this literal encodes the TABLE.
        // MEASURED at the Step-2b close (2026-07-28), not copied from the
        // research doc. The floor alone is weak — it is 39, so a row could
        // silently shed citations 6 -> 4 and still clear it, and the per-row
        // `>= 3` leg would not notice either. Only an exact total catches that.
        // A DELIBERATE citation change must edit this number and say so.
        #expect(totalCitations == 69,
                Comment(rawValue: "citation total moved to \(totalCitations); if that was "
                    + "deliberate, update this literal, and if it was not, a row lost a source"))
    }

    @Test("Step 1: Role.isDesirable is ONE home, and it partitions the roles")
    func roleDesirabilityIsOneHome() {
        let desirable = FrequencyBand.Role.allCases.filter(\.isDesirable)
        let problem = FrequencyBand.Role.allCases.filter { !$0.isDesirable }
        #expect(Set(desirable) == [.body, .presence, .attack, .air])
        #expect(Set(problem) == [.rumble, .mud, .boxiness, .harshness, .sibilance])
        #expect(desirable.count + problem.count == FrequencyBand.Role.allCases.count)
        #expect(FrequencyBand.Role.allCases.count == 9)
    }

    // MARK: - V6, widened at Step-1 review
    //
    // FOUND BY A REVIEW MUTATION, not by any of the 25 legs above: rewriting
    // every desirable role to `.boxiness` in the 16 PITCHED rows left the whole
    // suite GREEN, because V3's two checks bind through
    // `desirable.map(\.lowHz).min()` / `.max()` and an empty `desirable` binds
    // nothing. V6 gated on `.inharmonic`, so nothing objected. Two legs pin the
    // widened rule, and they pin DIFFERENT things: the first pins the RULE (it
    // fails on the pre-fix source), the second pins the TABLE (it fails under
    // the mutation itself). Neither substitutes for the other.

    @Test("V6 (widened): a PITCHED row with no desirable band is a finding")
    func v6FiresForPitchedRowsNotJustInharmonicOnes() {
        // `validate()` runs over the real table and rows are unconstructible
        // outside their file (the barrier), so the rule is exercised over its
        // parts — the SAME function validate() calls, not a re-implementation.
        let cite = FrequencyCitation(source: "test", url: "https://example.invalid/t",
                                     quote: "test", retrieved: "2026-07-28")
        let onlyProblems = [
            FrequencyBand(role: .mud, lowHz: 200, highHz: 400,
                          effect: "muddy", citation: cite),
            FrequencyBand(role: .boxiness, lowHz: 400, highHz: 800,
                          effect: "boxy", citation: cite),
        ]
        let withBody = onlyProblems + [
            FrequencyBand(role: .body, lowHz: 80, highHz: 200,
                          effect: "weight", citation: cite),
        ]

        // THE LEG THAT FAILS ON THE PRE-FIX SOURCE. Pre-fix, V6's `.inharmonic`
        // gate meant a pitched row with only problem bands produced nothing.
        let pitched = InstrumentFrequencyTable.missingDesirableBandFinding(
            family: .kick,
            fundamental: .pitched(lowestMIDINote: 28, highestMIDINote: 40),
            bands: onlyProblems)
        #expect(pitched != nil,
                Comment(rawValue: "a pitched row listing only problem bands must be a "
                    + "V6 finding — V3 checks nothing for it"))
        #expect(pitched?.contains("pitched") == true)
        #expect(pitched?.hasPrefix("V6 kick:") == true)

        // The original inharmonic case must keep firing — a widening that trades
        // one branch for the other is not a widening.
        let inharmonic = InstrumentFrequencyTable.missingDesirableBandFinding(
            family: .crashCymbal,
            fundamental: .inharmonic(reason: "no fundamental"),
            bands: onlyProblems)
        #expect(inharmonic != nil)
        #expect(inharmonic?.contains("inharmonic") == true)

        // And the rule must stay SILENT when a desirable band exists, in both
        // shapes — otherwise it would fire on every real row and mean nothing.
        #expect(InstrumentFrequencyTable.missingDesirableBandFinding(
            family: .kick,
            fundamental: .pitched(lowestMIDINote: 28, highestMIDINote: 40),
            bands: withBody) == nil)
        #expect(InstrumentFrequencyTable.missingDesirableBandFinding(
            family: .crashCymbal,
            fundamental: .inharmonic(reason: "no fundamental"),
            bands: withBody) == nil)
        // An EMPTY band list is the degenerate case of the same hole.
        #expect(InstrumentFrequencyTable.missingDesirableBandFinding(
            family: .piano,
            fundamental: .pitched(lowestMIDINote: 60, highestMIDINote: 96),
            bands: []) != nil)
    }

    @Test("Every row in the table carries at least one desirable band")
    func everyRowRecordsWhatMakesTheInstrumentSoundLikeItself() {
        // The property the table actually exists for, asserted directly rather
        // than only through validate(): a row that lists only what to CUT tells
        // the copilot nothing about the instrument's characteristic region.
        for family in InstrumentFamily.allCases {
            let row = InstrumentFrequencyTable.reference(for: family)
            let desirable = row.bands.filter(\.role.isDesirable)
            #expect(!desirable.isEmpty,
                    Comment(rawValue: "\(family.rawValue) lists only problem bands — V3 "
                        + "would check nothing for it"))
        }
    }
}
