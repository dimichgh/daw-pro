import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// m23-p2 — the DRAWN honesty disclosure.
///
/// The bass enhancer manufactures harmonic content and its benefit is phrased
/// as revelation ("makes bass audible on small speakers"). Both sentences are
/// true and only one of them is flattering, so the card has to carry both. The
/// legs below are built so the two truths redden SEPARATELY: a copy edit that
/// keeps the marketing and drops the admission fails C2 while C3 stays green,
/// and vice versa. A single "the copy mentions harmonics" assertion would pass
/// on either half alone, which is exactly the failure mode this cycle exists to
/// prevent.
@Suite("Effect honesty note — the drawn disclosure (m23-p2)")
struct EffectHonestyNoteTests {

    private var note: EffectHonestyNote {
        get throws { try #require(EffectHonestyNote.note(for: .bassEnhancer)) }
    }

    // MARK: - C1: the note exists and reaches the kind that owes it

    @Test("the bass enhancer has a disclosure")
    func bassEnhancerHasANote() throws {
        let note = try note
        #expect(!note.headline.isEmpty)
        #expect(!note.body.isEmpty)
        #expect(!note.footnote.isEmpty)
        // STRUCTURAL, not a count. `drawnStrings.count == 3` would do the
        // OPPOSITE of what this leg needs: it PASSES when a fourth stored
        // string is added and left out of the list — the exact drift that would
        // slip a readout-shaped token past C6, since every content pin below
        // and the gate's wire sweep both read `drawnStrings` — and it FAILS
        // when someone correctly extends both. So ask the TYPE what it stores
        // and require the list to match it.
        let stored = Mirror(reflecting: note).children.compactMap { $0.value as? String }
        #expect(!stored.isEmpty,
                "Mirror found no stored strings on EffectHonestyNote — this leg would be vacuous")
        #expect(stored.sorted() == note.drawnStrings.sorted(),
                "a stored string is missing from drawnStrings (stored \(stored.count), drawn \(note.drawnStrings.count)) — every drawn field must be enumerated there or it is pinned by nothing")
    }

    // MARK: - C2: the ADMISSION (the unflattering truth)

    @Test("the disclosure says the harmonics are not in the user's recording")
    func theCopyAdmitsTheHarmonicsAreAdded() throws {
        let note = try note
        let headline = note.headline.lowercased()
        #expect(headline.contains("adds"),
                "the headline must lead with the mechanism: \(note.headline)")
        #expect(headline.contains("harmonics"),
                "the headline must name what is added: \(note.headline)")
        #expect(headline.contains("not in your recording"),
                "the headline must say the harmonics were not there: \(note.headline)")
        // And the body must not soften it back into revelation. "Uncovered" is
        // allowed only in the negative — the shipped sentence is "Nothing
        // hidden is being uncovered".
        let body = note.body.lowercased()
        #expect(body.contains("new sound"),
                "the body must call the contribution new sound: \(note.body)")
        #expect(!body.contains("reveals") && !body.contains("uncovers")
                && !body.contains("brings out"),
                "the body must never frame synthesis as revelation: \(note.body)")
    }

    // MARK: - C3: the BENEFIT (the reason anyone wants it)

    @Test("the disclosure also says why anyone would want it")
    func theCopyKeepsTheBenefit() throws {
        let note = try note
        let body = note.body.lowercased()
        #expect(body.contains("small speakers"),
                "the body must state the benefit, not only the admission: \(note.body)")
        #expect(body.contains("your ear"),
                "the body must explain the mechanism the benefit rests on — the listener supplies the missing note: \(note.body)")
    }

    // MARK: - C4: it prints

    @Test("the disclosure says the added sound is committed, not a monitoring aid")
    func theCopySaysItPrints() throws {
        let note = try note
        #expect(note.body.lowercased().contains("bounce"),
                "a beginner's next question is whether this is only for listening; the copy must answer it: \(note.body)")
    }

    // MARK: - C5: the two things the knob RANGES cannot teach

    @Test("the footnote teaches that amount is level AND brightness, and is level-independent")
    func theFootnoteTeachesTheKnobs() throws {
        let note = try note
        let footnote = note.footnote.lowercased()
        // `amount` sets the series weights, which move BOTH the level and the
        // tilt (h3 ∝ a², h4 ∝ a³) — it is not a second output gain, and a range
        // of 0…1 cannot say so.
        #expect(footnote.contains("loud") && footnote.contains("bright"),
                "the footnote must say AMOUNT is both: \(note.footnote)")
        // Level independence: the generator normalizes the low band before
        // shaping, so a quiet passage and a loud one get the same character.
        #expect(footnote.contains("quiet"),
                "the footnote must state the level-independence virtue: \(note.footnote)")
    }

    // `@MainActor` because `EffectEditorModel.groups(for:)` is — this leg reads
    // the real layout table the card uses, not a copy of it.
    @MainActor
    @Test("every knob the card draws is taught by the disclosure")
    func theFootnoteNamesEveryKnob() throws {
        let note = try note
        // Derived from the SAME table the card lays its knobs out from, never
        // from a hand-written list of three: a fourth knob added to
        // `groupTable(for: .bassEnhancer)` arrives on the card the same day and
        // reddens here until someone writes a sentence for it. A literal list
        // would go quietly stale, which is how CROSSOVER — the most jargon-
        // heavy word on this card — stayed unexplained in the first draft.
        let labels = EffectEditorModel.groups(for: .bassEnhancer)
            .flatMap(\.items).map(\.label)
        #expect(labels.count == 3,
                "the bass enhancer's knob table changed shape: \(labels)")
        let copy = note.drawnStrings.joined(separator: " ").uppercased()
        for label in labels {
            #expect(copy.contains(label.uppercased()),
                    "the card draws a knob labelled \(label) and the disclosure teaches it nowhere: \(note.footnote)")
        }
    }

    @Test("mix is never described as dry/wet")
    func mixIsNotCalledDryWet() throws {
        let note = try note
        let all = note.drawnStrings.joined(separator: " ").lowercased()
        // `BassEnhancerParams.mix` never attenuates the dry path — it trims
        // only what the effect CONTRIBUTES. A user reading "dry/wet" would
        // expect 0.5 to halve their bass, which is a dishonest readout reached
        // through a borrowed word.
        #expect(!all.contains("dry/wet") && !all.contains("dry / wet"),
                "mix is a trim on the contribution, not a dry/wet: \(all)")
        #expect(note.footnote.lowercased().contains("never turned down"),
                "the footnote must say the user's own signal is untouched: \(note.footnote)")
    }

    // MARK: - C6: NO READOUT-SHAPED TOKEN (the m23-o2 law, one door over)

    @Test("no drawn string carries a number that could read as a measurement")
    func theCopyCarriesNoReadout() throws {
        let note = try note
        // The discriminating shape is a DIGIT NEXT TO A UNIT. That is what
        // makes a string look like a reading of the user's own signal when it
        // sits inches from the card's real SF Mono readouts (m23-o2: `HP 35 Hz`
        // read as *your setting* rather than *a suggestion*). A blanket
        // no-digits rule would be wrong — "the 2nd, 3rd and 4th harmonics" is
        // factual and useful.
        let readout = try Regex(#"\d+\s*(Hz|kHz|dB|dBFS|ms|%|x)\b"#).ignoresCase()
        for string in note.drawnStrings {
            #expect(string.firstMatch(of: readout) == nil,
                    "readout-shaped token in drawn copy: \(string)")
        }
    }

    @Test("the regex used by the no-readout pin actually catches a readout")
    func theNoReadoutPinIsNotVacuous() throws {
        // A pin built on a regex that matches nothing is a pin that can never
        // fail. Prove the instrument bites before trusting the result above.
        let readout = try Regex(#"\d+\s*(Hz|kHz|dB|dBFS|ms|%|x)\b"#).ignoresCase()
        for planted in ["cuts below 35 Hz", "adds 6 dB", "settles in 50 ms",
                        "mix 40%", "HP 6 kHz"] {
            #expect(planted.firstMatch(of: readout) != nil,
                    "the no-readout regex missed \(planted)")
        }
        #expect("the 2nd, 3rd and 4th harmonics".firstMatch(of: readout) == nil,
                "the no-readout regex must not forbid plain ordinals")
    }

    // MARK: - C7: the table — who owes a disclosure today

    @Test("the bass enhancer is the only kind carrying a disclosure today")
    func exactlyOneKindHasANote() {
        let carrying = EffectDescriptor.Kind.allCases
            .filter { EffectHonestyNote.note(for: $0) != nil }
        #expect(carrying == [.bassEnhancer],
                "kinds carrying a disclosure: \(carrying.map(\.rawValue))")

        // THE NEAR NEIGHBOURS, named on purpose. `saturator`, `reverb` and
        // `chorus` all create frequency or time content the source did not
        // contain, so "it generates new material" cannot be the criterion. The
        // criterion is the GAP between what the copy promises and what the code
        // does: only the bass enhancer's benefit is phrased as an improvement
        // in the AUDIBILITY of the existing part. Pinning them explicitly means
        // a future decision to give one of them a note has to come here and
        // argue with this comment rather than quietly widening a filter.
        for neighbour in [EffectDescriptor.Kind.saturator, .reverb, .chorus] {
            #expect(EffectHonestyNote.note(for: neighbour) == nil,
                    "\(neighbour.rawValue) gained a disclosure — see the criterion in EffectHonestyNote's doc comment before allowing this")
        }
    }

    @Test("no open editor means no disclosure")
    func nilKindHasNoNote() {
        #expect(EffectHonestyNote.note(for: nil) == nil)
    }

    // MARK: - C8: the drawn copy is plain language (Rule 6)

    @Test("the disclosure speaks to a beginner, not to a manual")
    func theCopyIsPlainLanguage() throws {
        let note = try note
        let all = note.drawnStrings.joined(separator: " ").lowercased()
        // Jargon the mechanism section of ARCHITECTURE.md may use and this
        // card may not. A beginner who needs a manual to read the disclosure
        // has not been disclosed to.
        //
        // "crossover" was on this list in the first draft and was REMOVED on
        // purpose: it is not jargon the copy introduces, it is the LABEL
        // printed on a knob the user is looking at. Banning the disclosure
        // from naming a control the card already names left the one genuinely
        // opaque word on this surface as the only one nothing explained. The
        // rest stay banned because nothing on screen says them.
        for jargon in ["chebyshev", "high-pass", "highpass",
                       "polynomial", "psychoacoustic", "partial", "biquad",
                       "waveshaper", "butterworth"] {
            #expect(!all.contains(jargon),
                    "jargon '\(jargon)' in the drawn copy: \(all)")
        }
    }
}
