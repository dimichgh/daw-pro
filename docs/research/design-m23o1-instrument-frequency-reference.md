# m23-o1 — Instrument frequency reference: the family axis, the honest-nil ladder, and `frequency.reference`

**Design, 2026-07-28 · daw-architect · for implementing agents (route: research-analyst for the table CONTENT, mcp-integration-engineer for the four surfaces, qa-test-engineer for the staging gate).**
Scope: `docs/ROADMAP.md` line 441, `(m23-o1)`. Sibling `m23-o2` (pixels) rides on this and must not start before it.
Extends nothing; consumes `m22-a` (EQ HP/LP with slopes), `m23-r4` (`fx.spectrum`, wire 162).

**This document decides SHAPE, not NUMBERS.** No frequency value in here is table content. Every Hz figure below is either a constant already in the repo (`MasterMixAnalyzer.bandEdges`, `EQParams.highPassFreqRange`) or an arithmetic consequence of one, and each is shown with its derivation so the reader can check it. The table's actual rows are the research-analyst's job under §10 Step 2, governed by §7's admission rules.

---

## 0. Decisions, in one screen

| # | Decision |
|---|---|
| **D1** | **A v1 enum of 20 families, authored for engineering usefulness, in DAWCore.** Admission rule: *reachable by the ladder* ∧ *merging with its nearest neighbour would change the advice* ∧ *citable as a physical property of the instrument, not a genre convention.* Synths and section/ensemble sounds are **excluded on principle** (their range is a property of the patch/arrangement, not the instrument). GM program → family is an authored **128-entry array with an explicit `nil`** at every uncovered program. |
| **D2** | **Four-rung ladder: caller-supplied `family` → GM melodic program → GM percussion note → `unresolved(reason:)`.** The "explicit override" rung is a **per-call argument, not a persisted `Track` field** — no project-file schema change in v1. **No track-NAME heuristic, not even as a labelled suggestion.** The nil case is a first-class enum case carrying `reason` + `explanation` + `remedy`, and **every response — including the failure — carries the full family index**, so an unresolved answer is self-remedying in one round trip. |
| **D3** | **Percussion is IN v1, keyed by GM percussion note.** 17 covered notes across 6 drum families. An instrument track whose bank is `percussionBankMSB` (120) resolves to `.drumKit(coveredNotes:)`, *not* to a family — the payload names what is covered, so "not covered yet" can never read as "no data". |
| **D4** | **Three quantities, three representations.** Fundamental = **MIDI note numbers only**, Hz strictly derived (`440·2^((n−69)/12)`) — a typo'd Hz literal is unrepresentable. Presence/problem bands = Hz + **an inline citation each, with a verbatim quote**. HP/LP = a **separate** `FilterRecommendation`; HP is **required**, LP is a sum type with `.noneRecommended(reason:)`. Construction follows `InsertSpectrumTapPoint`: `fileprivate init` + static rows, one file. |
| **D5** | **A NEW namespace: `frequency.reference`** (the `note.*` precedent, m23-d). `instrument.*` means plugin/bank discovery, `reference.*` is m22-g's reference tracks, `fx.describe` is effect-param metadata. Params: `family?`, `trackId?`, `note?` — all optional; zero params is the legal "teach me the vocabulary" call. |
| **D6** | **The resolution ladder is a pure DAWCore function**, not inline in `Commands.swift`, because **m23-o2's EQ card must resolve identically** — one home for the RESOLUTION, separate from the one home for the VALUES. |
| **D7** | **The headline behavioural gate is two-sided and relative**, not absolute-dB: the recommended corner must *not* eat the instrument, and a deliberately naive corner must visibly cut. See §1 F1 — the gate as briefed could not have reddened. |

Wire count **162 → 163**. MCP tools **165 → 166**. Copilot catalog **68 → 69**.
Nothing here needs full Xcode: no entitlements, no AUv3, no signing. `swift build` + `./scripts/test.sh` + `npm test` + one staging run on port 17695 cover it.

---

## 1. Premise checks — three corrections to the brief, one confirmation, one labelled inference

The last two cycles turned on a premise that did not survive checking, so each of these is stated with the arithmetic or the file:line that establishes it.

### F1 (CORRECTION, and the load-bearing one) — the briefed headline gate could not have reddened

The brief says: *read the bass reference → HP at its recommended corner → measure with `fx.spectrum` that content below the cut dropped.* **For a bass, that measurement is structurally impossible with our analyzer.**

- `Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift:68-69` — `lowestBandHz = 40.0`. `bandEdges[k] = 40·400^(k/24)`, so **band 0 is [40.00, 51.34) Hz and there is nothing below it.** Everything under 40 Hz is outside the instrument the gate would measure with.
- `:116-119` + `:123-129` — `bandIndex(containing:)` *clamps* anything below 40 Hz to band 0. A 30 Hz tone does not read at 30 Hz; it reads as whatever leaks into the 40–51 Hz window.
- `Sources/DAWCore/EQFilterResponse.swift:48-52` — the HP is a **true Butterworth** cascade (Q = 0.7071 at 12 dB/oct; Qs 0.5412 / 1.3066 at 24 dB/oct), so `|H(f)| = (f/fc)^n / √(1+(f/fc)^(2n))` is exact, with n = 2 or 4.

Consequences, computed:

| corner `fc` | attenuation at 41.20 Hz (E1) | at 46.88 Hz (band 0's only bin @ 48 kHz) |
|---|---|---|
| 30 Hz, 24 dB/oct | **−0.33 dB** | **−0.12 dB** |
| 40 Hz, 24 dB/oct | −2.53 dB | ≈ −1 dB |
| 60 Hz, 24 dB/oct | −13.27 dB | −9.14 dB |
| 200 Hz, 24 dB/oct | −54.89 dB | −50.41 dB |

A plausible bass HP recommendation sits near 30 Hz (a 4-string's low E is 41.2 Hz; a 5-string's low B is 30.87 Hz). **Applying it moves band 0 by about a tenth of a dB** — indistinguishable from doing nothing, and far under the noise of a live poll. A gate asserting "content below the cut dropped" would have been green with the filter wired to nothing at all.

**Observability limit, stated so nobody re-discovers it:** through `fx.spectrum`, **any HP corner below ≈ 54 Hz is indistinguishable from no filter** for a bass-range probe (solving `|H(46.88 Hz)| = −6 dB` for n = 4 gives fc = 53.8 Hz).

**The repair is not to abandon bass** (it is the user's own scenario) — it is to make the leg *relative and two-sided*. See §8 legs B1–B4: the recommended corner must leave the family's own lowest fundamental essentially intact (≤ 6 dB), and a deliberately naive 200 Hz corner on the same fixture must produce ≥ 15 dB of drop in the same band with the control band unmoved. The first assertion is a statement about the *relationship* between the corner and the fundamental range, which is exactly the property the table exists to get right; the second proves the measurement chain is alive. **A red B2 is a DATA verdict — the shipped guidance cuts into the instrument — never a threshold to loosen.**

### F2 (CORRECTION) — our own EQ cannot execute low-pass advice below 1 kHz

`Sources/DAWCore/Effects.swift:184-185`:

```swift
public static let highPassFreqRange: ClosedRange<Double> = 20...1_000
public static let lowPassFreqRange: ClosedRange<Double> = 1_000...20_000
```

`fx.setParam` clamps silently into these ranges (`Commands.swift:4263` names the clamp law). So a row recommending "LP the kick at 800 Hz" would be **silently clamped to 1000 Hz** by the very command the copilot is told to use — the advice and the action would disagree with nothing surfaced. Two v1 consequences, both in D4: `recommendedLowPass` is a **sum type**, and `.noneRecommended(.belowHouseEQRange)` is the honest answer where real practice would cut below 1 kHz; and a validator pins **every shipped HP into `highPassFreqRange` and every shipped LP into `lowPassFreqRange`**. A recommendation the DAW cannot execute is a broken recommendation, not a rounding problem.

### F3 (CORRECTION) — several of the highest-value families have no fundamental at all

Hi-hats, ride and crash cymbals are **inharmonic**: there is no fundamental range to store, and a plausible-looking one is precisely the confabulation this item is guarding against. `Fundamental` must therefore be a **sum type** (`.pitched(lowest:highest:)` / `.inharmonic(reason:)`), not an optional pair of Ints and not a struct with sentinel zeros. Kick, snare and toms *do* have a published tuning range and stay `.pitched`; the admission rule in §7 tells the researcher which case a row takes and forbids inventing the other.

### F4 (CONFIRMATION, with one de-dup) — the brief's namespace survey is correct

Verified in `Sources/DAWControl/Commands.swift`: `instrument.*` is exactly the five discovery/import verbs (`:219-223`), `reference.*` is exactly m22-g's eight (`:328-335`), `note.audition` is the m23-d new-namespace precedent (`:338`), `fx.describe` is at `:1401`. No re-derivation needed; D5 builds on it.

One de-dup the brief did not have: **upright bass and double bass and GM 43 "Contrabass" are the same instrument.** v1 ships `uprightBass` once and maps GM 32 (Acoustic Bass) and GM 43 (Contrabass) both onto it. Shipping `uprightBass` *and* `contrabass` would be two rows with one physics.

### F5 (LABELLED INFERENCE — do not build on it as measured fact)

`MasterMixAnalyzer.swift:155-158`'s doc comment says bands are contiguous bin runs and *"a band with no bin center inside it reads its single nearest bin"*. At 2048-pt / 48 kHz the bin spacing is 23.44 Hz, so bands 0 and 1 (40–51.34 and 51.34–65.90) **appear** to share bin 2. **I did not measure this**, and the standing correction in memory (the `insertAnalysis` "drain" claim propagated from a doc comment) is exactly this failure mode. It does not threaten F1 — that is pure filter arithmetic, independent of binning — but it does constrain the gate: **probe and control bands must be widely separated (§8 uses bands 0 and 8), no leg may assert anything about adjacent low bands, and ties in the Δ-argmax assertion must be permitted** (§8 B3 asserts the probe band *is a* maximizer, not *the unique* maximizer).

---

## 2. D1 — the family axis

**Decision. A v1 enum of exactly 20 cases in DAWCore, keyed for engineering usefulness, with GM mapped onto it lossily.**

```swift
public enum InstrumentFamily: String, Sendable, Codable, CaseIterable, Hashable {
    // Percussion — reached by GM percussion NOTE (D3), never by program.
    case kick, snare, hiHat, tom, rideCymbal, crashCymbal
    // Bass
    case electricBass, uprightBass
    // Guitar
    case electricGuitar, acousticGuitar
    // Keys
    case piano, electricPiano
    // Voice
    case maleVocal, femaleVocal
    // Bowed strings
    case violin, viola, cello
    // Winds
    case trumpet, trombone, flute
}
```

### The admission rule (this, not the list, is the decision)

A family exists in v1 **iff all three hold**:

1. **Reachable.** At least one GM melodic program or GM percussion note maps to it, **or** it is a name a user/agent would plausibly pass as `family` for an audio track. (A family nothing can reach is dead weight that only widens the surface an LLM can hallucinate into.)
2. **Actionable.** Merging it into its nearest included neighbour would **change the advice**: its fundamental endpoints differ by ≥ 3 semitones, **or** its recommended HP differs by ≥ 1/3 octave. (Two rows with the same numbers are one row with two names — and two names for one answer is how an agent starts believing the distinction means something.)
3. **Citable as physics, not convention.** The fundamental range must be a published property of the instrument. If the only support is "engineers usually...", the row does not exist.

### What rule 3 excludes, and why that is the point

**Every synthesised family is out of v1** — `synthBass`, `synthLead`, `synthPad`, and all of GM 80–103. A synth patch's range is a property of the *patch*, not of any instrument; "synth bass sits 40–200 Hz" is a genre observation wearing a lab coat. This is the same argument the roadmap makes about `Ensemble` / `Synth Effects` / `Sound Effects`, applied consistently. **And the DAW has a better answer for synths already: `fx.spectrum` MEASURES what the patch actually produces.** Guessing is strictly worse than the measurement we shipped yesterday.

Also out for the same reason: organ (registration moves the sounding octave — a 16' drawbar sounds an octave below the key), sections/ensembles (a string section spans four families at once), choir programs (GM 52–54 span male *and* female ranges), orchestra hit, and the whole Sound Effects / Ethnic / Chromatic Percussion / Percussive categories.

Out for **cost-of-confidence**, not principle — deliberately deferred, each resolving to an honest `nil`: saxophones, clarinet, oboe, bassoon, piccolo, recorder, French horn, tuba, harp, timpani, side stick, tambourine, cowbell, splash/china cymbals, ride bell. **Deferral is cheap precisely because D2 makes `nil` first-class and self-describing.** A smaller v1 costs coverage; a bigger v1 costs confidence per row, and confidence is the scarce resource in a table of folklore.

### Why 20 and not 32

The long tail (four saxophones, four more brass, four more woodwinds) satisfies rules 1 and 2 but multiplies the **spot-check burden** — the gate hazard the roadmap names is fabricated citations, and the only real defence is a human-checkable sample per row. 20 rows with verifiable quotes beats 32 rows with a sampled 20%. The mechanism that makes the number safe to revisit is in §7: **the enum is fixed by this design; the table is TOTAL over `allCases` by test; a row the researcher cannot cite gets its CASE DELETED (a compile-time change that automatically turns its GM mappings into `nil`), never guessed.** Adding families later is additive and needs no wire change.

### GM → family is an authored 128-entry array, not a computed rule

```swift
/// Index == 0-based GM melodic program, exactly like
/// `GMProgramCatalog.programNames`. `nil` is AUTHORED at every uncovered
/// program — never a default, never a fallthrough.
static let melodicProgramFamilies: [InstrumentFamily?]   // count == 128
```

Sketch of the intended mapping (the researcher may narrow it, never widen it): 0–3 → `piano`; 4–5 → `electricPiano`; 24–25 → `acousticGuitar`; 26–30 → `electricGuitar`; 32 → `uprightBass`; 33–37 → `electricBass`; 40 → `violin`; 41 → `viola`; 42 → `cello`; 43 → `uprightBass`; 56 → `trumpet`; 57 → `trombone`; 59 (muted trumpet — same instrument, same fundamentals) → `trumpet`; 73 → `flute`; **everything else `nil`**, including 6–7, 8–23, 31, 38–39, 44–55, 58, 60–72, 74–127.

Two guards, both tests, because an array of 128 mostly-nil entries is exactly the shape that silently shifts by one:

- `count == 128`.
- **Category consistency sweep:** for every program `p` with a non-`nil` family `f`, `GMProgramCatalog.category(forProgram: p)` must be in `f`'s declared allowed GM categories (`electricBass`/`uprightBass` → "Bass" or "Strings" for 43; `violin`/`viola`/`cello` → "Strings"; `trumpet`/`trombone` → "Brass"; and so on). A one-index shift breaks this mechanically instead of needing review.

---

## 3. D2 — the resolution ladder, and how it fails honestly

**Decision.** One pure DAWCore function, four rungs, and a first-class failure.

```swift
// Sources/DAWCore/InstrumentFamilyResolution.swift
public enum InstrumentFamilyResolution: Sendable, Equatable {
    case resolved(InstrumentFamily, source: Source)
    case drumKit(coveredNotes: [Int])
    case unresolved(Reason)

    public enum Source: String, Sendable, Codable {
        case argument, gmProgram, gmPercussionNote
    }
    public enum Reason: String, Sendable, Codable {
        case audioTrackHasNoInstrument
        case instrumentKindCarriesNoFamily   // testTone / polySynth / sampler
        case hostedAudioUnitIsOpaque         // audioUnit
        case soundBankSelectionMissing       // kind == .soundBank, soundBank == nil
        case gmProgramNotCoveredInV1
        case percussionNoteNotCoveredInV1
        case trackIsNotAnInstrumentOrAudioTrack   // bus / master
    }
}

public enum InstrumentFamilyResolver {
    /// THE ONLY resolution home. m23-o2's EQ card calls THIS, not a copy.
    public static func resolve(trackKind: TrackKind,
                               instrument: InstrumentDescriptor?,
                               percussionNote: Int?) -> InstrumentFamilyResolution
}
```

### The rungs

1. **Caller-supplied `family`.** Handled *above* the resolver, in the command handler: if `family` is present it wins outright and the response says `resolvedFrom: "argument"`. **This is the "explicit override" rung.**
2. **GM melodic program** — only for `instrument?.kind == .soundBank` with a non-nil `SoundBankConfig` at `bankMSB == GMProgramCatalog.melodicBankMSB`. `melodicProgramFamilies[program]`; `nil` → `.unresolved(.gmProgramNotCoveredInV1)`.
3. **GM percussion note** — bank `percussionBankMSB` (120). Without a `note`: `.drumKit(coveredNotes:)`. With one: the note map, or `.unresolved(.percussionNoteNotCoveredInV1)`.
4. **`.unresolved(reason)`** for everything else — and "everything else" is the *common* case, not the edge: audio tracks (`TrackKind.audio`, `instrument == nil`) are where "clean up this bass" actually lives.

`Reason` carries `explanation` and `remedy` as computed properties **in that same file** (the `InsertSpectrumTapPoint` shape: the wire string, the agent-facing sentence, and any future UI label are one value, so they cannot drift).

### Why the override is a per-call argument and not a persisted `Track` field

Alternative A — **`Track.instrumentFamily: InstrumentFamily?`, additive-optional, with a `track.setFrequencyFamily` verb.** Loses on three counts: it is a project-document schema change plus a *second* wire command plus a UI affordance to set it, none of which m23-o1 needs to close its gap; a stored value goes stale the moment the user swaps the instrument, with nothing to notice; and it invents a persistent user-visible setting before a single pixel (m23-o2) has shown whether users ever want to override. **Filed as a future decision, not built.** Because the argument rung already exists, adding persistence later is additive on every surface.

Alternative B — **resolve from the track's `SamplerParams` zone file names / AU plugin name.** Loses hard: it is a name heuristic with extra steps and a worse signal (an AU named "Serum" tells you nothing about range).

### Track-NAME heuristics: NOT in v1, not even as a suggestion

**Decision: no substring matcher, no `suggestedFamily`, no `confidence` field.**

The argument that settles it: **the caller already has the track name.** `project.snapshot` gives every agent the string "Bass DI 01"; the in-app copilot sees it in context. A Swift substring table adds *no information the caller lacks*, but it does add an **authority gradient** — a field named `family` coming back from the DAW reads as *the DAW knows*, and an LLM will act on it. A field named `suggestedFamily` is no better: it will be summarised as the answer two turns later. Meanwhile the failure mode is severe and silent: "Bass" in a track name is as likely to mean a bass *drum* as a bass *guitar*, and the two families' recommended corners differ by roughly an octave — the copilot would confidently HP a kick at a bass guitar's corner, or worse, the reverse.

What v1 ships instead is **teaching**: the unresolved payload names the reason, states the remedy (*"call again with `family`"*), and — critically — **carries the full family index in the same response**, so the caller's next move needs no extra round trip and no guessing about vocabulary. An agent that reads "Bass DI 01", sees `unresolved`, and picks `electricBass` from the enumerated list has made a *visible* inference at the layer that is allowed to infer. That is the difference between an agent guessing and a data source lying.

### The nil case is representable, not empty

`.unresolved(reason)` is a **case with a payload**, never an empty struct, never `{}` , never a row of zeros. On the wire:

```json
{
  "resolution": "unresolved",
  "reason": "audioTrackHasNoInstrument",
  "explanation": "This is a recorded audio track, so the project carries no instrument identity for it — the DAW cannot tell a bass DI from a vocal.",
  "remedy": "Call frequency.reference again with `family` set to one of the ids in `families` below.",
  "families": [ ...the full index... ]
}
```

---

## 4. D3 — percussion: IN v1, keyed by GM note, with the exclusion stated in the payload

**Decision. Percussion ships in v1, keyed by GM percussion note number, covering 17 notes across 6 families.**

They are the highest-value rows in any frequency reference (kick/snare/hat cleanup is the single most common EQ move in the DAW's target genres), the key already exists in the protocol (`clip.addMIDI` pitches are GM percussion notes when the bank is 120), and excluding them would leave the most-asked question answered by nothing.

Intended note map (GM Level 1 percussion, bank MSB 120):

| Family | Notes |
|---|---|
| `kick` | 35, 36 |
| `snare` | 38, 40 |
| `hiHat` | 42, 44, 46 |
| `tom` | 41, 43, 45, 47, 48, 50 |
| `rideCymbal` | 51, 59 |
| `crashCymbal` | 49, 57 |

**Everything else is `.unresolved(.percussionNoteNotCoveredInV1)`** — including 37 side stick, 39 hand clap, 52 china, 53 ride bell, 54 tambourine, 55 splash, 56 cowbell. Each of those has a genuinely different spectrum; folding them into a neighbour would be exactly the confident-wrong-answer failure this item exists to prevent.

**The exclusion is stated in the payload, not implied by silence** — this is the roadmap's explicit requirement:

- A drum-kit track queried with no `note` returns `resolution: "drumKit"` **plus `coveredNotes` (the 17) plus `families`**, so "which pieces do you know about" is answered before it is asked.
- A drum-kit track queried with an uncovered note returns `reason: "percussionNoteNotCoveredInV1"` with an explanation that says *not covered yet*, plus `coveredNotes`. **An agent is never told "no data" when the truth is "not this one, but here are the ones I do have."**
- Covered notes ship their GM spec name (e.g. 38 → "Acoustic Snare"). **Uncovered notes ship no name** — GM's own names for them are spec data we simply did not author, and inventing them would be the same class of error one level down.

Toms are one family, not three (low/mid/high): rule 2 of §2 admits a split only if the advice changes, and that is a judgement the research pass can make — if it finds three genuinely different tuning ranges with citations, `tom` splits into three cases and the note map updates. That is a table decision inside this shape, not a shape change.

---

## 5. D4 — the data shape

**Decision. Three quantities, three representations, one construction home.** File: `Sources/DAWCore/InstrumentFrequencyReference.swift` — types **and** rows in the same file so `fileprivate init` is a real barrier (`InsertSpectrumTapPoint.swift` and `ArrangeDropSnap.swift:44` are the two proven models; read both before writing).

```swift
// ── 1. PHYSICS: MIDI notes in, Hz derived. No Hz literal exists to typo. ──
public enum Fundamental: Sendable, Equatable, Codable {
    case pitched(lowestMIDINote: Int, highestMIDINote: Int)
    /// No fundamental exists (cymbals, hats). The string says WHY, and the
    /// row's `bands` carry the body region instead — never a fake range.
    case inharmonic(reason: String)

    /// THE ONLY Hz source in this file. 440 · 2^((n−69)/12).
    public static func hz(midiNote: Int) -> Double {
        440.0 * pow(2.0, (Double(midiNote) - 69.0) / 12.0)
    }
}

// ── 2. ENGINEERING OPINION: Hz, and a citation PER ROW, inline. ──
public struct FrequencyCitation: Sendable, Equatable, Codable {
    public let source: String     // publication / author
    public let url: String        // https, must RESOLVE
    public let quote: String      // VERBATIM sentence that STATES this claim
    public let retrieved: String  // ISO-8601 date
}

public struct FrequencyBand: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case body, presence, attack, air          // desirable
        case rumble, mud, boxiness, harshness, sibilance   // problem
        public var isDesirable: Bool { ... }      // ONE home; drives V3 below
    }
    public let role: Role
    public let lowHz: Double
    public let highHz: Double
    public let effect: String                     // plain language, no dB advice
    public let citation: FrequencyCitation
}

// ── 3. THE ACTIONABLE FIELD: distinct from BOTH of the above. ──
public enum FilterRecommendation: Sendable, Equatable, Codable {
    case corner(hz: Double, slopeDbPerOct: Int, rationale: String,
                citation: FrequencyCitation)
    case noneRecommended(reason: NoneReason, explanation: String)
    public enum NoneReason: String, Sendable, Codable {
        /// Honest practice would cut below EQParams.lowPassFreqRange.lowerBound
        /// (1000 Hz) — the house EQ would silently clamp it (§1 F2).
        case belowHouseEQRange
        /// This source has content to the top of the band; cutting is a taste
        /// move, not cleanup.
        case notRecommendedForThisSource
    }
}

public struct InstrumentFrequencyReference: Sendable, Equatable {
    public let family: InstrumentFamily
    public let displayName: String
    public let fundamental: Fundamental
    public let fundamentalCitation: FrequencyCitation
    /// REQUIRED — every source benefits from a subsonic cut, and a required
    /// field cannot fail open in the validator (§7 V8).
    public let recommendedHighPass: FilterRecommendation   // always .corner
    public let recommendedLowPass: FilterRecommendation    // may be .noneRecommended
    public let bands: [FrequencyBand]

    fileprivate init(...)   // ← the barrier. No other file can mint a row.
}

public enum InstrumentFrequencyTable {
    /// TOTAL over InstrumentFamily.allCases — enforced by test, not by hope.
    public static func reference(for family: InstrumentFamily)
        -> InstrumentFrequencyReference
}
```

### Why each representation is what it is

**Fundamental as MIDI notes.** The roadmap's own argument, and it is airtight: there is no Hz field to mistype, and `E1 → 41.203 Hz` is a computation the test can check against `Fundamental.hz(midiNote:)` independently. Note *names* on the wire ("E1") must be derived through `KeyEstimate.pitchClassesSharp` (`Sources/DAWCore/AudioAnalysis.swift:33-35`) — **the existing one home for pitch-class names; do not add a second array** — with octave `n/12 − 1` (MIDI 60 = C4, 69 = A4, matching every schema in the repo). Pin 28 → "E1", 60 → "C4", 69 → "A4".

**Bands as Hz with an inline citation.** Sources state these in Hz; converting to notes would be a false precision. The citation is a **field of the band**, not a doc header, so "cited to sources" is a property of the value: a band without a citation cannot be constructed. The `quote` field is the anti-fabrication device — see §7 V7. **No dB advice ships in v1**: the row says *where* and *what it does*, never *boost 3 dB*. Amount is a mix decision the copilot makes with `fx.spectrum` in hand.

**HP/LP as a separate `FilterRecommendation`.** This is the field the copilot acts on, and it is *not* the fundamental range: a kick's corner sits **below** its lowest fundamental, a dense-mix vocal's may sit **above** it. Collapsing them (see below) would force one of those two truths to be a lie. It carries its own `slopeDbPerOct` because m22-a ships 12 and 24 and the right answer differs by source — and its own `rationale`, so the copilot can *tell the user why* rather than just moving a knob.

### Alternatives, and why they lose

- **One flat struct with `lowHz`/`highHz`/`hpHz`/`lpHz` Doubles.** Loses on the item's central hazard: every one of those four is independently typo-able, nothing relates them, and a decimal-point slip reads as data. It also cannot express `.inharmonic` (F3) or `.noneRecommended` (F2) without sentinels — and a sentinel *is* a fake number.
- **Derive the HP corner from the fundamental (e.g. "one third-octave below `lowest`").** Tempting — it would make HP typo-proof too. Loses on truth: real HP corners are conventional round numbers chosen against the *mix*, not offsets from physics, and for inharmonic families there is no anchor to offset from. It would trade a representable typo for a systematic fiction. The honest half-measure is §7 **V2a/V2b**, which bound the corner against the row's own physics — V2a is the exact form of "does not eat the instrument", and it is the rule the staging gate structurally cannot express (§8.2); the residue — a typo *within* the bounds (80 → 90 Hz) — is caught only by the citation spot-check, and this document says so rather than pretending otherwise.
- **A JSON resource file loaded at runtime.** Loses: it moves the table outside the type system (no exhaustiveness, no `fileprivate init`, decode errors at runtime), adds a bundle-resource path to a module that has none, and makes the "cannot mint a diverging value" property unenforceable.

---

## 6. D5 — the wire verb

**Decision: a new namespace and a single verb, `frequency.reference`.**

### Why a new namespace

The three existing candidates are all taken by a different meaning (verified, §1 F4): `instrument.*` = plugin/bank **discovery**, `reference.*` = m22-g **reference tracks** (a `reference.frequency` verb next to `reference.compare` would read as "compare against the reference track's spectrum" — an actively misleading neighbour), `fx.describe` = **effect-param metadata**. m23-d minted `note.*` for exactly this reason. Additive-only means the name is permanent, so the tie-breaker is *how it reads in a transcript two years from now*: `frequency.reference {family: electricBass}` states its own meaning, and the namespace has obvious room (`frequency.analyze`, `frequency.suggest`) without colliding with anything.

Rejected: `eq.*` (the table is not EQ-specific, and `fx.*` already owns EQ), `range.*` (too generic to survive contact with automation ranges and time ranges), `tone.*` (means timbre to musicians), `guide.*`/`advice.*` (says nothing about frequency).

### Why ONE verb and not two

A separate `frequency.families` lister would be a second wire command, a second MCP tool, a second catalog row, and a second thing to keep in sync — and it would leave the failure path needing two round trips. Instead **every response always carries `families`** (the compact index: id, displayName, whether it is note-keyed), and *additionally* carries `reference` when a family resolved. One stable shape, no mode-dependent schema, and the unresolved case is self-remedying. The index is ~20 short entries (well under a kilobyte); the full row rides only when asked for.

### Params and rules

| param | type | meaning |
|---|---|---|
| `family` | string, optional | An `InstrumentFamily` raw value. **Wins over `trackId`** — this is the override rung. |
| `trackId` | uuid string, optional | Run the ladder against this track. **No `"master"` sentinel** — a bus has no instrument identity (it resolves `.trackIsNotAnInstrumentOrAudioTrack`). |
| `note` | int 0–127, optional | GM percussion note. Meaningful only with `trackId`, when that track resolves to `.drumKit`. Passing it together with `family` is **rejected** — two keys that can disagree. Passing it with a `trackId` whose bank is **melodic** is NOT rejected (an agent cannot know the bank before asking): the program resolves normally and the response carries **`noteIgnored: true`** plus a one-line explanation. Silent ignore is the thing this design refuses everywhere else. |

- **Zero params is legal**: `resolution: "index"`, `families` only. This is how an agent learns the vocabulary, and it means `rejectUnknownKeys(["family","trackId","note"], verb:)` is the only param guard needed. (It does **not** belong in `ZeroParamVerbRejectionTests.zeroParamVerbs` — that table scrapes `rejectUnknownKeys([], verb:)` call sites specifically, and this verb has a non-empty allow-list.)
- **`family` + `trackId` together**: `family` wins, and the response says `resolvedFrom: "argument"` so nothing is silent. This is `ResolvedDropBeat.Source` applied to a different question — **carry WHY, always**.
- **`family` + `note` together**: rejected with a teaching error. (A named family already answers the question; a note would be a second, possibly contradicting key.)
- **Unknown `family` value**: an error naming the valid ids, never a nil-ish success. A typo must not read as "not covered".
- Not in v1, and **additive later without renaming anything**: a `gmProgram` param (ask about a program without a track).

### Response shape

```json
{
  "resolution": "family" | "drumKit" | "unresolved" | "index",
  "resolvedFrom": "argument" | "gmProgram" | "gmPercussionNote",
  "reason": "gmProgramNotCoveredInV1",
  "explanation": "...", "remedy": "...",
  "coveredNotes": [{ "note": 36, "name": "Bass Drum 1", "family": "kick" }],
  "noteIgnored": true,
  "families": [{ "family": "kick", "displayName": "Kick drum", "notes": [35, 36] }],
  "reference": {                      // SHAPE ONLY — every number below is illustrative, not authored content
    "family": "electricBass",
    "displayName": "Electric bass guitar",
    "fundamental": {
      "kind": "pitched",
      "lowestMidiNote": 28, "highestMidiNote": 67,
      "lowestHz": 41.203, "highestHz": 391.995,
      "lowestNoteName": "E1", "highestNoteName": "G4",
      "citation": { "source": "...", "url": "https://...", "quote": "...", "retrieved": "2026-07-28" }
    },
    "recommendedHighPass": {
      "kind": "corner", "hz": 30, "slopeDbPerOct": 24,
      "rationale": "...", "citation": { ... }
    },
    "recommendedLowPass": {
      "kind": "noneRecommended", "reason": "notRecommendedForThisSource", "explanation": "..."
    },
    "bands": [{ "role": "mud", "lowHz": 200, "highHz": 400, "effect": "...", "citation": { ... } }]
  }
}
```

`resolvedFrom`, `reason`, `explanation`, `remedy`, `coveredNotes`, `noteIgnored`, `reference` are **omitted** when they do not apply (the repo's nil-means-no-evidence convention, `AudioAnalysis.swift:7-9`). `families` is **always** present — including on `unresolved`, which is the whole point.

---

## 7. The research brief and the validator — how bad numbers are made hard

### What the research-analyst produces, per row

For each of the 20 families: `displayName`; `Fundamental` (**as MIDI note numbers**, or `.inharmonic` with a reason); one `FrequencyCitation` for the fundamental; a **required** `recommendedHighPass` `.corner` with slope, rationale and citation; a `recommendedLowPass` (corner **or** `.noneRecommended` with reason); and 2–5 `FrequencyBand`s each with role, span, plain-language effect, and citation.

**Four rules that are not negotiable:**

1. **`quote` is VERBATIM, ≤ 200 characters, contains no ellipsis** (`...` or `…`) and no square-bracket edits. This is what makes the spot-check mechanical: fetch the URL, search for the string. A paraphrase is unfalsifiable; a quote is not.
2. **`url` is `https://` and must RESOLVE to a page that STATES the claim.** A citation to a page that merely discusses the instrument is a fabricated citation with extra steps.
3. **A row that cannot be cited does not get guessed — its enum case is DELETED.** Deleting the case is a compile-time change: `melodicProgramFamilies` entries pointing at it must become `nil`, `reference(for:)`'s exhaustive `switch` stops compiling until they do, and every GM program that used to reach it now returns an honest `nil`. **The mechanism, not the researcher's discipline, is what keeps folklore out.**
4. **Roles are chosen from the enum, never invented in prose**, and `isDesirable` is what V3 checks against — so a row cannot describe a band as characteristic and then recommend cutting it away.

### The validator (`InstrumentFrequencyTable.validate() -> [String]`, test-invoked, never a runtime `precondition`)

A returned non-empty array **is** the failure; a `precondition` would turn a data error into a crash for users, and the totality test already guarantees every row is constructed during the suite.

| # | Rule | What it catches |
|---|---|---|
| V1 | `.pitched` rows: `0 ≤ lowest ≤ highest ≤ 127` | swapped or out-of-range endpoints |
| **V2a** | `.pitched` rows: **`hp ≤ lowestHz × 2^(1/3)`** (a third of an octave above the lowest fundamental) | **guidance that eats the instrument** — the invariant S3 cannot measure (§8.2). Exact, no measurement floor. Calibration: at the bar the lowest note loses 8.66 dB (n=4) — that is the LIMIT, not the target. It admits the legitimate dense-mix vocal case (a 100 Hz corner over an 85 Hz floor = 1.176×) and rejects folklore (80 Hz over a 41.2 Hz bass floor = 1.942×; 45 Hz over a 30.87 Hz 5-string floor = 1.458×). |
| **V2b** | `.pitched` rows: `hp ≥ lowestHz / 4` | decade-scale HP typos downward (80 → 8) |
| V3 | `hp ≤ min(lowHz)` over **desirable** bands; corner `lp ≥ max(highHz)` over them | guidance that cuts away the row's own characteristic region |
| V4 | `hp ∈ EQParams.highPassFreqRange`; corner `lp ∈ EQParams.lowPassFreqRange`; `slope ∈ {12, 24}` | a recommendation the house EQ would silently clamp (§1 F2) |
| V5 | every band: `0 < lowHz < highHz ≤ 20000` | inverted/degenerate spans |
| V6 | `.inharmonic` rows carry ≥ 1 **desirable** band | an inharmonic row that leaves V3 vacuous |
| V7 | every citation: non-empty `source`/`url`/`quote`/`retrieved`; `url` starts `https://`; `quote.count ≤ 200`; quote contains no `...`/`…`; `retrieved` parses ISO-8601 | fabrication-friendly citation shapes |
| — | *(V2 does not apply to `.inharmonic` rows — V3 and V6 cover them.)* | |
| V8 | **counts**: `rowsVisited == InstrumentFamily.allCases.count`; `hpCornersChecked == allCases.count`; `citationsChecked ≥ 3 × allCases.count` | **the validator failing open** — an early `return`, a skipped branch, or an optional that let it check nothing |

V8 exists because a validator over optional fields can legitimately check nothing and return `[]`. Making `recommendedHighPass` **required** removes the largest fail-open path at the type level; V8 closes the rest by asserting the work happened.

### The citation spot-check is a GATE STEP, not a suite leg

Tests do not touch the network. The in-suite legs are **structural only** (V7). The spot-check is a manual/agent step in the close-out:

> Sample **5 rows** (must include `kick`, `electricBass`, and one `.inharmonic` row). For each, `WebFetch` the `url` and confirm the page contains the `quote` **and** that the quote states the attributed numbers. **Name the five sampled rows and their verdicts in the close-out record.** A fabricated citation passes a naive read of "cited to sources"; only this step distinguishes them.

---

## 8. The gate — legs, and the mutation that must redden each

**Headline (behavioural, chains into m23-r4):** read the bass reference → HP at its recommended corner via `fx.setParam` → measure with `fx.spectrum`. **Re-shaped per §1 F1: two-sided and relative, because the absolute form cannot redden.**

### 8.1 The staging fixture (`scripts/gates/m23o1-frequency-reference.mjs`, port 17695)

Built on the proven `m23r3-insert-spectrum.mjs` shape — read that file before writing this one.

- `project.new {discardChanges:true}`; `mixer.setMasterVolume {volume:0}` (silent run; a strip insert taps **pre-fader**, which r3 proved and this gate re-asserts for free via `tapPoint`).
- One instrument track, `polySynth`, **`waveform: "sine"`**, `gain: 0.3`, `attack: 0.01`, `sustain: 1.0`, `release: 0.1`. Sine, not saw: a saw's harmonics land above the corner and would blur every Δ. Gain 0.3 so two summed sines keep headroom and nothing nonlinear happens upstream of the tap.
- **`FIXTURE_BEATS = 8192`** — the recorded law (a 128-beat fixture ended mid-run and produced a cascade of false reds; 8192 ≈ 68 min at 120 BPM is an order of magnitude past any plausible load).
- Two notes, both spanning the clip: **probe = `reference.fundamental.lowestMidiNote` read from the wire in leg S1** (never hardcoded — the probe follows the table), **control = MIDI 64** (E4, 329.63 Hz).
- `fx.add {trackId, kind:"eq"}`; `transport.play`.
- Every spectrum read: `fx.spectrum {trackId, effectId, arm:true}` **5 times at ~100 ms**, take the **per-band median** (the lease is 3 s and every read renews it; the analyzer's release e-folds every ~61 ms, so settle ≥ 600 ms after any param change before the first of the five). Release with `arm:false` at the end.
- Band indices are **sample-rate independent** — `bandEdges` are fixed Hz — so the gate may hardcode `PROBE_BAND = 0` / `CONTROL_BAND = 8`, **but only because Swift leg C12 — in `Tests/DAWControlTests/`, the target that actually has DAWEngine — pins `bandIndex(containing:)` for the same frequencies**. That pin-pair is what stops the gate's copy from drifting.

Derivations the gate depends on (all from `MasterMixAnalyzer` constants; recompute if those ever change): `bandEdges[0..1] = [40.00, 51.34)` → 41.20 Hz and 30.87 Hz both land in **band 0**; `bandEdges[8..9] = [294.72, 378.30)` → 329.63 Hz lands in **band 8**; 200 Hz lands in band 6.

### 8.2 Legs

| # | Leg | Assertion | Mutation that MUST redden it |
|---|---|---|---|
| **S1** | the table is on the wire and pitched | `frequency.reference {family:"electricBass"}` → `resolution:"family"`, `fundamental.kind:"pitched"`, `recommendedHighPass.kind:"corner"` | return `.noneRecommended` for that row |
| **S2** | **anti-vacuity: the fixture is alive** | baseline median: `bands[0] > −60` **and** `bands[8] > −60`; every band in 2…6 at least 20 dB below both (sine purity); `tapPoint == "postInsertPreFader"` | drop the control note from the clip; separately, set the polySynth to `saw` (purity leg reddens) |
| **S3 = B1** | **the read→apply→measure chain is live, and the corner is not coarsely wrong** | apply `highPassFreq = hp`, `highPassSlopeDbPerOct = slope` **from the row** → `abs(Δ bands[0]) ≤ 6 dB` **and** `abs(Δ bands[8]) ≤ 2 dB` | set the shipped `electricBass` HP corner to 200 Hz → S3 reddens. **A red S3 is a DATA verdict about the shipped table, never a threshold to loosen.** |
| **S4 = B2** | **anti-vacuity for S3** | set `highPassFreq = 100`, `highPassSlopeDbPerOct = 24` **(both fixed, NOT derived from the row)** → `abs(Δ bands[0]) > 6 dB`, using the same comparison code path S3 uses | wire `fx.setParam` for `highPassFreq` to a no-op → S4 reddens (and S3 would have stayed green, which is exactly why S4 exists) |
| **S5 = B3** | **the cut is real, selective, and visible** | set `highPassFreq = 200`, slope 24 → `Δ bands[0] ≥ 15 dB`, `abs(Δ bands[8]) ≤ 2 dB`, and `Δ[0] == max(Δ)` (ties allowed — §1 F5) | replace the HP with a broadband cut — a `gain` insert at −20 dB ahead of the EQ — → the `abs(Δ bands[8]) ≤ 2` clause reddens (this leg is what distinguishes "cut the low end" from "turned the whole thing down"). **NOT `track.setVolume`:** a strip insert taps **pre-fader**, so a fader move produces no Δ at all and would redden the wrong clause. |
| **S6** | the filter moves both ways | restore `highPassFreq = hp` → `bands[0]` returns within 6 dB of baseline | make the EQ latch its first corner → reddens |
| **S7** | the honest failure, live | `track.add {kind:"audio"}` → `frequency.reference {trackId}` → `resolution:"unresolved"`, non-empty `reason`/`explanation`/`remedy`, **and `families` present and byte-identical to the index S1 returned** (never a hardcoded count — Step 2 may legitimately delete a row) | omit `families` from the unresolved branch |
| **S8** | drum kit, live | a `soundBank` track at `bankMSB 120` → `resolution:"drumKit"` + 17 `coveredNotes`; with `note:38` → `family:"snare"`; with `note:54` → `reason:"percussionNoteNotCoveredInV1"` + `coveredNotes` still present | return a bare error for note 54 |

**Expected magnitudes, so the thresholds are not arbitrary** (Butterworth, measured at band 0's observation window ≈ 46.9 Hz @ 48 kHz): at n = 4 a 30 Hz corner costs **0.12 dB**, 40 Hz **≈1 dB**, 60 Hz **9.14 dB**, 100 Hz **26.33 dB**, 200 Hz **50.41 dB**. So S3's 6 dB bar accepts any corner up to ≈ 54 Hz and rejects anything at or above ≈ 60 Hz; S5's 200 Hz saturates it. **State this in the gate's own header** so a future reader can tell a derived threshold from a tuned one.

**What S3 does NOT establish, stated so nobody over-reads it.** S3 measures **band 0's observation window** (≈ 46.9 Hz @ 48 kHz), not the probe tone. Whenever a family's lowest fundamental sits **below** 40 Hz, the window is ABOVE the fundamental and the two attenuations diverge: for a 5-string floor of 30.87 Hz, a 45 Hz corner costs the **fundamental 13.30 dB** while costing the **window only 2.36 dB** — S3 passes and the guidance has eaten the instrument. So S3 proves the chain and catches a *coarse* folklore corner (≥ ≈60 Hz); it does **not** prove the fundamental survived. **That invariant is V2a's job** (§7), where the arithmetic is exact and there is no 40 Hz floor to hide behind. Two instruments, two claims — do not let either stand in for the other.

**Why S4's corner is FIXED at 100 Hz / 24 dB/oct and not `2 × hp` (computed, and it blocks):** doubling the row's own corner does **not** reliably clear the 6 dB bar. At the window, `2 × 25 Hz` costs only **4.27 dB** (n = 4) and **3.61 dB** (n = 2); `2 × 20 Hz` costs **1.08 dB**. Both a subsonic-only recommendation near 25 Hz and **any row shipping the perfectly legal 12 dB/oct slope** would make S4 fail while S3 was green — and the natural reading of "S3 green, S4 red" is to loosen S4, which is exactly inverted. A fixed 100 Hz at 24 dB/oct costs **26.33 dB** (and 13.37 dB even at n = 2), clearing the bar with margin for every legal corner and slope, and it makes the control leg **independent of table content**, which is what a control leg should be.

### 8.3 In-suite legs

`Tests/DAWCoreTests/InstrumentFrequencyReferenceTests.swift`:

| # | Leg | Mutation |
|---|---|---|
| C1 | `InstrumentFamily.allCases.count == 20`, and each row's `family` field equals the key it is returned for (catches copy-paste rows). **If Step 2 deletes an uncitable case, this literal moves to 19 deliberately — that is the pin working, not a break.** | swap two rows' `family` fields |
| C2 | `Fundamental.hz`: 69→440, 60→261.6256, 28→41.2034 (±1e-3) | 440→442, or `/12`→`/11` |
| C3–C8 | validator rules V1–V8 (§7, V2 split into V2a/V2b), each asserted **separately** so one red names one rule | one per rule, per the V-table |
| C9 | `melodicProgramFamilies.count == 128`; category-consistency sweep; pins 33→`electricBass`, 43→`uprightBass`, 40→`violin`, 48→nil, 96→nil | insert one `nil` at index 0 (shift by one) → the sweep reddens |
| C10 | percussion map: 17 notes, all in 35…59; 37/54/56 → nil | map 54 → `hiHat` |
| C11 | note names via `KeyEstimate.pitchClassesSharp` only: 28→"E1", 60→"C4", 69→"A4" | add a second name array |

**C12 lives in `Tests/DAWControlTests/`, NOT in DAWCoreTests — MEASURED, and it would not have compiled otherwise.** `Package.swift:124` declares `.testTarget(name: "DAWCoreTests", dependencies: ["DAWCore"])` — no DAWEngine — while `MasterMixAnalyzer` is `Sources/DAWEngine/Analysis/`. `DAWControlTests` declares DAWEngine as a test-only dependency (`Package.swift:129`), and it sits beside the wire legs the staging gate mirrors, so it is the right home:

| # | Leg | Mutation |
|---|---|---|
| C12 | **the pin-pair for the staging gate's hardcoded band indices**: `MasterMixAnalyzer.bandIndex(containing: 41.203) == 0`, `(329.63) == 8`, `(200) == 6`, `bandEdges[0] == 40` | change `lowestBandHz` → this reddens, and the gate's `PROBE_BAND`/`CONTROL_BAND` constants are caught with it |

`Tests/DAWCoreTests/InstrumentFamilyResolutionTests.swift`: R1–R7 exactly as §3 lists them. **R7 is structural**: `InstrumentFamilyResolver.resolve` **cannot accept a track name** — the signature has no such parameter, which is the recorded law *a function that cannot accept the varying input makes the property structural*. The accompanying behavioural leg resolves two tracks named "Bass DI 01" and "Lead Vox" with identical instrument state and asserts identical results; adding a name parameter with a heuristic reddens it.

`Tests/DAWControlTests/FrequencyReferenceCommandTests.swift`: W1–W10 as §6 lists them, plus:

- **W9 (the leg that matters most for the copilot):** sweep the `CopilotCatalog.v1` entry for `frequency.reference` and assert its `family` schema's `enum` array **equals `InstrumentFamily.allCases.map(\.rawValue)`** — computed on both sides, never a hand list. Mutation: add a family case without touching the catalog → reddens. Without this, a future family ships invisible to the in-app copilot, which is precisely the surface the roadmap says is the one that matters.
- **W6b:** `trackId` of a MELODIC-bank soundBank track **plus** `note` → resolves by program with `resolvedFrom:"gmProgram"` **and `noteIgnored: true`**. Mutation: drop the flag → the leg reddens (a silently-ignored param is the failure this leg exists for).
- W8: the wire-count pin moves 162 → 163 in **all 13 files** that carry it (`AUParamCommandTests`, `ClipFitToContentCommandTests`, `FXSpectrumCommandTests`, `LiveLoudnessCommandTests`, `MIDIFileExportCommandTests`, `MIDIFileImportCommandTests`, `ReferenceCommandTests`, `RenderCommandTests`, `RenderOutputFormatCommandTests`, `SoundBankCommandTests`, `TrackReorderCommandTests`, `VoiceListCommandTests`, `ZeroParamVerbRejectionTests`), and `CopilotCatalogTests.catalogCountPin` 68 → 69.

`mcp-server/test/frequency-reference.test.ts` (the `npm test` glob picks up new files automatically): M1 `tools.length` 165 → 166 in `integration.test.ts`; M2 params pass through verbatim with `undefined` omitted; **M3 the tool description names `fx_set_param`, `highPassFreq` and `highPassSlopeDbPerOct`** — mutation: delete the param name from the description. Without M3 the agent gets the number and not the move, which is half the item.

**Deliberate asymmetry, decided not accidental:** the **Swift** catalog schema uses `enumValues` (compiled against the same enum, pinned by W9); the **MCP** schema uses `z.string()` plus a description that says *"call with no arguments to list the valid ids"*. A `z.enum` in `server.ts` would be a second, separately-shipped source of truth for the family vocabulary — an MCP server built against an older table would **reject** a family the app supports, turning an additive table change into a client-side outage.

---

## 9. Failure modes

| # | Failure | Mitigation |
|---|---|---|
| FM1 | **Plausible numbers with plausible citations** (the roadmap's named hazard) | verbatim ≤200-char quotes (V7) + the 5-row URL spot-check (§7) + V2a/V2b + V3's desirable-band containment + V4's EQ-range pin + **delete-the-case, never guess** |
| FM2 | The copilot acts on a family it inferred from a track name | no heuristic anywhere in the resolver (structurally — R7); `resolvedFrom` always states the rung; the unresolved payload teaches the remedy |
| FM3 | The table grows and the copilot's vocabulary silently goes stale | W9's computed-both-sides enum sweep |
| FM4 | LP advice below 1 kHz silently clamped by `fx.setParam` | §1 F2 → `.noneRecommended(.belowHouseEQRange)` + V4 |
| FM5 | An agent polls `fx.spectrum` forever after acting | already handled by m23-r4's 3 s TTL lease — no new lifecycle here |
| FM6 | **Render-thread risk** | **None. This item adds no render-thread code at all**: a `static let` table of immutable values, a pure resolution function, a command handler, and reuse of the existing `fx.setParam` path. No allocation, no lock, and nothing new on the audio thread. If an implementer finds themselves touching `Sources/DAWEngine`, they have left this design. |
| FM7 | Swift 6 strict concurrency | every type is a value type of `Sendable` members; the table is immutable `static let`s inside an uninstantiable `enum` namespace — no global mutable state, no actor isolation needed, `Sendable` throughout by construction |
| FM8 | An agent reads `families` as "these are all the instruments that exist" | the index carries `displayName` and note-keying only; every uncovered route returns a `reason` whose text says *not covered yet*, never *no data* |

---

## 10. Implementation plan

**Step 1 — DAWCore types + the empty shape (`swift-app-engineer` or `mcp-integration-engineer`).**
Create `Sources/DAWCore/InstrumentFrequencyReference.swift` (enum, value types, `fileprivate init`, `reference(for:)` as an **exhaustive `switch`** so a missing row cannot compile, `validate()`) and `Sources/DAWCore/InstrumentFamilyResolution.swift` (resolution enum + `InstrumentFamilyResolver.resolve`, `melodicProgramFamilies`, the percussion note map). Read `Sources/DAWCore/InsertSpectrumTapPoint.swift` and `Sources/DAWAppKit/ArrangeDropSnap.swift:22-53` first — those are the two shapes being copied. Land C1/C2/C9/C10/C11 and R1–R7 with **placeholder rows** so the structure is gated before any content exists. **C12 is NOT part of this step** — it needs DAWEngine and therefore lands in Step 3's `DAWControlTests` file.

**Step 2 — the table content (`research-analyst`).**
Fill the 20 rows under §7's four rules. **Deliverable includes the five spot-check verdicts.** A row that cannot be cited: delete the case, set its GM entries to `nil`, say so in the report. Land C3–C8.

**Step 3 — the wire (`mcp-integration-engineer`).**
`Sources/DAWControl/Commands.swift`: append `"frequency.reference"` **at the end** of `allCommands` (the additive-at-end law — HEAD's list must stay an exact prefix) with a comment naming m23-o1, and add the `case "frequency.reference":` handler with `rejectUnknownKeys(["family","trackId","note"], verb:)`. Update the 13 count pins + `CopilotCatalogTests` 68 → 69. Land W1–W8, W6b, W10 **and C12** (the band-index pin-pair — this target is the one with DAWEngine).

**Step 4 — the copilot catalog (same agent, separate edit, `Sources/DAWControl/CopilotCatalog.swift`).**
Add the `CopilotTool`. Its description must teach three things: what the table is, that an unresolved answer means *ask the user or pass `family`*, and **how to act** — `fx.setParam` with `highPassFreq` / `highPassSlopeDbPerOct` on an `eq` insert. Land W9.

**Step 5 — MCP (`mcp-integration-engineer`, `mcp-server/src/server.ts`).**
`registerTool("frequency_reference", ...)` with `z.string()` for `family` (§8.3 asymmetry). New test file `mcp-server/test/frequency-reference.test.ts`; bump `integration.test.ts` 165 → 166. Land M1–M3.

**Step 6 — the staging gate (`qa-test-engineer`).**
`scripts/gates/m23o1-frequency-reference.mjs` per §8.1/§8.2. **Port 17695 only — 17600 is the user's live app.** Kill staging PIDFILE-exact.

**Step 7 — close-out.** Tick `(m23-o1)` in `docs/ROADMAP.md`; CHANGELOG; memory patch; **name the five spot-checked rows and their verdicts**; re-measure `allCommands` (163), MCP tools (166), catalog (69) **by counting them yourself** — never inherit a figure from an implementer's report; note that `dist/DAWPro.app` is again one command behind until the user rebuilds.

**Ordering constraint:** Step 3 must not start before Step 1's types compile, and Step 6 must not start before Steps 3–5 all land (the gate exercises all four surfaces). Step 2 can run in parallel with Steps 3–5 because the placeholder rows keep everything compiling.

**Full Xcode:** not required anywhere in this item. No entitlements, no AUv3, no signing, no bundle changes.

---

## 11. Deferred, and what would reopen it

- **A persisted `Track.instrumentFamily` override** (§3 Alternative A) — additive on every surface when m23-o2's pixels show users want it. Reopen if the EQ card needs a sticky user choice.
- **A `gmProgram` param on `frequency.reference`** — purely additive; add when an agent needs to ask before creating a track.
- **The deferred families** (saxophones, clarinet, oboe, bassoon, French horn, tuba, harp, timpani, piccolo, organ) and the deferred percussion notes (37, 39, 52, 53, 54, 55, 56) — adding a case is a compile-time change plus rows; **no wire change, no version bump**, because the vocabulary is delivered in every response and the MCP schema is `z.string()`.
- **Suggested cut/boost AMOUNTS in dB** — deliberately absent from v1. The copilot has `fx.spectrum` for amount; a table of dB values would be pure genre convention and would fail §2 rule 3.
- **Synth families** — reopen only if someone finds a *physical* basis, which there is not; the answer for synths is measurement.

## 12. ARCHITECTURE.md

One additive entry under **"Key future decisions"**, recording the settled namespace (`frequency.*`), the honest-nil ladder, and the F1/F2 observability findings. No restructuring, no commit.
