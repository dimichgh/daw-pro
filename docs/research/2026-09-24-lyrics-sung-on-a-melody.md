# Singing typed lyrics on the exact notes of a MIDI lead melody

Date: 2026-09-24
Author: research-analyst (agent)
Scope: **only** the second half of the standing question — given a MIDI lead-melody track that already
exists in a DAW Pro project, and a line of typed lyrics, can something make a vocal that sings those
words on those exact notes, either as a new track directly, or as a "placeholder" performance to be
re-skinned into the user's own voice afterward. Tuning a *real recorded* vocal onto a lead track is a
separate problem (pitch correction / auto-align) and is being designed elsewhere — see
`docs/research/m23-q-pitch-correction-survey.md` / `m23-q-pitch-correction-design.md`. This doc does not
repeat that work.

**Method note on citation tags.** VERIFIED = I fetched the primary source directly (an official repo
README/LICENSE/docs page, a vendor's own pricing/product page) and the quotes below are drawn from that
fetch. REPORTED = a secondary source (a review site, a search-engine synthesis of several pages, a forum
post) that I did not cross-check against the primary document. Every version-, price-, or license-
dependent claim is dated 2026-09-24 unless stated otherwise, because all three rot.

---

## 0. The plain-language answer, up front

The intuition in the question is correct on both counts, and it's worth saying plainly before the survey,
because the underlying technology is easy to make sound more exotic than it is:

1. **"A sample library of vocal notes that's already split up" is real, and it's not new.** It's called a
   **voicebank**: someone records a singer saying short syllables one at a time, chops the recording into
   pieces, and an editor plays back the right piece for each note you type. UTAU (2008, still free and
   widely used) and EastWest's "WordBuilder" choir libraries (2005, still sold today) are exactly this —
   literally "type words, the sample library sings them." See §1.
2. **Splicing pre-recorded syllables together is also *why this genre of software was largely replaced.***
   Stitched syllables have audible seams — the same problem as an old ransom-note voice, just for singing
   instead of speech. Since roughly 2020 the whole field has moved to **neural singing synthesis**: a model
   *trained on* recordings like these, rather than one that plays the recordings back and splices them.
   The neural model still needs the same two ingredients — a melody (specific notes) and lyrics (specific
   words) — and still produces one syllable per note (or a syllable held across several notes), which is
   the exact behavior the question describes. It just doesn't sound stitched together. See §2.
3. **DAW Pro's own local singing engine, ACE-Step 1.5, is not one of these tools and cannot be made into
   one.** It sings very well when it is also *inventing* the melody. It has no mechanism anywhere in its
   API to be handed a fixed set of notes and lyrics and forced to hit them. See §3.
4. **A real, Apache-2.0-licensed, English-capable engine that does exactly what's being asked (score +
   lyrics → note-accurate singing, run locally) exists and is only a few months old as of this report** —
   see §2.3 and §5. It has not been hands-on tested by anyone at DAW Pro yet; nothing below should be read
   as a promise about its quality until that happens.

---

## 1. Is "a sample library of split vocal notes" real?

Yes, in three distinct product categories, all real and currently available. None of the three is what
DAW Pro should ship as the primary path (see §5), but each is a genuine, checkable thing, and the third
(choir word-builders) is arguably the most literal match to the question's wording.

### 1a. UTAU / OpenUtau voicebanks — the free, community, "raw" version of the idea

**UTAU** is a free Japanese-origin singing-synthesis application (the format dates to the late 2000s).
A **voicebank** is a folder of short recordings of one singer, plus a text file (`oto.ini`) that maps each
audio snippet to the syllable it represents and the exact millisecond offsets to splice at
(REPORTED — general, well-established description, cross-checked across multiple UTAU wiki/community
pages fetched 2026-09-24). Three organizing schemes exist, each a different trade-off of recording effort
vs. how natural the joins sound:

- **CV** (consonant-vowel) — one recording per syllable, e.g. "ka", "shi". Cheapest to record, choppiest
  joins.
- **VCV** (vowel-consonant-vowel) — records the transition *into* each syllable from the previous vowel,
  roughly 7x more recordings than CV, smoother.
- **CVVC** (consonant-vowel + vowel-consonant) — the scheme most commonly used for **English** and other
  non-Japanese voicebanks specifically because it handles consonant clusters English needs and Japanese
  doesn't.
(REPORTED, cross-checked across vocadb.net/T/3127, utau.info/start/vbtypes, and the UTAU Wikipedia page,
fetched 2026-09-24.)

**OpenUtau** (`github.com/stakira/OpenUtau`) is the actively-maintained, cross-platform, **MIT-licensed**
successor editor/engine (VERIFIED — direct repo fetch, 2026-09-24: "MIT license"; 4,558+ commits on the
default branch, active CI badge). It runs classic UTAU voicebanks **and** — via a plugin renderer — modern
neural DiffSinger voicebanks (see §2.1), which is why it is the natural host for either technology.
It ships macOS builds including what the project's own install-wiki naming convention calls an
Apple-Silicon-native artifact (`OpenUtau-osx-arm64.dmg` — REPORTED, search-derived, not independently
opened in this pass).

**Licensing is the load-bearing catch, and it does not have one blanket answer.** The *editor* (OpenUtau)
is MIT. Each **individual voicebank** is a separate, separately-licensed artifact made by whoever recorded
it — ranging from fully free-for-commercial-use, to non-commercial-only, to "email us for a commercial
license." The DiffSinger wiki's own voicebank index lists a "Voicebanks supporting English" category with
8 sub-categories / 6 pages (VERIFIED — direct fetch of `diffsinger.miraheze.org/wiki/Category:DiffSinger_voicebanks`,
2026-09-24) confirming English voicebanks genuinely exist in this ecosystem, but the page states no
blanket license and each entry must be checked individually. The most-used flagship voicebank in the whole
DiffSinger ecosystem, **Opencpop**, is explicitly restricted to non-commercial use — but precisely, not
loosely: its own license page states the download itself is offered under a plain **Creative Commons
Attribution 4.0 (CC-BY 4.0)** license (which, on its own, *would* permit commercial use), with a
**separate, additional prose condition restricting that download to non-commercial purposes** and
requiring direct contact with the rights-holder for commercial use (VERIFIED — direct fetch of
`xinshengwang.github.io/opencpop/liscense/`, 2026-09-24, quoted verbatim: *"available to download for
non-commercial purposes under a Creative Commons Attribution 4.0 International License... If want to use
it commercially, you are welcome to contact us by email"*). Worth stating precisely because it's a
different thing from the standard "CC BY-NC" license family: this is CC-BY 4.0 plus a bespoke
non-commercial condition layered on top by the rights-holder, not the standard CC BY-NC license variant.
Net effect is the same either way — **not commercially usable as downloaded, without contacting the
rights-holder** — but the mechanism is worth getting right before anyone builds policy logic around it.
Some individual community voicebank creators sell an optional commercial license add-on separately
(REPORTED, one named example found: "Lain Noumen"). **There is no single "the DiffSinger English voice is
commercial-clean" answer — it must be resolved per voicebank, every time**, which is exactly the risk the
task brief anticipated.

**Quality**: classic (non-neural) UTAU concatenative synthesis has a long-standing community reputation
for audible splice artifacts, robotic/warbly tone especially on fast passages or large pitch jumps
(REPORTED, general community consensus, not a specific citation) — this is precisely the "stitched
syllables" problem described in §0 and is the reason the neural engines in §2 now dominate serious use.

### 1b. Commercial neural voice databases — the polished, paid version

These take the same underlying idea (a library of a specific singer's voice) but a trained *model* stands
between the library and the output, so nothing is spliced — see §2 for the technical detail on each; this
section is the product/pricing/licensing summary.

| Product | Vendor | Price (2026-09-24) | Runs offline on Apple Silicon? | English voices | Commercial-use terms |
|---|---|---|---|---|---|
| **Synthesizer V Studio 2 Pro** | Dreamtonics | App **$99** one-time + **$79**/voice one-time (REPORTED, Plugin Boutique bundle listings) | **Yes** — VERIFIED, vendor page states native "Apple Silicon (M1 or later)" support and "all vocal processing is done locally" once a voice is activated | Multiple (Felicia, Hayden, Natalie, others — VERIFIED, vendor page) | **Included** — VERIFIED, vendor quote: *"Synthesizer V Studio 2 Pro and all official Dreamtonics voices include commercial use licenses"* |
| **ACE Studio** | ACE Studio Inc. | **~$149/yr**, or ~$16.58/mo Artist tier; free tier exists (REPORTED, saasworthy.com/acestudio.ai aggregator, 2026-09-24) | **Ambiguous / mostly no** — REPORTED: cloud rendering is the default and needs a live connection; a perpetual-license path (2-yr subscribe, or buyout) lets the *app* keep running after cancelling, but generation itself is described as server-side even then | 100+ voices, 8 languages (REPORTED, vendor marketing) | "Free for commercial use," vendor claim (REPORTED) |
| **Vocaloid 6** | Yamaha / Vocaloid | **$225** (REPORTED, softwarefinder.com) | Windows + macOS confirmed; **Apple-Silicon-native status not confirmed in this pass** | Multiple, proprietary | Proprietary, not independently checked |

**Important disambiguation, because the names collide badly and it matters for this exact report: "ACE
Studio" (the company/product above) is one of the two co-developers of **ACE-Step**, the open model DAW
Pro already runs locally (`docs/research/2026-07-05-ace-step-local-song-generation.md` — "co-led by ACE
Studio and StepFun"). But "ACE Studio" the *company's own commercial app* (table above) is a completely
different, closed-source, subscription, cloud-first product — it is not more accessible to DAW Pro just
because the two share a name and a corporate parent (VERIFIED relationship via ACE-Step's own README
framing; ACE Studio app details REPORTED per its own marketing pages — direct fetches of `acestudio.ai`,
`acestudio.ai/pricing`, and `www.acestudio.ai/pricing` all returned HTTP 404 in this pass; the figures
above come from third-party aggregators only, not the vendor directly).**

Synthesizer V ships a scripting API (Lua or JavaScript, both hitting the same `SV` object model) for
automating tasks **inside an already-open project in the app** (VERIFIED — `resource.dreamtonics.com`
scripting manual exists, `github.com/Dreamtonics/svstudio-scripts` is the vendor's own official scripts
repo) — this is real automation, but it is **not an external API**: nothing found in this pass indicates a
documented headless/CLI/batch rendering mode callable from outside the running app. This matters directly
for §4/§5.

### 1c. Sample-based choir / "word builder" libraries — the most literal match to the question's wording

These exist, are decades-old, and are exactly "type text, the samples sing it": **EastWest's WordBuilder**
engine (currently "WordBuilder 2," bundled with **Hollywood Choirs**, successor to 2005's **Symphonic
Choirs**) lets a user "type in any words — in any language — and have them sung back... by the full choir
or individual male and female sections" (REPORTED, cross-checked across EastWest's own soundsonline.com
product pages via search, 2026-09-24). Price: Hollywood Choirs **Diamond $599 / Gold $499** one-time, or
EastWest's ComposerCloud rental subscription from **$24.99/mo** (REPORTED, multiple retailer listings).

**The shape mismatch that matters for DAW Pro:** these are **choir/ensemble pad instruments**, built and
marketed for cinematic backing vocal texture, not a solo lead vocalist. Nothing found in this pass
describes expressive solo-vocal phrasing control, vibrato matching, or the kind of fine pitch-bend nuance
a lead vocal needs — that's not a criticism of the product, it's simply not what it was built for. It is
the right tool for "I want a wordless or word-based choir pad behind my lead vocal," and the wrong tool for
"I want a lead vocal."

---

## 2. Singing voice synthesis (SVS): current options, 2026

The technical shape every option in this section shares, because it's what makes any of them usable for
"sing this on that note": **the model (or the splicer, in §1a) is handed an explicit sequence of
(phoneme, note pitch, note duration) triples and is not free to deviate from the notes.** This is the
opposite conditioning shape from ACE-Step (§3), which is handed a text prompt/caption and free-composes
melody, pitch and rhythm together.

### 2.1 DiffSinger (`openvpi/DiffSinger`) + OpenUtau

- **License**: code Apache-2.0 (VERIFIED — direct repo fetch, 2026-09-24).
- **Input**: a `.ds` project — JSON containing (per the format's own field names, REPORTED via
  cross-checked mirrors of `docs/README-SVS-opencpop-e2e.md`): `ph_seq` (phoneme sequence), `ph_dur`
  (phoneme durations), `note_seq` (note pitches), `note_dur` (note durations), and `is_slur` (whether a
  note continues the previous syllable rather than starting a new one — i.e. exactly the melisma flag
  needed for §4). This is unambiguously a "score + lyrics → audio" format, not a free-composition one.
- **Runs on**: ONNX models (acoustic/variance model + an **NSF-HiFiGAN vocoder**, trained on ~93 hours of
  singing data at 44.1 kHz per the vocoder project's own release notes — REPORTED, `openvpi/vocoders`
  release page) — deployed today mainly through **OpenUtau**, which embeds ONNX Runtime and exposes
  DiffSinger as a renderer option (VERIFIED — direct fetch of the OpenUtau wiki's "DiffSinger support"
  page, which confirms macOS 11 (Big Sur)+ support and a documented "50x realtime" default rendering
  speedup setting; that same fetch found Apple-Silicon-specific acceleration "not explicitly mentioned,"
  only that "a CoreML GPU option is available for macOS" generically).
- **Voices**: per §1a — fragmented licensing, no blanket-safe English commercial voice found in this pass;
  the flagship Opencpop voice is restricted to non-commercial use.
- **A headless, non-GUI path exists but is a dead end**: `openvpi/DiffSingerMiniEngine`, a minimal
  ONNX-only inference server explicitly built to skip the OpenUtau GUI, is **AGPL-3.0** and was
  **archived (made read-only) 2024-02-06** (VERIFIED — direct repo fetch, 2026-09-24) — the same
  "copyleft + unmaintained" risk pattern this repo's own 2026-07-11 voice-conversion report already flagged
  for `seed-vc`. Not recommended as an integration point. (It is also explicitly "MIDI-less mode," i.e.
  built for the *opposite* of what's wanted here — inventing its own melody rather than taking one in.)
- **Quality**: neural synthesis is broadly considered a large step up from classic UTAU splicing
  (general community consensus, REPORTED, not independently listening-tested here). The ecosystem is
  historically Chinese/Japanese-first; English voicebank count and maturity lag behind those languages
  (inference from the search results in this pass, not a specific citation — flagged as inference).

### 2.2 NNSVS / ENUNU

- **License**: MIT (VERIFIED — direct repo fetch of `github.com/nnsvs/nnsvs`, 2026-09-24).
- **Ships no pretrained voices** — it is a research toolkit; the user (or a community contributor) must
  record and train their own voicebank (VERIFIED, same fetch — no bundled model found). **ENUNU** is the
  commonly-used wrapper that makes NNSVS models load as OpenUtau/UTAU-compatible singers (REPORTED).
  Actively maintained as of 2026 (REPORTED — a companion standalone editor project shows commit activity
  dated July 2026).
- **Practical read**: architecturally credible (MIT is the cleanest license tier in this whole survey) but
  **"train your own voice" here is a materially bigger lift than DAW Pro's existing RVC training flow.**
  RVC needs ~10-30 minutes of ordinary clean singing (per `docs/research/2026-07-11-vocals-voice-conversion.md`
  §2a/§3a, already VERIFIED in that doc). A phoneme-labeled, note-aligned NNSVS/UTAU-style voicebank
  historically needs much more: a full phonetic-coverage recording session plus manual `oto.ini`-style
  timing alignment (§1a) — not a quick win for a non-musician user, and not independently timed on this
  Mac in this pass.

### 2.3 SoulX-Singer (Soul AI Lab, 2026) — the newest and best-fitting option found

This is the single most load-bearing new fact in this report, because it did not exist when the README's
"superseded" verdict was written and directly answers the question being asked here.

- **What it is**: an open singing-voice-synthesis + singing-voice-conversion system,
  `github.com/Soul-AILab/SoulX-Singer`, paper "SoulX-Singer: Towards High-Quality Zero-Shot Singing Voice
  Synthesis" (arXiv:2602.07803 — the ID format places this early-2026, contemporaneous with ACE-Step 1.5's
  own paper; exact submission date not independently confirmed in this pass, flagged as inference).
- **License: Apache-2.0, for BOTH code and model weights** (VERIFIED — direct repo README fetch,
  2026-09-24, quoting: *"We use the Apache 2.0 license. Researchers and developers are free to use the
  codes and model weights of our SoulX-Singer."*) — the **same permissive license family DAW Pro already
  depends on for ACE-Step and RVC**, i.e. no new legal-review class of risk to simply run this engine.
- **Input, confirmed to match this exact requirement**: it explicitly supports **"score-conditioned
  (MIDI notes)"** generation as well as a separate **"melody-conditioned (F0 contour)"** mode, plus lyrics
  (VERIFIED, direct README fetch). Score mode is precisely "give it discrete notes, get audio that follows
  them" — the F0-contour mode would be the one to use instead if driving from a hummed/recorded reference
  rather than DAW Pro's own `MIDINote` data.
- **Voice identity is zero-shot**: a short reference audio clip of a target voice, **no per-voice
  training** (VERIFIED, direct fetch) — architecturally the same idea as `seed-vc` (§2b of the 2026-07-11
  doc) rather than RVC's train-a-decoder approach.
- **Language**: trained on **"42,000+ hours of aligned vocals, lyrics, notes across Mandarin, English,
  Cantonese"** (VERIFIED, direct quote) — English is a first-class trained language, not a community
  afterthought grafted onto a Chinese-first tool.
- **Also ships its own singing-voice-*conversion*** (SVC) mode — redundant with DAW Pro's already-shipped
  RVC path; no reason to adopt it for that role.
- **Running it**: a CLI (`bash example/infer.sh` for SVS, `infer_svc.sh` for SVC) and a Gradio WebUI
  (`python webui.py`) exist (VERIFIED, direct fetch) — a genuine external automation entry point, the same
  shape class as ACE-Step's own CLI/API before DAW Pro wrapped it in a sidecar.
- **Apple Silicon: unofficial, community-converted MLX weights exist, but inference still runs through the
  official PyTorch model structure — this is a bridge, not a working native MLX pipeline, and that
  distinction is the load-bearing fact, not a footnote.** The repo is `ailuntx/SoulX-Singer-MLX`
  (community, third-party — not the official Soul AI Lab repo), mirrored on Hugging Face at
  `huggingface.co/mlx-community/SoulX-Singer` (Apache-2.0 inherited — VERIFIED via direct fetch of the HF
  card). The card's own wording: weights are converted to an "MLX-friendly format," but "full audio
  generation currently uses the official PyTorch model structure" through a bridge implementation (VERIFIED,
  direct quote) — the same "hybrid, not pure MLX" shape ACE-Step itself has on Apple Silicon (per
  `docs/research/2026-07-16-ace-mlx-native.md`), not disqualifying on its own, just not a finished native
  port, and practically meaning PyTorch/MPS still does the real work today. Weight sizes on that **MLX
  conversion's** card range from **774 MB (4-bit) to 2.6 GB (bf16, default) to 5.6 GB (fp32)** (VERIFIED) —
  the **official, upstream PyTorch checkpoint's own size was not fetched in this pass** and should not be
  assumed identical.
- **What is explicitly NOT known, stated plainly rather than assumed**: the exact score-input JSON schema
  (whether it mirrors DiffSinger's `.ds` shape or is bespoke), inference speed and peak memory on Apple
  Silicon (**unmeasured — no benchmark of any kind found for this model on any Apple Silicon hardware**),
  and — most importantly — **real-world output quality**. It is months old as of this report, has no
  independent listening-test track record, and its headline claim ("zero-shot" from a short reference clip)
  is architecturally the same category of claim that produced a documented, verified real-world complaint
  elsewhere in this codebase's own research: VocalNet's flagship 5-10-second voice-clone mode was reported
  by one hands-on user as *"quite terrible, full of artifacts... the target voices impart almost no
  character at all"* (VERIFIED in `docs/research/2026-08-09-vocalnet-comparison.md`, re-cited here by
  analogy, not as a claim about SoulX-Singer specifically — flagged explicitly as an inference, not a
  measurement). **None of this should be promised to a user before a hands-on spike measures it on this
  Mac** — see §5.

### 2.4 Watch-list only — not actionable today

- **VocalRender** (arXiv:2607.27768, "Score-Native Singing Voice Synthesis for Real-World Composition") —
  its own abstract claims exactly the right shape ("directly synthesizes singing from lyrics, pitches,
  symbolic note values, and tempo," "strong melody control" — VERIFIED, direct abstract-page fetch), but
  **no code, weights, or license were found in this pass**. Not actionable; re-check in a few months.
- **YingMusic-Singer** — already flagged as a name-collision risk in `docs/research/2026-07-11-vocals-voice-conversion.md`
  §2e ("not to be confused" with the sibling `YingMusic-SVC`). Described in this pass's search results as
  "zero-shot singing voice synthesis and editing with **annotation-free** melody guidance" (REPORTED) —
  "annotation-free" suggests it may infer its own melody rather than accept an explicit note sequence,
  which would make it the wrong shape for this task; **not independently confirmed either way in this
  pass** — do not size work against it without a dedicated read of its own repo/paper.

### Summary table

| Engine | License (code / weights or voices) | MIDI/score input? | English | Local on Apple Silicon | Automatable from outside the app |
|---|---|---|---|---|---|
| UTAU classic (via OpenUtau) | MIT (editor) / **varies per voicebank** | Yes (splice-based) | Yes, fragmented | Yes (REPORTED — arm64 build named, not independently opened) | Not designed for it |
| DiffSinger (via OpenUtau) | Apache-2.0 (engine) / **varies per voicebank, flagship = non-commercial download condition** | Yes (`.ds`: note_seq/ph_seq/is_slur) | Yes, thinner than CN/JP | macOS 11+ (VERIFIED via OpenUtau); Apple-Silicon-specific acceleration unconfirmed | No clean headless path found (MiniEngine = AGPL + archived) |
| NNSVS / ENUNU | MIT / **user must train, no bundled voice** | Yes | Train-your-own | Yes (research toolkit; not independently timed) | Toolkit-level, not a service |
| **SoulX-Singer** | **Apache-2.0 / Apache-2.0** | **Yes, explicit "score-conditioned (MIDI notes)"** | **Yes, trained-in, 42k+ hrs** | **Unmeasured — unofficial MLX weights exist (774 MB–5.6 GB); inference still runs via PyTorch/MPS, not pure MLX** | **Yes — CLI + WebUI** |
| Synthesizer V Studio 2 Pro | Proprietary, $99+$79/voice | Yes (native workflow) | Yes, strong reputation | **Yes, native, offline** (VERIFIED, vendor) | In-app scripting only, no external API found |
| ACE Studio (the app) | Proprietary, ~$149/yr | Yes (native workflow) | Yes | Mostly cloud, ambiguous offline (REPORTED only — vendor pages 404'd) | No API found |
| Vocaloid 6 | Proprietary, $225 | Yes (native workflow, the original) | Yes | macOS yes, Apple-Silicon-native unconfirmed | Not found |

---

## 3. Can ACE-Step 1.5 be conditioned on a melody + lyrics to sing specific notes? No — and this is the correction to the README's "superseded" verdict.

Checked directly against the upstream project's own tutorial and musician's guide (both fetched
2026-09-24), plus the source-level task-type inventory this repo's own 2026-07-11 report already verified
(`constants.py` `TASK_TYPES`).

- **No task type anywhere in ACE-Step accepts a MIDI file or an explicit note sequence.** Confirmed absent
  from `Tutorial.md` and `ace_step_musicians_guide.md` (VERIFIED, direct fetch, 2026-09-24: *"No mention of
  MIDI support exists in this guide... no documented way to feed ACE-Step an external MIDI file or exact
  note sequence"*).
- **"Cover" (UI label "Remix") is the closest feature, and it is a real, usable, zero-new-weights
  experiment — but it is not note-accurate by design, not by omission.** It takes an existing **audio**
  file (not MIDI) as a structural reference, and — genuinely useful — it **does** let the user supply new,
  different lyrics to be sung over that structure: the tutorial's own text is *"Change lyrics: Rewrite
  lyrics with new Lyrics, maintaining original melody structure"* (VERIFIED, direct fetch). So: render the
  DAW's lead MIDI clip to a plain guide-tone audio file (any simple patch), feed it into Cover with the
  user's typed lyrics, and ACE-Step will try to sing those words while loosely tracking that guide's shape.
  But the vendor's own documentation is explicit that this tracking is **contour-level, not note-exact**:
  *"keeps the structure (melody shape, rhythm, song form) but changes everything else... does NOT preserve
  exact pitch"* (VERIFIED, direct fetch), and real usage on the project's own GitHub discussions confirms
  this in practice: *"in most cases it generates melodic variations rather than simply copying the original
  melody exactly"* (VERIFIED, direct fetch of discussion #398), except on the simplest, sparsest material.
  This is architecturally a diffusion resynthesis conditioned on a compressed structural code, not a
  score-locked synthesizer — it cannot be tuned into exact-note behavior; that is not what the mechanism
  does.
- **"Lego" adds new layers onto an existing track** and its track-name vocabulary does include
  `"vocals"`/`"backing_vocals"` (already VERIFIED at the source level in
  `docs/research/2026-07-11-vocals-voice-conversion.md` §1a), but every documented example and description
  found in this pass is instrumental-layering only (*"adds new tracks (e.g., drums, guitar, bass, etc.)"*
  — VERIFIED, direct fetch) — using it to add a lyrics-driven vocal layer onto an instrumental guide is
  theoretically reachable but **not demonstrated anywhere**; treat as an unverified second cheap experiment,
  not a working feature.
- **"Complete" runs the opposite direction** (vocals in → instrumental backing out) and is not useful here.

**Verdict, stated precisely so it can correct the README line accurately:** ACE-Step 1.5, exactly as
shipped, has no mechanism to guarantee specific words land on specific notes. The README's "superseded"
verdict was answering a real, different, already-settled question — *"do we need a dedicated singing model
at all, given ACE-Step already sings convincingly when composing its own melody?"* — and that answer stands
unchanged for whole-song generation. It was never a claim about *this* capability (a fixed, pre-composed
melody plus specific lyrics), because that capability didn't exist as a stated goal at the time and
ACE-Step has no path to it regardless. See §6 (Actionable takeaways) for the proposed wording fix.

---

## 4. Pipelines for DAW Pro

### (a) A synthesis engine sings the lead track's notes into a new audio track

**The note data already exists in exactly the shape this needs.** DAW Pro's `MIDINote`
(`Sources/DAWCore/Model.swift:137-169`, read directly for this report) carries `pitch: Int` (0-127 MIDI
number), `startBeat: Double`, `lengthBeats: Double`, and `velocity: Int` per note — onset, duration and
pitch are already first-class fields; only a beats-to-seconds conversion (via the project's existing tempo
map) stands between this and the "note_seq / note_dur" shape every engine in §2 wants.

**Steps, in order:**

1. **Read the lead clip's notes**, canonically ordered (the type already provides
   `MIDINote.canonicallyOrdered`), convert beat positions to seconds via the tempo map.
2. **Phonemize the typed lyric line.** If driving OpenUtau/DiffSinger, its own bundled English phonemizer
   can be used directly (VERIFIED as present in the DiffSinger-support wiki fetch). If driving a raw
   `.ds`-shaped or SoulX-Singer request directly, a standalone grapheme-to-phoneme step is needed:
   **`g2p_en`** (`github.com/Kyubyong/g2p`), **Apache-2.0** (VERIFIED, direct fetch, 2026-09-24), built on
   the public-domain CMU Pronouncing Dictionary — a small, permissively-licensed, well-understood choice
   consistent with the rest of this codebase's dependency posture. (SoulX-Singer's own exact expected input
   format — raw text vs. pre-phonemized — is one of the explicitly-unknown items in §2.3 and belongs in the
   spike, not asserted here.)
3. **Split syllables across notes (melisma).** Don't invent a new convention — both real ecosystems
   surveyed already encode the same idea and can be copied directly:
   - OpenUtau's own convention (VERIFIED, direct fetch of the "Getting Started" wiki): type the syllable on
     the first note, then `+` on a following note to start a *new* syllable there, or `+~` to *extend/tie*
     the current syllable across that note instead.
   - DiffSinger's `.ds` format encodes the identical decision as a per-note `is_slur` boolean (REPORTED,
     §2.1).
   - **Default rule for DAW Pro's own assignment logic**, matching both conventions: syllable count equal
     to note count → one syllable per note; fewer syllables than notes → tie (`is_slur`/`+~`) the last
     syllable of the relevant word across the extra notes; more syllables than notes (unusual, since the
     user is typing prose, not pre-scanned verse) → **do not guess** — surface a warning and ask the user to
     shorten the line or add notes, the same "flag, don't silently resolve" posture this codebase already
     applies to ambiguous cases elsewhere (e.g. the pitch-correction survey's own treatment of segmentation
     ambiguity, `m23-q-pitch-correction-survey.md` §B).
4. **Run the engine, offline, as a local sidecar** — the same architectural shape already proven twice in
   this codebase (ACE-Step on `127.0.0.1:8001`, RVC on `127.0.0.1:8002`): lazy-spawn on first use,
   health-check, idle-teardown, a narrow facade HTTP contract rather than exposing the vendored tool's own
   wire format directly (mirroring both prior reports' explicit recommendation to do this). Pick the next
   free loopback port at implementation time — **not asserted here**: `8003` is *tentatively* named in the
   still-unshipped `m23-fc` real-time-VC-streaming spike proposal (`docs/research/2026-08-10-realtime-vc-spike.md`
   §9), so confirm against the current `docs/AI-INTEGRATIONS.md` port table before picking a number, rather
   than colliding with it.
5. **Import the result** using the **existing** take/track import machinery already built for ACE-Step and
   RVC results — both prior reports independently confirm this exists and is reusable (2026-07-11 doc §4a;
   the vocalnet-comparison doc's confirmation that "Convert to Voice" already "lands at the clip's own
   beat, one undo removes it"). No new import mechanism is needed.

### (b) Convert into the user's own voice with the RVC path DAW Pro already has

This is **already shipped** — nothing new to design. `vc.convertVocals` (`Sources/DAWControl/Commands.swift:337`,
confirmed live in both `docs/research/2026-07-11-vocals-voice-conversion.md` and
`docs/research/2026-08-09-vocalnet-comparison.md`) runs the RVC/Applio-derived MLX pipeline, **MIT-licensed**,
fully offline, on `127.0.0.1:8002`. Feed the new synthesized-vocal audio stem from (a) into it exactly like
any other vocal stem — RVC's whole design point is preserving the *performance* (pitch, vibrato, sustained
notes) of its input while changing timbre (VERIFIED claim already on record in the 2026-07-11 doc), which
is precisely what's wanted: keep the note-accurate performance from (a), change only whose voice it sounds
like.

**A genuine simplification worth naming explicitly**: if the synthesis engine in (a) is a zero-shot,
reference-clip model (SoulX-Singer is; RVC-trained voices are not), the cleanest version of this pipeline
may skip step (b) entirely for a first pass — **set (a)'s own voice reference to a short clip of the
user's own voice** as the DEFAULT. Then no third-party voicebank timbre enters the output and no
license-chaining question arises (see §5). ⚠️ *Orchestrator correction, 2026-09-24:* the "own voice only"
restriction recorded in `docs/research/2026-07-11-vocals-voice-conversion.md` §3c was WITHDRAWN by the user
on 2026-07-27. The provenance of any voice is the user's responsibility. So the user's own voice is a
default here, never a restriction, and any reference voice the user supplies is allowed. Step (b) then becomes an optional *quality upgrade* for users who have
already invested in training a proper RVC voice (10-30 minutes of their own singing), since a fully-trained
RVC decoder should have a materially higher fidelity ceiling than a few-second zero-shot reference clip —
this is inference, not measurement, reasoning from the general architecture of few-shot vs. trained voice
cloning and from the one concrete, verified complaint about few-second cloning already on file
(§2.3's VocalNet citation) — and should be confirmed, not assumed, in the spike.

### (c) Anything better

- **Try the ACE-Step Cover/Lego zero-cost experiment from §3 first**, purely as a free sanity check while a
  real engine is spiked — it costs nothing (the sidecar is already resident when in use), reuses 100%
  shipped infrastructure, and needs zero new licensing review. Expect it to work passably on simple, sparse
  material and to drift on anything melodically complex, per the vendor's own documented caveat — this is a
  baseline to compare against, not a candidate for the shipped feature.
- **SoulX-Singer (§2.3) is the actual engine worth building against**, for the reasons in §5.

### Rough MCP tool shape (research-level sketch, not a spec)

Mirrors the existing `ai.generateSong`/`ACEStepClient` async submit/poll shape and the `vc.` naming
convention already established in this codebase, sitting behind a new narrow provider protocol (a sibling
to the existing `SongGenerating`) rather than exposing the vendored engine's own wire format:

```
sing_lyrics_on_lead(
  leadClipId: UUID,
  lyrics: string,                      // one line, or pre-authored with '+' / '+~' melisma hints
  voiceRef: audioFileRef | trainedVoiceId,   // a short clip (zero-shot) or an existing RVC voice
  targetTrackName: string?
) -> { jobId }

get_sing_job(jobId) -> {
  status: queued | running | done | failed,
  audioUrl?: string,
  warnings?: string[]                  // e.g. "3 notes had no syllable left; tied to the previous one"
}
```

---

## 5. Recommendation

### Route A — recommended primary, gated on a spike: vendor SoulX-Singer as a third local sidecar, feeding the existing RVC path

- **Effort**: sized like the RVC integration epic already on record (`docs/research/2026-07-11-vocals-voice-conversion.md`
  §4c: spike → install script → client → wire+MCP → UI → real-model gate, 5-6 sub-items). Route the spike
  itself to `daw-architect` first, exactly as that epic's own `(vi-a)` sub-item was scoped — the spike must
  answer, hands-on, on this Mac: does it actually run; does the MLX bridge work or silently fall back to
  full PyTorch/MPS; what is the exact score-input schema; what is real inference speed and peak memory;
  what does the zero-shot voice cloning actually sound like.
- **Disk**: the community **MLX-converted** weights are 774 MB - 5.6 GB depending on quantization
  (VERIFIED, §2.3) — trivial against this machine's free disk either way, but note this is the conversion's
  size, not the official upstream PyTorch checkpoint, which was not fetched in this pass and may differ.
- **RAM**: **not measured anywhere, for this model, on this hardware — do not quote a number until the
  spike runs**, consistent with this codebase's own standing rule that an unmeasured figure is not a
  measured one (applies here exactly as it did to ACE-Step's and RVC's own onboarding reports).
- **Quality risk**: real and currently unresolved — a few-months-old project with no independent
  listening-test track record, and a documented failure mode in an architecturally similar
  short-reference-clip cloning product elsewhere (§2.3). Needs hands-on listening before any user-facing
  promise.
- **Licensing risk**: **low for the engine itself** — Apache-2.0 code and weights, the same permissive
  family already covering ACE-Step and RVC, no new legal-review class. **Low-to-none for the output**
  when the voice reference is the user's own recording (§4b), which is why that is the proposed default.
  Any other reference voice is the user's call: they withdrew the own-voice-only policy on 2026-07-27,
  and provenance is their responsibility.
- **Needs the user's word**: not yet — a spike ships nothing and commits to nothing, the same bar the RVC
  epic's own research phase cleared without a decision gate. The word is needed only when this moves from
  spike to shipped feature.

### Route B — try today, ships nothing, costs nothing: the ACE-Step Cover/Lego experiment

- **Effort**: near-zero — an afternoon, reuses the already-running ACE-Step sidecar and whatever
  bounce-to-audio mechanism already exists for rendering a MIDI clip.
- **Disk/RAM**: zero marginal cost.
- **Quality risk**: **high and structural, not tunable** — the vendor's own documentation and real usage
  reports agree this preserves melodic *contour*, not exact notes, for anything beyond simple material.
  Will not satisfy "split and assign to the exact note" as a general solution.
- **Licensing risk**: none — already-cleared MIT engine, already-shipped.
- **Needs the user's word**: no. This is a comparison baseline to run before or alongside Route A's spike,
  not a roadmap commitment.

### Route C — highest quality available today, but real money and a strategic mismatch: Synthesizer V Studio 2 Pro as a hosted AU plugin

- **Effort**: **low engineering effort only if hosted purely as an AU instrument the user plays/edits by
  hand** — DAW Pro already hosts AUv2/v3 per its own stack description (`CLAUDE.md`). But **there is no
  confirmed external API**: the scripting surface found (§1b) runs *inside* an already-open SynthV project,
  not from outside the app, so **an AI agent cannot type lyrics into it via MCP** — a direct conflict with
  DAW Pro's stated constitution goal of full AI control (`CLAUDE.md`'s opening line). This route buys
  vocal quality, not AI-drivability.
- **Cost**: **$99 + $79/voice, real money**, one-time (REPORTED pricing, §1b).
- **Disk/RAM**: light — a few GB, runs on hardware the user already has if purchased.
- **Quality risk**: **low** — the best-reviewed, most mature English AI-singing product surveyed, by
  reputation (REPORTED, general).
- **Licensing risk**: **low** — commercial use included with official voices (VERIFIED, §1b).
- **Additional integration risk to flag explicitly, from this codebase's own prior experience**: hosting a
  new third-party AU has already once wedged the main actor for minutes with a different plugin (Surge XT,
  per this project's own recorded lesson) — treat any new third-party AU host as needing its own spike, not
  an assumption that hosting "just works."
- **Needs the user's word**: **yes** — real money, and it does not deliver the "AI types the lyrics"
  automation goal the way a sidecar does. Present as an explicit "pay for it, do the typing by hand, get
  the best quality available today" alternative alongside Route A's spike — not a silent default.

### Net recommendation

Spike **Route A** first (route to `daw-architect`), run **Route B** today as a free zero-effort comparison
baseline while that spike is scheduled, and offer **Route C** to the user as a named, priced alternative in
parallel — not instead of the spike. Route A is the only one of the three that is both fully local and
agent-drivable end-to-end, which is the architecture DAW Pro has already built and proven twice (ACE-Step,
RVC), and matches the project's own stated mission better than either alternative.

---

## 6. Actionable takeaways

1. **Correct `docs/research/README.md`'s "Answered" line.** Current text: *"~~DiffSinger-class local
   singing synthesis~~ — superseded: ACE-Step-1.5 sings, locally."* Proposed replacement: *"~~DiffSinger-class
   local singing synthesis~~ — superseded **for whole-song generation** (ACE-Step-1.5 sings, locally,
   2026-07-05). **Re-opened 2026-09-24** for a narrower, different requirement — note-accurate lyrics sung
   on a pre-composed MIDI melody — which ACE-Step has no mechanism for (verified against its task-type
   inventory and docs, 2026-09-24). See `2026-09-24-lyrics-sung-on-a-melody.md`."* This preserves the
   original, still-correct verdict while removing the misleading implication that it covers a capability it
   was never asked about.
2. **Add a new standing research item to `docs/research/README.md`**: *"Hands-on spike: SoulX-Singer
   (Apache-2.0, `github.com/Soul-AILab/SoulX-Singer`) on this Mac — does its score-conditioned MIDI+lyrics
   mode actually run, at what speed/memory, and does the zero-shot voice cloning sound usable? No
   independent listening test exists yet anywhere, including here."*
3. **Propose a new `ROADMAP.md` item**, sized and routed like the existing RVC epic
   (`docs/research/2026-07-11-vocals-voice-conversion.md` §4c), e.g. *"Lyrics-on-melody singing (spike →
   install → client → wire+MCP → UI → real-gate): third local sidecar running SoulX-Singer; pipeline =
   DAW Pro's own `MIDINote` data + typed lyrics → phonemize/melisma-split → SoulX-Singer score-conditioned
   synthesis (voice reference defaults to the user's own recorded clip) → optional existing RVC re-skin for
   users with a trained voice → import via existing take/track machinery."* Gate the first sub-item on the
   spike in item 2; do not size the rest until it reports back.
4. **Default SoulX-Singer's zero-shot reference clip to the user's own recorded voice.** This is a
   DEFAULT, not a restriction. The user withdrew the own-voice-only policy on 2026-07-27 (the 07-11 §3c
   rule is superseded), and the provenance of any voice they supply is their responsibility. The default
   also happens to sidestep the one open licensing question in this report (see item 5).
5. **Disclose, do not police.** Suppose a *non-owned, license-encumbered* voicebank or reference voice is
   used as the "carrier" performance in step (a). It is not established whether running the result
   through RVC (step (b)) clears whatever restriction applied to that carrier: a voice-changer does not
   obviously launder a non-commercial licence. Under the user's 2026-07-27 ruling that judgement is
   theirs. The product's job is to show a voicebank's own terms where they are known, not to block it.
   Item 4's default (the user's own voice) avoids the question.
6. **Do not adopt `DiffSingerMiniEngine`** (AGPL-3.0, archived 2024) as an integration point under any
   circumstance found in this report — flagged for the record so a future pass doesn't have to re-discover
   this.

---

## Primary sources consulted

**Internal (read directly, this repo, read-only):**
- `docs/research/README.md`, `docs/research/2026-07-05-ace-step-local-song-generation.md`,
  `docs/research/2026-07-16-ace-mlx-native.md`, `docs/research/2026-07-11-vocals-voice-conversion.md`,
  `docs/research/2026-08-09-vocalnet-comparison.md`, `docs/research/2026-08-10-realtime-vc-spike.md`,
  `docs/research/m23-q-pitch-correction-survey.md`
- `Sources/DAWCore/Model.swift:137-169` (`MIDINote`)
- `docs/AI-INTEGRATIONS.md` (port assignments, grepped)

**UTAU / OpenUtau / DiffSinger (fetched 2026-09-24 unless noted):**
- https://github.com/stakira/OpenUtau (LICENSE = MIT, activity, platform support)
- https://github.com/stakira/OpenUtau/wiki/DiffSinger-support
- https://github.com/openutau/OpenUtau/wiki/Getting-Started (`+` / `+~` melisma convention)
- https://github.com/openvpi/DiffSinger (LICENSE = Apache-2.0)
- https://github.com/openvpi/DiffSingerMiniEngine (LICENSE = AGPL-3.0, archived 2024-02-06)
- https://github.com/openvpi/vocoders/releases/tag/nsf-hifigan-v1
- https://diffsinger.miraheze.org/wiki/Category:DiffSinger_voicebanks
- https://xinshengwang.github.io/opencpop/liscense/ (Opencpop = CC-BY 4.0 download + separate non-commercial condition, not a CC BY-NC license variant)
- https://vocadb.net/T/3127/utau-cvvc, https://utau.info/start/vbtypes/, https://en.wikipedia.org/wiki/Utau (REPORTED, cross-checked)
- https://github.com/boxboy523/OpenUtau-Headless (checked, low-activity, not recommended)

**NNSVS / ENUNU:**
- https://github.com/nnsvs/nnsvs (LICENSE = MIT, no bundled voices)

**SoulX-Singer:**
- https://github.com/Soul-AILab/SoulX-Singer (README: license, input modes, CLI, training-free voice)
- https://github.com/ailuntx/SoulX-Singer-MLX (community MLX conversion repo, named on the HF card below)
- https://huggingface.co/mlx-community/SoulX-Singer (MLX bridge status, weight sizes)
- https://arxiv.org/abs/2602.07803 (paper existence — REPORTED for exact date)

**Watch-list:**
- https://arxiv.org/html/2607.27768 (VocalRender abstract — no code/license found)

**Commercial products (REPORTED unless marked VERIFIED; fetched/searched 2026-09-24):**
- https://dreamtonics.com/synthesizerv/ (VERIFIED: Apple Silicon, offline, commercial license included)
- https://github.com/Dreamtonics/svstudio-scripts, https://resource.dreamtonics.com/scripting/ (scripting API, in-app only)
- https://www.pluginboutique.com/products/17719-... (SynthV pricing, REPORTED)
- https://acestudio.ai/pricing/, https://www.saasworthy.com/product/ace-studio-ai/pricing (ACE Studio pricing/offline ambiguity, REPORTED — direct fetches of `acestudio.ai`, `acestudio.ai/pricing`, and `www.acestudio.ai/pricing` all returned HTTP 404 in this pass)
- https://softwarefinder.com/artificial-intelligence/vocaloid6 (Vocaloid 6 pricing, REPORTED)
- https://www.soundsonline.com/vocals/hollywood-choirs and aggregator retailer listings (WordBuilder, pricing, REPORTED)

**ACE-Step (upstream, fetched 2026-09-24):**
- https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/Tutorial.md
- https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/ace_step_musicians_guide.md
- https://github.com/ace-step/ACE-Step-1.5/discussions/398

**G2P:**
- https://github.com/Kyubyong/g2p (LICENSE = Apache-2.0)
