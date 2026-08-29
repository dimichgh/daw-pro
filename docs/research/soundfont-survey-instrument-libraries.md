# Survey: individual high-quality instrument libraries (clear licences)

Date: 2026-08-27. Author: research-analyst (sonnet).

Scope note: this is deliberately **not** a survey of full-GM soundfont banks (FluidR3, GeneralUser GS,
Musyng Kite, etc.) — a parallel research task covers those. This doc surveys **individual instruments
and small curated libraries** with the cleanest possible licences, on the theory that a handful of
genuinely good instruments (many velocity layers, round robin, decent mic'ing) beats 128 mediocre GM
patches. DAW Pro's sampler has a full keyzone model (pitch/velocity ranges, round robin, loop points,
per-zone envelopes/crossfades) and can import raw WAV/SFZ mappings in addition to loading .sf2/.dls
directly, so SFZ-format and plain-WAV libraries are in scope, not just soundfonts.

Every licence claim below is sourced with a URL. Where I could not find primary licence text, or the
text was ambiguous, I wrote **LICENCE UNVERIFIED** or flagged the ambiguity explicitly — I did not
infer a licence from marketing language like "free."

---

## Comparison table

| Library | Instrument(s) | Licence | CC0/PD? | Format | Approx. size | Velocity layers / RR |
|---|---|---|---|---|---|---|
| [VSCO 2 Community Edition](https://versilian-studios.com/vsco-community/) | Orchestral (strings/brass/ww/perc), some keys | CC0 | **Yes** | WAV + SFZ | ~3 GB | Not documented per-instrument |
| [VCSL (Versilian Community Sample Library)](https://github.com/sgossner/VCSL) | Broad general-purpose (orchestral, world, misc) | CC0 | **Yes** | WAV (44.1/48 kHz, 16/24-bit) + SFZ | ~20–75 MB per instrument, library-wide total large | Mostly 1 RR / 2–3 vel. layers; more for percussion |
| [Salamander Grand Piano V3](https://archive.org/details/SalamanderGrandPianoV3) | Piano (Yamaha C5) | CC BY 3.0 | No (attribution required) | WAV/SFZ (multiple community ports) | 1.9 GB (48 kHz/24-bit set) | **16 velocity layers**, no RR documented |
| [Sonatina Symphonic Orchestra](https://github.com/peastman/sso) | Full orchestra (strings/brass/ww/perc/piano/harp/organ) | **CC Sampling Plus 1.0** (⚠ non-standard, see notes) | No | SFZ, 16-bit/44.1 kHz | multi-GB | ≥2× RR on most short articulations; vel. layer count not documented |
| [Virtual Playing Orchestra](https://virtualplaying.com/virtual-playing-orchestra/) | Full orchestra | Mixed sources (CC Sampling+, CC BY-SA, CC0); author-added no-resale term | No (attribution required by underlying sources) | SFZ + WAV | 603 MB–842 MB depending on version | 2 vel. layers (brass documented); RR on staccato strings |
| [Philharmonia Orchestra Sound Samples](https://philharmonia.co.uk/resources/sound-samples/) | Full orchestra + guitar/mandolin/banjo | Custom "free to use, no resale as-is" | No (not CC-licensed per se) | WAV | not stated | Not documented; generally single-velocity |
| [University of Iowa Electronic Music Studios samples](https://theremin.music.uiowa.edu/) | Strings, winds/brass, percussion, Steinway piano | "Freely available… without restrictions" (site statement, no formal CC licence) | Effectively PD-like but **LICENCE TEXT UNVERIFIED** as a formal document | AIFF, 16-bit/44.1 kHz mono (piano stereo) | not stated | Single dynamic per note in most sets (site is decades old, sparse) |
| [Karoryfer Samples (30+ free libraries)](https://shop.karoryfer.com/pages/free-samples) | Bass, guitar, drums (Big Rusty/Unruly/Swirly/Frankensnare), piano (Osiris), sax, tuba, misc | CC0 (all except Marie Ork) | **Yes** (except Marie Ork) | SFZ, some with WAV | varies, individually small (10s–100s MB) | Varies by title; not globally documented |
| [jRhodes3d (Rhodes Mark I Stage 73)](https://sfzinstruments.github.io/pianos/jrhodes3d/) | Electric piano | CC0 | **Yes** | SFZ, 16-bit | small (~67 samples) | Up to 5 velocity layers |
| [MuseScore Drumline (MDL)](https://musescore.org/en/mdl) | Marching drumline percussion | **Mixed per-instrument** — MIT (MS_General.sf2), other components separately credited (Michael Schorsch, 2016) | Partial | SFZ (9 soundfonts) | not stated | Not documented |
| [99 Drum Samples I/II (99Sounds)](https://99sounds.org/drum-samples/) | One-shot drum hits (not a mapped kit) | "Royalty-free" — **LICENCE UNVERIFIED** as a formal redistribution grant | No | WAV, 24-bit | not stated | N/A — one-shots, not a velocity-layered instrument |
| [Pianobook libraries (community)](https://www.pianobook.co.uk/terms-conditions/) | Various pianos/keys, community-recorded | Custom EULA — **explicitly forbids resale/redistribution of the samples or derivatives** | No | varies | varies | varies |
| [MT Power Drum Kit (Manda Audio)](https://www.powerdrumkit.com/) | Acoustic drum kit | Free plugin, donationware — **not a sample-library licence, it's a closed VST/AU/AAX plugin**; no bundling rights found | No | Plugin (not raw samples) | N/A | N/A — not usable as a sampler asset |

---

## Section-by-section evidence

### 1. Piano

**Salamander Grand Piano V3** — Alexander Holm.
- URL: https://archive.org/details/SalamanderGrandPianoV3 (canonical mirror; original site is defunct/moved)
- Licence: **CC BY 3.0** — https://creativecommons.org/licenses/by/3.0/. Attribution required; commercial use and modification explicitly permitted under the licence.
- Format: WAV/SFZ community ports; 48 kHz/24-bit source, 1.9 GB.
- Recording: Yamaha C5 grand, two AKG C414 in AB position ~12 cm above the strings.
- Velocity layers: **16**, sampled in minor thirds from the lowest A. No round-robin documented (single take per velocity/pitch step; separate hammer-noise and string-resonance release samples).
- Redistribution inside a commercial app: **permitted with attribution** — this is the single biggest quality library with an unambiguous, commercially-safe licence. Attribution obligation = one line in a credits screen.
- Widely re-packaged by the community (Pianoteq comparisons, LinuxSampler configs, multiple SFZ ports) — a mature, battle-tested asset, not a fringe find.

**Osiris Piano (Karoryfer × Versilian Studios)** — mentioned on Karoryfer's free page as a 2026 KVR Developer Challenge entry, CC0 per Karoryfer's blanket policy. I did not independently verify a separate licence file for this specific title; treat as CC0 pending a direct check of its own SFZ header, since Karoryfer's stated blanket policy is "all CC0 except Marie Ork."

**University of Iowa Steinway piano** samples exist within the broader Iowa EMS collection (see Orchestral section) — stereo, unlike the rest of that mono collection. Licence text is a website statement, not a formal licence document — flagged **UNVERIFIED** as a legal instrument even though the practical risk looks low.

### 2. Drums / percussion

This category is the weakest of the four in "one clearly-licensed, well-mapped, multi-velocity kit" terms. Findings:

- **Karoryfer's drum titles** (Big Rusty Drums, Unruly Drums, Swirly Drums, Frankensnare, Virtuosity Drums, Gogodze Phu I/II) are CC0 per https://www.kvraudio.com/news/karoryfer-samples-sets-drum-kit-and-snare-drum-libraries-free-57708 and the shop's free-samples page. These are small, characterful kits (not GM-complete), SFZ format. Velocity/RR counts are not documented library-wide; would need per-file inspection of each SFZ before committing to a bundling decision.
- **VCSL** explicitly calls out percussion as one of the categories where it deviates from its default "1 RR / 2–3 velocity layers" — https://github.com/sgossner/VCSL/blob/master/README.md. CC0. This is probably the best *broad* CC0 percussion source, but exact RR/velocity counts need per-instrument confirmation once we pick specific patches.
- **MuseScore Drumline** — mixed per-file licensing (MIT for `MS_General.sf2`, individually credited components for the rest per Michael Schorsch, 2016). Good recordings ("professional musicians, SFZ format, 9 separate soundfonts" per MuseScore's own description) but the licence needs a per-file audit before bundling — I could not find one composite licence statement covering the whole extension. **Do not bundle without that audit.**
- **99Sounds "99 Drum Samples I/II"** — one-shot hits, not a mapped/velocity-layered instrument, and the licence is marketing language ("royalty-free") with no primary licence text found on the product page. **LICENCE UNVERIFIED.** Even if resolved, this isn't the right shape of asset (no keyzone mapping, single dynamic per sample) for our sampler's velocity-layer story.
- **MT Power Drum Kit** — a closed AU/VST/AAX *plugin*, donationware, not redistributable raw samples. Excluded from consideration; noted only because it's a very common recommendation in "free drums" lists and I want the exclusion on record so it doesn't get re-proposed.

**Conclusion for drums: no single library here matches the piano/orchestral tier's clarity + quality.** The realistic path is VCSL/Karoryfer CC0 percussion patches assembled into our own kit mapping, accepting we may need to record or commission a proper multi-velocity/RR kit later if drum quality becomes a differentiator claim.

### 3. Orchestral — strings, brass, woodwinds

**VSCO 2 Community Edition** — Versilian Studios.
- URL: https://versilian-studios.com/vsco-community/
- Licence: **CC0**, stated directly on the page ("Creative Commons 0 (i.e. public domain)... no rules, no royalties, no limits"). https://versilian-studios.com/vsco-community/
- Format: WAV (44.1 kHz, 16/24-bit) and SFZ, ~3 GB, ~3,000 samples across ~70 packs, covering woodwinds, brass, strings, percussion, and some keys.
- Velocity/RR: not documented on the page for individual instruments; this is the CE (cut-down) tier of the paid VSCO 2 library, so expect fewer layers than the commercial version.
- Redistribution: unrestricted — CC0 removes the question entirely.

**VCSL (Versilian Community Sample Library)** — successor/expansion project.
- URL: https://github.com/sgossner/VCSL, README: https://github.com/sgossner/VCSL/blob/master/README.md
- Licence: **CC0**, explicit in the README ("Essentially it's Public Domain... no royalties, no credit, no special terms").
- Format: WAV 44.1/48 kHz, 16/24-bit, + auto-generated SFZ.
- Size: individual instruments ~20–75 MB.
- Velocity/RR: "Most articulations only have a single round robin and two to three velocity layers," with percussion and select cases getting more. This is candidly disclosed by the maintainers, which I read as a good-faith signal about the rest of their claims too.

**Sonatina Symphonic Orchestra (SSO)** — originally Mattias Westlund, community-maintained fork at https://github.com/peastman/sso.
- Licence: **Creative Commons Sampling Plus 1.0** — this needs a flag. CC retired the "Sampling" licence family; Sampling Plus 1.0 historically permitted *sampling* (using excerpts to create new derivative recordings) and commercial use of the *derivative*, but is **not** a standard "use and redistribute freely" licence like CC-BY or CC0, and its terms are murkier for "ship the original samples verbatim inside a sampler instrument in a commercial app" than for "chop up small excerpts into a song." Given DAW Pro would be shipping the *original, unmodified* keyzone-mapped samples (not excerpts folded into a fixed recording), **I would not treat SSO as clearly clear for our exact use case** without a lawyer's read of Sampling Plus 1.0 against "redistribute inside a commercial sampler." Flagging this explicitly since it's one of the libraries the task asked me to check.
- Format: SFZ, 16-bit/44.1 kHz. Round robin ≥2× on most short articulations. Wide instrument coverage (strings/brass/ww/pitched & unpitched percussion/piano/harp/harpsichord/organ).

**Virtual Playing Orchestra (VPO)** — Paul Battersby, https://virtualplaying.com/virtual-playing-orchestra/.
- Licence: **composite** — built from CC Sampling Plus 1.0, CC BY-SA 3.0/4.0, and CC0 sourced material, with the compiler's own added term: "I do not feel it is right to repackage and sell this library in part or in whole for profit." That line is a *request*, not obviously a binding term layered on top of the underlying CC licences, but it signals the author's intent clearly enough that I would not treat "sell/bundle VPO into a paid commercial DAW" as safe without reaching out to Paul Battersby directly. Attribution to original sources ("copy, redistribute, modify... provided appropriate credit is given") is required regardless.
- Format: SFZ + WAV, 603 MB–842 MB depending on version, 168 instrument patches.
- Velocity/RR: 2 velocity layers documented for brass; round robin on staccato strings.
- **Net: same underlying licence murkiness as SSO (they share source material), plus an explicit no-resale ask from the compiler. Treat as higher legal exposure than VSCO2/VCSL, not recommended for bundling into a commercial app without direct permission.**

**Philharmonia Orchestra Sound Samples** — https://philharmonia.co.uk/resources/sound-samples/.
- Licence: custom terms, not a standard CC licence: "free to use as you wish, including releasing them as part of a commercial work," but explicitly **"must not be sold or made available 'as is' (i.e. as samples or as a sampler instrument)."**
- This is a direct, sourced answer to a real bundling risk: **a DAW that ships a sampler instrument built from Philharmonia's raw samples is exactly the "as a sampler instrument" case they prohibit.** Do not bundle Philharmonia samples as loadable keyzone content. (Fine to use for one-off SFX/demo audio inside marketing material, not fine as a shipped instrument.)

**University of Iowa Electronic Music Studios (EMS)** — https://theremin.music.uiowa.edu/.
- Licence: informal — the site states samples "have been freely available... and may be downloaded and used for any projects, without restrictions" since 1997, but I found no formal licence document (no CC badge, no explicit "you may redistribute commercially" clause). **Practically low-risk (an academic institution's own long-standing public statement, widely relied upon by the freeware sample-library community, e.g. as an SSO source), but formally LICENCE UNVERIFIED as a document I can cite in a compliance file.**
- Format: AIFF, mono, 16-bit/44.1 kHz (piano is stereo). Old recordings (anechoic chamber), single dynamic per note in most sets — not multi-velocity, so of limited value against our "velocity layers are the differentiator" thesis even where legally fine.

### 4. Electric piano / organ / guitar / bass

- **jRhodes3d** (Rhodes Mark I Stage 73) — CC0, SFZ, 16-bit, ~67 samples with up to 5 velocity layers, sampled every 4th white key. https://sfzinstruments.github.io/pianos/jrhodes3d/ — good small, clean CC0 electric piano.
- **Karoryfer bass/guitar titles** (Meatbass, Big Little Bass, Black And Blue Basses, Black And Green Guitars, Shinyguitar, Emilyguitar, War Tuba, Bear Sax) — all CC0 per the blanket policy verified above. SFZ format, individually small. Good breadth for "one decent bass, one decent guitar, one decent horn" rather than orchestral-grade coverage.
- **Organ**: no CC0/PD library found in this pass with documented multi-velocity sampling. SSO and VPO both include a pipe-organ patch, but inherit the Sampling-Plus-1.0 licence caveat above. **Gap — flag for a follow-up search specifically targeting organ (e.g. Versilian's own commercial organ line, or a dedicated Hammond-clone freeware SFZ) if organ becomes a near-term roadmap need.**
- **Pianobook** (community platform, many electric pianos/organs/guitars posted) — explicitly **excluded**: its EULA (https://www.pianobook.co.uk/terms-conditions/) forbids resale or redistribution of the samples or derivatives outside individual musical compositions. Not usable as bundled DAW content regardless of the specific pack's apparent generosity.

---

## Ranked shortlist — bundle these first

Ranked by (licence clarity × sound quality × format-fit for our keyzone sampler), most confident first:

1. **Salamander Grand Piano V3** (CC BY 3.0) — the single best acoustic piano available for free, 16 velocity layers, mature/well-tested, one-line attribution obligation. This should be DAW Pro's default piano on day one.
2. **VSCO 2 Community Edition** (CC0) — broadest CC0 orchestral coverage (strings/brass/ww/some perc/keys), zero licence risk, directly usable as WAV+SFZ source for our keyzone importer.
3. **VCSL** (CC0) — complements VSCO2 CE with a wider, still-growing CC0 pool, candidly documents its own velocity/RR limits (2–3 layers typical, more for percussion) so we can pick the better-sampled instruments rather than bundling the whole set blind.
4. **jRhodes3d** (CC0) — closes the "electric piano" gap cheaply; small, clean, up to 5 velocity layers, zero licence risk.
5. **Karoryfer's CC0 catalogue (selected titles)** — best source for bass, guitar, and characterful drum kits with zero licence risk; treat as a grab-bag to cherry-pick from (Meatbass for bass, Big Rusty/Unruly Drums for a percussion starter, Bear Sax for a solo horn) rather than bundling all 30+ titles.

**Explicitly not recommended for bundling, with reasons:**
- Sonatina Symphonic Orchestra and Virtual Playing Orchestra — CC Sampling Plus 1.0 lineage is not a clean "redistribute the unmodified samples inside a commercial sampler" grant; VPO's compiler additionally asks not to resell. Re-evaluate only after either (a) a lawyer's read of Sampling Plus 1.0 against our exact use, or (b) direct written permission from the compilers.
- Philharmonia Orchestra samples — licence text directly prohibits distributing "as a sampler instrument," which is exactly what we'd be doing.
- Pianobook packs — EULA forbids redistribution outright.
- 99Sounds drum packs and MT Power Drum Kit — wrong asset shape (one-shots / closed plugin) and/or licence text not found.
- MuseScore Drumline — needs a per-file licence audit before use; not a blanket-clear grant.

---

## Actionable takeaways

1. **Ship Salamander Grand Piano V3 as the default/bundled piano**, replacing reliance on a GM soundfont's single-velocity-layer piano patch. Add a `THIRD_PARTY_LICENSES.md` (or extend an existing credits surface) with the CC BY 3.0 attribution line — this is the one bundling obligation it carries. Suggest a new ROADMAP item under the sampler/content milestones: "Bundle Salamander piano as default instrument + attribution credits screen entry."
2. **Bundle VSCO 2 CE + curated VCSL patches as the default orchestral starter kit**, imported through our existing SFZ import path (per `docs/research/2026-07-16-spike-sfz-dspreset-formats.md` — the SFZ importer this survey assumes exists). Both are CC0, so no credits-screen entry is legally required, though crediting Versilian Studios in an "acknowledgements" list is good practice and costs nothing.
3. **Do not bundle SSO or VPO without a licence re-check.** If orchestral depth beyond VSCO2/VCSL becomes a priority, the next research step is either (a) a targeted legal read of CC Sampling Plus 1.0 against "shipping unmodified samples inside a commercial sampler instrument," or (b) reaching out to the SSO/VPO maintainers for explicit written permission — cheap to ask, given both projects are actively maintained.
4. **Treat drums as an open gap.** Recommend a follow-up research pass specifically on CC0/PD multi-velocity, multi-round-robin drum kits (this survey did not find one that clears our quality bar at the same licence-clarity tier as the piano/orchestral picks). Until then, ship a starter kit assembled from Karoryfer + VCSL CC0 percussion patches, explicitly framed internally as "adequate, not a differentiator," and consider commissioning a proper drum kit recording later if drum quality becomes a marketed feature.
5. **Organ has no clean CC0/PD candidate found in this pass** — flag as a gap for whoever owns instrument-library roadmap planning; do not silently ship an SSO/VPO organ patch under the flagged Sampling-Plus-1.0 licence without the re-check in (3).
6. **Build a `docs/LICENSES-BUNDLED-CONTENT.md` (or equivalent) now, before any of these are wired into `bundle.sh`** — the M30 dogfooding work already showed the bundle-and-ship pipeline is sensitive to exactly this kind of "what's actually in the .bundle and under what terms" question. One file listing library, licence, URL, and attribution-required (Y/N) prevents the CC-BY obligation (Salamander) from getting silently dropped in a future rebuild.
