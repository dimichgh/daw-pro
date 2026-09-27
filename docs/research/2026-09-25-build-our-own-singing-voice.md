# Could DAW Pro build its own Synthesizer-V-class singing voice?

Date: 2026-09-25 (corrected 2026-09-25, same day, after an adversarial fact-check — see "Corrections,
2026-09-25 fact-check" at the end)
Author: research-analyst (agent)
Scope: answers the question the 2026-09-24 report explicitly did not — not "which existing engine should we
integrate" but "what does Synthesizer V actually run locally, is 'CPU-based, so cheap to build' the right
premise, and what would it really take for DAW Pro to build or train its own singing voice." Builds on, and
does not repeat, `docs/research/2026-09-24-lyrics-sung-on-a-melody.md` (voicebank/engine survey, licensing
fragmentation, SoulX-Singer basics, ACE-Step's lack of MIDI input) and `docs/design/2026-09-24-p2-sing-spike.md`
(the in-flight hands-on spike of SoulX-Singer on this Mac). Both are cross-referenced by section below rather
than re-derived.

**Citation tags.** VERIFIED = I fetched the page myself and the quote is drawn from that fetch — dated
2026-09-25 unless noted; "VERIFIED, this session" marks fetches done specifically for the 2026-09-25
fact-check correction pass, to distinguish them from the first pass's own VERIFIED claims (some of which the
fact-check found wrong despite being tagged VERIFIED — a citation of a page is not the same as reading the
right page; see the corrections section). REPORTED = a secondary source, or a search-engine synthesis of a
page I did not independently open — treated as **not independently confirmed**, i.e. it falls under the
"UNVERIFIED" bucket the task asked for, just with a named, checkable source rather than being pure inference.
INFERRED = my own reasoning from the verified facts, not a claim any source makes directly — flagged every
time, including when it's the load-bearing point of a section. VERIFIED-2ND = already verified by a prior
report in this repo, re-cited rather than re-fetched. Every price/version/license claim is dated 2026-09-25
because all three rot.

**2026-09-25 fact-check note**: an adversarial fact-check of this report's first pass, run the same day,
found seven errors — one of them (the DiffSinger fine-tuning claim) wrong in a way that changed a
recommendation, not just a detail. All seven are corrected in place below and logged with old text, new text,
and source in the dated "Corrections" section at the end.

---

## 0. The plain-words answer

Your read on the CPU part is basically right, with one boundary worth keeping in mind: Synthesizer V's own
maker says the singing runs entirely on your computer and needs no separate graphics card, and their own
release notes tie a real performance bug to specific CPU core types — that's evidence, not just marketing
copy. Small, hand-tuned neural networks like that really are cheap to **run** — for one voice at a time.
"No dedicated GPU required" is not the same claim as "never touches the GPU," and nothing found says the
latter; it's also only shown to hold for a single voice, not for Dreamtonics' own newer multi-voice AI Choir
feature, where one user reports a four-part choir rendering slowly even on a fairly capable CPU and has
publicly asked Dreamtonics for a GPU render path, unanswered as found.

But "cheap to run" is a different bill from "cheap to build." A new voice needs many hours of one singer's
studio-quality recordings with the right to use them, that audio labeled precisely, and a training run whose
computer cost nobody in this field publishes — itself a clue that data and labeling, not GPU time, are the
real expense. Every open research corpus this report checked gives roughly **4 to 5 hours of audio per
voice** — not the "5 to 80 hours" a first pass of this report said, which mistook one dataset's 80.59-hour
*total across 20 singers* (about 4 hours each) for a single big voice; the one genuinely strong recent open
model used over 42,000 hours.

For DAW Pro specifically there's a real shortcut, though: since the words and notes are already known
(typed lyrics, a MIDI melody), labeling the user's own recording only needs two free tools, not the
industrial six-tool pipeline a company scraping the internet needs — that part really would be cheap. The
*code* to fine-tune an existing acoustic model onto a new voice, rather than train one from nothing, also
turns out to already exist and be free: DiffSinger's own current recipe documents exactly this, which
corrects a first pass of this report that checked a stale page and concluded no such option existed. What's
still missing, and still expensive, is a *starting checkpoint* worth fine-tuning: no freely reusable,
commercially clean pretrained acoustic voice model was found anywhere this report looked — including five
checkpoints that advertise a permissive license and turn out, on reading their own fine print or their
training data's license, not to be one. So the realistic plan is still training from a cold start on the
user's own singing — likely a few hours of it (closer to 4-5 than to 80), not the 10–30 minutes DAW Pro's
existing voice-changer gets away with — and how long that training would take on this Mac has never been
tested, by us or, as far as this pass found, by anyone.

---

## 1. What Synthesizer V Studio 2 Pro actually runs locally

### 1.1 CPU or GPU: what Dreamtonics states, what has to be inferred

Dreamtonics never publishes one sentence that says "our synthesis runs on the CPU, not the GPU." What they
publish, checked directly across every official page found, converges hard on that being true anyway — and
one piece of it is now a direct vendor statement, not an inference:

- **VERIFIED** (`dreamtonics.com/synthesizerv/`, fetched 2026-09-25): *"Synthesizer V Studio 2 Pro performs AI
  vocal synthesis locally on your computer"* and *"it does not upload your creative content to servers for
  processing."* One caveat, also VERIFIED on the same page: *"When using trial voices, your data may be sent
  to Dreamtonics servers for license verification... Once a voice is purchased and activated, all vocal
  processing is done locally."*
- **VERIFIED, this session** (`manual.synthv.info/setup/`, fetched 2026-09-25, corrects/adds to the bullet
  above): the trial-voice caveat is not the only channel through which data can leave the machine. Studio 2
  Pro's opt-in "AI Retakes" feedback feature — a checkbox in the Telemetry Consent dialog, off by default —
  transmits, whenever a user hearts ("Likes") a retake, *"minimal snippets of project data required to
  reconstruct your preferred retake, such as note duration and pitch, phoneme data, the selected voice
  database, etc.,"* stated as used *"exclusively for research and development purposes."* This is opt-in and
  applies regardless of trial vs. fully purchased/activated voice — a second, separate channel, not a
  trial-only one. It does not contradict "rendering itself is local" (the audio is still rendered on-device;
  this is telemetry about a preference, not an audio upload), but it means "does not upload your creative
  content to servers, except for trial voices" understates Dreamtonics' own documented data practices by one
  clause.
- **VERIFIED**, Dreamtonics' own **2.2.1 release notes** (`dreamtonics.com/synthesizer-v-studio-2-pro-2-2-1/`,
  fetched 2026-09-25) — this is the strongest single fact in this section, because it is Dreamtonics
  describing their own bug fix, not marketing copy: *"Fixed performance degradation on Windows on CPUs with
  performance/efficiency cores,"* and, in the same release, *"Added a settings option for the number of
  rendering threads."* A performance bug the vendor itself ties to a specific CPU core architecture, in a
  release that also adds a user-facing "number of rendering threads" setting, is about as direct as it gets
  short of Dreamtonics simply writing "we render on the CPU." (This upgrades what was, before this fetch, only
  a correlational inference from a community forum thread — see below.)
- **VERIFIED**, the marketing claim for the launch of Studio 2 Pro (announced ~December 2024, released
  ~March 2025, REPORTED via search synthesis for the exact dates), fetched from two independent pages — both
  carry the full composite sentence, not fragments (**corrected this session**: a first pass of this report
  misread recordingmag.com's copy as fragmentary; re-fetched directly and it is not).
  `futuremusic.com/2026/04/dreamtonics-synthesizer-v-studio-2-pro-review/`: *"Up to 300% faster rendering
  speed — without requiring a dedicated GPU or acceleration hardware, allowing for offline use."*
  `recordingmag.com/news/dreamtonics-unveils-synthesizer-v-studio-2-pro/` (**VERIFIED, this session,
  re-fetched**): *"Up to 300% faster rendering speed – without requiring a dedicated GPU or acceleration
  hardware, allowing for **seamless** offline use"* — one word different ("seamless"), same composite
  sentence, not fragments. Both are Dreamtonics' own launch language reproduced by press, not the outlets'
  own testing.
- **VERIFIED**, system requirements fetched from three separate official/store pages (`dreamtonics.com/synthesizerv/`,
  `native-instruments.com/products/synthesizer-v-studio-2-pro`, and Dreamtonics' own Zendesk article for
  Studio Version 1) list **only a CPU spec** — *"Intel Core i5 (1st gen or later) / AMD Ryzen (equiv. or
  better) / Apple Silicon (M1 or later)"* for Studio 2 Pro, *"Intel Core i5 or a higher-grade CPU, or
  equivalent AMD CPUs"* for Version 1 — plus RAM (4 GB+ for Studio 2 Pro, 2 GB+ for V1) and 1 GB+ disk.
  **No GPU, VRAM, or "dedicated graphics" line appears anywhere in official system requirements for either
  version.**
- **VERIFIED**, DTM Station's interview with Kanru Hua about Studio 2 (`dtmstation.com/archives/69769.html`,
  Japanese, fetched and translated 2026-09-25): Hua states plainly *"all processing is performed locally, and
  nothing is sent to the internet,"* and that the 300% figure covers *"rendering time, waveform display
  speed, and voice database loading performance."* He also states Studio 2's *"architecture differs
  significantly [from V1], so existing voice databases cannot be read directly"* — Studio 2 is a rebuild, not
  an incremental tune of V1's engine, which matters for the next point.
- **REPORTED**, and explicitly dated to the *older* version — via a search-engine synthesis of the SynthV
  Fandom wiki (direct fetch returned HTTP 402, paywalled; not independently opened) describing a Kanru Hua
  Twitter/X post from February 2021 about the Studio **1.2** update: *"Synthesizer V Studio 1.2 uses
  JIT-compiled quantized sparse matrix-vector multiplication (MVM) kernels"* — matrices are pruned to be
  mostly zero, then the remaining values are integer-quantized, specifically to speed up CPU matrix-**vector**
  multiplication (the kernel shape a *small* model uses one note at a time), which is a different problem
  from the dense matrix-**matrix** multiplication GPUs are built to accelerate at scale. The same synthesis
  states *"the software is able to run on every x86 CPU since the Pentium 4 processor... developed in
  2004,"* and that *"Gen 2 AI voices achieve significant speed up with quantized sparse linear algebra
  kernels."* This needs a precise caveat: it describes the 2021, version-1.2 engine, sourced through a wiki
  summarizing a developer's own social-media post, not independently re-opened here. **Whether this exact
  kernel technique carries into the rebuilt Studio 2 engine is genuinely unresolved** — plausible given the
  same company and the same "no GPU needed" claim, but Studio 2 is stated by its own developer (above) to
  differ significantly in architecture from V1. This is one of the four facts this report is least sure of
  (see the closing summary).
- One more converging, non-definitive signal: Dreamtonics' own user forum (VERIFIED,
  `forum.dreamtonics.com/t/seeking-testers-rendering-performance-issues-with-synthesizer-v-studio-2-pro-2-2-0/7616`)
  documents users reporting the *same* performance-degradation symptom the 2.2.1 release notes above confirm
  fixing, narrowed by Dreamtonics to *"high-end devices with 64GB+ memory and Intel 12–14th gen i9
  processors"* — the exact Intel generations with performance/efficiency-core scheduling, consistent with
  the fix.

**Net read, stated precisely so it isn't overclaimed**: nothing found states "Synthesizer V's neural
inference runs on the CPU" in those exact words. But one piece of evidence is now a direct vendor statement
about their own bug (P/E-core-specific performance degradation, fixed alongside a rendering-thread-count
setting), not an inference — combined with zero GPU spec across three official pages and two product
generations, an explicit "no dedicated GPU needed" marketing claim, and a developer-sourced description of
CPU-targeted sparse/quantized kernels (dated to the prior version), this is about as solid a picture as this
kind of proprietary-software research produces without the vendor simply writing "CPU" in a spec sheet.

Two boundaries on that picture, both found this session rather than assumed, and both dropped by the first
pass of this report's plain-words summary even though §1.1 itself already hedged the first one. **First**,
"no dedicated GPU or acceleration hardware **required**" is marketing-safe wording that rules out a
*mandatory* discrete GPU; it does not rule out optional use of the integrated GPU or Neural Engine already
present in every Apple Silicon Mac — no Dreamtonics source fetched anywhere in this pass, this session
included, ever states "we do not use the GPU." **Second**, "cheap to run" is demonstrated here for rendering
*one voice*, not for Dreamtonics' own newer multi-voice AI Choir feature: a Dreamtonics forum thread
(**VERIFIED, this session**, `forum.dreamtonics.com/t/the-time-has-come-for-gpu-rendering/7450`, opened
2026-01-16) has a user reporting *"rendering a four-part standard choir takes a long time"* on a 12th-gen
Intel Core i5, and asking Dreamtonics to *"consider a CUDA or Tensor Core based render path"* — with no
staff reply as fetched, only a community-suggested workaround. The same opening post also says *"rendering a
choir with 64 voices in total takes quite a while"*, and a later post (2026-03-16) reports the same trouble
with a 4-part choir on *"a good cpu and 64 gigs of ram"* (orchestrator re-fetch, 2026-09-25, settling a
disagreement between the fact-check and the correction pass: the 64-voice sentence IS in this thread; the
"12th–14th gen i9" framing is NOT). That is two unanswered user reports, not proof of a general problem. What it does establish is that "cheap to
run" is shown for a single voice, not demonstrated for the multi-voice feature Dreamtonics itself now
markets, and that the question is live enough that a user is asking the vendor for GPU acceleration in
2026, not a settled non-issue.

### 1.2 Voice database size and render speed: not found

**UNVERIFIED — not found anywhere in this pass**, despite checking Dreamtonics' own site, its Zendesk help
center, the Native Instruments and Adorama store listings, and the DiffSinger/SynthV community wikis. No
page states a download size in GB/MB for an official Synthesizer V voice database. No page states an
absolute render speed (seconds of compute per second of audio, or similar) — only the *relative* "up to 300%
faster than the previous version" claim exists (VERIFIED, §1.1), and the one hands-on review fetched
(`futuremusic.com`) says rendering *"performed admirably... no CPU or latency issues"* with no numbers
attached. Per this task's own rule: not guessed, flagged as missing.

### 1.3 The architecture, in Kanru Hua's own words

**VERIFIED**, DTM Station's earlier interview (`dtmstation.com/archives/45880.html`, Japanese, fetched and
translated 2026-09-25): Hua frames Synthesizer V's founding concept as a deliberate **hybrid** of two
approaches he saw diverging by 2016 — sample-based synthesis (his description: good audio quality) and
"AI"/neural methods (his description: more human-like expression, worse audio quality at the time) —
*"ハイブリッドで行こう、と考えたのがSynthesizer Vのコンセプトです"* ("let's go hybrid — that became Synthesizer
V's concept"). This matters directly for §2: Synthesizer V is not "just a small trained neural net." Its
foundation includes a recorded sample library per voice (the same lineage as the voicebank/splicing systems
in the 2026-09-24 report §1a/§1b) *plus* neural components layered on top for expression — built by a
company (Dreamtonics, founded 2019 per Hua's own bio, REPORTED) that has worked on exactly this problem for
years. Kanru Hua has also given at least one academic-audience talk on the subject — VERIFIED existence via
CCRMA's own event listing (`ccrma.stanford.edu/events/singing-voice-synthesis-towards-state-of-art-dreamtonics-inc-tokyo-japan`),
titled "Singing Voice Synthesis: towards the State of the Art" — framing this as a live, hard research area,
not a solved, commodity problem; the fetched abstract itself gave no further technical detail.

---

## 2. Is "CPU-based, so cheap to build and train" the right premise?

### 2.1 The conceptual split (INFERRED, general ML-engineering reasoning, not a specific citation)

CPU-friendliness at *inference* time is a property of two things: a small model, and hand-optimized
low-level kernels written specifically for that small model (§1.1's sparse-quantized-MVM description, and
the vendor's own thread-count setting, are exactly this kind of hand-optimization). That is orthogonal to
*training* cost. A small model can still be expensive to train well, because getting a small model to sound
natural typically demands **more** careful data and engineering, not less — there's no large model's worth
of slack to hide gaps in. Training cost and inference-hardware requirements are different axes; §1's
evidence answers the first, this section answers the second, with real numbers from the open projects that
publish them.

### 2.2 Data

| Corpus / voice | Hours | Singers | License | Source |
|---|---|---|---|---|
| Opencpop (Mandarin, flagship DiffSinger corpus) | **~5.2 h** (100 songs, 3,756 utterances) | 1, professional female | CC-BY 4.0 + bespoke non-commercial condition (VERIFIED-2ND, 09-24 report) | VERIFIED, direct fetch of `github.com/wenet-e2e/opencpop` README (*"The final dataset contains 3,756 utterances, with a total of about 5.2 hours"*) + arXiv abstract page (2201.07429, singer/song count only, no hours) |
| NSF-HiFiGAN vocoder training set (used across the whole DiffSinger/OpenUtau ecosystem) — three releases checked, **corrected this session** from a first pass that only found the oldest one | **~93 h** (v1, Dec 2022, 1M+ steps) · **~72 h** (2024.02, 110k fine-tune steps) · **~79 h** (pc-nsf-hifigan, 2025.02) | not stated for any release | **CC BY-NC-SA 4.0** for all three releases' weights; the **code** repo (`openvpi/vocoders`) is separately **AGPL-3.0** — a first pass of this report checked only the weights' license and missed the code license entirely | VERIFIED, this session — direct fetch of `api.github.com/repos/openvpi/vocoders/releases` (all three release bodies) and `raw.githubusercontent.com/openvpi/vocoders/main/LICENSE` |
| GTSinger (NeurIPS 2024 Spotlight, largest published open singing corpus as of its own paper) | **80.59 h** total, 9 languages incl. English — **≈4.0 h/singer average** (INFERRED, 80.59 ÷ 20 singers; **added this session** — a first pass's summary treated the 80.59 h total as if it were a per-voice figure) | 20 professional | **CC BY-NC-SA 4.0, "may not use the material for commercial purposes"** | VERIFIED, direct fetch of arXiv abstract (2409.13832: *"80.59 hours of high-quality singing voices"*, *"20 professional singers"*, *"nine widely spoken languages"*) + direct fetch of `AaronZ345/GTSinger`'s `dataset_license.md`; per-language/per-singer hours not stated anywhere found — UNVERIFIED breakdown |
| Namine Ritsu (NNSVS's own benchmark voice) | **4.35 h** (110 songs, 100/5/5 split) | 1, Japanese | not stated in the paper | VERIFIED, direct HTML fetch of the NNSVS paper (arXiv:2210.15987) |
| **SoulX-Singer training set** | **42,000+ h** (~20,000 Mandarin / ~20,000 English / ~2,000 Cantonese) | many, unsourced | Apache-2.0 for code+weights (VERIFIED-2ND, 09-24 report); **data sourcing itself not disclosed** | VERIFIED, GitHub README (09-24 report) and this session's own direct fetch of the full paper HTML (arXiv:2602.07803v1) |
| Community DiffSinger voicebank guidance (one forum data point) | *"a minimum of 30 minutes per language... adding more will help greatly"* | — | — | **REPORTED**, a single UtaForum.net commissioning-service post found via search, not independently opened — one of the four facts this report is least sure of |
| DAW Pro's own already-shipped RVC voice-**conversion** requirement (for comparison — a different technique, see the boundary note in §3(c)) | **10–30 min** | 1, the user | MIT tooling (Applio) | VERIFIED-2ND, `docs/research/2026-07-11-vocals-voice-conversion.md` |

**Per-voice average, corrected this session**: the "5 to 80 hours" range a first pass of this report's
plain-words summary gave conflated GTSinger's 80.59-hour *total* (across 20 singers) with a per-voice figure.
Divided out (INFERRED, 80.59 ÷ 20), GTSinger averages **≈4.0 h/singer** — consistent with Opencpop's 5.2 h
and Namine Ritsu's 4.35 h, both genuinely single-voice corpora. The per-voice range these three corpora
actually support is **about 4 to 5 hours**, not "5 to 80."

**The sharpest number in this table**: SoulX-Singer's own paper describes its 42,000+ hours as *"an
order-of-magnitude increase compared to the data scale used in existing SVS studies"* (VERIFIED, direct
quote from the paper HTML) — roughly 8,000×–10,000× more than a single voice's worth in every other named
open dataset here. That is squarely a "not cheap" resource: sourcing, cleaning, and rights-clearing audio at
that scale is an industrial data operation, not a weekend project, regardless of how small the resulting
inference model is.

**Consent/licensing, stated honestly rather than assumed**: none of the fetched sources for the boutique
academic datasets (Opencpop, GTSinger, Namine Ritsu) describe payment or rights terms beyond "recorded by a
professional/named singer" — not found, flagged rather than guessed. For SoulX-Singer's 42,000 hours, the
paper explicitly does **not** disclose how the data was sourced (VERIFIED-absence: asked directly of the
fetched HTML, which describes only the *processing pipeline* applied to "songs with background music," not
where those songs came from). A 42,000-hour multilingual singing corpus assembled by an industry lab with
undisclosed sourcing is exactly the situation where "was consent obtained, or was this scraped" is a live,
open, and currently unanswerable question from the outside — noted here as a real gap, not an accusation,
since no evidence either way was found.

### 2.3 Labelling — and this is where DAW Pro's own situation is genuinely cheaper than the general case

Every voice needs the same things labelled onto its audio: **phoneme boundaries** (what sound is happening
when), **note pitch/duration** (what note it's on), and often **F0/pitch contour** (the actual sung pitch
curve). What that labelling costs depends entirely on **whether the words and notes are already known**.

- **The general/industrial case — words and notes are *not* known in advance**, because the source is a
  scraped or licensed recording with no ground-truth score. This is SoulX-Singer's situation, and its own
  preprocessing pipeline (VERIFIED, direct fetch of `preprocess/README.md`) is the most concretely documented
  example found in this pass: **six separate pretrained models** chained together — two Mel-Band-Roformer
  models for lead-vocal isolation and de-reverberation (needed because the source has a backing track);
  SenseVoiceSmall for language ID; Paraformer (Mandarin/Cantonese) and NVIDIA's **Parakeet-TDT-0.6B-v2**
  (English) for lyric *transcription* (needed because the lyrics aren't already known as text), with a QC
  step discarding samples whose transcribed lyrics don't match a reference; **RMVPE** for F0 extraction; and
  **ROSVOT** for note-boundary/pitch-class *transcription* (needed because the score isn't already known
  either). Each is a separate open-source project with its own license to check and its own compute cost.
  Notably, **Parakeet is an NVIDIA NeMo model** — the same fact the already-running spike plan flags as a
  possible **"real Mac blocker, not the synthesiser"** for exactly this reason (VERIFIED-2ND, directly quoting
  `docs/design/2026-09-24-p2-sing-spike.md` failure mode F5).
- **DAW Pro's own case is not this case.** When the user records themselves singing typed lyrics on a MIDI
  melody DAW Pro already has, the words and the notes are **known by construction** — there is nothing to
  transcribe or vocal-separate, because there's no backing track and no unknown lyric. What's actually needed
  to label that one recording is **forced alignment** (matching the known words to the known audio timing —
  SOFA, MIT, VERIFIED §2.3 below) and **F0 extraction** (RMVPE, as used by SoulX-Singer's own pipeline,
  VERIFIED) — **two tools, not six** — with ROSVOT-class note-boundary refinement as an optional third if the
  sung timing needs correcting against the MIDI reference rather than trusted outright. This is a genuine,
  DAW-Pro-specific simplification, not a general claim about singing-voice labelling being cheap everywhere:
  it is cheap here specifically because DAW Pro already has the score and the lyrics before the user opens
  their microphone.
- **VERIFIED**, the standard tools either path draws on: `openvpi/MakeDiffSinger`'s own pipeline names **MFA**
  (Montreal Forced Aligner) for its "acoustic-forced-alignment" recipe (direct README fetch); **SOFA**
  (`github.com/qiuqiao/SOFA`, "Singing-Oriented Forced Aligner") is **MIT-licensed** (VERIFIED, direct fetch)
  and built specifically as an easier-to-install, singing-tuned alternative to MFA.
- **Net picture, corrected from a first pass of this report that conflated the two cases**: labelling a
  voicebank at SoulX-Singer's industrial scale, from unknown source audio, genuinely needs six chained
  models and is real infrastructure work. **Labelling DAW Pro's own use case — a user singing known lyrics on
  a known melody — needs two tools and is the genuinely cheap part of this whole picture**, which is the
  precise "what would be cheap, what would not" split the user's question asked for.

### 2.4 Compute — the weakest-evidenced part of this whole report, and that gap is itself informative

Despite direct fetches of the original DiffSinger paper (arXiv:2105.02446), the VISinger and VISinger 2
paper abstracts (arXiv:2110.08813, arXiv:2211.02903), the full NNSVS paper (arXiv:2210.15987), and the full
SoulX-Singer paper (arXiv:2602.07803v1) — **none of them state a GPU model, GPU count, or GPU-days/hours for
training.** Two step/epoch counts were found: the NSF-HiFiGAN vocoder's **original v1 release (Dec 2022)**
trained *"beyond 1 million steps"* (VERIFIED, `openvpi/vocoders` release notes) — the two newer releases give
different figures of their own: 2024.02 states 110k *fine-tuning* steps, and pc-nsf-hifigan 2025.02's fetched
release body doesn't restate a step count (VERIFIED, this session, `api.github.com/repos/openvpi/vocoders/releases`)
— and NNSVS's own recipe trains *"acoustic models for 100 epochs... neural vocoders for 600K steps"*
(VERIFIED, paper HTML). None of these convert to a wall-clock or dollar figure without a stated GPU model and
batch size, which this report will not guess.

**This absence is itself a finding, flagged as INFERRED rather than proven**: if GPU-days mattered enough to
be the dominant cost, papers in a field this competitive would very likely report it as a selling point (the
way LLM papers report GPU-hours prominently). That nobody in this specific literature does so is consistent
with — though it does not prove — data acquisition and labelling engineering being the actual bottleneck for
singing-voice synthesis, not raw training compute. That reading matches this report's own §2.2/§2.3 evidence
directly: every hard number found in this pass is about hours of singing and annotation pipelines, never
about GPU-time.

---

## 3. Options for DAW Pro, concretely

### (a) Integrate an existing open zero-shot model: SoulX-Singer — already in motion, not a training question

One paragraph, by design: this is the subject of the entire 2026-09-24 report (§2.3, §5) and the currently
running spike (`docs/design/2026-09-24-p2-sing-spike.md`), and this report does not redo either. Apache-2.0
code and weights (VERIFIED-2ND; re-confirmed this session directly from the README — *"We use the Apache 2.0
license. Researchers and developers are free to use the codes and model weights of our SoulX-Singer."*). It
works by cloning a voice from a short reference clip at inference time — **it is already trained**, which is
exactly why it sidesteps every cost this report has been measuring; its own README and file tree (VERIFIED,
this session) confirm it ships *"Official inference code"* only, with no training or fine-tune path for the
core model. Effort/risk/quality are already scoped there and gated on the spike's own results, which are not
yet in as of this report. The one thing worth restating here because it directly bears on the user's
question: **(a) is the fast path precisely because it is not "building our own" in the sense options
(b)–(d) mean** — it answers "how do we get a working singing voice soon," not "could we cheaply train/build
the underlying model," which is what was actually asked this time.

### (b) Run an open acoustic model + vocoder in-app on CPU/Neural Engine with an existing voicebank (DiffSinger-class, ONNX)

- **License reality, and this is the blind spot the prior report only tagged REPORTED**: DiffSinger's engine
  code is Apache-2.0 (VERIFIED-2ND), but the pretrained **NSF-HiFiGAN vocoder** almost every voicebank in
  this ecosystem is rendered through is **CC BY-NC-SA 4.0 — non-commercial**, across all three releases
  checked (VERIFIED, this session, §2.2). So even a voicebank whose own license says "commercial OK"
  typically still gets rendered through a vocoder that says "non-commercial only," and the license question
  doesn't resolve just because one layer is clean. **This is not hypothetical**: a GitHub issue on
  `openvpi/DiffSinger` (VERIFIED, direct fetch of issue #336, opened by a user on **2026-09-22 — three days
  before this report**) asks exactly this question about a named voicebank ("Ria") plus NSF-HiFiGAN, and as
  fetched has **no maintainer or community reply yet**. Stated precisely rather than oversold: this is a
  currently open, unanswered question as of a three-day-old issue with zero replies — evidence the question
  is live and unresolved, not evidence the whole community has debated it and failed to agree. **One more
  restriction underneath even that, found this session**: the `openvpi/vocoders` **code** repository itself —
  separate from the released weights — is **AGPL-3.0** (VERIFIED, this session, direct fetch of its
  `LICENSE` file), a much stronger copyleft than the weights' non-commercial CC license. This applies to
  anyone building on the training/inference *code*; DAW Pro consuming the released weights through its own
  ONNX runtime, without redistributing openvpi's code, would not itself trigger AGPL — but it is a second,
  separate license to track, invisible if only the weights' license is checked (which is what a first pass of
  this report did).
- **A real way out exists, but is unintegrated**: **BigVGAN v2** (NVIDIA, `github.com/NVIDIA/BigVGAN`) is
  **MIT-licensed for both code and pretrained weights** (VERIFIED, direct fetch of the repo's `LICENSE` file
  and of the Hugging Face model card's license metadata, both 2026-09-25) — a general-purpose vocoder that
  NVIDIA's own materials claim generalizes to singing voices in zero-shot, despite being trained on speech
  (REPORTED, vendor's own claim, not independently listening-tested here). It was **not found integrated
  into the stock OpenUtau/DiffSinger pipeline** in any source fetched — swapping it in is unbuilt work, not
  a settings toggle.
- **Fine-tuning an existing acoustic-model checkpoint onto a new voice: corrected this session, and the
  mechanism turns out to exist.** A first pass of this report checked only `docs/README-SVS-opencpop-e2e.md`
  and concluded the acoustic model trains "entirely from scratch." That page is stale: it 404s on
  `openvpi/DiffSinger`'s actual default branch, `main` (**VERIFIED, this session**: `api.github.com/repos/openvpi/DiffSinger`
  reports `default_branch: main`; a direct fetch of `raw.githubusercontent.com/openvpi/DiffSinger/main/docs/README-SVS-opencpop-e2e.md`
  returns HTTP 404, while the identical path on the old `master` branch returns 200 and carries MoonInTheRiver
  badges — it is inherited legacy content, not the repo's current primary doc). The current `main` branch
  documents fine-tuning directly: `configs/acoustic.yaml` (**VERIFIED, this session, direct fetch**) contains
  `finetune_enabled: false`, `finetune_ckpt_path: null`, `finetune_ignored_params`, and `finetune_strict_shapes`
  fields — the schema exists and is off by default, not absent — and `docs/BestPractices.md` (**VERIFIED,
  this session, direct fetch**) has a full "Fine-tuning from existing checkpoints" section whose worked
  example is explicitly the **acoustic model**: *"take acoustic models as an example / finetune_enabled: true
  ... finetune_ckpt_path: checkpoints/pretrained/model_ckpt_steps_320000.ckpt."* So the mechanism to
  fine-tune an acoustic-model checkpoint onto a new voice is real, documented, and Apache-2.0. **What is
  still missing is the checkpoint to start from**: `BestPractices.md` does not state how much data a
  fine-tuning run needs (checked directly, not found), and — per the counter-example hunt in §4 — no freely
  reusable, commercially clean pretrained *acoustic* checkpoint was found anywhere this report looked to plug
  into that mechanism. The **vocoder** separately has its own fine-tune option (`ft_hifigan.yaml`'s
  `finetune_ckpt_path`, REPORTED via search synthesis, not independently re-opened this session, so kept at
  its original confidence level rather than upgraded) — but that vocoder is the CC BY-NC-SA 4.0 (and
  AGPL-3.0-code) asset flagged above, so fine-tuning it inherits those restrictions rather than escaping them.
- **The flagship voicebank itself (Opencpop) also carries a bespoke non-commercial condition** on top of its
  CC-BY-4.0 base (already VERIFIED in the 09-24 report) — so this route's "existing voicebank" half is *also*
  commercially murky by default, independent of the vocoder question above.
- **Runtime story on Apple Silicon**: OpenUtau embeds ONNX Runtime and documents a "50x realtime" default
  rendering setting, with Apple-Silicon-specific (ANE) acceleration explicitly "not explicitly mentioned"
  and only a generic macOS CoreML GPU option available (VERIFIED-2ND, already directly fetched and quoted in
  the 09-24 report, §2.1). Given DAW Pro has already approved ONNX Runtime as a dependency, this route's
  runtime integration risk is architecturally lower than (a)'s PyTorch/MPS bridge — a genuine point in its
  favor — though no concrete ONNX voicebank file size was found despite several attempts (UNVERIFIED).
- **Quality**: general community reputation (REPORTED, not independently re-verified) rates neural
  DiffSinger output as a large step up from classic splicing, with English coverage historically thinner
  than SoulX-Singer's dedicated ~20,000-English-hour training set (VERIFIED-2ND, 09-24 report §2.1).

### (c) Train or fine-tune ONE voice from the user's own singing, on this Mac (M5 Max, 128 GB, MPS/MLX)

- **Data needed**: the honest range, not a single number. Community DiffSinger folklore (one forum source,
  REPORTED) says 10–30 minutes "per language," which is the same order of magnitude as DAW Pro's already-shipped
  RVC voice-*conversion* requirement (VERIFIED-2ND, 10–30 min). But **every actual published SVS training
  corpus found in this pass used hours, not minutes, per voice** — 4.35 h (Namine Ritsu), 5.2 h (Opencpop),
  and GTSinger's 80.59 h spread across 20 singers averages to ≈4.0 h/singer (INFERRED, §2.2) — a tight
  **≈4–5 h per voice** band, corrected this session from "up to 80.59 h," which conflated GTSinger's total
  with a per-voice figure. **INFERRED, and the single most important original point this report can offer on
  option (c)**: RVC's 10–30-minute sufficiency is not evidence that full singing-voice *synthesis* is equally
  cheap in data — RVC is a voice-**conversion** technique that keeps a large, already-trained content encoder
  frozen and only trains a small per-speaker decoder on top of it. §3(b)'s corrected finding sharpens rather
  than removes this point: DiffSinger's *current* recipe does support fine-tuning an acoustic-model checkpoint
  (`finetune_ckpt_path`, VERIFIED, this session) — the kind of mechanism RVC-style cheap adaptation would
  need. But no freely reusable, license-clean pretrained acoustic checkpoint was found to fine-tune *from*
  (§4's counter-example hunt checked five Hugging Face candidates and found none that survives scrutiny), so
  the mechanism existing doesn't yet translate into a cheap path in practice. Until a clean base checkpoint is
  found or DAW Pro trains its own, the realistic planning assumption for a full SVS voice is **hours (≈4–5),
  not minutes, of the user's own clean singing** — closer to Opencpop's or Namine Ritsu's scale than to RVC's,
  though genuinely less than a cold start would need if a fine-tunable, license-clean base ever surfaces.
- **Labelling needed**: per §2.3's corrected picture, this is the genuinely cheap part — forced alignment
  (SOFA, MIT, VERIFIED) plus F0 extraction (RMVPE, VERIFIED via SoulX-Singer's own precedent), because the
  words and notes are already known from the DAW Pro project itself. Two tools, not six. Assembling and
  validating even that two-tool chain is still unbuilt engineering work with no measured time cost anywhere
  in DAW Pro's own research, but it is a small, bounded task, not an open-ended one.
- **Training time on this Mac: UNVERIFIED — no figure exists anywhere in this pass, or anywhere in DAW Pro's
  own prior research.** This is not a gap unique to this report: the 2026-07-11 RVC report's own action item
  #2 already flags that **"no verified M-series-Max number exists yet"** for the *simpler* voice-conversion
  case (VERIFIED-2ND, direct quote). Full SVS training from scratch would be at least as hard to time, likely
  harder to get running at all — every SVS toolkit checked in this pass (DiffSinger, NNSVS) targets CUDA/PyTorch
  primarily, and **no MPS-specific training guidance was found in either** (UNVERIFIED-absence: this means
  the search didn't surface it, not that it's confirmed impossible). No number is stated here because none
  exists to state.
- **What it would sound like**: UNVERIFIED — no comparable in-house listening test exists. The SoulX-Singer
  spike tests zero-shot *cloning*, not training a new model from scratch, so it will not answer this either.

### (d) A from-scratch in-house model

Concretely, from every figure gathered above: data at the scale actually published for a competitive result
(SoulX-Singer's 42,000+ hours, roughly four orders of magnitude beyond a single voice's worth in every
smaller open dataset — VERIFIED, §2.2); labelling via a bespoke multi-model pipeline built in-house rather
than reused off the shelf, because at industrial scale the words and notes are *not* known in advance the way
DAW Pro's own use case has them (§2.3); compute at an amount nobody in this literature publishes, which is
itself a signal to not assume it's the limiting factor (§2.4); and research/engineering expertise at the
scale of a company founded specifically to work on this one problem for years (Dreamtonics, 2019–present,
REPORTED bio; framed by its own founder, in his own words, as a live "state of the art" research question,
§1.3). **This is not realistic for a small team, and is not recommended.** A small team *assembling* existing
open building blocks — which is actually option (c), or a lighter version of (b) — is realistic. "From
scratch," meaning novel architecture research at Dreamtonics'/SoulX-Singer's scale, is not what a small team
should attempt.

---

## 4. Licensing and ethics

- **Voicebank licences**: fragmented per-voicebank, already established precisely in the 09-24 report
  (Opencpop CC-BY-4.0 + bespoke non-commercial condition; the DiffSinger English-voicebank category exists
  but each entry must be checked individually) — cross-referenced, not redone. **New finding this session**:
  the flagship community **vocoder** (NSF-HiFiGAN, CC BY-NC-SA 4.0 across all three releases checked — v1,
  2024.02, pc-nsf-hifigan 2025.02, VERIFIED this session) is a *separate, additional* non-commercial
  dependency sitting underneath most DiffSinger voicebanks regardless of that voicebank's own license, and its
  **code** repository is separately **AGPL-3.0** (VERIFIED, this session) — and the community's own currently
  -open GitHub issue (#336, unanswered as of 2026-09-22, VERIFIED) shows this question is live and unresolved
  right now, not settled either way. **BigVGAN v2 (MIT, both code and weights, VERIFIED) is a real way out of
  this specific trap**, but was not found already wired into the stock pipeline anywhere checked. **Corrected
  this session**: DiffSinger's own acoustic model *does* support a documented fine-tune mechanism (§3(b)) —
  the missing piece isn't the code, it's a commercially clean pretrained acoustic checkpoint to feed into it;
  none was found (counter-example hunt, next bullet).
- **Model licences, per option**: SoulX-Singer Apache-2.0 code+weights (VERIFIED-2ND, re-confirmed this
  session); DiffSinger/OpenVPI engine code Apache-2.0 (VERIFIED-2ND) *but see the vocoder/voicebank caveat
  above*; NNSVS MIT (VERIFIED-2ND); SOFA MIT (VERIFIED, this session); BigVGAN v2 MIT (VERIFIED, this
  session); `DiffSingerMiniEngine` AGPL-3.0 and archived (VERIFIED-2ND) — already correctly excluded by the
  09-24 report, no new reason to revisit. GTSinger, the largest published open singing dataset, is CC
  BY-NC-SA 4.0 with an explicit *"may not use the material for commercial purposes"* clause (VERIFIED, this
  session) — a data source, not a code dependency, but worth naming alongside Opencpop as another
  commercially-restricted asset in this ecosystem. Synthesizer V itself is proprietary (~$99 app + ~$79/voice,
  REPORTED-2ND pricing), with commercial use included for official voices (VERIFIED, re-confirmed this session
  directly from `dreamtonics.com/synthesizerv/`: *"Synthesizer V Studio 2 Pro and all official Dreamtonics
  voices include commercial use licenses"*) — a bought, closed tool, not a building block for options (b)–(d).
- **Counter-example hunt, run this session specifically to test whether a clean fine-tunable acoustic base
  already exists**: checked openvpi/DiffSinger's current recipe, SoulX-Singer, five Hugging Face SVS
  checkpoints in the ESPnet/GTSinger lineage, and the original VISinger2 repo, TCSinger, and TechSinger. **No
  project found combines a genuinely permissively-licensed acoustic-model checkpoint with documented
  fine-tune code for that checkpoint.** SoulX-Singer ships no training/fine-tune code for its core model at
  all (**VERIFIED, this session**, direct fetch of its README and file tree — *"Official inference code"*
  only, and the training-looking file names in its tree, e.g. `soulxsinger/config/soulxsinger.yaml`, are
  inference configuration, not a training entry point; no `train.py` or equivalent was found). More
  pointedly, **five Hugging Face checkpoints carry MIT or Apache-2.0 license badges that don't survive
  reading their own card or their training data's license** (checked directly this session):
  `espnet/visinger2-zh-jp-multisinger-svs` is badged MIT but its own README says *"This model is for research
  use only and is strictly prohibited for any commercial use"* (**VERIFIED, this session**) — a direct
  self-contradiction. `lanlanliu/espnet_gtsinger_zh_svs1` is badged apache-2.0 but its own card says it was
  *"obtained by training the Chinese portion of the gtsinger dataset"* (**VERIFIED, this session**) — GTSinger
  itself is CC BY-NC-SA 4.0, non-commercial (VERIFIED, §2.2), a direct conflict between badge and disclosed
  training data. `espnet/kiritan_svs_visinger2` is badged apache-2.0 (**VERIFIED, this session**, license
  field only — its card carries no data-provenance prose) and is understood, from this report's own prior,
  already-verified source (`github.com/r9y9/kiritan_singing`, 09-24/09-25 sourcing, VERIFIED-2ND), to be
  trained on the Kiritan corpus, which carries a Japan Copyright Act Article 30-4 usage restriction — the same
  pattern, one step more indirect. `AaronZ345/TCSinger` and `verstar/TechSinger` (code by
  `gwx314/TechSinger`) are both badged MIT (**VERIFIED, this session**); their READMEs (**VERIFIED, this
  session**) tell users to *"prepare your own singing dataset or download GTSinger"* to extend the released
  checkpoint — weaker, softer evidence than the other three that the *shipped* checkpoint itself was trained
  on GTSinger (the wording reads as guidance for further training, not a disclosure of the original training
  set), so these two are flagged as an **unconfirmed, softer version** of the same pattern, not an equally
  solid conflict. **Net lesson, stated precisely**: a Hugging Face MIT/Apache badge in this specific ecosystem
  cannot be trusted at face value — check the model card's own prose and the disclosed training data's
  license every time, five for five this session. One negative claim could not be confirmed either way:
  NNSVS is reported (via search synthesis only, not this report's own fetch) to withhold pretrained
  checkpoints for license reasons except a research-only NIT-song070 model. Two direct fetches this session
  (`nnsvs.github.io`, and `raw.githubusercontent.com/nnsvs/nnsvs/master/README.md`) found no such statement
  — **UNVERIFIED**, neither confirmed nor refuted, flagged rather than dropped or assumed true.
- **Using the user's own voice**: per this codebase's own standing 2026-07-27 ruling (already recorded in the
  09-24 report and this project's own memory), the provenance of any voice supplied is the user's
  responsibility, and their own voice is the default with zero third-party licensing risk by construction.
  **The one precise caveat worth stating plainly**: training on the user's own voice does not launder an
  NC-licensed *vocoder* or *base model* sitting underneath it in the pipeline. Voice provenance and tool/model
  licensing are two separate questions — option (c) is licensing-cleanest of the four **only if** every tool
  in its chain (aligner, pitch extractor, acoustic-model trainer, vocoder) is itself Apache/MIT, which is
  achievable (SOFA + BigVGAN + an Apache/MIT-licensed trainer, and DiffSinger's own trainer code qualifies —
  the corrected §3(b) finding) but must be verified tool-by-tool, not assumed from the voice being the user's
  own; a license-badge alone, per the counter-example hunt above, is not sufficient verification.
- **What would block shipping in a commercial app**: (1) shipping the stock NSF-HiFiGAN vocoder *weights*,
  the Opencpop voicebank, or GTSinger-derived data as-is — all three need the rights-holder contacted first;
  for the vocoder this is a confirmed live block (the open, unanswered issue cited above), not a vague risk.
  (2) copyleft code: `DiffSingerMiniEngine` (AGPL-3.0, already excluded) and, newly found this session,
  `openvpi/vocoders`' own **code** repository (AGPL-3.0, VERIFIED, this session) — distinct from its weights'
  CC BY-NC-SA 4.0 license, and a reason to consume the released weights through DAW Pro's own runtime rather
  than build on openvpi's training/inference code directly. (3) **trusting a Hugging Face license badge
  without checking the card text and training-data license** — five checked this session carried MIT/Apache
  badges that conflicted with one or the other. Everything else checked in this report — SoulX-Singer,
  NNSVS, SOFA, BigVGAN, the DiffSinger engine code itself, and DAW Pro's existing RVC path — is Apache-2.0 or
  MIT and does not itself block shipping; the blocker is always a specific *data, weights, or badge-mismatched*
  artifact, never the code framework.

---

## 5. Comparison table and recommendation

| Option | Effort | $ cost | Risk | License | Quality expectation |
|---|---|---|---|---|---|
| **(a) Integrate SoulX-Singer (zero-shot)** | Medium — epic already scoped, spike running | $0 license, engineering time only | Quality and Apple-Silicon performance unmeasured pending spike | Apache-2.0, code+weights — clean | Unknown pending spike; architecturally the strongest English-capable open option found |
| **(b) Open acoustic model + vocoder in-app, existing voicebank** | Medium–high — ONNX pipeline + a license-clean vocoder swap-in that doesn't exist off the shelf yet | Possibly $ if a commercial voicebank license must be purchased; otherwise $0 | Vocoder/voicebank licensing is a live, currently-unresolved question (VERIFIED, issue #336); acoustic-model fine-tune **mechanism** exists (corrected this session) but no license-clean base checkpoint was found to fine-tune from | Engine clean; **default vocoder weights and flagship voicebank are NOT commercially clean, and the vocoder's own code repo is separately AGPL-3.0**; an MIT fix (BigVGAN) exists but is unintegrated | Reputationally good; English coverage historically thinner than SoulX-Singer's; untested by DAW Pro |
| **(c) Train/fine-tune one voice, user's own singing, this Mac** | High, and importantly **unmeasured** — no MPS/MLX SVS training path confirmed anywhere checked; DiffSinger's own fine-tune **code** exists (corrected this session) but has no license-clean base checkpoint to start from, so this still sizes as a cold-start training run; **labelling itself is cheap (2 tools) because the lyrics/notes are already known** | $0 license (own voice, open tools); real engineering time to build a training pipeline that does not exist off the shelf | Highest technical uncertainty of the four; the parallel, simpler RVC-training-time question is *also* still unmeasured on this Mac | Cleanest possible if every chain tool is Apache/MIT (achievable, not automatic) | Unknown; likely needs **≈4–5 hours**, not minutes, of data for a full SVS model — this report's own inference from Opencpop/GTSinger-per-singer/Namine Ritsu, distinct from RVC's 10–30 min figure |
| **(d) From-scratch in-house model** | Very high — lab-scale, multi-year, per Dreamtonics'/SoulX-Singer's own evident scale | Not realistically estimable; every reference point found (42,000 h of data, a company founded in 2019 for this one problem) points to "large" | Not realistic for a small team | N/A | Not recommended |

### Recommendation and first concrete step

**Do not start a new "build our own" engineering effort yet.** Let the already-running SoulX-Singer spike
(option (a)) finish and report first — its findings (Apple Silicon performance, zero-shot cloning quality on
the user's own voice) directly determine whether (b)/(c) are worth pursuing at all. If (a)'s zero-shot
cloning already sounds acceptable, this entire training-cost question becomes moot for the near term, because
(a) delivers a working voice without paying any of the costs §2 measured.

**If** the spike's quality comes back inadequate, the recommended next concrete step is small and
research-first, not an engineering commitment: **check whether a fine-tunable, Apache/MIT-licensed,
English-capable SVS *acoustic-model* base checkpoint exists at all** — not whether the fine-tune *code*
exists, because it does (DiffSinger's current `main`-branch recipe documents `finetune_ckpt_path` for the
acoustic model directly, corrected this session from a first pass that checked a stale page and got this
wrong) — but whether a checkpoint worth loading into that mechanism, with a genuinely clean commercial
license, exists anywhere. This session's own counter-example hunt checked five Hugging Face candidates that
advertise permissive badges and found every one either says "research use only" in its own card or was
trained on non-commercially-licensed data (GTSinger, Kiritan) despite the badge; it found no clean one. That
does not rule out one existing somewhere unchecked, but it means option (c) should currently be sized as
**"the fine-tune code is free and working, but there is nothing license-clean to fine-tune from yet — plan
for a cold-start training run on the user's own singing,"** which is a materially better starting position
than "the acoustic model trains entirely from scratch, full stop" (a first pass's wrong conclusion), but not
yet the cheap shortcut RVC enjoys either.

**The one part of option (c) that genuinely is cheap and can be scoped now is the labelling step** (§2.3,
§3(c)): forced alignment plus F0 extraction on the user's own recording, two tools, because DAW Pro already
knows the words and the notes. If a cold-start acoustic-model training run is pursued, plan for **≈4–5 hours**
of the user's own clean, labelled singing — the tightest range this report's corpora actually support —
paired with a permissively-licensed vocoder (BigVGAN v2, MIT, VERIFIED) rather than the ecosystem's default
NSF-HiFiGAN (CC BY-NC-SA 4.0 weights, and separately AGPL-3.0 code).

---

## Four facts this report is least sure of

1. **Whether the 2021 sparse-quantized-MVM-kernel description of Synthesizer V's engine (§1.1) still applies
   to the rebuilt Studio 2 engine.** Sourced through a community wiki summarizing a developer social-media
   post, not independently re-opened, and Studio 2 is stated by its own developer to differ significantly in
   architecture from the version that description covers.
2. **The "30 minutes per language is enough" DiffSinger voicebank-training figure (§2.2, §3(c)).** A single
   UtaForum.net community post found via search, not independently opened — the weakest-sourced number in
   the whole report, and the one this report's own inference (§3(c)) argues *against* taking at face value
   for a full-quality result.
3. **Whether a cheap, fine-tunable, license-clean SVS acoustic-model base checkpoint exists anywhere beyond
   the five checked this session.** The fine-tune *code* is confirmed to exist and apply to the acoustic
   model (corrected this session, VERIFIED via `openvpi/DiffSinger`'s current `main` branch) — that part is
   no longer uncertain. What remains genuinely unresolved is the checkpoint: five Hugging Face candidates were
   checked directly and every one's permissive badge conflicted with its own card text or training data's
   license; that is a checked, VERIFIED-this-session absence among five, not a survey of the whole open-SVS
   ecosystem, and a clean one could still exist unchecked.
4. **Whether Hugging Face license badges can be trusted anywhere else in this ecosystem without checking
   further, and whether NNSVS specifically withholds its pretrained checkpoints for license reasons.** Five
   for five badges checked this session didn't survive reading the card or the training data's license — a
   strong but small sample. Separately, a specific claim that NNSVS withholds pretrained checkpoints except a
   research-only exception could not be confirmed by two direct fetches this session (`nnsvs.github.io`, its
   GitHub README); it is left **UNVERIFIED**, neither confirmed nor refuted, rather than imported as fact.

---

## Actionable takeaways

1. **Add a standing research item to `docs/research/README.md`**: *"Does a commercially-clean, Apache/MIT-
   licensed, English-capable pretrained SVS acoustic-model checkpoint exist to fine-tune (the fine-tune code
   itself is confirmed free and working, on DiffSinger's own `main` branch)? Five Hugging Face candidates were
   checked in the 2026-09-25 pass and every one's permissive badge conflicted with its own card text or
   training data's license; NNSVS's own reported restriction could not be independently confirmed. Not a
   survey of the whole ecosystem — check again before sizing option (c) of
   `2026-09-25-build-our-own-singing-voice.md`, and check any new badge's card text and training-data license
   directly, not just the badge."*
2. **Do not commit to option (b) or (c) until the SoulX-Singer spike (§5 above) reports.** Both are gated on
   its result by design, not by omission.
3. **If option (b) is ever pursued, budget a vocoder swap (NSF-HiFiGAN → BigVGAN v2, both fetched and
   confirmed MIT this session) as a first-class, separately-licensed sub-task, not an afterthought** — the
   stock community vocoder's *weights* are a confirmed live-and-unresolved commercial-use question per
   `openvpi/DiffSinger` issue #336 cited in §3(b)/§4, and its *code* repository is separately AGPL-3.0
   (VERIFIED, this session) — two independent reasons to swap, not one.
4. **Carry forward the still-open RVC-training-time gap** (07-11 report's own action item #2: no verified
   M-series-Max training-time number exists) **as a prerequisite for option (c), not a parallel unknown** —
   full SVS training is expected to be at least as hard to time as RVC's simpler voice-conversion training,
   which itself has never been measured on this Mac.
5. **If option (c) is ever scoped, split it into its cheap half and its expensive half rather than costing it
   as one item**: labelling (SOFA + RMVPE on the user's own known-lyrics/known-notes recording) is small and
   bounded; training an acoustic model is the large, currently-unmeasured half — and per the correction above,
   that half is a **cold-start training run sized at ≈4–5 hours of labelled singing**, not a from-scratch
   architecture problem (the fine-tune code exists) and not a 10–30 minute RVC-style adaptation either (no
   license-clean base checkpoint was found to fine-tune from).
6. **Do not size option (d).** Every figure gathered in this report — data scale, labelling pipeline
   complexity at industrial scale, the total absence of published compute figures, and Dreamtonics' own
   multi-year specialist team — points the same direction: not a small-team undertaking.
7. **Before citing any Hugging Face SVS checkpoint's license badge in a future report, read the card's own
   prose and trace its training data's license — do not stop at the badge.** Five for five checked this
   session had a permissive badge that conflicted with one or the other; treat any new badge in this
   ecosystem as unverified until both checks are done.

---

## Primary sources consulted

**Internal (read directly, this repo, read-only):**
- `docs/research/2026-09-24-lyrics-sung-on-a-melody.md`, `docs/design/2026-09-24-p2-sing-spike.md`,
  `docs/research/2026-07-11-vocals-voice-conversion.md` (grepped for training/data/GPU/hour references),
  `docs/research/README.md`

**Synthesizer V / Dreamtonics (fetched 2026-09-25 unless noted):**
- https://dreamtonics.com/synthesizerv/ (local processing, commercial license, "no dedicated GPU" claim, system requirements)
- https://manual.synthv.info/setup/ (VERIFIED, this session: opt-in "AI Retakes" feedback transmits project-data snippets regardless of trial/purchased status)
- https://dreamtonics.com/synthesizer-v-studio-2-pro-2-2-1/ (release notes: P/E-core performance fix, rendering-thread-count setting)
- https://www.native-instruments.com/products/synthesizer-v-studio-2-pro (system requirements)
- https://dreamtonics.zendesk.com/hc/en-us/articles/50217519196057-System-requirements-of-Synthesizer-V-Studio-Version-1
- https://www.recordingmag.com/news/dreamtonics-unveils-synthesizer-v-studio-2-pro/ (VERIFIED, this session, re-fetched: carries the FULL composite sentence, "seamless offline use" variant — not fragments, correcting a first-pass misreading)
- https://futuremusic.com/2026/04/dreamtonics-synthesizer-v-studio-2-pro-review/ (hands-on review; full composite marketing sentence; no quantified numbers of its own)
- https://forum.dreamtonics.com/t/seeking-testers-rendering-performance-issues-with-synthesizer-v-studio-2-pro-2-2-0/7616 (P/E-core-correlated slowdown reports, matches 2.2.1's fix)
- https://forum.dreamtonics.com/t/the-time-has-come-for-gpu-rendering/7450 (VERIFIED, this session: user reports slow 4-part-choir rendering on a 12th-gen i5, requests a CUDA/Tensor Core render path; no staff reply as fetched)
- https://www.dtmstation.com/archives/69769.html (Kanru Hua interview, Studio 2 technical background, Japanese)
- https://www.dtmstation.com/archives/45880.html (Kanru Hua interview, hybrid concept origin, Japanese)
- https://ccrma.stanford.edu/events/singing-voice-synthesis-towards-state-of-art-dreamtonics-inc-tokyo-japan (talk existence only)
- https://www.vocaloidnews.net/vnn-interview-kanru-hua-synthesizer-v/ (checked, no new technical detail)
- SynthV Fandom wiki (`synthv.fandom.com/wiki/Synthesizer_V_Studio`) — HTTP 402 on direct fetch; content reached only via search-engine synthesis, tagged REPORTED throughout, re-sourced to a 2021 Kanru Hua tweet about Studio 1.2

**Training data, labelling, compute (fetched 2026-09-25 unless noted):**
- https://github.com/wenet-e2e/opencpop (README, direct fetch: 5.2 h, 3,756 utterances) + https://arxiv.org/abs/2201.07429 (abstract, singer/song count)
- https://api.github.com/repos/openvpi/vocoders/releases (VERIFIED, this session: all three release bodies — v1 ~93h/Dec 2022/1M+ steps, 2024.02 ~72h/110k fine-tune steps, pc-nsf-hifigan 2025.02 ~79h — all CC BY-NC-SA 4.0)
- https://raw.githubusercontent.com/openvpi/vocoders/main/LICENSE (VERIFIED, this session: AGPL-3.0, the code repo, distinct from the CC BY-NC-SA 4.0 weights)
- https://github.com/openvpi/DiffSinger/issues/336 (live, unresolved commercial-use question, opened 2026-09-22, unanswered as fetched)
- https://api.github.com/repos/openvpi/DiffSinger (VERIFIED, this session: `default_branch: main`)
- https://raw.githubusercontent.com/openvpi/DiffSinger/main/docs/README-SVS-opencpop-e2e.md (VERIFIED, this session: HTTP 404 on `main`)
- https://raw.githubusercontent.com/openvpi/DiffSinger/master/docs/README-SVS-opencpop-e2e.md (VERIFIED, this session, positive control: HTTP 200 on the old `master` branch, MoonInTheRiver-badged legacy content — the page a first pass of this report wrongly treated as current)
- https://raw.githubusercontent.com/openvpi/DiffSinger/main/docs/BestPractices.md (VERIFIED, this session: full "Fine-tuning from existing checkpoints" section, worked example is the acoustic model, no data-amount figure stated)
- https://raw.githubusercontent.com/openvpi/DiffSinger/main/configs/acoustic.yaml (VERIFIED, this session: `finetune_enabled`, `finetune_ckpt_path`, `finetune_ignored_params`, `finetune_strict_shapes` fields present, off by default)
- https://arxiv.org/abs/2409.13832 (GTSinger abstract: 80.59 h, 20 singers, 9 languages) + https://github.com/AaronZ345/GTSinger/blob/master/dataset_license.md (CC BY-NC-SA 4.0, no commercial use)
- https://arxiv.org/pdf/2210.15987 / https://arxiv.org/html/2210.15987 (NNSVS paper: Namine Ritsu 4.35 h, 100 epochs / 600K steps, no GPU stated)
- https://github.com/r9y9/kiritan_singing (labels only, no audio, hours not stated, Japan Copyright Act Article 30-4 restriction noted)
- https://arxiv.org/abs/2105.02446 (original DiffSinger paper — no GPU/compute figures in the fetched content)
- https://arxiv.org/abs/2110.08813, https://arxiv.org/abs/2211.02903 (VISinger, VISinger 2 — no GPU/compute figures found)
- https://arxiv.org/abs/2602.07803, https://arxiv.org/html/2602.07803v1 (SoulX-Singer paper: 42,000+ h, "order-of-magnitude increase," data sourcing not disclosed, no GPU figures)
- https://github.com/Soul-AILab/SoulX-Singer/blob/main/preprocess/README.md (the six-model labelling chain: Mel-Band-Roformer ×2, SenseVoiceSmall, Paraformer, Parakeet-TDT-0.6B-v2, RMVPE, ROSVOT)
- https://raw.githubusercontent.com/Soul-AILab/SoulX-Singer/main/README.md (VERIFIED, this session: "Official inference code" only, Apache-2.0, no training/fine-tune path for the core model)
- https://api.github.com/repos/Soul-AILab/SoulX-Singer/git/trees/main?recursive=1 (VERIFIED, this session: no train/finetune entry point for the core model in the full file tree)
- https://github.com/qiuqiao/SOFA (MIT license)
- https://raw.githubusercontent.com/openvpi/MakeDiffSinger/main/README.md (MFA, MinLabel)
- https://github.com/NVIDIA/BigVGAN, https://raw.githubusercontent.com/NVIDIA/BigVGAN/main/LICENSE, https://huggingface.co/nvidia/bigvgan_v2_24khz_100band_256x (MIT, code and weights)
- UtaForum.net DiffSinger commissioning thread (REPORTED, "30 minutes per language" — single source, not independently opened)
- Search synthesis, `finetune_ckpt_path`/`ft_hifigan.yaml` vocoder fine-tuning reference (REPORTED, not independently opened this session — kept at its original confidence level, not upgraded by the acoustic-model correction)

**Counter-example hunt for a clean, fine-tunable acoustic base (all fetched this session, 2026-09-25):**
- https://huggingface.co/espnet/visinger2-zh-jp-multisinger-svs/raw/main/README.md (badged MIT; own text: "for research use only and is strictly prohibited for any commercial use")
- https://huggingface.co/lanlanliu/espnet_gtsinger_zh_svs1/raw/main/README.md (badged apache-2.0; own text: trained on "the Chinese portion of the gtsinger dataset," which is CC BY-NC-SA 4.0)
- https://huggingface.co/espnet/kiritan_svs_visinger2/raw/main/README.md (badged apache-2.0; no data-provenance prose on the card itself — conflict inferred via the Kiritan-corpus source already cited above)
- https://raw.githubusercontent.com/AaronZ345/TCSinger/main/README.md and https://huggingface.co/AaronZ345/TCSinger (badged MIT; README recommends but does not confirm the shipped checkpoint was trained on GTSinger — weaker evidence, flagged as such)
- https://raw.githubusercontent.com/gwx314/TechSinger/main/README.md and https://huggingface.co/verstar/TechSinger (badged MIT; same weaker GTSinger-recommendation pattern as TCSinger)
- https://nnsvs.github.io and https://raw.githubusercontent.com/nnsvs/nnsvs/master/README.md (checked directly for a "pretrained models are research-only" statement; not found — UNVERIFIED, not confirmed or refuted)

---

## Corrections, 2026-09-25 fact-check

An adversarial fact-check of this report's first pass (same day) ran 14 claim checks across two independent
lenses each, plus a counter-example hunt for a clean fine-tunable acoustic base. Every verdict in that check
came from a fresh fetch of the primary source; this correction pass then independently re-fetched the
load-bearing sources itself (see the sources list above) rather than importing the fact-check's findings
untested. Seven corrections follow, numbered to match the fact-check's own claim groups, plus one additional
label-honesty correction found while re-fetching.

1. **DiffSinger fine-tuning (the significant one — changed a recommendation, not just a detail).**
   Old (§3(b), §3(c), §4, §5, recommendation, least-sure list, takeaways, sources — throughout): *"DiffSinger's
   own primary training recipe (`docs/README-SVS-opencpop-e2e.md`, VERIFIED, direct fetch) documents training
   the acoustic/variance model **entirely from scratch** — no `finetune_ckpt_path` or equivalent option is
   present for it... No evidence was found... of a cheap 'fine-tune an acoustic model onto a new voice' path."*
   New: DiffSinger's *current* `main`-branch recipe (`configs/acoustic.yaml` + `docs/BestPractices.md`)
   documents `finetune_enabled`, `finetune_ckpt_path`, `finetune_ignored_params`, `finetune_strict_shapes` for
   the acoustic model directly, with a full worked "Fine-tuning from existing checkpoints" example. The cited
   file, `docs/README-SVS-opencpop-e2e.md`, 404s on `main` and exists only on the stale `master` branch /
   upstream `MoonInTheRiver/DiffSinger`. The corrected conclusion: the fine-tune *mechanism* exists and is
   Apache-2.0; what's missing is a commercially clean pretrained *acoustic* checkpoint to start from (none
   found among five candidates checked). Source: `raw.githubusercontent.com/openvpi/DiffSinger/main/docs/BestPractices.md`,
   `raw.githubusercontent.com/openvpi/DiffSinger/main/configs/acoustic.yaml`, `api.github.com/repos/openvpi/DiffSinger`
   (fetched 2026-09-25, this session).
2. **Hours per voice.**
   Old (§0): *"Open research voices run 5 to 80 hours each."*
   New: *"Every open research corpus this report checked gives roughly 4 to 5 hours of audio per voice... not
   the '5 to 80 hours' a first pass of this report said, which mistook one dataset's 80.59-hour total across
   20 singers (about 4 hours each) for a single big voice."* Source: GTSinger arXiv abstract 2409.13832 (80.59
   h / 20 singers = ≈4.0 h/singer, INFERRED arithmetic), cross-checked against Opencpop (5.2 h, 1 singer) and
   Namine Ritsu (4.35 h, 1 singer) — all previously fetched, re-cited here with the arithmetic corrected.
3. **NSF-HiFiGAN vocoder.**
   Old (§2.2 table, §2.4, §3(b), §4): *"~93 h ... CC BY-NC-SA 4.0"* stated as if it were the only release, and
   no mention anywhere of the code repository's own license.
   New: three releases exist and were all checked — v1 (Dec 2022, ~93 h), 2024.02 (~72 h), pc-nsf-hifigan
   2025.02 (~79 h) — all CC BY-NC-SA 4.0 for the weights. The `openvpi/vocoders` **code** repository is
   separately **AGPL-3.0**, added throughout §2.2/§3(b)/§4/§5/takeaways as a distinct restriction from the
   weights' license. Source: `api.github.com/repos/openvpi/vocoders/releases` and
   `raw.githubusercontent.com/openvpi/vocoders/main/LICENSE` (fetched 2026-09-25, this session).
4. **SynthV and the graphics card.**
   Old (§0, §1.1 net read): implied "no dedicated GPU or acceleration hardware required" as close to "cheap to
   run" without qualification, and did not connect that claim to the multi-voice AI Choir feature.
   New: added, in §0 and §1.1's net-read paragraph, that "no dedicated GPU required" rules out a *mandatory*
   discrete GPU, not optional GPU/Neural Engine use (a hedge §1.1 already carried but the summary dropped),
   plus a new finding: a Dreamtonics forum thread has a user reporting slow multi-part-choir rendering on a
   12th-gen Intel Core i5 and requesting a CUDA/Tensor Core render path, unanswered by staff — "cheap to run"
   is shown for one voice, not for the choir feature. Source:
   `forum.dreamtonics.com/t/the-time-has-come-for-gpu-rendering/7450` (fetched 2026-09-25, this session).
5. **recordingmag.com.**
   Old (§1.1): *"`recordingmag.com/...` returns the same claim in fragments... rather than the single
   composite sentence."*
   New: recordingmag.com carries the full composite sentence, with "seamless" inserted before "offline use" —
   not fragments. Source: `recordingmag.com/news/dreamtonics-unveils-synthesizer-v-studio-2-pro/` (re-fetched
   2026-09-25, this session): *"Up to 300% faster rendering speed – without requiring a dedicated GPU or
   acceleration hardware, allowing for seamless offline use."*
6. **Local processing caveat.**
   Old (§1.1): stated the trial-voice data-upload caveat as the only exception to "does not upload your
   creative content to servers."
   New: added a second, opt-in channel — Studio 2 Pro's "AI Retakes" feedback feature sends snippets of
   project data (note duration, pitch, phoneme data, voice database) to Dreamtonics when a user opts in and
   hearts a retake, regardless of trial/purchased status. Rendering itself remains local; this is a nuance on
   top, not a contradiction. Source: `manual.synthv.info/setup/` (fetched 2026-09-25, this session).
7. **Counter-example hunt: the conclusion survives, with a new caution.**
   Old: no equivalent section existed in the first pass (the first pass's own fine-tune claim was itself
   wrong, per correction 1, so no hunt for a base checkpoint was meaningful yet).
   New: added to §4 and referenced from §3(c)/§5/least-sure/takeaways — five Hugging Face SVS checkpoints
   carry MIT/Apache-2.0 badges that conflict with either their own card text ("research use only") or their
   training data's license (GTSinger CC BY-NC-SA; Kiritan's Article 30-4 restriction):
   `espnet/visinger2-zh-jp-multisinger-svs`, `lanlanliu/espnet_gtsinger_zh_svs1`, `espnet/kiritan_svs_visinger2`,
   `AaronZ345/TCSinger`, `verstar/TechSinger` (the latter two on weaker, unconfirmed evidence — their own
   cards only recommend GTSinger for further training, not confirm the shipped checkpoint's own training set).
   SoulX-Singer confirmed Apache-2.0 for code+weights but ships no training/fine-tune code for its core model.
   The NNSVS "pretrained models are research-only" claim was attempted twice this session
   (`nnsvs.github.io`, its GitHub README) and could not be confirmed — left **UNVERIFIED**, not imported as
   fact. Sources: listed in the "Counter-example hunt" block above (all fetched 2026-09-25, this session).
8. **Label-honesty correction, found while re-fetching (not one of the seven, added on my own initiative).**
   Several claims a first pass tagged **VERIFIED** turned out, on re-fetch, to rest on a page that wasn't
   actually the source it claimed to be current (correction 1) or to be misread (correction 5). Every VERIFIED
   tag touched by this correction pass has been re-earned by an actual fetch this session, marked "VERIFIED,
   this session" to distinguish it from the first pass's own (sometimes wrong) VERIFIED tags. Anything drawn
   from the fact-check JSON itself but not independently re-fetched this session — e.g. a specific claim that
   pc-nsf-hifigan 2025.02 is "what the ecosystem uses now," or that Hugging Face's `--init_param` mechanism
   applies to a given ESPnet recipe — was deliberately **not** imported as fact and does not appear in this
   report; the fact-check's own two lenses flagged those as suggestive synthesis, not confirmed findings, and
   this pass respected that distinction rather than upgrading it.
