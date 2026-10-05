# Spike: one-click SoundFont download (m34-c)

Date: 2026-08-30. Author: research-analyst (delegated). Docs only — no code touched, no `Sources/`
edits, nothing downloaded (all sizes/checksums below are the publishers'/mirrors' own stated
numbers, not something measured locally).

Roadmap item (verbatim, `docs/ROADMAP.md:2842`): **"One-click download of a permissive SoundFont."**
Route: `swift-app-engineer` (+ `research-analyst` for the licence audit — this document). The bar the
user set is explicit and load-bearing: (1) redistribution permitted — we download it to users'
machines and possibly mirror it; (2) commercial output permitted — no royalty, no attribution-in-song,
no field-of-use limit. Ambiguity ranks a candidate down, it does not disqualify by itself, but it
disqualifies when it stacks with independent corroboration of real risk (see GeneralUser GS below).

---

## Recommendation

**Ship `MuseScore_General.sf2`** — 215,614,036 bytes, native `.sf2`, MIT licence.

> ⚠️⚠️ **SUPERSEDED IN ONE RESPECT, 2026-08-30 — READ BEFORE COPYING A URL FROM
> THIS DOCUMENT.** This section's recommendation of the osuosl URL as **the**
> source stands only as the *fallback* now. The user was asked how we should
> distribute the bank and chose **"mirror it ourselves, keep upstream as a
> fallback"**, so the shipped catalogue is:
>
> - **PRIMARY** — `https://github.com/dimichgh/daw-pro/releases/download/soundbanks-v1/MuseScore_General.sf2`
> - **FALLBACK** — the osuosl URL below, unchanged and byte-identical
>
> ⛔ **AND THE LICENCE OBLIGATION MOVED WITH IT.** Everything below was written
> for a world where we distributed **nothing** — the bytes went publisher→user,
> so MIT's notice condition never attached to us. **Hosting the primary makes us
> a distributor**, so the notice is now embedded in the app and written to disk
> beside the bank on install. Do not read this document's licence section as
> "nothing to do". Full record: `docs/ROADMAP.md` **m34-c-1**.

The upstream source this audit examined:
`https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2`

**Why it wins, in order of what actually decided it:**

1. **The MIT licence text is genuinely verbatim-fetched by me, today, from the file that sits next to
   the binary at the same host** — not reconstructed from fragments, not an aggregator's paraphrase:

   > *"Permission is hereby granted, free of charge, to any person obtaining a copy of this software
   > and associated documentation files (the "Software"), to deal in the Software without
   > restriction, including without limitation the rights to use, copy, modify, merge, publish,
   > distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
   > Software is furnished to do so, subject to the following conditions: The above copyright notice
   > and this permission notice shall be included in all copies or substantial portions of the
   > Software."*

   Copyright holders: Michael Cowgill (2014–16) and Frank Wen (2000–2002, 2008). Source:
   `MuseScore_General_License.md`, same directory as the binary, fetched 2026-08-30. This is standard,
   unmodified MIT — "distribute... sublicense... and/or sell" covers both halves of the user's bar
   without needing interpretation.

2. **A real, structured provenance document ships next to it** —
   `MuseScore_General_Sample_Sources.csv`, 186 data rows, columns for Bank#/Preset#/Preset
   Name/Details/Sample Credit/Changes. This is categorically stronger footing than an author's blanket
   "I can't be sure," even though not every row's Details/Credit field is filled (spot-checked; some
   are blank, meaning "nothing unusual to note," not "provenance unknown" — I did not audit all 186
   rows line by line). Fetched 2026-08-30.

3. **Native `.sf2` — this sidesteps a real, measured risk.** DAW Pro's sound-bank loader accepts only
   `.sf2`/`.dls` natively; `.sf3` (Vorbis-compressed) is auto-converted to a real `.sf2` on import via
   a vendored `stb_vorbis` decoder, **but that decoder is measured to fail on 17 of 1186 streams in the
   one file it has actually been run against** (`FluidR3Mono_GM.sf3`, 15 mainstream GM presets gone
   silent — 80 Square Lead, 81 Saw Lead, 38/39 Synth Bass, 62/63 Synth Brass; see
   `docs/research/soundfont-survey-gm-banks.md:494-517`, itself citing `Sources/DAWCore/SoundBanks.swift`
   and the m31-h close-out). `MuseScore_General.sf3` (the compressed sibling at the same osuosl mirror)
   has never been run through that decoder. Downloading the native `.sf2` directly means this whole
   risk class — and the compression math that turns a 38 MB download into a ~206 MB on-disk file —
   never enters the picture for this feature.

4. **The host is genuinely stable, and more stable than the alternative most people would reach for.**
   Every file at `ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/` is dated 2020-07-08/10 and
   has evidently sat unchanged for six years — Oregon State University's Open Source Lab is
   long-standing FOSS-hosting infrastructure (used by Debian, Linux Mint, and others). Compare: the
   *app's own* GitHub repo (`musescore/MuseScore`, `share/sound/`) has already changed what it ships
   once (from a full `MuseScore_General` release to today's `FluidR3Mono_GM.sf3` + `MS Basic.sf3`,
   per `docs/research/soundfont-survey-gm-banks.md:331-345`) — a plan that pointed at that repo path
   would already be broken. The dedicated osuosl mirror is a different, more stable target.

5. **It directly answers the brief that started this item.** Bank 128 (percussion) rows from the CSV
   (fetched 2026-08-30, searched for every Bank#=128 row): `Standard`/`Standard 1–7`, `Room`/`Room
   1–7`, `Power`/`Power 1–3`, `Electronic`, `TR-808`, `Jazz`/`Jazz 1–4`, **`Brush`, `Brush 1`, `Brush
   2`**, `Orchestra Kit`, `Marching Snare`, `OldMarchingBass`, `Marching Cymbals`, `Marching Bass`,
   `OldMarchingTenor`, `Marching Tenor` — roughly a dozen distinct kit families against the stock Mac's
   exactly one. The brushes brief that couldn't be honoured before, can be after this ships.

**Caveats on the recommendation, stated plainly, not buried:**

- **No published checksum for this exact file.** The osuosl directory listing (fetched 2026-08-30)
  contains the `.sf2`, the `.sf3`, a changelog, licence, readme, sample-sources CSV, and a 6-byte
  `VERSION` file (`"0.2.0"`) — no `SHA256SUMS` or equivalent. Debian packages a **newer** point release
  (`musescore-general-soundfont-lossless` 0.2.1-1) with a real, verified SHA-256 for its *source
  tarball* — `0e481d40ac7114d6aef5bdcf7d0246829b8f8873de02049896cd120d8490bcae`,
  274,424,736 bytes, for `musescore-general-soundfont_0.2.1.orig.tar.xz`
  (`https://deb.debian.org/debian/pool/main/m/musescore-general-soundfont/`, fetched 2026-08-30) — but
  that hash is for a different *version* (0.2.1 vs this file's 0.2.0), a different *archive format*
  (`.tar.xz` source bundle vs standalone `.sf2`), and **possibly a different *variant* entirely**: the
  same Debian search turned up a separate `musescore-general-soundfont-lossless` package description
  distinguishing an uncompressed "HQ" build from the standard one, and the CSV fetched below has its
  own HQ-comparison column — meaning the Debian tarball may unpack to `MuseScore_General_HQ.sf2`, not
  the plain `MuseScore_General.sf2` at the recommended URL. **Do not treat the Debian hash as
  verification for the mirror file under any circumstance** — it's evidence the lineage is legitimate
  and checksummable by a careful distro, not a hash you can check the download against.
- ~~**Exact byte size not published**, only the directory listing's rounded "206M".~~
  ✅ **RESOLVED 2026-08-30 — MEASURED, not published: `Content-Length: 215614036` (215,614,036 bytes
  = 205.63 MiB), `Last-Modified: Fri, 10 Jul 2020 08:27:44 GMT`, `HTTP/1.1 200 OK`.** Obtained with a
  `curl -I` **HEAD request — nothing was downloaded**, so the research constraint held. A `404`
  negative control on a fabricated filename in the same directory confirms the `200` distinguishes a
  real file from a missing one, and the `Last-Modified` independently corroborates this doc's
  "unchanged since 2020-07-10" stability claim.
  ⭐ **THIS IS A COMPLETENESS CHECK, NOT AN AUTHENTICITY ONE, AND THE IMPLEMENTER MUST NOT CONFUSE
  THEM.** An exact expected byte count defeats the failure this item actually names — *"a
  half-downloaded bank that reports success"* — but it says nothing about whether the bytes are the
  right ones. ⚠️ **`Content-Length` is a claim by the server, not a fact about the file**, so it is a
  precondition to check the download against, never the definition of "installed correctly"; the
  post-install `namesParsed == true` sentinel below remains the real gate.
- **Mono/stereo character is not fully resolved.** The bundled README states plainly: *"Instruments
  without specific attribution use samples from FluidR3Mono"* — i.e., for an unstated fraction of its
  128+ presets, the underlying samples are mono-sourced regardless of the file's own channel layout.
  I could not determine the file's actual channel structure without opening it in a tool like Polyphone,
  which is out of this pass's scope. **This is a sonic-character question, and per the brief, that's the
  user's call to make, not mine to assert** — see the runner-up section.
- **The name is legacy-branded.** MuseScore's *current* handbook (`handbook.musescore.org`, fetched
  2026-08-30) says "MuseScore comes packaged with its own native SoundFont, **MS Basic**" and does not
  itself link to the osuosl `MuseScore_General` mirror — I checked specifically and it doesn't. The
  version-number trail (License-file cross-naming pointing at "MuseScore_General.sf2 v0.2", and Debian's
  `musescore-general-soundfont` package being at 0.2.1) strongly suggests `MS Basic` and
  `MuseScore_General` are the same lineage under a rename — but this is inference from converging
  version numbers, not a byte-for-byte confirmation, and there is no "project's own published link" to
  point at. The six years of unchanged hosting plus Debian independently packaging the same lineage is
  the basis for calling this host "stable," not an official MuseScore endorsement of this specific URL.

---

## Runner-up: FluidR3 GM (Frank Wen, original stereo release)

**Loses on exactly one axis: no live, canonical, checksummed single-file host exists today.** Its
licence story is, if anything, *cleaner* than the winner's:

- Copyright © 2000–2002, 2008 Frank Wen, MIT. Provenance, in Wen's own words, quoted **identically**
  across three independent sources fetched/cross-checked 2026-08-30 — MuseScore's own
  `share/sound/FluidR3Mono_License.md` (which quotes it while explaining `MS_General.sf2` is *a fork
  of* FluidR3Mono), a Debian maintainer's dedicated copyright file
  (`https://people.debian.org/~tg/sf/MuseScore_General_Lite.copyright`, which attributes it directly
  to "Original Stereo Version... Copyright © 2000-2002, 2008 Frank Wen"), and independent WebSearch
  corroboration:

  > *"Fluid was constructed in part from samples found in the public domain that I
  > edited/cleaned/remixed/programmed and largely from recordings of my own and in conjunction with
  > the people below who helped along the way."*

  A first-person, positive assertion of origin — the opposite shape of GeneralUser GS's disclaimer
  below.
- **But there is no canonical live host.** The original hammersound.net/SourceForge location is
  defunct; this is not my inference, it's an **open, unresolved GitHub issue**
  (`fluidsynth/fluidsynth#479`) from a MacPorts maintainer asking exactly "where is the official
  download," still open as of this pass. Every current distribution is a downstream mirror.
- Best options found today, both with real gaps for a "point our downloader at this" use:
  - **`https://archive.org/download/fluidr3-gm-gs`** → `FluidR3_GM_GS.sf2`, 144.0 MB, dated
    2020-06-22, backed by a preservation `.torrent` (fetched 2026-08-30). Note the filename: this is
    the **GM+GS merged** variant, not the bare "FluidR3_GM.sf2" some other lists reference — same Wen
    authorship/licence, but I did not independently confirm the two are byte-identical in melodic
    content. **No checksum published on this listing.**
  - **Debian's `fluid-soundfont` source package** — real SHA-256 on the record:
    `2621acaa1c78e4abdb24bdd163230cc577e61276936d6aa6e3180582142f0343`, 134,835,922 bytes, for
    `fluid-soundfont_3.1.orig.tar.gz` (`.dsc` fetched 2026-08-30). This is a **source tarball**, not a
    standalone `.sf2` — using it means the downloader needs to unpack `.tar.gz`, a format this app's
    import path has no current reason to handle, and the tarball's contents split downstream into
    separate `fluid-soundfont-gm`/`fluid-soundfont-gs` binary packages, so it likely bundles more than
    one variant (the same "tarball may not equal one standalone file" caveat that applies to
    MuseScore_General's Debian checksum above applies here too — verify what's actually inside before
    trusting the hash against any single extracted `.sf2`).
- **Content**: full GM 128 + GS-extended kit variety (implied by the "GM_GS merged" naming). I did not
  find an enumeration with the rigor of MuseScore_General's CSV — flagged as unverified in this pass,
  not asserted.

**If the team wants FluidR3 GM instead:** either (a) vendor a copy ourselves after verifying it once
(fully permitted by MIT), becoming the durable host and minting our own pin, or (b) build one-time
`.tar.gz` extraction against Debian's checksummed source, confirming what's actually inside the tarball
before trusting the hash against a specific extracted file. Either is a reasonable call, but it's
strictly more engineering than the winner requires for a first ship, for a licence story that is
already excellent on both.

**On sound quality specifically:** if the deciding factor between these two ever becomes *how it
sounds* — stereo-original FluidR3 GM vs. a MuseScore_General bank partly built from mono-sourced
samples — that is a preference nobody on this side of the screen can actually judge, and per the
brief, it should be put to the user as a choice, not asserted by either agent.

---

## Not recommended: GeneralUser GS

Smallest (30.7 MB) and richest content-per-MB of the three — **261 instrument presets, 13 drum kits**
(per `https://github.com/mrbumpy409/GeneralUser-GS`, a maintained GitHub mirror, fetched 2026-08-30) —
and its licence *text* is not ambiguous: ScanCode LicenseDB (a third-party open-source licence
compliance database) classifies it **"Category: Permissive"**
(`https://scancode-licensedb.aboutcode.org/generaluser-gs-2.0.html`, fetched 2026-08-30), and the
operative grant is broad: *"You may use GeneralUser GS without restriction for your own music
creation, private or commercial."*

**What disqualifies it under this item's bar is provenance risk, not licence ambiguity — that
distinction matters and I'm keeping it precise.** The author's own words (quoted consistently across
ScanCode's entry, a haikuports licence mirror, and search-indexed copies of the primary page — see
verification notes below):

> *"[The author] cannot be 100% sure where all of the samples originated"* though none *"came from
> commercially published soundfont packages or sample CDs,"* and *"I have never received any complaint
> regarding sample ownership since I published the original GeneralUser GS back in 2000."*

That is a real mitigating fact (25+ years, no incident) but it is still the author disclaiming
certainty about the very thing our redistribution licence depends on: that he had the right to grant
it. **Independent corroboration that this is treated as a real disqualifier, not a theoretical one**:
searching for GeneralUser GS's Debian packaging status turned up a `linux.debian.legal` mailing-list
thread titled *"Is GeneralUser soundfont's license suitable for Debian main?"* A WebSearch summary of
that thread (the thread itself returned HTTP 429 on two separate fetch attempts — **flag this as
search-summary, unfetched, corroboration-only, not independently verified by me**) states the licence
"would not pass ftp-master review due to uncertainty about the provenance and license of the samples."
What I *did* verify directly: GeneralUser GS has no official Debian package, while `fluid-soundfont-gm`
and `musescore-general-soundfont` both do — an observed fact, not a search summary, and it's the kind
of absence that's consistent with the disputed thread's claim.

Given the user's own framing — *"ambiguity is a disqualifier here, not a footnote"* — I'm reading
"ambiguity" broadly enough to include "the grantor himself is not sure he owns what he's granting,"
even though the licence text itself is clean. Ranking this third is the conservative reading; if the
team judges 25 years with zero incidents is sufficient comfort, that's a call for the user or a legal
reviewer to make explicitly, not one to default into.

**Other findings, for completeness:**
- **Author's own primary page never rendered.** `https://schristiancollins.com/generaluser.php`
  returned only page headers via WebFetch across **two independent attempts by me**, plus one by the
  2026-08-27 survey — three failures total. The Wayback Machine is blocked entirely for my tooling
  ("Claude Code is unable to fetch from web.archive.org"). Every GeneralUser GS claim in this section
  is reconstructed from secondary/near-primary mirrors (ScanCode, haikuports, GitHub mirror,
  WebSearch), never a single verbatim capture of the author's own page. **This is a real verification
  gap, not a footnote — flagged per the task's own instruction that an unfetched licence is a
  blocker.**
- **Version numbering is inconsistent across every source checked**, and I could not resolve it:
  `1.471` (haikuports package recipe, older), `2.0.2` (one low-confidence secondary mention, per the
  2026-08-27 survey), `2.0.3` (current per a GitHub mirror's own summary). No checksum found for either
  2.0.x figure.
- **One real checksum exists, but for the old version**: SHA-256
  `4203835164766f428c4926c097c9ea58dae431c7fb8f9dbe277b92d80da45ec2` for
  `GeneralUser_GS_1.471.zip`, hosted at a **personal Dropbox share link**
  (`dropbox.com/s/4x27l49kxcwamp5/...`), captured in a Haiku OS package-recipe (third-party-verified at
  packaging time, not author-published). A Dropbox share link is also a materially weaker long-term
  hosting bet than a dedicated mirror or CDN. The author's own licence text additionally **asks users
  not to deep-link the download file** and to link to the main site instead — direct friction against
  a "one-click, no interstitial" feature even setting the provenance question aside.

---

## Candidate facts matrix

Everything above, consolidated in one place for an implementer with no web access. "Verified" means
fetched by me on 2026-08-30 unless noted; a `⚠` marks a gap called out in detail above.

| | **MuseScore_General.sf2 — WINNER** | **FluidR3 GM — runner-up** | **GeneralUser GS — not recommended** |
|---|---|---|---|
| **Licence** | MIT, verbatim-fetched, named copyright holders | MIT, verbatim-fetched provenance quote (3-source corroborated) | "Permissive" per ScanCode, but author disclaims sample-provenance certainty ⚠ |
| **Redistribution-safe?** | Yes | Yes | Provenance risk — see full section above |
| **Download URL** | `https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2` | None canonical ⚠ — best: `https://archive.org/download/fluidr3-gm-gs` (`FluidR3_GM_GS.sf2`) | Author page unreachable ⚠ — best: `https://github.com/mrbumpy409/GeneralUser-GS` |
| **Host stability** | 6 years unchanged, dedicated FOSS mirror (OSUOSL) | No live canonical host (open fluidsynth issue #479) ⚠ | Unverified — primary page never rendered ⚠ |
| **Size** | ≈206 MB (rounded, not exact) | 144.0 MB (archive.org copy) | 30.7 MB |
| **Format DAW Pro can load** | Native `.sf2` ✅ | Native `.sf2` ✅ | Native `.sf2` ✅ |
| **Checksum** | None published for this file. Debian has a real SHA-256, but for a newer version *and possibly a different (HQ) variant* — not usable to verify this download ⚠ | None on archive.org. Debian source tarball has a real SHA-256 (`2621acaa1c...`, 134,835,922 B) but for a `.tar.gz` bundle, not this `.sf2` ⚠ | One real SHA-256, but for the old v1.471 zip on a personal Dropbox link; nothing for the current 2.0.x ⚠ |
| **Contents** | Full GM+GS; 186-row provenance CSV; ~15 drum-kit families incl. **Brush/Brush 1/Brush 2** | Full GM 128 + GS kit variety (no per-preset enumeration found) ⚠ | 261 presets, 13 drum kits (richest content/MB) |
| **Known caveat** | Some presets mono-sourced per own README; legacy-branded, no official MuseScore link to this URL | No stable host is the whole story | Author's own provenance disclaimer, corroborated by Debian's apparent non-packaging |

---

## The already-shipped alternative I deliberately did NOT recommend: `MS Basic.sf3` / `FluidR3Mono_GM.sf3`

Worth naming explicitly since it's the file the app's own GitHub-hosted dependency (MuseScore) ships
*today*, and DAW Pro can already ingest it — m31-g/h (shipped 2026-08-28) added `.sf3` discovery plus
automatic Vorbis→`.sf2` conversion. I'm not recommending routing the one-click download through that
pipeline for this feature, for two concrete reasons, both already measured and on record in
`docs/research/soundfont-survey-gm-banks.md`:

1. `FluidR3Mono_GM.sf3` is explicitly **mono** — a real quality downgrade for a stereo DAW's default
   content, not a neutral size optimization.
2. The Vorbis decoder that makes `.sf3` usable **measurably failed on 17 of 1186 streams** in the one
   file it's actually been tested against, silencing 15 mainstream GM presets. `MS Basic.sf3` (the
   bigger, default MuseScore bank) has never been run through it — that specific file is untested, and
   a new feature is the wrong place to accept an unverified risk class for free when a native `.sf2`
   sidesteps it entirely.

If a future item wants the *app's own default bank swapped for MS Basic specifically* (as opposed to
"offer a one-click bigger palette"), that's a different, narrower question this doc doesn't answer.

---

## Prior art — what's already settled, what this doc adds

Two prior research docs cover most of this ground; this section states plainly what's already decided
so the rest of the document doesn't re-derive it.

**`docs/research/soundfont-survey-gm-banks.md` (2026-08-27, `research-analyst`, verified in a second
pass by the main session same day) already established:**
- The full comparative licence survey across eleven GM banks (FluidR3, GeneralUser GS,
  MuseScore_General, Musyng Kite, Arachno, Timbres of Heaven, SGM, Chorium, Airfont 380, Papelmedia,
  Crisis GM) — this doc does not re-survey the ones that were clean "no"s there (Arachno explicitly
  forbids commercial use; Crisis GM requires a paid licence; Papelmedia's provenance is
  community-disputed; Chorium/Airfont have no verifiable licence at all; Musyng Kite's CC BY-SA
  share-alike is a poor fit for redistribution).
- **The MIT-vs-disclaimer provenance distinction between FluidR3 and GeneralUser GS** — this doc's
  ranking agrees with and re-confirms that finding independently, rather than repeating it uncritically
  (see the fresh corroboration above: the Debian ftp-master signal and the observed absence of
  GeneralUser GS from Debian's archive, neither of which the 2026-08-27 pass had).
- **The format gate, by direct code citation**: `Sources/DAWCore/SoundBanks.swift:205,230` accepts
  only `.sf2`/`.dls`; a bundling/download plan built around `.sf3` "cannot be executed as written"
  without conversion.
- **m31-g/h shipped** (2026-08-28): `.sf3` auto-discovery + Vorbis→`.sf2` conversion, with the measured
  17/1186-stream decoder failure on `FluidR3Mono_GM.sf3` as a named, on-record risk.

**What is new in this document:**
- **The `ftp.osuosl.org` dedicated MuseScore soundfont mirror** — the 2026-08-27 survey only checked
  the app's own GitHub repo (`share/sound/`), found it now ships `.sf3`-only, and concluded (its own
  final correction) "the bundle target is therefore `FluidR3_GM.sf2`." It never found this separate,
  stable, native-`.sf2`-hosting mirror, which changes the recommendation for *this specific feature*
  (a one-click network download, where a dedicated stable URL matters far more than it does for a
  one-time bundling decision made once at build time).
- **The Bank-128 drum-kit enumeration** (Brush/Brush 1/Brush 2 confirmed present) — directly answers
  the brief's own stated pain point; the prior survey never opened the sample-sources CSV.
- **Checksum research for all three candidates** — the prior survey didn't attempt this; this doc found
  one real (if version/variant-mismatched) SHA-256 for the MuseScore_General lineage via Debian, one
  real (if differently-packaged) SHA-256 for the FluidR3 lineage via Debian, and one real (if
  version-old, Dropbox-hosted) SHA-256 for GeneralUser GS via Haiku's package recipe — and states
  plainly where no checksum exists at all.
- **The download-as-a-feature engineering spec** (below) — out of scope for a licence survey, in scope
  here.
- **Independent re-corroboration of the GeneralUser GS provenance risk** via the Debian ftp-master
  signal and the observed Debian-packaging asymmetry (GeneralUser GS absent; FluidR3 and
  MuseScore_General present) — the prior survey's caution rested on the author's words alone; this
  adds a second, independent voice reaching the same conclusion.

**The m18-h SFZ/DecentSampler spike** (`docs/research/2026-07-16-spike-sfz-dspreset-formats.md`,
`-design.md`, referenced from `docs/research/README.md:17-20`) is **not substantively relevant to this
item** — it settled a different question (importing SFZ/`.dspreset` *instrument mappings* the user
supplies) and its own GO decision is about a mapping-format importer, not GM soundfont acquisition.
Checked per the task's instruction to read it first; it doesn't bear on licensing, download UX, or the
format gate this item turns on, beyond confirming (consistent with everything above) that DAW Pro's
sampler already has a real keyzone model to receive whatever lands on disk.

**`docs/research/2026-07-16-free-instruments.md` (m17-e)** — also checked. Different content class
entirely (free *AU instrument plugins*: Vital, Surge XT, Splice INSTRUMENT, etc., not soundfonts). Its
one relevant, reusable fact: DAW Pro's sound-bank library already imports to
`~/Library/Application Support/DAWPro/SoundBanks/` (row 19, independently re-confirmed by me below
directly against current source).

**Curated-instrument-library question** (the task brief asks whether a smaller curated bank beats a
full GM set): **already surveyed separately and answered — `docs/research/soundfont-survey-instrument-libraries.md`
(2026-08-27)** recommends Salamander Grand Piano V3 (CC BY 3.0), VSCO 2 CE + VCSL (CC0), and jRhodes3d
(CC0) as a *complementary* track for "a handful of genuinely good instruments beats 128 mediocre GM
patches." That is a different shape of problem than m34-c: this item's stated pain is **breadth** — one
bank, one drum kit, a brushes brief that cannot be honoured *at all*. A single one-click GM download
fixes breadth across all 128 program slots and a dozen-plus drum kits in one action; matching that
coverage with curated individual libraries would take many separate per-instrument downloads, which
defeats "one-click." Recommend both tracks proceed as separate roadmap items, per that survey's own
actionable takeaways — not a substitute for each other.

---

## Format compatibility — verified against source, today

Confirmed by direct read of `Sources/DAWCore/SoundBanks.swift` (2026-08-30, current tree, not the
2026-08-27 survey's account of it — re-checked in case anything moved in three days; nothing has):

- `SoundBankLibrary.supportedExtensions: Set<String> = ["sf2", "dls"]` (`:369`).
- The import gate (`:274-316`, `importBank(from:)`): a `.sf3` is admitted **only** when a
  `VorbisDecoder` is wired, in which case it's converted to a real `.sf2` in the library directory
  before anything downstream sees it; every other extension throws `"sound bank must be a .sf2 or .dls
  file"`.
- `SoundBankSource` (`:13-43`) has exactly two cases: `.generalMIDI` (the system bank sentinel) and
  `.file(path: String)`. **No third case for a remote/downloadable source exists, and none is needed** —
  a completed download is just an ordinary `.file(path:)` once it's sitting in the library directory.
- Library directory (`:161-209`): `libraryDirectory` defaults to
  `AppDirectories.applicationSupport(.soundBanks)`, i.e. `~/Library/Application Support/DAWPro/SoundBanks/`,
  created lazily. `scanDirectories` additionally references (never copies) the two standard macOS bank
  folders (`/Library/Audio/Sounds/Banks`, `~/Library/Audio/Sounds/Banks`).
- `programs(for:)` (`:324-362`): parses real preset names from a `.sf2`'s `phdr` chunk when possible,
  returning `namesParsed: Bool` alongside the list; **falls back to a generic 0–127 list rather than
  throwing** when parsing fails ("an unparsable SF2 or any other `.dls`"). This is directly relevant to
  the download feature's completion check — see below.

**Conclusion**: every candidate in this doc is either already-native `.sf2` (the winner, and
GeneralUser GS) or resolvable to one via the existing, already-shipped conversion path (`.sf3`
variants). No new `SoundBankSource` case, no new model type, no wire-protocol change is implied by this
feature at the domain-model layer — it is a download-then-place-then-existing-import problem, not a new
kind of instrument.

---

## The download itself as a feature

The roadmap item is explicit that this is *"a network feature in an offline-capable app"* needing
progress, cancel, resume-or-restart, a checksum, a disk-space check, and an honest failure path — and
names the exact failure shape to avoid: *"a half-downloaded bank that reports success."*

**There is a real, in-tree precedent to build from: `Sources/AIServices/WhisperModelInstaller.swift`.**
It solves the adjacent problem (download a multi-hundred-MB-to-multi-GB model file, install it where a
catalog can see it) and gets several of these properties right already. What it covers, and what it
deliberately does *not* — read both, because the gap list is as important as the reuse list:

**Patterns worth reusing directly:**
- **Same-volume hidden staging.** Downloads land under `<libraryDirectory>/.staging-<uuid>/`, not
  `NSTemporaryDirectory()` — the installer's own comments spell out why: the final install step becomes
  a cheap rename instead of a second multi-hundred-MB copy, and it's guaranteed the same volume.
  `WhisperModelCatalog`'s directory scan explicitly passes `.skipsHiddenFiles` so a dot-prefixed,
  half-filled staging directory is invisible mid-download — **verify `SoundBankLibrary.scan()` does the
  same before assuming it; I read `SoundBankLibrary.swift:238-268` and did not confirm it skips hidden
  entries the way `WhisperModelCatalog` does. Check this explicitly rather than assuming the analogy
  holds for free.**
- **Phase-based progress, not one blended percentage.** `WhisperModelInstallProgress` reports a
  `Phase` enum (`.preparing`/`.downloadingModel`/`.downloadingTokenizer`/`.installing`/`.finished`) with
  a 0...1 fraction *within* that phase, deliberately not merged into a single overall number — the
  documented reasoning ("a guessed percentage that stalls at 3% is worse than an honest phase label")
  applies identically here.
- **The completeness-signal discipline.** The installer's own docs are explicit: *"`download()`
  returning without throwing is the completeness signal"* — a directory-existence check is explicitly
  called out as **not** sufficient proof, because an interrupted download can leave a passable skeleton.
  This is the exact shape of the failure this roadmap item warns against, already articulated once in
  this codebase.
- **Rollback, not deletion, on overwrite** — the previous install is displaced to a park location and
  restored on any failure, never destroyed until success is confirmed.
- **Teaching errors** — every `WhisperModelInstallError` case names the path it acted on and the next
  action in its `errorDescription`. Reuse this idiom rather than inventing a new error-message style.

**Gaps the precedent does NOT cover — genuinely new work for this feature, don't assume they're solved
by analogy:**
- **Checksum verification.** `WhisperModelInstaller` has none — its completeness story rests entirely
  on relocate-then-catalog-inspect, never a cryptographic hash. This item explicitly requires one; see
  "what 'done' must mean" below.
- **Disk-space pre-check.** Not present in the precedent. Needs fresh implementation — check available
  capacity against the expected size (plus margin) *before* starting the transfer, not after it fails
  partway through.
- **User-facing cancel.** Not evidenced in the precedent's code path. Needs a cancellable download task
  wired to a control-protocol command + MCP tool, per this project's standing rule that every
  user-facing capability ships both.
- **True resume vs. clean restart.** The roadmap item's own wording is "resume-or-restart" — an
  explicit *or*. The precedent gives clean-restart-on-failure (staging directory removed, no corrupt
  partial ever left where the scanner can see it) — that satisfies the item's letter. True HTTP
  byte-range resume (`URLSessionDownloadTask` + `resumeData`) is a nicer UX for a 206 MB file on a slow
  connection but is not required by the item's own phrasing.

**What "done" must mean — concrete and testable, not a vibe:**

1. All expected bytes on disk. Because no publisher-side checksum exists for the recommended file (and
   Debian's is confirmed above to be for a different version and possibly a different variant), the
   implementing team should mint its own pin: download once during implementation, record the exact
   byte count and SHA-256, hard-code both. This is standard practice for checksum-less static assets and
   converts today's "no checksum published" gap into "we verified it once and pin what we saw" — weaker
   than a publisher-signed hash, but load-bearing for exactly the failure mode this item warns about.
2. SHA-256 verified against that pinned hash **before** the file is treated as usable at all. A mismatch
   is a hard failure — delete the staged file, report it plainly, never a soft warning. (A corrupt bank
   silently accepted is the same defect this item is written to prevent, wearing a different hat.)
3. Atomic rename from the hidden staging path into `SoundBankLibrary.libraryDirectory` as a plain
   `.sf2` — same-volume rename, not a copy.
4. The bank appears in `SoundBankLibrary.scan()`.
5. **`SoundBankLibrary.programs(for:)` returns with `namesParsed == true`** — not merely "scan() lists
   it," and not merely "the call didn't throw." This is the sentinel most likely to catch a truncated
   download: an SF2's preset-header chunk (`phdr`) sits structurally *after* the sample-data chunk in
   the file (RIFF chunk order), so a transfer that died partway through the (much larger) sample data
   will very plausibly fail to parse valid preset names — and `programs(for:)`'s own documented
   fallback to a generic 0–127 list means a truncated file could otherwise present as a normal, if
   blandly-named, bank rather than erroring loudly. **The installer must assert `namesParsed == true`
   as an explicit post-install gate, and the test suite must feed a deliberately truncated copy of a
   real `.sf2` through the same path to prove the sentinel actually fires** (a positive control) —
   trusting this by inspection, without that test, is exactly the kind of unverified assumption this
   tree has been burned by before.

**Where it lands on disk**: `~/Library/Application Support/DAWPro/SoundBanks/` —
`AppDirectories.applicationSupport(.soundBanks)`, the existing "one home" for this path (m23-n1b),
same place manual imports already land. **Never in the app bundle or the repo** — consistent with the
task's instruction and with how this project already treats every other large downloadable asset
(Whisper speech models land under the sibling `.../DAWPro/Models`, via the identical
stage-then-atomic-install shape).

---

## What I could not verify (blockers, not gaps)

- **GeneralUser GS's own primary page never rendered** — `schristiancollins.com/generaluser.php`
  returned only headers across two independent WebFetch attempts by me, plus one by the prior survey
  (three failures total, different sessions, different days). The Wayback Machine is entirely blocked
  for my tooling. Every claim about GeneralUser GS's licence/version/checksum in this doc is
  reconstructed from secondary sources (ScanCode LicenseDB, a Haiku OS package recipe, a GitHub mirror,
  WebSearch snippets) — never a single verbatim capture of the author's own statement. Per the task's
  own instruction, this is a blocker on that candidate, not a footnote — it is the main reason
  GeneralUser GS is not the pick even before weighing the provenance-disclaimer question.
- **The `linux.debian.legal` thread on GeneralUser GS's Debian suitability** — HTTP 429 on two fetch
  attempts. The "would not pass ftp-master review" claim rests on a WebSearch summary of that thread,
  not a primary read. Flagged as corroboration-only throughout this doc, never load-bearing on its own
  (the author's own words are the primary basis for ranking GeneralUser GS down; this would only add
  weight, not create it).
- **Exact byte size and any checksum for `MuseScore_General.sf2` (the recommended file) itself** — the
  osuosl directory listing rounds to "206M" and hosts no checksum file. Not resolvable without
  downloading, which this pass was instructed not to do.
- **`MuseScore_General.sf2`'s actual channel structure (mono/stereo)** — the bundled README states
  unattributed presets use FluidR3Mono (mono) samples but doesn't state the file's overall channel
  layout; would need direct inspection (e.g. Polyphone), out of scope here.
- **Whether Debian's checksummed 0.2.1 tarball unpacks to the same file as the recommended URL, or to
  the separate "HQ" variant** — the Debian search surfaced a distinct `musescore-general-soundfont-lossless`
  package description implying an HQ/standard split; I did not open the tarball (or find a file listing
  of it) to confirm which variant it contains. Treat the Debian hash as evidence the lineage is
  legitimate, never as a way to verify the mirror download.
- **FluidR3 GM's exact program/drum-kit enumeration** — unlike MuseScore_General's 186-row CSV or
  GeneralUser GS's mirror-stated "261 presets, 13 kits," I found no equivalently authoritative
  per-preset breakdown for FluidR3 GM in this pass.
- **Whether `SoundBankLibrary.scan()` skips hidden/dot-prefixed directories** the way
  `WhisperModelCatalog` does — read the relevant code and could not confirm either way; flagged above
  as something the implementer must check, not assume.
- **Byte-identical confirmation that MuseScore's current "MS Basic" default equals the osuosl mirror's
  "MuseScore_General.sf2"** — the version-number trail is consistent (both point at "0.2.x") but this is
  inference across separately-fetched documents, not a hash comparison. I checked MuseScore's current
  handbook page directly (`handbook.musescore.org/sound-and-playback/soundfonts`, fetched 2026-08-30)
  and it names "MS Basic" without linking the osuosl mirror at all — so this inference has no official
  confirmation to lean on, only the converging version numbers.

---

## Actionable takeaways

1. **Ship `MuseScore_General.sf2` from `https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2`
   as the one-click download target.** Licence and provenance are the cleanest verified combination of
   the three named candidates; native format avoids the measured `.sf3`-decoder risk entirely; the host
   has been stable for six years. Attribute per the MIT notice (Michael Cowgill 2014–16, Frank Wen
   2000–2002/2008) in the app's acknowledgements/credits surface — a one-time, one-line obligation.

2. **First implementation step: mint a real checksum.** No publisher-side SHA-256 exists for this exact
   file, and Debian's checksum is confirmed to be for a different version and possibly a different (HQ)
   variant — do not substitute it. Download the mirror file once by hand during implementation, record
   the exact byte count and SHA-256, and hard-code both as the app's own integrity pin. Treat this as a
   required step, not a nice-to-have.

3. **Build the download feature on the `WhisperModelInstaller` shape** (same-volume hidden staging,
   phase-based progress, "downloaded-without-throwing is the only completeness signal," rollback not
   deletion) **but do not assume it's a complete template** — checksum verification, disk-space
   pre-check, and user-facing cancel are all absent from that precedent and need fresh implementation
   here. Wire a control-protocol command + MCP tool for start/progress/cancel, per this project's
   standing rule that every user-facing capability ships both plus a test.

4. **The post-install completion gate must assert `SoundBankLibrary.programs(for:).namesParsed == true`**,
   not merely that `scan()` lists the file — and ship a test that runs a deliberately truncated copy of
   a real `.sf2` through the exact same path to prove that sentinel fires. This is the concrete,
   testable answer to the item's own warning about a half-downloaded bank reporting success.

5. **No domain-model or wire-protocol change is implied.** `SoundBankSource` needs no new case; a
   completed download becomes an ordinary `.file(path:)` inside the existing
   `AppDirectories.applicationSupport(.soundBanks)` directory, going through the same
   `SoundBankLibrary`/`ProjectStore.validateSoundBank`/wire-`parseSoundBankSource` gates every other
   import already passes. Confirm `SoundBankLibrary.scan()`'s hidden-file handling before relying on the
   staging directory being invisible mid-download (flagged above as unverified, not assumed safe).

6. **Keep FluidR3 GM on file as the documented runner-up**, not discarded: if the missing checksum on
   the recommended file turns out to be a harder blocker than expected (e.g. a security reviewer wants
   a publisher-signed hash, not a self-minted one), FluidR3 GM's licence story is at least as strong and
   the path forward is known — either vendor a verified copy ourselves, or build one-time `.tar.gz`
   extraction against Debian's already-checksummed source package (confirming, first, exactly which
   variant that tarball unpacks to — the same "don't assume the hash matches a specific extracted file"
   caution that applies to MuseScore_General's Debian package applies here too).

7. **Do not add GeneralUser GS to the download picker without either (a) a successful direct fetch of
   the author's own primary page confirming current licence/redistribution terms, or (b) an explicit
   legal/user sign-off that 25 years without an incident is sufficient comfort despite the author's own
   provenance disclaimer and the Debian-packaging asymmetry.** It remains the best content-per-MB
   option and may be worth revisiting under those conditions — just not a default.

8. **File a follow-up, separate from this item**: the curated-instrument-library recommendations in
   `docs/research/soundfont-survey-instrument-libraries.md` (Salamander piano, VSCO2 CE, VCSL,
   jRhodes3d — all CC0/CC-BY, all already surveyed) address a *different* gap (depth/quality of a few
   instruments) than this item's breadth problem, and should proceed on their own roadmap item rather
   than being folded into or blocked by m34-c.
