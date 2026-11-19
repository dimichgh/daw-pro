# Music to MIDI: is MuScriptor better than what we have, and can it turn sung vocals into notes?

Date: 2026-10-12. Lane W9-MUSC. Research only: nothing was installed, no weights downloaded, no licence accepted, no account made.

Evidence labels: **VERIFIED** = read on the cited page today. **INFERRED** = my reasoning. Web pages were read through a summarising fetch tool, so every number below should be re-read against the PDF before it is quoted outside this repo (flagged as **UNCHECKED-AGAINST-PDF**).

## The short answer (for a non-musician)

1. **MuScriptor is a real, strong "audio to MIDI" model for full bands, but we are not allowed to ship it in the app.** Its model files are licensed for non-commercial use only, and the download is locked behind a sign-in and a licence you have to accept. Its terms also forbid transcribing music you do not have the rights to.
2. **It is not shown to be better for singing.** The paper reports no singing-specific result. The one choir test it ran (Dagstuhl ChoirSet) shows it finding note starts *worse* than the older YourMT3+ (14.4 vs 22.3 note-start F1, UNCHECKED-AGAINST-PDF).
3. **For sung vocals there are better-targeted tools, and one of our own is already in the app.** Our SwiftF0 + note-splitter path has never been scored against known answers. The right next step is a measurement on audio where we know the correct notes, not a swap.
4. **Recommendation: evaluate only (on our own machine, with a licence acceptance by you), do not adopt.** Details and the decisions that need your word are in the last section.

## 1. What MuScriptor really is

- Multi-instrument transcription: audio in, MIDI (and MusicXML / sheet-music PDF via MuseScore) out. Decoder-only transformer, three sizes: small 103M, medium 307M (default), large 1.4B parameters. Apple Silicon runs on Metal (MPS) automatically; large wants a GPU. VERIFIED: https://github.com/muscriptor/muscriptor
- Authors Rouard, Krause, Roebel, Simon-Gabriel, Defossez; ISMIR 2026 camera-ready; arXiv 2607.08168 (paper is CC BY 4.0). VERIFIED: https://arxiv.org/abs/2607.08168
- Method (VERIFIED, same abstract): pre-train on synthetic audio, fine-tune on real recordings, then reinforcement learning. You can tell it which instruments to look for.
- Training data (VERIFIED, https://arxiv.org/html/2607.08168): about 1.45 million MIDI files rendered with 250+ soundfonts; 170,000 real recordings (11,000+ hours) with aligned notes; 300 tracks for RL; 372 held-out test tracks. 36 instrument groups. "Voice" is one group in the data, but "no vocal-specific results are reported".
- Known limits stated by the authors (VERIFIED, model card https://huggingface.co/MuScriptor/muscriptor-medium): no velocity/dynamics; cannot write two notes of the same pitch and instrument sounding together; data skews to pop and Western classical.

### Reported numbers (UNCHECKED-AGAINST-PDF; from https://arxiv.org/html/2607.08168)

On their own 372-track test set, 1.3B model, final stage: onset F1 60.4, frame F1 73.3, offset F1 49.0. YourMT3+ on the same set: onset 32.5, frame 45.5, offset 17.8. Caveat the authors state: overlapping same-pitch notes were removed for scoring; with them kept, onset F1 falls 60.4 to 51.8. The test set comes from the same pool as their training data ("D_Real"), so this flatters MuScriptor (INFERRED).

Public benchmarks, onset F1, YourMT3+ vs MuScriptor:

| Dataset | What it is | YourMT3+ | MuScriptor |
|---|---|---|---|
| Bach10 | 4-part classical, played | 59.8 | 43.1 |
| Dagstuhl ChoirSet | **sung choir** | 22.3 | **14.4** |
| PHENICX-Anechoic | orchestra | 56.7 | 56.1 |
| RWC-P (pop) | | 36.1 | 46.1 |
| RWC-C (classical) | | 71.7 | 67.7 |
| RWC-G / J / R | | 36.9 / 52.9 / 46.1 | 44.7 / 59.4 / 47.1 |

Reading: MuScriptor wins clearly on its home turf and on pop/genre sets, ties or loses on classical and on the only sung set, and it is much better at "how long the note lasts" (frame F1 80.7 vs 51.0 on the choir). Choir singing is not solo lead vocals, so this is weak evidence either way (INFERRED). Basic Pitch was not in the paper's comparison, so "better than Basic Pitch" is unmeasured by the authors.

## 2. Licence consequences in plain words

VERIFIED from the model cards (https://huggingface.co/MuScriptor/muscriptor-small and -medium): weights are CC BY-NC 4.0, **gated** (you share contact info and accept conditions while logged in to Hugging Face), with extra terms: prohibited use includes "inputting music files and transcribing them to MIDI/music sheet without having all the necessary rights, including intellectual property rights"; you must warrant you have those rights for input and output; you indemnify Mirelo and Kyutai. The code is MIT, which does not help, because the weights are what does the work.

What that means:
- **Trying it yourself on your own recordings or ones you have rights to:** allowed after you accept the licence. That acceptance is yours to give, not ours.
- **Bundling the weights in DAW Pro, free or paid:** not allowed. "Non-commercial" would almost certainly cover a paid app, and distributing the file to users is the part the licence never granted (INFERRED; not legal advice).
- **Downloading on the user's behalf:** the gate requires the end user's own account and acceptance, so the app could at most guide users to do it themselves. It would also be an app feature that asks users to promise they own the rights to every song they drop in.
- **Commercial licence:** the card says contact the developers; no price or process is published (VERIFIED: nothing found).

## 3. Alternatives (the ones that could ship are marked)

| Tool | Does | Code licence | Weights licence | Size / Mac feasibility | Accuracy evidence |
|---|---|---|---|---|---|
| **Basic Pitch** (Spotify) | any single instrument or voice, polyphonic, + pitch bends | **Apache 2.0** | ships with the package (same repo licence, VERIFIED repo page) | ~17K parameters (secondary source); **CoreML, ONNX, TFLite builds already in the package** | Slakh note F 0.43 vs MT3 0.57 vs YourMT3+ 0.85 (secondary aggregator hyper.ai; UNCHECKED). Repo itself says it "works best on one instrument at a time" |
| MT3 (Google) | multi-instrument | Apache 2.0 (INFERRED, not re-read today) | checkpoints published by Google (licence not re-read) | 77M; JAX/T5X, hard on Mac | Slakh 0.57 (see above) |
| YourMT3 / YourMT3+ | multi-instrument, includes vocals | **GPL-3.0** (VERIFIED, https://github.com/mimbres/YourMT3) | not re-read | PyTorch | the best open baseline in the MuScriptor paper |
| **ROSVOT** | solo singing to MIDI | **MIT** (VERIFIED, https://github.com/RickyL-2000/ROSVOT) | checkpoints trained on M4Singer only (a Mandarin dataset) | Python 3.9, PyTorch 2.1.1, CUDA 11.8 in docs; Mac conversion untested | COn F 94.0 / COnPOff 77.4 clean on its own M4Singer test, vs 65.8 for the previous best (https://arxiv.org/html/2405.09940v2). Out-of-domain (MIR-ST500, TONAS) only in an appendix, no full numbers |
| SOME | solo singing to MIDI | MIT | **CC BY-NC-SA 4.0** (VERIFIED, https://github.com/openvpi/SOME/releases). Repo says it is superseded by GAME | "9x real time on an i5 CPU" | none published in README |
| GAME | solo singing to MIDI, successor to SOME | MIT (VERIFIED, https://github.com/openvpi/GAME) | **CC BY-NC-SA 4.0** (VERIFIED, https://github.com/openvpi/GAME/releases) | 12M / 50M / 100M parameters; **ONNX provided** (opset 17) | none published in README; also carries a "no impersonation" use clause |
| Ours: SwiftF0 + splitter | solo voice, one note line | MIT (`Sources/DAWEngine/Analysis/Resources/VENDORED.md:12`) | 397,987 bytes, bundled | already running, 62.5 frames/s | not benchmarked against known notes |

Not verified at all this session: VOCANO, MIR-ST500 benchmark scores for any tool, MT3's checkpoint licence, any Basic Pitch singing score. Treat as open.

**Consequence (INFERRED):** the only shippable-by-licence candidates are Basic Pitch (Apache 2.0, polyphonic but weak) and ROSVOT (MIT, singing, but trained on one Mandarin dataset). The two newest high-quality singing models (SOME, GAME) and MuScriptor are non-commercial. YourMT3 is GPL-3.0, which would force the whole app open if linked in; running it as a separate user-installed tool would be a different question for a lawyer.

## 4. What the app already does (read in the repo)

- There is **no polyphonic audio-to-MIDI** anywhere in the app. Searches for Basic Pitch, MuScriptor and "vocal to MIDI/notes" in `docs/` returned nothing (grep with a files-found output; the control for this shape of search was the other greps in this session returning hits).
- Pitch detection: `SwiftF0PitchTracker` (`Sources/DAWEngine/Analysis/PitchTracker.swift:379`), 16 kHz model rate (`:382`), hop 256 giving 62.5 frames/s (`:385`, `:197`). Analysis wrapper: `ClipPitchAnalyzer` (`Sources/DAWEngine/Analysis/ClipPitchAnalyzer.swift:46`). One pitch per instant, so it is a single-voice tool by design.
- Voiced stretches: `PitchAutoCorrect.voicedRuns` (`Sources/DAWCore/PitchCorrection.swift:3892`); shortest note 60 ms (`:3881`).
- Splitting a run into notes: `PitchNoteSplitter` (`Sources/DAWCore/PitchNoteSplitter.swift:111`), a rule-based plateau scan (steps 1 to 6 documented at `:85-105`), plus the note table `PitchNoteTable.detected` (`Sources/DAWCore/ProjectStore+PitchNoteEdits.swift:1309`). CHANGELOG entry "a sung phrase becomes notes" is dated 2026-09-24 (`CHANGELOG.md:252`).
- Known weakness, ROADMAP `p2-sing-x9-f4` (`docs/ROADMAP.md:3568`): measured pitch-dependent bias from +4.7 cents at MIDI 52 to -16.4 cents at MIDI 77 on synthetic tones, and two confidence holes (MIDI 71 and 78). Agreement with an independent instrument on real voice was within one note.
- There is **no command that turns a vocal clip into a MIDI clip** (task brief; not re-verified by me beyond the grep above).
- Important gap (INFERRED): the existing splitter was tuned to *editing and correcting* a take. Nobody has scored its note boundaries against known notes, so we do not know our own baseline.

## 5. A bake-off we can run ourselves

Everything below is a plan; none of it was run. Scoring: `mir_eval.transcription` note-level precision/recall/F1, onset tolerance 50 ms, pitch tolerance 50 cents, reported both **without** offsets and **with** offsets (offset tolerance max(50 ms, 20% of note length), the library default). Plus wall-clock seconds per minute of audio on this Mac, and peak memory.

Ground truth sets (we generate the answers, so no one can argue about what the right notes were):
- **A. Our built-in singer on known MIDI:** the "Light On" lead melody and the male/female material under `$S/w9/MF/` (e.g. `control/decoupled-melody-written.wav` and the `-octave-down` pair). The MIDI used to make the audio is the truth. Caveat: synthetic singer, so it is easier than a human; also the same-voice-twice structure of the MF files means they test pitch-shift robustness, not new tunes.
- **B. Multi-instrument renders of known MIDI** with our own instruments and GM kit (piano + bass + drums + pad). Truth is the MIDI. Caveat: MuScriptor trained on 250 soundfont renders, so synthetic renders flatter it (INFERRED); this set shows ceilings, not real-world performance. Add a few real recordings the user owns, scored by ear and by a human-marked key-note list.
- **C. VocalSet scales and arpeggios** (CC BY 4.0, real human singers). Truth: the prescribed scale/arpeggio notes, which are known to be a fixed pattern; onsets must be hand-aligned for a handful of files since the dataset has no note labels (INFERRED, check the dataset docs before relying on this).

Contestants:
- Vocal sets A and C: ours (SwiftF0 + splitter) as baseline; ROSVOT (MIT); Basic Pitch (Apache); MuScriptor small/medium (evaluation only, local, never committed).
- Polyphonic set B: baseline is "none", so compare Basic Pitch against MuScriptor medium.

Decision rule (proposed): if MuScriptor beats ours by at least 10 points of note-onset F1 on C, that is real information about how much headroom exists, and the next question is whether a permissive model (ROSVOT, or training our own with the MIT-licensed GAME/SOME code on licensed data) can capture it. If the gap is small, drop the topic.

Safety for the run: sandboxed Python venv under the scratchpad, weights only in a scratch cache, no tokens in the repo, ACE sidecar kill after each model test if one is loaded, never port 17600.

## Actionable takeaways

1. **Do not add MuScriptor to the product, bundle its weights, or auto-download them.** Reason: CC BY-NC 4.0 plus the "own the rights to every input" clause (section 2).
2. **Run the bake-off as a scratch experiment**, route `research-analyst` for scoring scripts, with the user's licence acceptance (needs their word, see below). Also score our own baseline first: that costs nothing, needs no licence, and answers "is our vocal path good enough?" by itself.
3. **Ship a "vocal clip to MIDI notes" command regardless**, built on `PitchNoteTable.detected` (`ProjectStore+PitchNoteEdits.swift:1309`). New control command + MCP tool + test per CLAUDE.md. Do not wait for any model.
4. **Add the fixed-pitch calibration from `p2-sing-x9-f4`** to the bake-off as an extra column: how many of our errors are the known cents bias rather than segmentation.
5. **If a polyphonic feature is wanted for sale, the realistic ship path today is Basic Pitch** (Apache 2.0, CoreML build exists) as a "rough sketch" tool, with honest labels, or a request for a commercial licence from the MuScriptor authors. ARCHITECTURE note: a model-runner behind a provider-style protocol in `Sources/AIServices` so models are swappable.
6. **If we ever want better singing transcription we may ship:** evaluate ROSVOT's generalisation (it was trained on one Mandarin set) before relying on it; SOME and GAME weights are non-commercial, so they are references, not options.

## What needs the user's word

- Accepting the MuScriptor licence with a Hugging Face account (and its "I own the rights to what I transcribe" promise) to run the evaluation. Nothing can proceed on that without you.
- Whether DAW Pro will be sold. That is what turns "non-commercial" from a footnote into a blocker for every NC-weighted tool above.
- Disk and download budget: small/medium/large sizes were not stated on the pages read (the model pages show parameters only: 0.1B / 0.3B / ~1B-1.4B); check before approving a download.
- Whether to contact the MuScriptor team about a commercial licence.

## Sources

- https://github.com/muscriptor/muscriptor
- https://arxiv.org/abs/2607.08168 and https://arxiv.org/html/2607.08168
- https://huggingface.co/MuScriptor (and muscriptor-small, -medium)
- https://github.com/spotify/basic-pitch
- https://github.com/mimbres/YourMT3
- https://github.com/RickyL-2000/ROSVOT and https://arxiv.org/html/2405.09940v2
- https://github.com/openvpi/SOME (releases) and https://github.com/openvpi/GAME (releases)
- Slakh numbers for Basic Pitch: secondary aggregator at https://hyper.ai/fr/sota/tasks/music-transcription/benchmark/music-transcription-on-slakh2100 (unchecked)
