import Foundation

// m23-o1 Step 1 — the instrument frequency reference: the family axis (design
// §2 / D1) and the data shape (design §5 / D4). Pure Foundation; DAWCore is the
// dependency-free floor (the `GMProgramCatalog` precedent, LAW L9). No UI, no
// engine, and — per design FM6 — NO render-thread code anywhere in this item.
//
// THE CONSTRUCTION BARRIER IS THE POINT. The types and every row live in THIS
// ONE FILE so `InstrumentFrequencyReference.init` can be `fileprivate`: no
// other file in the module, and no other module, can mint a row that diverges
// from the table. That is the `InsertSpectrumTapPoint` / `ArrangeDropSnap`
// (`ResolvedDropBeat`) shape, both of which this file deliberately copies.
// `reference(for:)` is an EXHAUSTIVE switch with NO `default:`, so a family
// case without a row does not compile, and — the design's §7 rule 3 mechanism —
// DELETING an uncitable case makes every stale reference stop compiling until
// it is dealt with. There is deliberately no `allRows` array: anything needing
// all rows writes `InstrumentFamily.allCases.map(reference(for:))`, because a
// second hand-written list is exactly the drift the switch exists to prevent.
//
// ✅ STEP 2b: THE PLACEHOLDER SCAFFOLDING IS GONE. All 13 rows below are
// transcribed from `docs/research/m23o1-frequency-reference-table.md`, which is
// the AUTHORITY for every number, quote, URL and date here. Step 1's sentinel
// machinery (`placeholderSourcePrefix`, `placeholderURL`, `placeholderRow`,
// `isPlaceholder`, and validator rule V9) has been DELETED — both close-out
// greps now read 0, and the gate is `validate().isEmpty`, which is the stronger
// statement anyway because it reads the constructed values.
//
// ⚠️ SOFT SOURCES SHIP THEIR SOFTNESS IN THE PROSE **AND, SINCE m23-o2, IN A
// FIELD**. Six rows carry a source weakness the research pass flagged. It is
// stated inside the `rationale` / `explanation` strings that already reach the
// copilot — a confident-sounding number with a soft source is the worst thing
// this table could ship — AND, since m23-o2, in `fundamentalStrength` /
// `highPassStrength` (`SourceStrength`), because the EQ card DRAWS these
// numbers and a drawing layer cannot read prose. Keep BOTH in sync; the prose
// is the copilot's disclosure, the field is the pixels'. Note that the prose
// marker alone was never sufficient: `SOURCE CAVEAT:` appears in FOUR strings
// for SIX soft facts, so a UI scraping for it would have drawn two soft claims
// as firm ones. The six:
//   • ADMISSION-DOUBTFUL (`kick`, `snare`, `tom`) — the fundamental is a TUNING
//     CHOICE from a practice source, not a published physical constant.
//   • FILTER-WEAK (`piano`, `rideCymbal`, `crashCymbal`) — the required HP
//     corner rests on a tier-C publisher, and for the two cymbals it is
//     class-level guidance addressed to "cymbals", not to that cymbal.
// Do not delete those sentences to tidy the prose. They ARE the disclosure.
//
// ⚠️ FOUR SHIPPED FIELDS SIT AT EXACT EQUALITY against V3/V5, deliberately:
// `snare` HP 100 == body low 100; `femaleVocal` HP 100 == body low 100;
// `hiHat` HP 300 == body low 300; `acousticGuitar` air high 20000 == V5's
// ceiling. V3 and V5 are NON-STRICT at those bounds — MEASURED, see the
// boundary notes at each comparison in `validate()`. **A strict `<` rejects all
// four and fails a correct table.** Do not "tidy" any of these numbers.
//
// ON THE SPEC NAMES those boundary notes cite (B02r, B05r…B08r, B10r…B14r,
// T1-V3-strict, T2-V5-strict, V6r): the spec FILES are session scratch and are
// gone. Each note therefore states its mutation and its outcome inline — "hp
// == 110 → no V2a, `110.0.nextUp` → V2a fires" — and THAT is the durable form.
// The name is a label for a recipe you can re-run in ten seconds, not a path.
//
// ⚠️ QUOTES ARE VERBATIM, INCLUDING THE SOURCES' OWN ERRORS. `kick` carries
// "as high at", `snare` carries "tuned sound great" and "tiger up",
// `crashCymbal` carries "any where", `electricGuitar` carries a lowercase "hz".
// Several quotes begin mid-sentence at a lowercase word, which is legal and
// intentional. Several carry U+2011 non-breaking hyphens, U+2013 en dashes,
// U+2248, or primes. **Correcting any of these breaks the property the quote
// exists to provide.** If a close-out check disagrees: words or numbers differ
// ⇒ delete the field; only a hyphen/dash CLASS differs ⇒ rendering artifact,
// correct the character; sentence returned without its leading clause ⇒ re-ask
// for the exact first five words (the research pass caught two such drops).
//
// ⚠️ V6 WAS WIDENED AT STEP-1 REVIEW — DO NOT RE-NARROW IT. The design words
// V6 as "an INHARMONIC row with no desirable band". A review mutation proved
// that wording is a hole: against the Step-1 table, rewriting every desirable
// role to `.boxiness` in the 17 PITCHED rows only left `validate()` returning
// the same findings and the whole suite GREEN. The reason is V3's shape — its two checks bind through
// `desirable.map(\.lowHz).min()` and `.max()`, so with `desirable` empty they
// bind nothing and V3 checks NOTHING. The generalisation is correct in both
// directions: pitched or inharmonic, a row with no desirable band makes V3
// vacuous, AND it has recorded only what to CUT, never what makes the
// instrument sound like itself — the opposite of this table's purpose. The rule
// now lives in `missingDesirableBandFinding(family:fundamental:bands:)` so a
// test can reach it over constructed parts; two legs pin it (see
// `InstrumentFrequencyReferenceTests`).

/// The v1 family axis (design §2 / D1) — **13 cases**, authored for engineering
/// usefulness rather than mirroring GM's 16 categories (GM puts ALL percussion
/// behind one program, and kick/snare/hat are the highest-value rows here).
///
/// **The design proposed 20. Seven were DELETED by the research pass** — that is
/// design §7 rule 3 working, not a shortfall (`docs/research/m23o1-frequency-
/// reference-table.md` §7.0). Do not "restore" them from the design sketch
/// without doing the citation work; each was searched and rejected for a stated
/// reason:
/// - `cello`, `trombone` — killed by **V2a**. The only fetchable low-cut
///   guidance is section-level ("Orchestral Strings … below 100 Hz",
///   "Orchestral Brass … below 150 Hz") and both corners eat the instrument's
///   own bottom note (cello open C2 bound 82.41 Hz; trombone E2 bound 103.83).
/// - `trumpet` — quote↔field mismatch. Its source states a **written** F♯,
///   which sounds E3 on a B♭ instrument, so the MIDI field would disagree with
///   the pitch named in its own quote.
/// - `violin`, `viola` — citation scope: every actionable field would come from
///   ensemble-level bullets that never name the instrument.
/// - `flute`, `electricPiano` — searched, no source found at all. A
///   `recommendedHighPass` is REQUIRED, so neither row can ship.
///
/// A family exists in v1 iff all three admission rules hold: **reachable** by
/// the ladder, **actionable** (merging with its nearest neighbour would change
/// the advice), and **citable as physics, not convention**. Rule 3 is why every
/// synthesised family is absent: a synth patch's range is a property of the
/// PATCH, and the DAW already has a better answer for those — `fx.spectrum`
/// MEASURES what the patch actually produces.
///
/// Adding a family later is additive on every surface (the vocabulary rides in
/// every `frequency.reference` response and the MCP schema is `z.string()`), so
/// this list is safe to grow. It is also safe to SHRINK: design §7 rule 3 says
/// a row that cannot be cited gets its CASE DELETED, never guessed.
public enum InstrumentFamily: String, Sendable, Codable, CaseIterable, Hashable {
    // Percussion — reached by GM percussion NOTE (design D3), never by program.
    case kick, snare, hiHat, tom, rideCymbal, crashCymbal
    // Bass
    case electricBass, uprightBass
    // Guitar
    case electricGuitar, acousticGuitar
    // Keys
    case piano
    // Voice
    case maleVocal, femaleVocal
    // NO bowed strings and NO winds in v1 — see the deletions above. An agent
    // with a violin or flute track gets `.unresolved(.gmProgramNotCoveredInV1)`
    // with its remedy, which is the honest-nil path D2 exists for.
}

// ── 1. PHYSICS: MIDI notes in, Hz derived. No Hz literal exists to typo. ──

/// The fundamental range of a family, or an honest statement that it has none.
///
/// A SUM TYPE, not an optional pair of Ints and not a struct with sentinel
/// zeros (design §1 F3): hi-hats, ride and crash cymbals are **inharmonic** —
/// there is no fundamental to store, and a plausible-looking one is precisely
/// the confabulation this item guards against. A sentinel IS a fake number.
///
/// `Codable` is carried because design §5 lists it, but the synthesized enum
/// encoding (`{"pitched":{"lowestMIDINote":28,…}}`) is **not** the wire shape:
/// design §6's response is hand-built at Step 3 with `lowestHz` / `lowestNoteName`
/// derived here. Do not reach for `JSONEncoder` on this type expecting §6.
public enum Fundamental: Sendable, Equatable, Codable {
    /// Lowest and highest sounding fundamental, as MIDI note numbers.
    case pitched(lowestMIDINote: Int, highestMIDINote: Int)
    /// No fundamental exists (cymbals, hats). The string says WHY, and the
    /// row's `bands` carry the body region instead — never a fake range.
    case inharmonic(reason: String)

    /// THE ONLY Hz source in this file: 440 · 2^((n − 69)/12). Every Hz figure
    /// for a fundamental is derived through here, so a typo'd Hz literal is
    /// unrepresentable (the roadmap's own argument for MIDI-note storage).
    public static func hz(midiNote: Int) -> Double {
        440.0 * pow(2.0, (Double(midiNote) - 69.0) / 12.0)
    }

    /// Scientific-pitch note name for a MIDI note: MIDI 60 = "C4", 69 = "A4",
    /// 28 = "E1".
    ///
    /// Pitch-class names come from `KeyEstimate.pitchClassesSharp` — the repo's
    /// SOLE pitch-class-name array (`AudioAnalysis.swift`). **Do not add a
    /// second one here**: a private flats/sharps table in this file would be a
    /// competing home for the same twelve strings, which is the drift this
    /// codebase spends its "ONE home" discipline preventing.
    public static func noteName(midiNote: Int) -> String {
        let names = KeyEstimate.pitchClassesSharp
        // Floor division / floored modulo so the derivation stays correct for
        // hypothetical negative inputs rather than only for the 0…127 the model
        // actually carries.
        let pitchClass = ((midiNote % names.count) + names.count) % names.count
        let octave = Int((Double(midiNote) / Double(names.count)).rounded(.down)) - 1
        return names[pitchClass] + String(octave)
    }

    /// The lowest fundamental in Hz, or `nil` for an inharmonic family — the
    /// repo's nil-means-no-evidence convention, never a 0.0 sentinel.
    public var lowestHz: Double? {
        if case .pitched(let lowest, _) = self { return Self.hz(midiNote: lowest) }
        return nil
    }

    /// The highest fundamental in Hz, or `nil` for an inharmonic family.
    public var highestHz: Double? {
        if case .pitched(_, let highest) = self { return Self.hz(midiNote: highest) }
        return nil
    }
}

// ── 2. ENGINEERING OPINION: Hz, and a citation PER ROW, inline. ──

/// One inline citation. A field of the value it supports, never a doc header,
/// so "cited to sources" is a PROPERTY of the data: a band without a citation
/// cannot be constructed.
///
/// `quote` is the anti-fabrication device (design §7 rule 1): VERBATIM,
/// ≤ 200 characters, no ellipsis, no square-bracket edits — so the close-out
/// spot-check is mechanical (fetch the URL, search for the string). A
/// paraphrase is unfalsifiable; a quote is not.
public struct FrequencyCitation: Sendable, Equatable, Codable {
    /// Publication or author.
    public let source: String
    /// `https://`, and it must RESOLVE to a page that STATES the claim.
    public let url: String
    /// The VERBATIM sentence that states this claim.
    public let quote: String
    /// ISO-8601 date the URL was retrieved.
    public let retrieved: String

    public init(source: String, url: String, quote: String, retrieved: String) {
        self.source = source
        self.url = url
        self.quote = quote
        self.retrieved = retrieved
    }

}

/// One named frequency region of an instrument, with the plain-language effect
/// of touching it and the citation that supports it.
///
/// **No dB advice ships in v1**: the row says WHERE and WHAT it does, never
/// "boost 3 dB". Amount is a mix decision the copilot makes with `fx.spectrum`
/// in hand — a table of dB values would be pure genre convention and would fail
/// design §2's admission rule 3.
public struct FrequencyBand: Sendable, Equatable, Codable {
    /// Chosen from this enum, never invented in prose (design §7 rule 4), so a
    /// row cannot describe a band as characteristic and then recommend cutting
    /// it away — that contradiction is what validator rule V3 checks.
    public enum Role: String, Sendable, Codable, CaseIterable {
        // Desirable — the region that makes the instrument sound like itself.
        case body, presence, attack, air
        // Problem — the region an engineer typically reaches for to clean up.
        case rumble, mud, boxiness, harshness, sibilance

        /// ONE home for desirable-vs-problem; V3 and V6 both read it, so the
        /// two rules cannot disagree about which roles are which.
        public var isDesirable: Bool {
            switch self {
            case .body, .presence, .attack, .air: return true
            case .rumble, .mud, .boxiness, .harshness, .sibilance: return false
            }
        }
    }

    public let role: Role
    public let lowHz: Double
    public let highHz: Double
    /// Plain language, no dB advice.
    public let effect: String
    public let citation: FrequencyCitation

    public init(role: Role, lowHz: Double, highHz: Double,
                effect: String, citation: FrequencyCitation) {
        self.role = role
        self.lowHz = lowHz
        self.highHz = highHz
        self.effect = effect
        self.citation = citation
    }
}

// ── 3. THE ACTIONABLE FIELD: distinct from BOTH of the above. ──

/// The HP or LP recommendation — the field the copilot ACTS on, and
/// deliberately NOT the fundamental range: a kick's corner sits BELOW its
/// lowest fundamental, a dense-mix vocal's may sit ABOVE it. Collapsing the two
/// would force one of those truths to be a lie.
///
/// `slopeDbPerOct` rides along because m22-a ships 12 and 24 and the right
/// answer differs by source; `rationale` rides along so the copilot can TELL
/// THE USER WHY rather than just moving a knob.
///
/// As with `Fundamental`, `Codable` is carried per design §5 but the
/// synthesized encoding is not design §6's `{"kind":"corner",…}` wire shape.
public enum FilterRecommendation: Sendable, Equatable, Codable {
    case corner(hz: Double, slopeDbPerOct: Int, rationale: String,
                citation: FrequencyCitation)
    case noneRecommended(reason: NoneReason, explanation: String)

    public enum NoneReason: String, Sendable, Codable, CaseIterable {
        /// Honest practice would cut below `EQParams.lowPassFreqRange`'s lower
        /// bound (1000 Hz), which `fx.setParam` would SILENTLY CLAMP (design
        /// §1 F2) — the advice and the action would disagree with nothing
        /// surfaced. Saying "none" is the honest answer, not a gap.
        case belowHouseEQRange
        /// This source has content to the top of the band; cutting is a taste
        /// move, not cleanup.
        case notRecommendedForThisSource
    }

    /// The corner in Hz, or `nil` when nothing is recommended.
    public var cornerHz: Double? {
        if case .corner(let hz, _, _, _) = self { return hz }
        return nil
    }

    /// The slope in dB/oct, or `nil` when nothing is recommended.
    public var slopeDbPerOct: Int? {
        if case .corner(_, let slope, _, _) = self { return slope }
        return nil
    }

    /// The citation, or `nil` when nothing is recommended (there is nothing to
    /// cite for a non-recommendation — the `explanation` carries it instead).
    public var citation: FrequencyCitation? {
        if case .corner(_, _, _, let citation) = self { return citation }
        return nil
    }
}

// ── 3b. THE SOFTNESS, AS A FIELD (m23-o2). ──

/// How strong the SOURCE behind one field of a row is.
///
/// **Added at m23-o2 because the softness had to reach PIXELS and could not.**
/// m23-o1 disclosed six soft rows in the `rationale` / `explanation` PROSE (see
/// the file header) — correct for the copilot, which reads prose, and useless
/// for a drawing layer, which cannot. Worse, the prose marker is not even
/// uniform: `SOURCE CAVEAT:` appears in FOUR strings for SIX soft facts, so a
/// UI that scraped for it would silently draw two soft claims as firm ones.
/// A token search finds the token, not the property.
///
/// So the review finding is a FIELD now. The two soft cases keep the names the
/// m23-o1 review gave them, verbatim, so the vocabulary in the header comment,
/// in the roadmap, and on this enum is one vocabulary rather than three.
///
/// **The cases are FIELD-SPECIFIC by construction**, which is the whole reason
/// this is not one `isSoft: Bool`: the two findings are about different facts.
/// `admissionDoubtful` is a claim about a FUNDAMENTAL and `filterWeak` is a
/// claim about a CORNER, and a row can be soft in one and firm in the other
/// (`piano`'s compass is a published instrument spec; its corner is not).
/// `InstrumentFrequencyReferenceTests` pins that partition in both directions.
///
/// Deliberately NOT on the wire. `frequency.reference`'s payload is hand-built
/// (design §6) and m23-o1 chose prose disclosure there ON PURPOSE — an LLM acts
/// on a sentence it reads, and the sentence says more than an enum case can.
/// This field exists for the surface that cannot read prose.
public enum SourceStrength: String, Sendable, Codable, CaseIterable {
    /// A reproducible source states this value FOR THIS INSTRUMENT.
    case published
    /// **ADMISSION-DOUBTFUL** — the fundamental is a TUNING CHOICE recorded by
    /// a practice source (a drum-tuning guide), not a physical constant of the
    /// instrument. A differently tuned drum moves it. `kick`, `snare`, `tom`.
    case admissionDoubtful
    /// **FILTER-WEAK** — the corner rests on a single tier-C publisher, or on
    /// class-level guidance addressed to a CATEGORY rather than to this
    /// instrument. `piano`, `rideCymbal`, `crashCymbal`.
    case filterWeak

    /// Whether a surface must present this fact as guidance rather than as a
    /// measurement. ONE home for that question, so a drawing layer and a
    /// caption cannot disagree about which facts are soft.
    public var isSoft: Bool { self != .published }
}

/// One family's complete reference row.
///
/// `init` is `fileprivate` — **the barrier**. The only way to obtain one is
/// `InstrumentFrequencyTable.reference(for:)`, so no other file can mint a row
/// that diverges from the table. Deliberately NOT `Codable`: a synthesized
/// `Decodable` initializer would be a second, public construction path and
/// would breach the barrier outright.
public struct InstrumentFrequencyReference: Sendable, Equatable {
    public let family: InstrumentFamily
    public let displayName: String
    public let fundamental: Fundamental
    public let fundamentalCitation: FrequencyCitation
    /// m23-o2 — how strong the source behind `fundamental` is. Defaults to
    /// `.published`, so only the rows the m23-o1 review actually flagged carry
    /// a value, and adding the field changed no other row's meaning.
    public let fundamentalStrength: SourceStrength
    /// REQUIRED, and always `.corner` — every source benefits from a subsonic
    /// cut, and a required field cannot fail open in the validator (design V8).
    public let recommendedHighPass: FilterRecommendation
    /// m23-o2 — how strong the source behind `recommendedHighPass` is.
    public let highPassStrength: SourceStrength
    /// May be `.noneRecommended` — design §1 F2's honest answer where real
    /// practice would cut below the house EQ's 1 kHz floor.
    public let recommendedLowPass: FilterRecommendation
    public let bands: [FrequencyBand]

    fileprivate init(family: InstrumentFamily,
                     displayName: String,
                     fundamental: Fundamental,
                     fundamentalCitation: FrequencyCitation,
                     fundamentalStrength: SourceStrength = .published,
                     recommendedHighPass: FilterRecommendation,
                     highPassStrength: SourceStrength = .published,
                     recommendedLowPass: FilterRecommendation,
                     bands: [FrequencyBand]) {
        self.family = family
        self.displayName = displayName
        self.fundamental = fundamental
        self.fundamentalCitation = fundamentalCitation
        self.fundamentalStrength = fundamentalStrength
        self.recommendedHighPass = recommendedHighPass
        self.highPassStrength = highPassStrength
        self.recommendedLowPass = recommendedLowPass
        self.bands = bands
    }

    /// Every citation this row carries, in a stable order — the validator's
    /// single traversal point, so V7 cannot silently skip one.
    public var allCitations: [FrequencyCitation] {
        var result = [fundamentalCitation]
        if let hp = recommendedHighPass.citation { result.append(hp) }
        if let lp = recommendedLowPass.citation { result.append(lp) }
        result.append(contentsOf: bands.map(\.citation))
        return result
    }

}

// ── THE TABLE ──

/// The uninstantiable namespace holding the 13 rows and the validator.
/// Immutable `static let`s only — no global mutable state, so Swift 6 strict
/// concurrency is satisfied by construction (design FM7).
public enum InstrumentFrequencyTable {

    /// TOTAL over `InstrumentFamily.allCases` — enforced by the compiler, not
    /// by hope: no `default:` clause exists, so a new case stops the build.
    public static func reference(for family: InstrumentFamily) -> InstrumentFrequencyReference {
        switch family {
        case .kick: return kickRow
        case .snare: return snareRow
        case .hiHat: return hiHatRow
        case .tom: return tomRow
        case .rideCymbal: return rideCymbalRow
        case .crashCymbal: return crashCymbalRow
        case .electricBass: return electricBassRow
        case .uprightBass: return uprightBassRow
        case .electricGuitar: return electricGuitarRow
        case .acousticGuitar: return acousticGuitarRow
        case .piano: return pianoRow
        case .maleVocal: return maleVocalRow
        case .femaleVocal: return femaleVocalRow
        }
    }

    // MARK: - The rows (13, transcribed from the research table)
    //
    // The `.inharmonic` / `.pitched` split is design §1 F3's finding: hi-hats,
    // ride and crash cymbals have no fundamental, and inventing one for them is
    // the exact confabulation this item prevents. Kick, snare and toms DO have a
    // published tuning range and stay `.pitched` — which is also what keeps V2a
    // able to protect them, since an `.inharmonic` kick would carry no
    // `lowestHz` and nothing would stop a future edit shipping the folklore
    // 80 Hz corner.
    //
    // Every number, quote, URL and date below comes from
    // `docs/research/m23o1-frequency-reference-table.md`. Non-ASCII characters
    // inside QUOTES are written as `\u{…}` escapes on purpose: the exact
    // character class is load-bearing for a verbatim check, and an escape cannot
    // be silently normalised by an editor the way a literal U+2011 can.

    private static let kickRow = InstrumentFrequencyReference(
        family: .kick,
        displayName: "Kick drum",
        // 48.999 Hz (G1) … 92.499 Hz (F#2). Bridge from the quote's Hz to MIDI:
        // "as low as 50" → 31 (Δ1.00 vs 32's Δ1.91); "80 or 90" → 42 (Δ2.50).
        fundamental: .pitched(lowestMIDINote: 31, highestMIDINote: 42),
        fundamentalCitation: cite(
            idrumtuneSource, idrumtuneURL,
            // 198 characters — the longest quote in the table, and the only one
            // near V7's 200 limit. "as high at" is the page's own wording.
            "Kick drums can be tuned to have a fundamental frequency as low as "
                + "50 Hz and as high at 80 or 90 Hz depending on the drum size, "
                + "the type of drumheads used and the style of music that is "
                + "being played."),
        // ADMISSION-DOUBTFUL (m23-o2): the same finding the rationale's SOURCE
        // CAVEAT sentence states, in a form a drawing layer can read.
        fundamentalStrength: .admissionDoubtful,
        recommendedHighPass: .corner(
            hz: 35, slopeDbPerOct: 24,
            rationale: "The kick's own lowest tuning sits near 49 Hz; 35 Hz "
                + "clears room rumble and stand thump beneath it while costing "
                + "that fundamental only about 0.3 dB. Do NOT follow the common "
                + "'high-pass everything at 80 Hz' advice here — at 80 Hz this "
                + "drum loses about 17 dB of its own fundamental. SOURCE CAVEAT: "
                + "a kick's fundamental is a TUNING CHOICE, not a physical "
                + "constant of the instrument, and the range above comes from a "
                + "drum-tuning guide rather than a published spec — a "
                + "differently tuned drum moves it.",
            citation: cite(
                "Sound On Sound, Mix Tips For Kick & Bass",
                kickBassURL,
                "Applying a low\u{2011}cut (high\u{2011}pass) filter to anything "
                    + "below 30-40Hz will help to keep this under control.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "A kick's beater click lives at 2–4 kHz and useful "
                + "content continues above it; anything higher is cymbal spill, "
                + "which is a gating and balance decision, not cleanup."),
        bands: [
            FrequencyBand(
                role: .body, lowHz: 70, highHz: 90,
                effect: "The low-end weight you feel in the chest rather than hear.",
                citation: cite(sparkleSource, sparkleURL,
                    "If the kick needs more low-end weight, you can EQ it after "
                        + "gating it, by applying some boost in the 70-90Hz region")),
            FrequencyBand(
                role: .boxiness, lowHz: 150, highHz: 200,
                effect: "Cardboard hollowness that makes the drum sound like a "
                    + "box instead of a drum.",
                citation: cite(sparkleSource, sparkleURL,
                    "you may also find that cutting in the 150-200Hz region "
                        + "reduces any tendency for the kick drum to sound boxy")),
            FrequencyBand(
                role: .attack, lowHz: 2000, highHz: 4000,
                effect: "The beater click that lets the kick be heard on small speakers.",
                citation: cite(sparkleSource, sparkleURL,
                    "dedicated kick-drum mics on the market that have tailored "
                        + "frequency response curves to accentuate the 70-90Hz "
                        + "thump, as well as the 2-4kHz beater click")),
        ])

    private static let snareRow = InstrumentFrequencyReference(
        family: .snare,
        displayName: "Snare drum",
        // 174.614 Hz (F3) … 195.998 Hz (G3). 170 → 53, 200 → 55.
        fundamental: .pitched(lowestMIDINote: 53, highestMIDINote: 55),
        fundamentalCitation: cite(
            idrumtuneSource, idrumtuneURL,
            // "tuned sound great" and "tiger up" are the page's own typos.
            "A standard 14 inch snare drum can usually be tuned sound great at "
                + "a fundamental frequency of 170 Hz and also tiger up at 200 Hz too."),
        // ADMISSION-DOUBTFUL (m23-o2) — see the kick row.
        fundamentalStrength: .admissionDoubtful,
        recommendedHighPass: .corner(
            hz: 100, slopeDbPerOct: 24,
            rationale: "A close snare mic hears the kick as much as the snare. "
                + "100 Hz sits well below the drum's own ~175 Hz fundamental and "
                + "removes the kick bleed and stand rumble that muddy the middle "
                + "of the kit. SOURCE CAVEAT: like the kick, a snare's "
                + "fundamental is a TUNING CHOICE from a practice source, and "
                + "the cited range is one 14-inch drum — narrower than the "
                + "family. Piccolo and deep snares sit outside it.",
            citation: cite(
                idrumtuneSource, idrumtuneURL,
                // The lowercase "if" is the page's own; this is a contiguous
                // mid-sentence substring, not a truncation.
                "if our snare is tuned to 200 Hz, we know we can safely set a "
                    + "low-cut EQ on the snare channel at, say 100 Hz")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "The snare's crack and wire rattle run past 8 kHz; a "
                + "corner low enough to matter would dull the drum, and anything "
                + "gentler is a taste move."),
        bands: [
            // ⚠️ lowHz 100 EQUALS the high-pass corner. V3 is non-strict; do not
            // "tidy" either number (research table §1.3 note 7).
            FrequencyBand(
                role: .body, lowHz: 100, highHz: 150,
                effect: "The weight of the shell — makes a thin snare sound like "
                    + "a real drum.",
                citation: cite(multitrackedSource, multitrackedURL,
                    "you can add more body to the sound by applying a cautious "
                        + "amount of EQ boost at 100 to 150Hz")),
            FrequencyBand(
                role: .boxiness, lowHz: 300, highHz: 350,
                effect: "The edge overtone that rings on after the hit and "
                    + "distracts from the drum's pitch.",
                citation: cite(idrumtuneSource, idrumtuneURL,
                    "by applying some attenuation at the snare drum's edge "
                        + "overtone frequency, which will usually be at around "
                        + "300-350 Hz")),
            FrequencyBand(
                role: .attack, lowHz: 4000, highHz: 8000,
                effect: "The crisp snap that makes the backbeat cut through a dense mix.",
                citation: cite(multitrackedSource, multitrackedURL,
                    "If the snare needs any extra crispness, then try a little "
                        + "high EQ at between 4 and 8kHz")),
        ])

    private static let hiHatRow = InstrumentFrequencyReference(
        family: .hiHat,
        displayName: "Hi-hat",
        fundamental: .inharmonic(
            reason: "Hi-hat cymbals have no single fundamental — their partials "
                + "are not harmonically related, so any stated pitch range would "
                + "be invented."),
        fundamentalCitation: cymbalIndefinitePitch,
        recommendedHighPass: .corner(
            hz: 300, slopeDbPerOct: 12,
            rationale: "A hat mic hears kick and snare bleed plus pedal and "
                + "stand thump. 300 Hz is the top of the range published "
                + "practice puts the corner in; the gentle 12 dB/oct slope is "
                + "chosen because the corner sits right at the bottom edge of "
                + "the hat's own body region, so a steeper cut would start "
                + "eating it.",
            citation: cite(
                "Production Expert, 5 Hi-Hat Mixing Tips",
                "https://www.production-expert.com/production-expert-1/5-hi-hat-mixing-tips",
                "Set the cutoff frequency just below the point at which it "
                    + "starts to alter the sound significantly as you raise it, "
                    + "which will likely be somewhere between 200 and 400Hz.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "A hi-hat's usefulness IS its top end — cited content "
                + "runs to 17 kHz. Any corner low enough to matter would remove "
                + "the instrument."),
        bands: [
            // ⚠️ lowHz 300 EQUALS the high-pass corner — deliberate, §1.3 note 7.
            FrequencyBand(
                role: .body, lowHz: 300, highHz: 3000,
                effect: "The 'chick' — the substance of the closed hat, without "
                    + "which it becomes a hiss.",
                citation: hiHatRangeQuote),
            FrequencyBand(
                role: .harshness, lowHz: 4000, highHz: 8000,
                effect: "Ringing resonances that make busy hat patterns tiring "
                    + "over a whole song.",
                citation: cite(
                    "iZotope, How to Mix Hi-Hats",
                    "https://www.izotope.com/community/blog/how-to-mix-hi-hats",
                    "Pro-tip: remember that some resonances exist in a lower "
                        + "part of the spectrum, between 4\u{2013}8 kHz.")),
            FrequencyBand(
                role: .air, lowHz: 10000, highHz: 17000,
                effect: "Crispness and sparkle — the shimmer that sits above the "
                    + "rest of the kit.",
                citation: hiHatRangeQuote),
        ])

    private static let tomRow = InstrumentFrequencyReference(
        family: .tom,
        displayName: "Tom-tom",
        // 77.782 Hz (D#2) … 123.471 Hz (B2). 80 → 39; 120 sits within 0.012 Hz
        // of both 46 and 47, and the tie breaks OUTWARD → 47.
        fundamental: .pitched(lowestMIDINote: 39, highestMIDINote: 47),
        fundamentalCitation: cite(
            idrumtuneSource, idrumtuneURL,
            "For example, a 16 inch floor tom can feasibly be tuned to have a "
                + "fundamental frequency at 80 Hz or at 120 Hz."),
        // ADMISSION-DOUBTFUL (m23-o2) — see the kick row.
        fundamentalStrength: .admissionDoubtful,
        recommendedHighPass: .corner(
            hz: 60, slopeDbPerOct: 12,
            rationale: "Toms are the kit's biggest rumble source between hits — "
                + "the shells resonate with the kick. 60 Hz is the top of the "
                + "published starting range and still sits under the lowest "
                + "floor-tom fundamental near 78 Hz. SOURCE CAVEAT: this "
                + "fundamental is a TUNING CHOICE from a practice source, and "
                + "the only per-drum statement available covers a 16-inch floor "
                + "tom — the lowest drum in the family.",
            citation: cite(
                tomsSource, tomsURL,
                "Start with a gentle high-pass filter, rolling off everything "
                    + "below 40\u{2013}60 Hz.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "Stick definition lives at 4–8 kHz and cymbal spill "
                + "above it is a balance decision made with the overheads, not a "
                + "filter decision on the tom."),
        bands: [
            // The body/mud overlap is deliberate and both edges are cited: the
            // region genuinely carries warmth AND bloat. Do not "fix" it.
            FrequencyBand(
                role: .body, lowHz: 80, highHz: 250,
                effect: "The tom's own note — where each drum's pitch and sustain live.",
                citation: cite(multitrackedSource, multitrackedURL,
                    "experiment with frequencies between 80Hz and 250Hz to try "
                        + "to pick out the resonance of each tom")),
            FrequencyBand(
                role: .mud, lowHz: 150, highHz: 200,
                effect: "Bloat that makes a tom fill sound heavy and slow.",
                citation: cite(tomsSource, tomsURL,
                    "A gentle cut around 150\u{2013}200 Hz can clean things up.")),
            FrequencyBand(
                role: .boxiness, lowHz: 400, highHz: 600,
                effect: "The cardboard tone that makes close-miked toms sound cheap.",
                citation: cite(tomsSource, tomsURL,
                    "The 'cardboard' or 'boxy' sound tends to live between "
                        + "400\u{2013}600 Hz.")),
            FrequencyBand(
                role: .attack, lowHz: 4000, highHz: 8000,
                effect: "Stick definition — the tom's front edge in a busy fill.",
                citation: cite(multitrackedSource, multitrackedURL,
                    "a high\u{2011}end boost between 4 and 8kHz can add "
                        + "definition to the attack of a sound")),
        ])

    private static let rideCymbalRow = InstrumentFrequencyReference(
        family: .rideCymbal,
        displayName: "Ride cymbal",
        fundamental: .inharmonic(
            reason: "A ride cymbal is of indefinite pitch — its partials are "
                + "inharmonic, so there is no fundamental to state."),
        fundamentalCitation: cymbalIndefinitePitch,
        recommendedHighPass: .corner(
            hz: 200, slopeDbPerOct: 12,
            rationale: "A ride mic mostly hears the rest of the kit below "
                + "200 Hz. Cutting there removes kick and snare bleed while "
                + "leaving the cymbal's 300–600 Hz body intact; pushing the "
                + "corner higher starts thinning the cymbal itself. SOURCE "
                + "CAVEAT: this corner is CLASS-LEVEL guidance addressed to "
                + "cymbals generally, from a smaller publisher — it is not "
                + "ride-specific, and it is the weakest field on this row.",
            citation: cite(
                cymbalEQSource, cymbalEQURL,
                "In the case of cymbal EQ, there's nothing below 200Hz that we "
                    + "need, so set your high pass filter here as a starting point.")),
        // FILTER-WEAK (m23-o2): class-level cymbal guidance, not ride-specific.
        highPassStrength: .filterWeak,
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "The ride's sheen and air run to the top of the audible "
                + "band; a corner low enough to matter would remove the wash "
                + "that identifies the instrument."),
        // ⚠️ Exactly 3 distinct sources on this row (Wikipedia Cymbal, the
        // cymbal-EQ guide, Musical U) — that is V8's floor, not a margin.
        // Deleting any citation here fails V8.
        bands: [
            FrequencyBand(
                role: .body, lowHz: 300, highHz: 600,
                effect: "The weight behind the stick hit — cut too much and the "
                    + "ride turns into a hiss.",
                citation: rideRangeQuote),
            FrequencyBand(
                role: .presence, lowHz: 4000, highHz: 6000,
                effect: "Upper sheen — the sustained shimmer that carries the "
                    + "pattern under a vocal.",
                citation: rideRangeQuote),
        ])

    private static let crashCymbalRow = InstrumentFrequencyReference(
        family: .crashCymbal,
        displayName: "Crash cymbal",
        fundamental: .inharmonic(
            reason: "A crash cymbal is of indefinite pitch — its partials are "
                + "inharmonic, so there is no fundamental to state."),
        fundamentalCitation: cymbalIndefinitePitch,
        recommendedHighPass: .corner(
            hz: 200, slopeDbPerOct: 12,
            rationale: "Same reasoning as the ride: below 200 Hz a crash mic is "
                + "hearing the rest of the kit. The crash's own body starts "
                + "around 400 Hz, so 200 Hz leaves a comfortable margin. SOURCE "
                + "CAVEAT: as on the ride, this corner is CLASS-LEVEL guidance "
                + "about cymbals from a smaller publisher, not crash-specific.",
            citation: cite(
                cymbalEQSource, cymbalEQURL,
                "Begin by high passing around 200Hz to remove unwanted bleed and "
                    + "create space for the bass and kick.")),
        // FILTER-WEAK (m23-o2): class-level cymbal guidance, not crash-specific.
        highPassStrength: .filterWeak,
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "A crash is almost entirely high-frequency content; its "
                + "sheen is cited to 12 kHz and beyond. Cutting the top removes "
                + "the instrument."),
        bands: [
            FrequencyBand(
                role: .body, lowHz: 400, highHz: 500,
                effect: "The low clang of a big crash — what makes it feel large "
                    + "rather than thin.",
                citation: crashRangeQuote),
            FrequencyBand(
                role: .harshness, lowHz: 3000, highHz: 6000,
                effect: "The brash edge that makes repeated crashes painful over "
                    + "a whole song.",
                citation: cite(sparkleSource, sparkleURL,
                    "harshness can be reduced by cutting in the 3-6kHz region "
                        + "where cymbals tend to be at their most brash")),
            FrequencyBand(
                role: .air, lowHz: 10000, highHz: 12000,
                effect: "Sheen — the bright wash that opens the top of the mix on a hit.",
                citation: crashRangeQuote),
        ])

    private static let electricBassRow = InstrumentFrequencyReference(
        family: .electricBass,
        displayName: "Electric bass guitar",
        // 41.203 Hz (E1) … 97.999 Hz (G2). BOTH endpoints are stated by the
        // citation's tuning; Hz is derived, never quoted. Fretted notes go above
        // G2 and v1 invents no upper bound.
        fundamental: .pitched(lowestMIDINote: 28, highestMIDINote: 43),
        fundamentalCitation: cite(
            "Wikipedia, Bass guitar (New Grove tuning)",
            "https://en.wikipedia.org/wiki/Bass_guitar",
            "Electric bass guitar, usually with four heavy strings tuned "
                + "E1'\u{2013}A1'\u{2013}D2\u{2013}G2."),
        recommendedHighPass: .corner(
            hz: 30, slopeDbPerOct: 12,
            rationale: "Nothing musical exists below the low E's 41.2 Hz, but "
                + "stage rumble, handling noise and DI thump do — and they eat "
                + "headroom in the loudest part of the mix. The 12 dB/oct slope "
                + "is the shallower of the two the cited source names and the "
                + "only one of them this DAW can execute (its other option, "
                + "18 dB/oct, does not exist here). This corner is deliberately "
                + "NOT the folklore 80 Hz: at 80 Hz the low E loses about 12 dB "
                + "even at this gentle slope, and about 23 dB at 24 dB/oct. A "
                + "5-string's low B sits at 30.9 Hz and loses about 2.8 dB here.",
            citation: cite(
                "Sound On Sound, Mixing DI Bass Guitar",
                "https://www.soundonsound.com/techniques/mixing-di-bass-guitar",
                "So slope it off with a 30Hz high\u{2011}pass filter (HPF) at 12 "
                    + "or 18 dB per octave.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "String and fret noise and amp fizz run past 6 kHz and "
                + "are part of how a bass reads on small speakers. A low-pass "
                + "here is an arrangement decision, not cleanup."),
        bands: [
            FrequencyBand(
                role: .body, lowHz: 40, highHz: 80,
                effect: "The bottom octave — the weight the bass shares with the "
                    + "kick drum.",
                citation: bassBottomOctave),
            FrequencyBand(
                role: .presence, lowHz: 220, highHz: 300,
                effect: "The instrument's essential character — where a bass "
                    + "stops being a rumble and starts being an instrument.",
                citation: cite(
                    "Sound On Sound, Mix Tips For Kick & Bass",
                    kickBassURL,
                    "you'll probably identify that part of the sound that gives "
                        + "the bass its essential character somewhere in the "
                        + "220\u{2011}300 Hz region")),
            FrequencyBand(
                role: .harshness, lowHz: 3000, highHz: 6000,
                effect: "Hiss, amp fuzz, pick noise and filter whistle — where a "
                    + "boosted bass starts fighting the vocal.",
                citation: cite(mixingBassSource, mixingBassURL,
                    "nor sends too much hiss, amp fuzz, pick noise or filter "
                        + "whistle into a mix's 3-6kHz presence/harshness band")),
        ])

    private static let uprightBassRow = InstrumentFrequencyReference(
        family: .uprightBass,
        displayName: "Upright (double) bass",
        // 41.203 Hz (E1) … 97.999 Hz (G2). `highest` is the open G string; a
        // fretless fingerboard has no countable upper limit to cite, so none is
        // invented. A C-extension or 5-string reaches C1/B0 and the 35 Hz corner
        // clears V2a against both.
        fundamental: .pitched(lowestMIDINote: 28, highestMIDINote: 43),
        fundamentalCitation: cite(
            "Wikipedia, Double bass",
            "https://en.wikipedia.org/wiki/Double_bass",
            "The lowest note of a double bass is an E1 (on standard four-string "
                + "basses) at approximately 41 Hz or a C1 (\u{2248}33 Hz), or "
                + "sometimes B0 (\u{2248}31 Hz), when five strings are used."),
        recommendedHighPass: .corner(
            hz: 35, slopeDbPerOct: 12,
            rationale: "Slightly above the electric bass's corner on purpose: an "
                + "upright's body resonance and stage rumble sit lower and "
                + "louder than a DI'd electric, and the kick drum owns the "
                + "bottom octave in most arrangements.",
            citation: cite(mixingBassSource, mixingBassURL,
                "Kick drum will naturally tend to dominate over acoustic bass in "
                    + "the bottom octave, so try high-pass filtering the latter "
                    + "from around 35Hz.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "Bow and finger noise carry the instrument's identity; "
                + "cutting the top makes an upright sound like a synth bass."),
        bands: [
            FrequencyBand(
                role: .body, lowHz: 40, highHz: 80,
                effect: "The bottom octave the upright shares with the kick drum.",
                citation: bassBottomOctave),
            FrequencyBand(
                role: .presence, lowHz: 400, highHz: 800,
                effect: "Articulation — where the note's start becomes audible "
                    + "instead of just felt.",
                citation: cite(knobsSource, knobsURL,
                    "a gentle boost somewhere in the 400 to 800 Hz region can "
                        + "help a double bass to sound more articulate and "
                        + "present in the mix")),
        ])

    private static let electricGuitarRow = InstrumentFrequencyReference(
        family: .electricGuitar,
        displayName: "Electric guitar",
        // 82.407 Hz (E2) … 659.255 Hz (E5). The quote names the ACOUSTIC guitar;
        // this is the table's one stated scope exception, and it covers TUNING
        // claims only — standard tuning is a property of the string set and the
        // fretboard, not of the body, and the numbers agree to 0.05%.
        fundamental: .pitched(lowestMIDINote: 40, highestMIDINote: 76),
        fundamentalCitation: guitarStandardTuning,
        recommendedHighPass: .corner(
            hz: 80, slopeDbPerOct: 24,
            rationale: "A guitar cabinet produces boom below the low E that no "
                + "listener needs, and distorted chords generate a lot of it. "
                + "80 Hz sits just under the low E's 82.4 Hz fundamental — as "
                + "high as this corner may legally go. The widely repeated "
                + "'high-pass guitars at 150 Hz' advice is rejected here: at "
                + "150 Hz the open low E loses about 21 dB.",
            citation: cite(
                essentialsSource + " — Electric Guitar section", essentialsURL,
                "Cut below 80Hz to reduce unnecessary bassy cabinet boom.")),
        // THE ONLY ROW IN THE TABLE WITH A CORNER LOW-PASS, and therefore the
        // only row that exercises V3's low-pass half at all.
        recommendedLowPass: .corner(
            hz: 6000, slopeDbPerOct: 12,
            rationale: "A guitar amp cabinet rolls off on its own above about "
                + "6 kHz; anything above that is amp fizz, cymbal spill or DI "
                + "buzz rather than guitar.",
            citation: cite(knobsSource, knobsURL,
                "For example, most guitar amp cabinets don't produce a great "
                    + "deal of sound above 6kHz or so.")),
        bands: [
            FrequencyBand(
                role: .mud, lowHz: 150, highHz: 300,
                effect: "Thickness that turns into fog when several guitars are layered.",
                citation: cite(essentialsSource + " — Electric Guitar section",
                               essentialsURL, "Muddy at 150 to 300 Hz.")),
            FrequencyBand(
                role: .presence, lowHz: 800, highHz: 3000,
                effect: "The bite that lets a guitar be heard next to a vocal.",
                citation: cite(essentialsSource + " — Electric Guitar section",
                               essentialsURL, "Biting at 800Hz to 3kHz.")),
            FrequencyBand(
                role: .harshness, lowHz: 5000, highHz: 10000,
                effect: "Fizz from the amp's distortion — the region that makes "
                    + "long listens tiring.",
                citation: cite(essentialsSource + " — Electric Guitar section",
                               essentialsURL, "Fizzy at 5 to 10 kHz.")),
        ])

    private static let acousticGuitarRow = InstrumentFrequencyReference(
        family: .acousticGuitar,
        displayName: "Acoustic guitar",
        // 82.407 Hz (E2) … 659.255 Hz (E5) — the citation names this instrument
        // and states both endpoints, so no scope exception is needed here.
        fundamental: .pitched(lowestMIDINote: 40, highestMIDINote: 76),
        fundamentalCitation: guitarStandardTuning,
        recommendedHighPass: .corner(
            hz: 70, slopeDbPerOct: 12,
            rationale: "The low E fundamental sits at 82 Hz; what lies beneath "
                + "it on a close-miked acoustic is foot-tap, mic-stand and "
                + "handling noise. 70 Hz clears that without touching the "
                + "string. Keep the slope gentle: the same source that gives "
                + "this fundamental explicitly warns against reflexively "
                + "filtering an acoustic guitar, because room information and "
                + "low body are part of the sound. Note the quote states the "
                + "PLACEMENT REASONING, not the literal 70 — that number is this "
                + "row's engineering choice inside the cited statement.",
            citation: cite(knobsSource, knobsURL,
                "The fundamental frequency of the lowest note played on the "
                    + "acoustic guitar might be 80Hz or so, whereas most of the "
                    + "sound picked up from the foot-taps will be at lower "
                    + "frequencies.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "The source that measured this instrument found useful "
                + "content well above 10 kHz and argued explicitly against "
                + "low-passing it; string detail is what an acoustic guitar "
                + "contributes to a mix."),
        bands: [
            FrequencyBand(
                role: .mud, lowHz: 80, highHz: 150,
                effect: "Boom from the body cavity — pleasant alone, cloudy in a "
                    + "full mix.",
                citation: cite(essentialsSource + " — Acoustic Guitar section",
                               essentialsURL, "Boomy at 80 to 150 Hz.")),
            // ⚠️ This exact quote ALSO appears under the page's Drums heading —
            // the section named in `source` is what disambiguates it, so do not
            // drop the section from the source string.
            FrequencyBand(
                role: .boxiness, lowHz: 150, highHz: 300,
                effect: "The hollow, boxed-in tone of a close mic pointed at the "
                    + "soundhole.",
                citation: cite(essentialsSource + " — Acoustic Guitar section",
                               essentialsURL, "Boxy at 150 to 300 Hz.")),
            FrequencyBand(
                role: .presence, lowHz: 2500, highHz: 4000,
                effect: "Where the pick and the string meet — the guitar's front edge.",
                citation: cite(essentialsSource + " — Acoustic Guitar section",
                               essentialsURL, "Presence at 2.5 to 4 kHz.")),
            // ⚠️ highHz 20000 EQUALS V5's audible ceiling. V5 is NON-STRICT
            // there (`highHz <= 20_000`); a strict `<` rejects this row. The
            // upper edge is the ceiling itself, not a cited number — the source
            // says only "above 8 kHz".
            FrequencyBand(
                role: .air, lowHz: 8000, highHz: 20000,
                effect: "String shimmer and room detail — openness rather than "
                    + "brightness.",
                citation: cite(essentialsSource + " — Acoustic Guitar section",
                               essentialsURL, "Airy above 8 kHz.")),
        ])

    private static let pianoRow = InstrumentFrequencyReference(
        family: .piano,
        displayName: "Acoustic piano",
        // 27.500 Hz (A0) … 4186.009 Hz (C8) — the 88-key compass, derived from
        // the cited note names.
        fundamental: .pitched(lowestMIDINote: 21, highestMIDINote: 108),
        fundamentalCitation: cite(
            "Wikipedia, Piano",
            "https://en.wikipedia.org/wiki/Piano",
            "Most modern pianos have 52 white keys and 36 black keys, for a "
                + "total of 88 keys (seven octaves plus a minor third, from A0 "
                + "to C8)."),
        recommendedHighPass: .corner(
            hz: 30, slopeDbPerOct: 12,
            rationale: "The bottom key of an 88-note piano sounds at 27.5 Hz, so "
                + "the room to work in is tiny: any corner above 34.6 Hz starts "
                + "eating the instrument's own lowest note. 30 Hz removes pedal "
                + "thump, floor rumble and HVAC without touching A0. Every other "
                + "piano high-pass number this pass found in the wild (60, 70, "
                + "80 Hz) would cost A0 at least 14 dB, and up to 37 dB at the "
                + "steeper slope. SOURCE CAVEAT: this corner rests on a single "
                + "smaller publisher with no corroboration — the weakest-sourced "
                + "field in the table. The arithmetic above, not the source, is "
                + "what makes it safe.",
            citation: cite(
                "Stock Music Musician, How to EQ Piano",
                "https://www.stockmusicmusician.com/blog/tips-for-eqing-piano",
                // The BOTTOM of the cited range on purpose: 40 Hz — its top —
                // fails V2a against A0 (40 > 34.648).
                "Very gentle high-pass at 30\u{2013}40Hz (rumble only), minimal "
                    + "cutting.")),
        // FILTER-WEAK (m23-o2): a single smaller publisher, no corroboration.
        highPassStrength: .filterWeak,
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "A piano's harmonics run to the top of the audible band "
                + "and are most of what makes it read as a piano rather than an "
                + "electric keyboard."),
        bands: [
            FrequencyBand(
                role: .body, lowHz: 75, highHz: 250,
                effect: "Depth and richness — the wood and the soundboard.",
                citation: cite(pianoEQSource, pianoEQURL,
                    "With warmth, the goal here is to add a little extra depth "
                        + "and richness to the piano recording, which usually "
                        + "lies between 75Hz and 250Hz.")),
            FrequencyBand(
                role: .boxiness, lowHz: 350, highHz: 400,
                effect: "The boxed-in honk of a lid-down or close-miked piano.",
                citation: cite(pianoEQSource, pianoEQURL,
                    "When mixing piano, this boxy frequency range usually sits "
                        + "around 350Hz to 400Hz.")),
            // The leading "However," IS on the page and IS capitalised —
            // separately confirmed by a first-five-words check.
            FrequencyBand(
                role: .presence, lowHz: 3000, highHz: 4000,
                effect: "Cut-through for a lead piano line without making it brittle.",
                citation: cite(pianoEQSource, pianoEQURL,
                    "However, if you want your piano to cut through the mix, "
                        + "especially for leads, I usually reach for a little "
                        + "boost between 3-4kHz.")),
            FrequencyBand(
                role: .air, lowHz: 9000, highHz: 11000,
                effect: "Hammer and damper detail — the transient sparkle that "
                    + "reads as a real instrument.",
                citation: cite(pianoEQSource, pianoEQURL,
                    "These sounds typically sit in the 9-11kHz range, and "
                        + "they're crucial if you want your piano to punch "
                        + "through the mix.")),
        ])

    private static let maleVocalRow = InstrumentFrequencyReference(
        family: .maleVocal,
        displayName: "Male voice",
        // 87.307 Hz (F2) … 391.995 Hz (G4), derived from the cited note names.
        fundamental: .pitched(lowestMIDINote: 41, highestMIDINote: 67),
        fundamentalCitation: singingVoiceRanges,
        recommendedHighPass: .corner(
            hz: 80, slopeDbPerOct: 24,
            rationale: "Deliberately the LOW end of the published 50-100 Hz "
                + "window, because the conservative male floor F2 sounds at "
                + "87.3 Hz: a 100 Hz corner would cost that note about 6 dB, and "
                + "a bass singer below F2 more. The cited range is explicitly "
                + "CONSERVATIVE, so real voices reach under it. 80 Hz still "
                + "removes proximity-effect boom, plosive thump and stand "
                + "rumble. Steep slope, because everything under the corner on a "
                + "vocal track is noise.",
            citation: cite(vocalEQSource, vocalEQURL,
                "remove everything from anywhere between 50\u{2013}100 Hz and below")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "Vocal intelligibility and air live at the top; any "
                + "corner low enough to matter would dull the voice. Use a "
                + "de-esser for sibilance instead."),
        bands: [
            FrequencyBand(
                role: .rumble, lowHz: 20, highHz: 80,
                effect: "Room rumble, handling noise and mic bleed — none of it "
                    + "is the singer.",
                citation: cite(vocalEQSource, vocalEQURL,
                    "What lives below 80 Hz in a vocal recording is most often "
                        + "low frequency room rumble, microphone handling noise, "
                        + "microphone bleed from unintended sources, or inherent "
                        + "equipment noise.")),
            FrequencyBand(
                role: .body, lowHz: 100, highHz: 400,
                effect: "The main body and warmth — where the voice's own "
                    + "fundamentals sit.",
                citation: vocalFundamentals),
            FrequencyBand(
                role: .mud, lowHz: 300, highHz: 400,
                effect: "Where the voice piles up with guitars and keys and "
                    + "everything gets muddy.",
                citation: cite(maleVocalSource, maleVocalURL,
                    "One common problem is excess energy around 300-400 Hz. "
                        + "Because many instruments produce energy in this "
                        + "range, the sounds can 'pile up' and sound muddy.")),
            FrequencyBand(
                role: .presence, lowHz: 2500, highHz: 4500,
                effect: "Upper mids — the difference between a vocal that sits "
                    + "back and one that fronts the track.",
                citation: cite(maleVocalSource, maleVocalURL,
                    "If the vocal still sits too far back in a busy track, focus "
                        + "on the upper mids, using a parametric EQ boost, "
                        + "typically in the 2.5-4.5 kHz range.")),
        ])

    private static let femaleVocalRow = InstrumentFrequencyReference(
        family: .femaleVocal,
        displayName: "Female voice",
        // 174.614 Hz (F3) … 783.991 Hz (G5), derived from the cited note names.
        //
        // ⚠️ THIS ROW CARRIES TWO CITED, INCOMPATIBLE CLAIMS ABOUT THE SAME
        // QUANTITY, ON PURPOSE. The `fundamental` is a female-specific,
        // CONSERVATIVE F3–G5 from an acoustics reference. The `body` band below
        // cites a GENERIC-vocal figure of 100–400 Hz, whose lower edge sits
        // 75 Hz BELOW this row's own fundamental floor. Both are correctly
        // transcribed. The band is left extending below the floor because
        // `body` describes where the ENGINEER WORKS, not where the fundamentals
        // lie. **Do NOT "fix" this by raising the band to 174 Hz** — that number
        // would be uncited, and the advice would be wrong for a low female voice
        // whose chest register genuinely reaches under the conservative floor.
        // V3 is unaffected: 100 ≤ 100.
        fundamental: .pitched(lowestMIDINote: 53, highestMIDINote: 79),
        fundamentalCitation: singingVoiceRanges,
        recommendedHighPass: .corner(
            hz: 100, slopeDbPerOct: 24,
            rationale: "The TOP of the same published 50-100 Hz window the male "
                + "row takes the bottom of — the conservative female floor sits "
                + "an octave above the male one (174.6 Hz), so 100 Hz is pure "
                + "cleanup with 74 Hz of margin. This is the design's own worked "
                + "example of a legitimate dense-mix vocal corner.",
            citation: cite(essentialsSource + " — Vocals section", essentialsURL,
                "Most voices have little below 100Hz so use low cut to remove "
                    + "unwanted bass frequencies.")),
        recommendedLowPass: .noneRecommended(
            reason: .notRecommendedForThisSource,
            explanation: "Air and intelligibility live at the top of a vocal; a "
                + "corner low enough to matter would dull the voice. Use a "
                + "de-esser for sibilance instead."),
        bands: [
            // ⚠️ lowHz 100 EQUALS the high-pass corner — deliberate, §1.3 note 7.
            FrequencyBand(
                role: .body, lowHz: 100, highHz: 400,
                effect: "The main body and warmth — where the voice's own "
                    + "fundamentals sit.",
                citation: vocalFundamentals),
            FrequencyBand(
                role: .boxiness, lowHz: 800, highHz: 1500,
                effect: "Nasal, honky quality — the 'talking through a tube' region.",
                citation: cite(essentialsSource + " — Vocals section",
                               essentialsURL, "Nasal at 800Hz to 1.5kHz.")),
            FrequencyBand(
                role: .presence, lowHz: 2000, highHz: 4000,
                effect: "Penetration — where the voice cuts through a dense arrangement.",
                citation: cite(essentialsSource + " — Vocals section",
                               essentialsURL, "Penetrating at 2 to 4 kHz.")),
            FrequencyBand(
                role: .air, lowHz: 7000, highHz: 12000,
                effect: "Openness and breath — the sheen that makes a vocal sound "
                    + "expensive.",
                citation: cite(essentialsSource + " — Vocals section",
                               essentialsURL, "Airy at 7 to 12 kHz.")),
        ])

    // MARK: - Citation plumbing
    //
    // ONE home for each repeated source string, URL and shared quote. A source
    // used by several rows is declared ONCE here: two hand-typed copies of a
    // 150-character verbatim quote is exactly the divergence the construction
    // barrier exists to prevent, and a one-character drift between them would be
    // invisible in review.

    /// Every citation in this table was retrieved on the same day, during the
    /// m23-o1 Step 2 research pass. ONE home for the date.
    private static let retrievedDate = "2026-07-28"

    private static func cite(_ source: String, _ url: String,
                             _ quote: String) -> FrequencyCitation {
        FrequencyCitation(source: source, url: url, quote: quote,
                          retrieved: retrievedDate)
    }

    private static let idrumtuneSource = "iDrumTune (Dr Rob Toulson), Guide To Mixing Drums"
    private static let idrumtuneURL =
        "https://www.idrumtune.com/mixing-drums-know-your-drum-frequencies/"
    private static let kickBassURL = "https://www.soundonsound.com/techniques/mix-tips-kick-bass"
    private static let sparkleSource = "Sound On Sound, Tricks To Make Your Drums Sparkle"
    private static let sparkleURL =
        "https://www.soundonsound.com/techniques/tricks-make-your-drums-sparkle"
    private static let multitrackedSource = "Sound On Sound, Mixing Multitracked Drums"
    private static let multitrackedURL =
        "https://www.soundonsound.com/techniques/mixing-multitracked-drums"
    private static let mixingBassSource = "Sound On Sound, Mixing Bass (Mike Senior)"
    private static let mixingBassURL = "https://www.soundonsound.com/techniques/mixing-bass"
    private static let knobsSource = "Sound On Sound, EQ: What Do All Those Knobs Do?"
    private static let knobsURL =
        "https://www.soundonsound.com/sound-advice/eq-what-do-all-those-knobs-do"
    private static let essentialsSource = "Sound On Sound, Mixing Essentials"
    private static let essentialsURL = "https://www.soundonsound.com/techniques/mixing-essentials"
    private static let maleVocalSource =
        "Sound On Sound, How To Make Your Vocals Twice As Good! Part 2"
    private static let maleVocalURL =
        "https://www.soundonsound.com/techniques/how-make-your-vocals-twice-good-part-2"
    private static let tomsSource = "eMastered, How to EQ Toms"
    private static let tomsURL = "https://emastered.com/blog/floor-toms-eq"
    private static let pianoEQSource = "eMastered, How to EQ Piano"
    private static let pianoEQURL = "https://emastered.com/blog/piano-eq"
    private static let vocalEQSource = "iZotope, Ultimate guide: How to EQ vocals"
    private static let vocalEQURL = "https://www.izotope.com/en/learn/how-to-eq-vocals"
    private static let cymbalEQSource = "Music Guy Mixing, Cymbal EQ Guide"
    private static let cymbalEQURL = "https://www.musicguymixing.com/cymbal-eq/"
    private static let musicalUSource =
        "Musical U, Percussion Frequencies Part 2 \u{2013} Cymbals"
    private static let musicalUURL =
        "https://www.musical-u.com/learn/percussion-frequencies-part-2-cymbals/"

    /// Serves all THREE inharmonic rows — the encyclopedic statement that a
    /// cymbal has no definite pitch. Treated as a physics claim even though
    /// there is no range to derive: no acoustics-reference alternative was
    /// reachable (the two candidates 502 and publish no cymbal page).
    private static let cymbalIndefinitePitch = cite(
        "Wikipedia, Cymbal", "https://en.wikipedia.org/wiki/Cymbal",
        "The majority of cymbals are of indefinite pitch, although small "
            + "disc-shaped cymbals based on ancient designs (such as crotales) "
            + "sound a definite note.")

    /// Serves BOTH guitar rows. Self-verifying: E2 derives to 82.407 Hz against
    /// the quote's 82, E5 to 659.255 against 659 — agreement to 0.05%. The
    /// lowercase `hz` in the first instance is the page's own; do not normalise.
    private static let guitarStandardTuning = cite(
        "iZotope, How to EQ acoustic guitar in a mix",
        "https://www.izotope.com/en/learn/acoustic-guitar-eq.html",
        "Depending on the tuning, the low E string of an acoustic guitar sounds "
            + "at around 82 hz, while the 12th fret of the high E string plays "
            + "around 659 Hz.")

    /// One sentence states BOTH vocal rows' endpoints. Hz is derived from the
    /// note names, never quoted. Note the source's own word "conservatively" —
    /// real voices reach beyond both ends, which is why the male corner takes
    /// the low end of its window.
    private static let singingVoiceRanges = cite(
        "UNSW Music Acoustics (Joe Wolfe), Voice acoustics: an introduction",
        "https://newt.phys.unsw.edu.au/jw/voice.html",
        "Men's singing voice ranges are typically about an octave lower than "
            + "women's (conservatively, about F2 to G4 and F3 to G5, respectively).")

    /// The generic-vocal fundamentals figure, on BOTH vocal rows' `body` band.
    /// On `femaleVocal` it disagrees with that row's own fundamental floor — see
    /// the disclosure on the row.
    private static let vocalFundamentals = cite(
        vocalEQSource, vocalEQURL,
        "The fundamental frequencies of a vocal are typically found between 100 "
            + "and 400 Hz.")

    /// One sentence carries the bottom-octave band on BOTH bass rows.
    private static let bassBottomOctave = cite(
        mixingBassSource, mixingBassURL,
        "you'll want to give the bass as much room in the 40-80Hz region as you "
            + "can without completely losing the weight of the kick")

    /// Each of these three sentences carries TWO roles on its row (a low/body
    /// figure and an upper figure), which is why each is declared once.
    private static let hiHatRangeQuote = cite(
        musicalUSource, musicalUURL,
        "Typical hi-hats are usually between 300-3000 Hz dominant frequencies, "
            + "and can extend up to 10-17k Hz for crispness")

    private static let rideRangeQuote = cite(
        musicalUSource, musicalUURL,
        "So where does a ride cymbal live Hz wise? Typically between 300-600 Hz, "
            + "all the way up to 4-6k Hz for upper sheen.")

    /// "any where" is the page's own spelling.
    private static let crashRangeQuote = cite(
        musicalUSource, musicalUURL,
        "A typical crash can be any where from 400-500 Hz (or lower) all the way "
            + "up to 10k-12k Hz for sheen")

    // MARK: - The validator (design §7)

    /// Structural validation of the whole table. Returns the list of problems —
    /// a NON-EMPTY array IS the failure.
    ///
    /// Test-invoked, never a runtime `precondition`: a precondition would turn
    /// a data error into a crash for users, and the totality test already
    /// guarantees every row is constructed during the suite.
    ///
    /// Rules V1–V8 are design §7's table verbatim. Step 1's extra rule V9
    /// (which reported one finding per surviving placeholder row) was DELETED at
    /// Step 2b along with the scaffolding it policed — there is no placeholder
    /// left to find, and `validate().isEmpty` is now the whole gate.
    public static func validate() -> [String] {
        var problems: [String] = []
        // V8's counters — a validator over optional fields can legitimately
        // check nothing and return []. These prove the work happened.
        var rowsVisited = 0
        var hpCornersChecked = 0
        var citationsChecked = 0
        var desirableBandChecksRun = 0

        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]

        for family in InstrumentFamily.allCases {
            let row = reference(for: family)
            rowsVisited += 1
            let id = family.rawValue

            // V1 — pitched endpoints in range and ordered.
            if case .pitched(let lowest, let highest) = row.fundamental {
                if !(0 <= lowest && lowest <= highest && highest <= 127) {
                    problems.append("V1 \(id): fundamental endpoints out of order or "
                        + "out of 0…127 (lowest \(lowest), highest \(highest))")
                }
            }

            // V6 (WIDENED AT REVIEW — see the file header) — ANY row with no
            // desirable band leaves V3 vacuous, not just an inharmonic one.
            // It sits ABOVE the HP guard on purpose: it does not depend on the
            // corner, and running it before that `continue` keeps its V8 count
            // exactly equal to rowsVisited, so DELETING THIS CALL SITE is a
            // failing mutation rather than a silent one.
            desirableBandChecksRun += 1
            if let finding = missingDesirableBandFinding(
                family: family, fundamental: row.fundamental, bands: row.bands) {
                problems.append(finding)
            }

            // The HP is REQUIRED to be a corner (design D4); anything else is a
            // fail-open path that V8's hpCornersChecked count also catches.
            guard case .corner(let hpHz, let hpSlope, _, _) = row.recommendedHighPass else {
                problems.append("V4 \(id): recommendedHighPass is not a .corner — "
                    + "the high pass is REQUIRED for every row")
                continue
            }
            hpCornersChecked += 1

            // V2a / V2b — bound the corner against the row's OWN physics.
            // Deliberately NOT applied to inharmonic rows: V3 and V6 cover them.
            //
            // BOUNDARY (audited m23-o1 Step 2a, RE-MEASURED against the real
            // rows at Step 2b): both comparisons are STRICT, so a corner
            // sitting EXACTLY on either bound is LEGAL and only a value past
            // it is a finding. MEASURED through this very function by mutating
            // the table, not by reading the code — specs B05r…B08r, which
            // attribute BY FINDING TEXT because both probes also trip another
            // rule (a 6.875 Hz corner is outside EQParams' range, so V4 fires
            // either way; a 110 Hz corner on a vocal cuts the body band, so V3
            // fires either way). maleVocal hp == 110 → no V2a, `110.0.nextUp`
            // → V2a fires. piano hp == 6.875 → no V2b, `6.875.nextDown` → V2b
            // fires.
            //
            // ⚠️ CORRECTION — Step 2a's comment here claimed these bounds are
            // "computed irrationals" that NO decimal literal can land on
            // bit-for-bit. THAT IS FALSE, and B05r/B07r disprove it: the
            // literal 110 sits exactly on maleVocal's ceiling and 6.875 sits
            // exactly on piano's floor. The reasons differ, and only one is a
            // guarantee:
            //   • V2b is ALGEBRAICALLY exact when `lowestHz` is — dividing a
            //     Double by 4 is exact in binary. A0 is 440·2⁻⁴ = 27.5 on the
            //     nose, so its quarter is 6.875 on the nose.
            //   • V2a is a ROUNDING COINCIDENCE. A third of an octave is four
            //     semitones, so the ceiling *should* equal the pitch four
            //     notes up, and for maleVocal (F2 → A2 = 110) and snare /
            //     femaleVocal (F3 → A3 = 220) the two-step Double product
            //     lands there exactly. It does NOT always: electricGuitar's
            //     ceiling is 103.8261743949863 while pitch(E2+4) is
            //     103.82617439498628 — ONE ULP APART. So a refactor of this
            //     expression can move the bound by an ULP and turn a legal
            //     corner into a finding.
            // Do NOT add a tolerance to paper over that. Nothing in the table
            // depends on it: the tightest V2a pass is piano at 30 Hz against a
            // 34.65 Hz ceiling (86.6% of the headroom), and no shipping row
            // sits ON either bound. If a future row ever wants to, pin it with
            // a spec rather than trusting the arithmetic to stay put.
            if let lowestHz = row.fundamental.lowestHz {
                // V2a: at most a third of an octave above the lowest fundamental.
                // The bar costs that lowest note 8.66 dB at 24 dB/oct — a LIMIT,
                // not a target. This is the "does not eat the instrument"
                // invariant the staging gate structurally cannot express, because
                // the analyzer's lowest band starts at 40 Hz (design §1 F1/§8.2).
                let ceiling = lowestHz * pow(2.0, 1.0 / 3.0)
                if hpHz > ceiling {
                    problems.append(String(
                        format: "V2a %@: high-pass %.1f Hz is above %.1f Hz "
                            + "(a third of an octave over the lowest fundamental "
                            + "%.1f Hz) — the guidance eats the instrument",
                        id, hpHz, ceiling, lowestHz))
                }
                // V2b: decade-scale typo downward (80 → 8).
                if hpHz < lowestHz / 4.0 {
                    problems.append(String(
                        format: "V2b %@: high-pass %.1f Hz is below a quarter of "
                            + "the lowest fundamental %.1f Hz — likely a decade typo",
                        id, hpHz, lowestHz / 4.0))
                }
            }

            // V3 — the recommendation must not cut away the row's own
            // characteristic region.
            //
            // BOUNDARY (audited m23-o1 Step 2a, RE-MEASURED against the real
            // rows at Step 2b): `>` and `<` are STRICT, so a corner sitting
            // EXACTLY on the desirable edge is LEGAL — and that is the NORMAL
            // authoring case, not an edge case: "start the high-pass where the
            // body starts" puts hp == lowestDesirable on the nose. THREE
            // SHIPPING ROWS DO EXACTLY THAT (snare, femaleVocal, hiHat), so
            // `validate().isEmpty` is itself the standing proof of the
            // high-pass half's non-strictness — spec B01 was retired as
            // redundant against it, and making the comparison `>=` reddens
            // (spec T1-V3-strict). The other three directions still need
            // mutations, because no row sits on them:
            //   • B02r — snare hp `100.0.nextUp` against a 100 Hz body → V3
            //     fires. Note the message prints "100.0 Hz cuts into … 100.0
            //     Hz": the difference is below %.1f, which is what a boundary
            //     bug looks like in a log.
            //   • B03r — electricGuitar lp == 3000 against a 3000 Hz desirable
            //     top → NO finding.
            //   • B04r — the same corner at `3000.0.nextDown` → V3 fires.
            // Unlike V2 these bounds ARE decimal literals from the table, so
            // equality is reachable by construction rather than by luck, and
            // the non-strictness is load-bearing for real rows.
            //
            // ⚠️ V3's LOW-PASS half ran for the FIRST TIME at Step 2b, and it
            // runs on EXACTLY ONE ROW. `electricGuitar` is the only family whose
            // sources state an instrument-level top-end limit inside
            // `EQParams.lowPassFreqRange`; the other 12 rows are
            // `.noneRecommended`, so `cornerHz` is nil and this branch is
            // skipped. It was dead code against the Step-1 table — boundary
            // specs B03/B04 were the only evidence it worked at all. Deleting
            // that one corner would silently make it dead again.
            let desirable = row.bands.filter(\.role.isDesirable)
            if let lowestDesirable = desirable.map(\.lowHz).min(), hpHz > lowestDesirable {
                problems.append(String(
                    format: "V3 %@: high-pass %.1f Hz cuts into the desirable band "
                        + "starting at %.1f Hz", id, hpHz, lowestDesirable))
            }
            if let lpHz = row.recommendedLowPass.cornerHz,
               let highestDesirable = desirable.map(\.highHz).max(), lpHz < highestDesirable {
                problems.append(String(
                    format: "V3 %@: low-pass %.1f Hz cuts into the desirable band "
                        + "ending at %.1f Hz", id, lpHz, highestDesirable))
            }

            // V4 — a recommendation the house EQ would silently clamp is broken.
            //
            // BOUNDARY (audited m23-o1 Step 2a, RE-MEASURED against the real
            // rows at Step 2b): both `EQParams` ranges are
            // `ClosedRange<Double>` (`Effects.swift:184-185`), so `contains` is
            // INCLUSIVE at both ends and a corner exactly on 20 / 1000 / 20000
            // is legal. MEASURED, specs B13r/B14r: electricGuitar's low-pass
            // at exactly 1000.0 — `lowPassFreqRange`'s LOWER bound — produced
            // no V4 finding, while `1000.0.nextDown` produced one. (Both also
            // trip V3, since 1 kHz cuts the 3 kHz top of the presence band, so
            // that pair is attributed by finding text rather than by
            // pass/fail.) Had these been half-open `Range`s, every corner on
            // the top bound would have been a false finding; they are not.
            if !EQParams.highPassFreqRange.contains(hpHz) {
                problems.append(String(
                    format: "V4 %@: high-pass %.1f Hz is outside "
                        + "EQParams.highPassFreqRange — fx.setParam would clamp it",
                    id, hpHz))
            }
            if hpSlope != 12 && hpSlope != 24 {
                problems.append("V4 \(id): high-pass slope \(hpSlope) dB/oct is "
                    + "neither 12 nor 24")
            }
            if case .corner(let lpHz, let lpSlope, _, _) = row.recommendedLowPass {
                if !EQParams.lowPassFreqRange.contains(lpHz) {
                    problems.append(String(
                        format: "V4 %@: low-pass %.1f Hz is outside "
                            + "EQParams.lowPassFreqRange — fx.setParam would clamp "
                            + "it (use .noneRecommended(.belowHouseEQRange))",
                        id, lpHz))
                }
                if lpSlope != 12 && lpSlope != 24 {
                    problems.append("V4 \(id): low-pass slope \(lpSlope) dB/oct is "
                        + "neither 12 nor 24")
                }
            }

            // V5 — inverted or degenerate spans.
            //
            // BOUNDARY (audited m23-o1 Step 2a) — the three comparisons here
            // deliberately do NOT agree, and that asymmetry is the rule:
            //   • `highHz <= 20_000` is NON-STRICT. A band ending exactly at
            //     20 kHz is legal (air bands routinely do). acousticGuitar's
            //     air band SHIPS at 8000…20000, so `validate().isEmpty` is
            //     itself the standing proof and spec B09 was retired as
            //     redundant against it; making the comparison `<` reddens
            //     (spec T2-V5-strict). MEASURED in the other direction, spec
            //     B10r (`20_000.0.nextUp`) → V5 fires.
            //   • `lowHz < highHz` is STRICT and MUST STAY STRICT. A zero-width
            //     band is degenerate — it names no region. MEASURED, spec B11r
            //     (tom's mud band as `150…150`) → V5 fires, which is CORRECT,
            //     not a bug.
            //   • `0 < lowHz` is STRICT. A band starting at DC is not a band.
            //     MEASURED, spec B12r (tom's mud band as `0…200`) → V5 fires.
            // So "a value exactly on a V5 bound" has two different answers
            // depending on WHICH bound: legal at 20 kHz, rejected at the span
            // ends. A row that trips V5 at `lowHz == highHz` is a table error.
            for band in row.bands {
                if !(0 < band.lowHz && band.lowHz < band.highHz && band.highHz <= 20_000) {
                    problems.append(String(
                        format: "V5 %@: band %@ span %.1f…%.1f Hz is degenerate or "
                            + "out of 0…20000", id, band.role.rawValue,
                        band.lowHz, band.highHz))
                }
            }

            // V7 — fabrication-friendly citation shapes.
            for (index, citation) in row.allCitations.enumerated() {
                citationsChecked += 1
                let where_ = "\(id) citation #\(index)"
                if citation.source.isEmpty { problems.append("V7 \(where_): empty source") }
                if citation.quote.isEmpty { problems.append("V7 \(where_): empty quote") }
                if citation.retrieved.isEmpty {
                    problems.append("V7 \(where_): empty retrieved date")
                } else if isoDate.date(from: citation.retrieved) == nil {
                    problems.append("V7 \(where_): retrieved '\(citation.retrieved)' "
                        + "is not an ISO-8601 full date")
                }
                if citation.url.isEmpty {
                    problems.append("V7 \(where_): empty url")
                } else if !citation.url.hasPrefix("https://") {
                    problems.append("V7 \(where_): url does not start https://")
                }
                if citation.quote.count > 200 {
                    problems.append("V7 \(where_): quote is \(citation.quote.count) "
                        + "characters, over the 200 limit")
                }
                // Ellipsis and square brackets both mean the quote was EDITED,
                // which defeats the fetch-and-search spot-check. The design's
                // V-table abbreviates to the ellipsis; §7 rule 1's full text
                // forbids square-bracket edits too, and this checks both.
                if citation.quote.contains("...") || citation.quote.contains("…") {
                    problems.append("V7 \(where_): quote contains an ellipsis")
                }
                if citation.quote.contains("[") || citation.quote.contains("]") {
                    problems.append("V7 \(where_): quote contains a square-bracket edit")
                }
            }

        }

        // V8 — the anti-fail-open counts.
        let expectedRows = InstrumentFamily.allCases.count
        if rowsVisited != expectedRows {
            problems.append("V8: visited \(rowsVisited) rows, expected \(expectedRows)")
        }
        if hpCornersChecked != expectedRows {
            problems.append("V8: checked \(hpCornersChecked) high-pass corners, "
                + "expected \(expectedRows) — every row's HP is REQUIRED")
        }
        if citationsChecked < 3 * expectedRows {
            problems.append("V8: checked \(citationsChecked) citations, expected at "
                + "least \(3 * expectedRows)")
        }
        // Gates the CONSUMER, not just the rule: without this, deleting V6's
        // call site above leaves every V6 leg green (the rule leg calls the
        // function directly, the table leg reads row.bands directly) and the
        // hole silently re-opens under Step 2's `#expect(validate().isEmpty)`.
        if desirableBandChecksRun != expectedRows {
            problems.append("V8: ran \(desirableBandChecksRun) desirable-band "
                + "checks, expected \(expectedRows) — V6 must run for EVERY row")
        }
        return problems
    }

    /// **V6, WIDENED AT REVIEW.** Returns a finding when `bands` carries no
    /// DESIRABLE role — for a pitched row exactly as much as for an inharmonic
    /// one. See the file header for why the original inharmonic-only wording
    /// was a hole: V3's two checks bind through `desirable.map(...).min()` /
    /// `.max()`, so an empty `desirable` makes V3 check NOTHING, and a row
    /// listing only rumble/mud/boxiness/harshness/sibilance tells the copilot
    /// what to CUT while never recording what makes the instrument sound like
    /// itself. Do NOT re-narrow this to `.inharmonic`.
    ///
    /// It is factored out of `validate()` for one reason: `validate()` runs
    /// over the REAL table and rows are unconstructible outside this file (the
    /// barrier), so a test can only reach this rule through its parts. Keeping
    /// it a pure function over `(family, fundamental, bands)` means the test
    /// exercises the SAME code `validate()` runs, not a re-implementation.
    static func missingDesirableBandFinding(
        family: InstrumentFamily,
        fundamental: Fundamental,
        bands: [FrequencyBand]
    ) -> String? {
        guard !bands.contains(where: \.role.isDesirable) else { return nil }
        let shape: String
        switch fundamental {
        case .pitched: shape = "pitched"
        case .inharmonic: shape = "inharmonic"
        }
        return "V6 \(family.rawValue): \(shape) row carries no desirable band, "
            + "so V3 checks nothing for it"
    }
}
