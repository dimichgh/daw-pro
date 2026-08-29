# Free General-MIDI SoundFont survey — for GM bank replacement

Date: 2026-08-27
Author: research-analyst (delegated)

## The decision

`gs_instruments.dls` (Apple's stock DLS bank) is measured to have exactly one
timbre per instrument (28 dB level swing across velocity 25→127, 0.05%
spectral-centroid change — i.e. a volume knob, not a multisampled
instrument). We need a full-GM replacement, either bundled in the app or
offered as a one-click download. This survey exists to separate "free to
play music with" from "free to redistribute inside a commercial macOS app."

**Method note:** all licence text below was pulled by web search + fetch of
what I believe are primary or near-primary sources (author pages, GitHub
`LICENSE`/`*_License.md` files distributed alongside the binary, or a
downstream redistributor's copy of the same file). I did **not** download
and open any `.sf2` file myself in this pass — sizes and coverage claims
below are what redistribution sites/READMEs state, not something I measured
locally. Where I could not reach a document that is unambiguously the
author's own statement, I say so and mark the claim **LICENCE UNVERIFIED**.

---

## Comparison table

| Bank | Licence (claimed) | Bundle-safe in a commercial app? | Size | GM coverage |
|---|---|---|---|---|
| **FluidR3 GM / FluidR3Mono** | MIT (per MuseScore's redistributed `FluidR3Mono_License.md`) | **Yes**, with attribution retained | ~141–148 MB (SF2, uncompressed); FluidR3Mono ~36 MB | Full 128 + drum kits |
| **GeneralUser GS** | Custom "GeneralUser GS License v2.0" — free incl. commercial use, BUT author states uncertain sample provenance | **Unclear** — author's own uncertainty is the blocker, not the licence wording | ~30.7 MB (v2.0.2 SF2) | Full 128 + GS/XG extras, drum kits |
| **MuseScore_General** | MIT (explicit `MuseScore_General_License.md`) | **Yes**, with attribution retained | ~35.9 MB (.sf3) / ~208 MB (.sf2, per a search-result claim I could not independently confirm) | Full 128+ incl. GM/GS/XG-ish extras, drum kits |
| **Musyng Kite** | CC BY-SA 3.0 (per author's own posts, per search summaries — not independently fetched from a primary licence file) | **No** — share-alike + attribution is a poor fit for a closed commercial bundle; also huge (~990 MB) | ~990 MB | Full 128, deep multisampling reported |
| **Arachno SoundFont** | Custom, "private use only" copyright page; author explicitly says he **cannot recommend commercial use** | **No** — author says so directly | Not confirmed | Full 128 + kits |
| **Timbres of Heaven (TOH)** | Author statement (via forum/search summary, not a fetched licence file) claims "free and open source," keep the name on edits | **LICENCE UNVERIFIED** — no primary licence file located | Not confirmed (3.4 Final; large, hundreds of MB reported historically) | Full 128 + GS/XG/SFX extensions |
| **SGM-v2.01** | Conflicting reports: CC BY 3.0 vs CC BY 4.0 depending on source/mirror | **LICENCE UNVERIFIED** — conflict unresolved, no single primary source found | Not confirmed | Full 128 + kits |
| **Chorium** | No licence text located; one listing tags a related file "Non-free" | **LICENCE UNVERIFIED — treat as No** | Not confirmed | Full 128 (reported) |
| **Airfont 380** | Third-party listing says "Public Domain"; **not the author's own statement** — I could not find Milton Paredes' own licence text | **LICENCE UNVERIFIED** | Not confirmed | Full 128 + kits |
| **Papelmedia GM 2007** | Reported as CC BY 3.0 Unported by search summaries; also a KVR thread titled "Papelmedia redistributing free soundfonts?" — provenance itself is disputed by the community | **No** — provenance dispute alone is disqualifying for bundling | ~229 MB | Full 128 |
| **Crisis General MIDI (CGM 3.01)** | Free for personal use; **commercial releases or public performance require a paid licence from Bismut Network** (per search summary of the author's own site; I could not fetch the page directly — it 502'd) | **No** — explicit paid-commercial-licence requirement | ~1.5 GB uncompressed | Full 128 + 47 percussion sounds |

---

## Per-bank detail

### FluidR3 GM / FluidR3Mono — MIT, bundle-safe
- Author: Frank Wen, copyright 2000–2002, 2008. FluidR3Mono is a mono
  conversion (Michael Cowgill, 2014–17) with further adaptation by
  S. Christian Collins (2018), plus contributed instruments (Ethan Winer's
  Temple Blocks, Michael Schorsch's Drumline Percussion).
- Primary-ish source fetched: MuseScore's own shipped licence file,
  `share/sound/FluidR3Mono_License.md` in the MuseScore repo
  (https://github.com/musescore/MuseScore/blob/master/share/sound/FluidR3Mono_License.md),
  full standard MIT text, condition: "The acknowledgements and copyright
  notices above must be included in any derivative work."
- No canonical single hosting site — there is an open, **unresolved** GitHub
  issue (fluidsynth/fluidsynth#479) from a MacPorts maintainer asking where
  the "official" download is, because the old SourceForge/hammersound.net
  location is defunct. Every current distribution (Debian, Fedora,
  Internet Archive, MuseScore's own repo) is a downstream mirror carrying
  forward the same MIT licence text. This is a real gap: we cannot point at
  one canonical author-hosted URL, only at multiple mirrors that agree with
  each other on the licence.
- **Bundle-safe: yes**, if we ship the standard MIT notice + the
  contributor list above somewhere in the app's acknowledgements. MIT
  explicitly permits sublicensing, selling copies, and inclusion in
  commercial products.
- Rendering caveat: none specific found for FluidR3 vs AUSampler beyond the
  general SF2-modulator caveat below.

### GeneralUser GS — free-for-commercial-use wording, but provenance caveat
- Author: S. Christian Collins. Current stable per web search:
  v2.0.2 (2025-04-21 per a GitHub-fork DeepWiki page — **not the author's
  own site**, treat version/date as low-confidence), ~30.7 MB SF2.
- Licence text (fetched via a GitHub mirror of "GeneralUser GS License
  v2.0", https://raw.githubusercontent.com/ad-si/GeneralUser/master/LICENSE.txt
  — this is a fork, not schristiancollins.com itself, so treat as
  **near-primary, not primary**): "You may use GeneralUser GS without
  restriction for your own music creation, private or commercial... This
  SoundFont bank is provided to the community free of charge." It also asks
  that direct-linking to the download file be avoided in favor of linking
  the main site.
- **The disqualifying line, in the author's own words** (as quoted back
  consistently across the licence file, the ScanCode LicenseDB entry, and
  the GitHub README mirrors): the project began as a personal effort with
  no intention of publication, so the author "cannot be 100% sure where all
  of the samples originated," though he states none came from commercially
  published soundfont packages or sample CDs, and he asks to be notified if
  a restricted sample is ever identified so he can replace it.
- I was not able to load `schristiancollins.com/generaluser.php` directly
  (WebFetch returned only a page header, no body) to confirm this is still
  the exact live wording — the quote above is corroborated by 3+
  independent mirrors including the ScanCode LicenseDB canonical entry, so
  confidence is fairly high, but the primary page itself is unverified in
  this pass.
- **Bundle-safe: unclear.** The grant of rights is broad enough (explicit
  commercial permission), but a legal reviewer should weigh the author's
  own "cannot be 100% sure" language before we put this inside a paid
  commercial product's install image. This is exactly the caveat the task
  brief flagged as our current front-runner's weak point — confirmed.

### MuseScore_General — MIT, cleanest paper trail of the set
- Ships inside MuseScore (itself GPLv3 application, but its bundled
  soundfont carries its own separate MIT licence — MuseScore is a
  commercial-adjacent open-source product that has shipped this file for
  years without incident, which is itself weak circumstantial evidence of
  bundling-safety).
- Primary source fetched directly:
  https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md
  — full MIT text, copyright holders: Michael Cowgill (mono conversion,
  2014–16), Frank Wen (original FluidR3 base, 2000–2002, 2008), plus the
  same Temple Blocks / Drumline Percussion contributors as FluidR3Mono.
  This confirms MuseScore_General is a **derivative of FluidR3**, not an
  independent bank — expect broadly similar timbral quality/character.
- Size: 35.9 MB reported for the `.sf3` (compressed) format; an `.sf2`
  variant at ~208 MB was mentioned in one search summary but I did not
  independently confirm that figure from a file listing.
- Velocity layering: confirmed via a MuseScore GitHub issue thread — e.g.
  the Violin preset is built from 3 velocity-keyed sub-instruments (P:
  0–89, F: 90–116, X: 117–127). This is real velocity layering, better than
  a single-timbre bank, though modest compared to sample libraries with
  8–16 layers.
- **Bundle-safe: yes**, same MIT terms as FluidR3, with the added benefit
  of a clean, directly-fetched, unambiguous licence file and a stable
  official host (osuosl.org mirror + the MuseScore GitHub repo itself).
  This is the strongest paper trail of everything surveyed.

### Musyng Kite — CC BY-SA 3.0, likely disqualifying for a closed app
- Reported ~990 MB, described across the KVR Audio forum thread as a
  heavily reworked/expanded GM bank with deep sampling (originator uses the
  handle "Cose"; I could not confirm a "Roland Fortin" attribution the
  brief's search query guessed at — no evidence found connecting that name).
- Licence per search-result summaries: CC BY Share-Alike 3.0. I did not
  fetch a primary licence file for this one — flag **LICENCE UNVERIFIED**
  strictly speaking, though CC BY-SA is a commonly repeated claim across
  multiple redistribution sites.
- Share-alike is a poor fit for bundling inside a closed-source commercial
  macOS app: it would require any modified version we ship to be
  redistributed under the same CC BY-SA terms, and attribution must be
  preserved. Also, at ~990 MB it's a poor bundle candidate purely on size
  grounds — better suited to "recommend as an optional download."

### Arachno SoundFont — author explicitly discourages commercial use
- Author: Maxime Abbey (Arachnosoft). Primary source fetched:
  https://www.arachnosoft.com/main/information/copyright.php
- Direct quote (paraphrased by the fetch but consistent with the site's
  stated position across the search summary too): all site content is
  offered for **private use only**; commercial use or public redistribution
  requires the author's written consent. Separately, in the soundfont's own
  documentation the author states he **cannot recommend commercial use**
  because Arachno incorporates sounds from other libraries/authors whose
  own licences may not permit it — i.e. the same "provenance uncertainty"
  problem as GeneralUser GS, but here the author has drawn the conclusion
  for us instead of leaving it open.
- **Bundle-safe: no.** This is the most explicit "do not do this" of the
  set.

### Timbres of Heaven (TOH) — LICENCE UNVERIFIED
- Author: Don Allen. Hosted at midkar.com/SoundFonts/TOH.html and mirrored
  on Internet Archive/Polyphone/MuseScore forum threads.
- I could not locate or fetch a document that is unambiguously the
  author's own licence statement in this pass — what surfaced was a search
  summary characterizing a forum/site claim as "free and open source, keep
  the name if you edit it." That is not a licence text I can quote or link
  with confidence.
- **LICENCE UNVERIFIED.** Do not treat as bundle-safe until someone opens
  midkar.com/SoundFonts/TOH.html directly (it did not surface fetchable
  content in this pass) and confirms actual licence wording, ideally from
  a README shipped inside the download itself.

### SGM-v2.01 — LICENCE UNVERIFIED, conflicting claims
- Author: "Shan". Search results themselves disagree — one source claims
  CC BY 4.0, another CC BY 3.0 Unported, and Musical Artifacts lists at
  least one derivative/mirror as "unknown licence."
- **LICENCE UNVERIFIED**, and the fact that the conflict exists across
  otherwise-reliable aggregator sites (Musical Artifacts, Polyphone) is
  itself a yellow flag — it suggests no single canonical licence file
  travels with every copy in circulation.

### Chorium — LICENCE UNVERIFIED
- Old (2003) bank, "openwrld" attribution in one MuseScore forum thread.
  No licence file located. One Musical Artifacts-style listing flags a
  related/adjacent file as "Non-free." Do not use without a much better
  paper trail.

### Airfont 380 — LICENCE UNVERIFIED (claimed public domain, not author-sourced)
- Author credited as Milton Paredes / MPJ Factory Studios (Quito, Ecuador),
  2005. The "Public Domain" tag comes from a third-party redistribution
  aggregator's metadata field, not from a licence file or statement I could
  attribute to Paredes himself. Third-party "public domain" tags on
  aggregator sites are a known unreliable source (they often just mean "no
  licence was stated," which legally is *not* the same as public domain).
- **LICENCE UNVERIFIED** despite the "public domain" label circulating.

### Papelmedia GM 2007 — provenance itself is disputed, treat as No
- Attributed to Simon Tristan Papel / Papelmedia. Reported CC BY 3.0
  Unported by aggregator sites, ~229 MB.
- Notably, there is a KVR Audio forum thread literally titled "Papelmedia
  redistributing free soundfonts?" — i.e. the community itself has
  questioned whether Papelmedia's own bank is built from other authors'
  uncredited work. That is a worse version of the GeneralUser GS/Arachno
  provenance problem: here it's not even the original author expressing
  doubt, it's outside accusation. **Do not bundle.**

### Crisis General MIDI (CGM 3.01) — explicit paid commercial licence required
- Author: Chris "Crisis" Maricourt with Simone Piervergili. ~1.5 GB
  uncompressed, full 128 GM instruments + 47 percussion sounds.
- Author's own site (bismutnetwork.com) states — per search-result
  quoting, since the page itself 502'd when I tried to fetch it directly —
  free for personal use, but **commercial releases or public performances
  require a licence purchased from Bismut Network**.
- **Bundle-safe: no**, unambiguously — this is a paid-commercial-licence
  product wearing "free soundfont" branding. Good candidate for neither
  list unless we're willing to pay for a commercial licence, which is out
  of scope for a "free GM bank" survey.

---

## SF2 modulator / AUSampler rendering caveat (applies broadly)

This wasn't bank-specific in what I found, but it matters for every
candidate above since DAW Pro loads `.sf2`/`.dls` directly:

- Apple's `AUSampler` accepts SF2 and DLS presets via the same
  `instrumentType` enum path (per Apple's TN2283 and the AUSampler
  properties docs), but real-world reports (Apple Developer Forums thread
  on `AVAudioUnitSampler` controllers) describe **inconsistent MIDI
  controller support** — volume/pan work, but other CCs configured via
  modulators/mod-matrix routing in the source instrument don't reliably
  come through.
- SoundFont-ecosystem documentation (synthfont.com's modulator page) notes
  that even mainstream SF2 players (SynthFont2 and similar) deliberately
  **ignore modulators for several CCs** (5 portamento time, 7 volume, 8
  balance, 10 pan, 11 expression, 65 portamento on/off, 84 portamento
  control) because those CCs already carry a fixed meaning in most files —
  i.e. modulator-driven behavior is inconsistently honored across the SF2
  ecosystem generally, not just on Apple's engine.
- **Practical implication for DAW Pro:** any bank whose "expressiveness"
  relies heavily on custom SF2 modulators (rather than plain
  velocity-keyed/velocity-layered zones, which is what MuseScore_General's
  violin preset example above shows) is a risk — those modulator-driven
  behaviors may simply not fire under AUSampler. This favors banks built
  primarily on velocity-range zone splitting over one leaning on exotic
  modulator wiring, but I did not find a bank-by-bank breakdown of
  modulator usage in this pass — this would need direct inspection of each
  `.sf2`'s preset/instrument chunks (e.g. with Polyphone) to confirm, which
  is future work, not something resolvable from documentation alone.

---

## Actionable takeaways

1. **Top pick for bundling: MuseScore_General.** Cleanest, directly-fetched
   MIT licence text with named copyright holders
   (https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md),
   small size (~36 MB `.sf3` — need a decoder check, since DAW Pro's stated
   support is `.sf2`/`.dls`, not `.sf3`; if we can't load `.sf3`, use the
   `.sf2` variant, at the cost of the reported ~208 MB, unconfirmed number),
   confirmed velocity layering, and years of precedent being shipped inside
   a real commercial-adjacent open-source product with no known legal
   incident. Recommend engineering spike: confirm DAW Pro's SF2/DLS loader
   can actually parse `.sf2` exported from this project (not just `.sf3`),
   and do a spot-check for velocity response similar to the measurement
   already done on `gs_instruments.dls`.

2. **Ranked shortlist — top 3 to BUNDLE in the app:**
   1. **MuseScore_General** — MIT, small, primary licence text in hand.
   2. **FluidR3Mono** (or full FluidR3 GM) — MIT, same lineage as #1 but a
      separate, larger, more "classic" GM timbre set; good as a second
      bundled option or fallback. Caveat: no single canonical hosting URL
      (open GitHub issue), so we'd need to pick and vendor one specific
      mirror and note its provenance.
   3. *(Tentative, needs legal sign-off, not a clean "yes")* **GeneralUser
      GS** — broad usage rights explicitly including commercial use, small
      size, but the author's own "cannot be 100% sure where all the
      samples originated" statement is a real liability for a paid
      commercial product; I would not ship this without either (a) a legal
      opinion that the risk is acceptable, or (b) the author's newer
      confirmation that no valid claims have surfaced since 2000. Do not
      silently promote this above #1/#2.

3. **Ranked shortlist — top 3 to RECOMMEND AS A SELF-DOWNLOAD instead
   (i.e., we point the user at it, we don't ship it):**
   1. **Musyng Kite** — deep/expanded GM set, but CC BY-SA 3.0's
      share-alike clause and ~990 MB size make it a poor bundle candidate
      even though it's legally usable by the *user* for their own music.
   2. **Timbres of Heaven** — reportedly strong GM/GS/XG coverage and long
      community track record, but no licence text I could verify in this
      pass; fine to link to, not fine to embed until someone reads the
      actual bundled README.
   3. **SGM-v2.01** — same story: usable by end users, but the CC BY
      3-vs-4 conflict and unresolved provenance mean we shouldn't be the
      one distributing it.
   These lists differ from the bundle list specifically because size,
   share-alike terms, and unverified licences are disqualifying for
   *us* redistributing the file inside a paid product, but none of those
   three properties stop an individual user from downloading and using the
   bank for their own music — which is the exact distinction the task
   brief asked me to preserve.

4. **Hard "no" list — do not use for either purpose without new
   information:** Arachno (author says don't), Crisis General MIDI (paid
   commercial licence required), Papelmedia (community-disputed
   provenance), Chorium and Airfont 380 (no verifiable licence at all).

5. **Follow-up work this report could not finish (flag honestly):**
   - I did not open any actual `.sf2` file to inspect modulator usage,
     preset counts, or true velocity-layer depth — every quality claim
     above is secondhand (author README / forum / aggregator). Before
     committing to MuseScore_General or FluidR3, someone should load both
     in Polyphone (or DAW Pro's own loader) and run the same velocity
     25/60/95/127 level+centroid measurement already done against
     `gs_instruments.dls`, to confirm they actually clear the "not a
     volume knob" bar before we build a decision on documentation alone.
   - `schristiancollins.com/generaluser.php` (GeneralUser GS's actual
     primary page) did not return usable body text via WebFetch in this
     session — worth a direct browser check before finalizing any
     GeneralUser GS decision.
   - `bismutnetwork.com`'s Crisis GM page 502'd — the "paid commercial
     licence required" conclusion rests on a search-engine summary of that
     page, not a page I read myself. High confidence given it's repeated
     independently, but flagging per the honesty requirement.

---

## Verification pass — done by the main session, 2026-08-27

The agent report above was **not taken at face value.** Four claims were checked
directly against primary sources. One was wrong, one was overstated, two held.

### ❌ CORRECTED — "MuseScore_General ships in the MuseScore repo"

It does not, any more. `gh api repos/musescore/MuseScore/contents/share/sound`
returns exactly:

```
FluidR3MonoChangeLog.txt   FluidR3Mono_GM.sf3  (23,712,790 B)
FluidR3Mono_License.md     MS Basic.sf3        (51,278,610 B)
MS Basic_License.md        MS_Basic_Changelog.md
README.md                  SF_VERSION
```

The shipped banks today are **FluidR3Mono_GM** and **MS Basic**. Any plan that
says "vendor MuseScore_General from the MuseScore repo" cannot be executed as
written.

⚠️ **And the two licence files are cross-named.** `FluidR3Mono_License.md`
actually describes **MS_General.sf2** (v0.1 alpha, 1 March 2018, carrying the
line *"alpha work-in-progress. Information on all sample sources will be
provided upon release"*); `MS Basic_License.md` describes
**MuseScore_General.sf2** v0.2, 13 May 2020. **Read the CONTENT, not the
filename** — picking a bank by which licence file sits next to it gets you the
wrong document.

### ⚠️ OVERSTATED — "documented provenance in a sample-sources CSV"

`MuseScore_General_Sample_Sources.csv` is **referenced by the licence prose but
is not in the repository.** `gh api search/code` for that name across
`musescore/MuseScore` returns only `MS Basic_Readme.md` and
`MS Basic_License.md` — the two files that MENTION it, not the file itself.

So the provenance claim rests on the licence's prose, **not** on a shipped
source table. That is still better than the alternative (below), but it is not
the auditable artifact the report implied. Do not cite the CSV as evidence.

### ✅ CONFIRMED — MIT, verbatim, including the right to sell

The COPYING section carries standard MIT text — *"Permission is hereby granted,
free of charge … to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies"* — copyright Michael Cowgill (2014-16) and Frank Wen
(2000-2002, 2008). Obligation: *"The acknowledgements and copyright notices
above must be included in any derivative work."* Attribution, not a viral term.

### ⭐ CONFIRMED, AND IT IS THE DECISIVE FINDING — provenance language

This is the sentence that settles the bundle question, and it is worth reading
against its competitor:

> **FluidR3 (MIT):** *"Fluid was constructed in part from samples found in the
> public domain that I edited/cleaned/remixed/programmed and largely from
> recordings of my own and in conjunction with the people below who helped
> along the way."*

> **GeneralUser GS:** *"I cannot be 100% sure where all of the samples
> originated."*

One author **asserts** where his material came from and names his collaborators.
The other **disclaims knowledge** of it. For a bank we would compile into a
shipped binary, that difference is the whole risk story — and it does not depend
on the missing CSV.

**Conclusion: the FluidR3 lineage is the bundle-safe line.** Ship
`FluidR3Mono_GM.sf3` (23.7 MB — the mono build is the small one) with the
attribution notice reproduced.

### Cross-check on the companion survey

Two headline claims from `soundfont-survey-instrument-libraries.md` were spot-
verified independently:

- **VSCO 2 Community Edition = CC0.** Confirmed via Versilian's own site and the
  VCSL repos: *"no royalties, no credit, no special terms"*, commercial software
  explicitly permitted. Bundling is unambiguous.
- **Salamander Grand Piano V3 = CC BY 3.0 Unported** (Alexander Holm, Yamaha C5,
  16 velocity layers). Confirmed across the sfzinstruments GitHub repo, the
  Internet Archive item, and the sfz-website instrument page.

⚠️ **CC BY is a SHIPPING OBLIGATION, not a free lunch.** Salamander is the best
free piano available and it costs us a credits screen. CC0 candidates
(VSCO 2 CE, VCSL, jRhodes3d, Karoryfer) cost nothing. That is a product
decision, not a research one.

### What is still UNMEASURED

Licence clarity is not sound quality. **None of these banks has been through
`scripts/probes/timbre-liveness.sh` yet** — which is the tool that would have
caught the "toy instrument" complaint that started this whole thread. A bank
with a clean licence and one velocity layer solves the legal problem and not the
musical one. Downloading the shortlist and running the ladder is the next step,
and until it is run, every quality claim here is reputation, not measurement.

---

## ⛔ CORRECTION TO MY OWN RECOMMENDATION ABOVE — measured 2026-08-27

**The file I named cannot be loaded by this app.** I wrote "Ship
`FluidR3Mono_GM.sf3`" three sections up. That is wrong, and it is wrong in the
way this tree fails most often — I named a plausible artifact without checking
the thing that consumes it.

`.sf3` is MuseScore's **Vorbis-compressed** SoundFont variant. This app accepts
**`.sf2` and `.dls` only**, at two independent gates:

- `Sources/DAWCore/SoundBanks.swift:205` — auto-discovery filter
  `["sf2", "dls"].contains($0.pathExtension.lowercased())`
- `Sources/DAWCore/SoundBanks.swift:230` — the import validator
  `guard ext == "sf2" || ext == "dls"`, throwing
  *"sound bank must be a .sf2 or .dls file"*

**The bundle target is therefore `FluidR3_GM.sf2`** — Frank Wen's original
stereo release, ~140 MB, the *same* MIT lineage and the same provenance
sentence, so every licence conclusion above stands unchanged. Only the artifact
and the size story change. ⚠️ Ship it from a source that carries the licence
text WITH the file: the cross-named-licence trap documented above is exactly why
"same lineage" does not imply "same terms travelled with this copy."

⚠️ **And note what "Mono" meant.** `FluidR3Mono_GM.sf3` is a *mono* build. Even
had the format loaded, a mono default piano in a stereo DAW is a quality
decision, not a neutral size saving — and the liveness probe measures timbre,
not width, so it would never have flagged it.

### 🐛 THIS IS ALSO A REAL IMPORT DEFECT — filed as m31-g

The user's question that started this survey was *"can we let consumers import
what they want?"* Partly **no**, and this is the measured reason:

**SF3 is the format a consumer most likely already has.** MuseScore — the single
biggest free-soundfont distribution channel — ships `.sf3` exclusively today
(see the repo listing above: `FluidR3Mono_GM.sf3`, `MS Basic.sf3`, and no `.sf2`
at all). A user who grabs "the free soundfont everyone recommends" gets a file
this app refuses.

**And the two rejection paths differ in a way that matters:**

| path | what the user sees |
|---|---|
| explicit import | an honest error naming the accepted formats — **fine** |
| **drop it in a scan directory** | **NOTHING. The bank silently never appears.** |

⭐ The auto-discovery filter does not warn, log, or list the file — a `.sf3`
sitting in the library directory is indistinguishable from no file at all. That
is this tree's characteristic failure mode stated exactly: **a tool that never
looked and a tool that looked and found nothing produce the same output.**

Fix shape, two tiers:
1. **Minimum — ✅ SHIPPED 2026-08-28 (m31-g tier ①).** Auto-discovery now
   notices `.sf3` and surfaces it as an unsupported-format entry instead of
   dropping it. `SoundBankInfo` gained `supported: Bool` (derived) and
   `unsupportedReason: String?`; `instrument.listSoundBanks` /
   `instrument_list_sound_banks` carry both, additively. The entry is
   **listed but never selectable** — three independent gates
   (`ProjectStore.validateSoundBank`, the wire's `parseSoundBankSource`,
   `SoundBankLibrary.importBank`) reject by extension and none of them reads
   the new field, so labelling a format can never accidentally make it
   loadable. Behavioural gates plant a real `.sf3` in a real temp scan
   directory: `Tests/DAWCoreTests/SoundBankUnsupportedFormatTests.swift`.
2. **Better — NOT DONE.** Decompress SF3→SF2 at import. SF3 is structurally
   SF2 with Vorbis-encoded sample data, so the conversion is mechanical
   and one-way at import time and nothing downstream changes. It needs a
   Vorbis decoder, which the tree does not currently link.

Until (2) exists, "consumers can import what they want" is only true for `.sf2`
and `.dls` — but a consumer who drops an `.sf3` in now gets told so, in the
list, with the way out ("export a .sf2 from MuseScore or Polyphone"). Our
documentation should still say `.sf2`/`.dls` plainly rather than implying
general SoundFont support.
