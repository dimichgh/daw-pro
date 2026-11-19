# p2-sing expansion: words on notes, harmonies, vibrato and breath, other languages, and extras

**Status: SETTLED BY DESIGN 2026-10-06 (lane W8-SX, `daw-architect`). NOT BUILT.** No product code changed while
writing this. Two capability probes ran against the INSTALLED singing engine (its own venv python, no sidecar, no port,
outputs only in the lane's scratch folder); their numbers are tagged [M] below and listed in §13.

**Extends** `docs/design/2026-09-27-p2-sing-integration.md` (the "base design"), including its 2026-10-05 errata. Where the
two differ, this document wins for the NEW features only; every rule of the base design that a new feature does not
touch stays as written. §11 lists every departure and its reason.

**Why this exists.** The user asked: "can we add missing UI and also expand it to support harmonies and per-note vibrato
or breathiness controls and what does it take to support other languages?", and then: **"so all of these and more if
it enriches our functionality without impact to main functionality"**. So the hard constraint is **no impact**: every
new thing is additive and opt-in, and every existing request, render, file and wire reply stays byte-identical when the
new things are not used (§9 is the gate that proves it).

**Evidence tags** (the base design's, unchanged):

| Tag | Meaning |
|---|---|
| **[M]** | Measured, with where. "[M, under load]" = measured while other lanes were building on this Mac, so a time is an upper bound, never a clean timing. |
| **[R]** | Read in source: `path:line`. `Sources/DAWControl/Commands.swift` is cited by **case label** and `mcp-server/src/server.ts` by **tool name** (other lanes edit both). Upstream SoulX-Singer is cited at the INSTALLED copy, `~/Library/Application Support/DAWPro/SingingEngine/upstream/` at commit `81aeb3ae772c70093c3de74dc23c92d983801ae4`, written `upstream/<path>:<line>`. |
| **[D]** | Derived by arithmetic from measured inputs. |
| **[A]** | Assumed or chosen, not measured. Every [A] number says what replaces it. |

---

## 0. In plain words (for the person who will use it)

- **Typing a word onto a note.** Click a note in the Sing sheet's note strip and type the word it should sing. DAW Pro
  rewrites the words box for you, so the box and the notes can never disagree. Typing everything into the one box still
  works exactly as before.
- **Harmonies.** DAW Pro can sing a second (and third) line with the same words: either a tune you draw yourself, or one
  it works out from your melody, such as "a third above" or "a sixth below". Each line lands on its own new track,
  a little quieter and a little to the side, so you can turn it up, down or off. Each extra line takes about as long to
  sing as the melody did.
- **Vibrato (the wobble on long notes).** Pick "As sung", "Straight", "Gentle", "Normal" or "Wide", for the whole vocal or
  for single notes. DAW Pro applies it to the finished vocal with the same tool the pitch editor uses, so you can still
  fine-tune any note afterwards without singing again.
- **Breathiness.** The singing engine itself has no breathiness control (we checked its code). DAW Pro adds a soft
  "air" layer to the notes you choose instead. It is off unless you turn it on.
- **Other languages.** The engine was trained on English, Mandarin Chinese and Cantonese. Mandarin and Cantonese need no
  extra download: the tools that turn Chinese characters into sounds are already installed with the engine, and a
  Mandarin line already sang in our test. Languages the engine never learned (Spanish, for example) can only be
  imitated with English sounds, so they would sound English-accented; they come later, marked "experimental".
- **Extras we recommend:** "ooh" and "aah" backing with no words; "Write words for me" that fit your tune's notes;
  double-tracking (a second take panned to the side, for a fuller sound); spelling a tricky name the way it sounds; and
  the word chips lighting up while the melody plays, so you can check the words land right before singing.
- **Nothing you have today changes.** If you never touch these, every song, saved file and sound stays exactly as it
  is now, byte for byte. That is tested, not promised (§9).

---

## 1. The decisions on one page

1. **Per-note lyric typing is a TEXT EDIT, never a stored assignment.** The base rule stands: only the text is stored and
   the word-to-note assignment is derived (base §3.1). Typing on a note runs a pure `LyricTextEdit` that rewrites the text
   with explicit markup (`+` and hyphen parts) so the derivation reproduces exactly what the user sees, and then
   re-derives and checks it (§3). No new stored field, so no old file can break.
2. **Harmonies are N monophonic renders in one job, landed as N new tracks in ONE undo.** The facade stays monophonic
   (`scripts/sing/singlib/schema.py:178-186` refuses overlap) [R]. A part comes from another MIDI clip, from the melody
   clip's own chords, or from a pure `HarmonyPlanner` (diatonic or chord-tone third/sixth above or below) (§4).
3. **Per-note vibrato, level and breathiness are a POST-RENDER layer**, chosen on the probe evidence (§5.2):
   - vibrato and per-note level are written into the landed clip's pitch-edit table (`PitchEditSet`) in the SAME undo
     step as the landing, with the store's existing one-clamp code, so the pitch editor can edit them afterwards;
   - breathiness is an offline "air" layer mixed into the take at assembly, before the loudness gain;
   - the engine stays in score mode. The engine route (melody mode with a synthesised pitch curve) WORKS [M] and is
     designed (§5.5), but ships only if listening Round VR picks it over the post-render route.
4. **Languages are carried by `ClipLyrics.language` (absent = English)** and phonemised in the facade by a per-language
   registry. Mandarin (`g2pM`) ships first, Cantonese (`ToJyutping`) second; both libraries are already in
   `scripts/sing/requirements.lock` and the installed venv [R][M]. Spanish through English phones is experimental and
   last (§6).
5. **The facade gets an optional `facadeVersion: 2`.** A v1 body is validated, converted and passed to `model.infer`
   byte-identically; the client sends 2 ONLY when a v2 key is present, so the base §4.3 cache key of every existing
   phrase is unchanged (§7).
6. **Enrichments, ranked by value to a novice ÷ cost, cut after rank 7** (§8): ooh/aah without words, word chips
   lighting up during playback, lyrics written to fit the tune, double-tracking, "sounds like" spelling, chord-tone
   harmony, dynamics from note velocity. Below the cut: a per-word listen button, translating lyrics, a choir preset,
   breath sounds between phrases.
7. **No full Xcode, entitlement, signing or render-thread change is needed** (§12).
8. **Items `p2-sing-x1`…`x11`** slot after base items e (wire) and f (UI); five of them (x1-x5) can be built before the base UI
   lands (§10).

---

## 2. What the engine can and cannot do (the four upstream questions, answered with evidence)

All reads are of the INSTALLED engine (commit `81aeb3a…`, verified with `git rev-parse HEAD` and `install.json`'s
`commit`) [M]. The probes are described in §13.2; their scripts and raw outputs are in the lane's scratch folder, not in
the repo.

### 2.1 `control`, and pitch curves (f0)

**What `control` accepts.** Exactly `"score"` and `"melody"`; anything else raises `ValueError`
(`upstream/soulxsinger/models/soulxsinger.py:121-132`; the CLI checks the same two at `upstream/cli/inference.py:66-67`)
[R]. Note that `infer()`'s own DEFAULT is `"melody"` (`soulxsinger.py:110`) and so is the CLI's (`cli/inference.py:146-152`)
[R]; the facade's explicit `control="score"` (`scripts/sing/singlib/engine.py:257-258`) is load-bearing.

**What each mode reads.**

| Mode | Uses | Zeroes | Needs in the metadata |
|---|---|---|---|
| `score` | note pitch (target AND prompt) | both f0 curves: `gt_f0 = pt_f0 = None`, then zeros (`soulxsinger.py:121-125, 150-151`) | `duration`, `phoneme`, `note_pitch`, `note_type`. An `f0` key is ignored (only `DataProcessor`'s length truncation can see it) |
| `melody` | f0 (target AND prompt) | both note-pitch sequences (`soulxsinger.py:126-130, 152-153`) | the same four keys plus `f0` on the target AND on the prompt |

**A target can carry an f0 curve.** Format: the metadata key `"f0"`, a space-separated string of Hz values, one per mel
frame; `0` means unvoiced (`upstream/soulxsinger/utils/data_processor.py:152-154`) [R]. The rate is one frame per
`hop_size / sample_rate` = 480 / 24000 = **20 ms (50 frames per second)** (`upstream/soulxsinger/config/soulxsinger.yaml`,
`audio.hop_size: 480`, `sample_rate: 24000`) [R]. The model hears it quantised to **20-cent bins from C1 (32.70 Hz),
361 bins** (`soulxsinger.py:64-92`, `f0_bin: 361`) [R], so a ±50 c vibrato spans about five bins.

Two traps, both read in source and both made into refusals or tests below:

- **A short f0 truncates the whole target.** `DataProcessor.process` cuts `mel2note` to `min(frames, len(f0))`
  (`data_processor.py:152-155`) [R]. A synthesised curve must have at least as many frames as the phrase has mel frames.
  The facade's own test hook already pads by +5 (`scripts/sing/singlib/score.py:120-122`) [R].
- **Melody mode with a missing PROMPT f0 sings with no pitch at all.** `if gt_f0 is None or pt_f0 is None` sets BOTH
  curves to zero, and melody mode has already zeroed both note-pitch sequences (`soulxsinger.py:150-153`) [R]. So an own
  voice (whose prompt has no f0 today, base §3.7 step 9) can never be sent in melody mode without a prompt curve:
  refusal `promptF0Missing` (§7.4). The built-in voice's shipped `prompt.json` carries 519 f0 values for its 10.37 s
  window [M: read from the installed `voices/builtin-1/prompt.json`, positive-controlled against upstream's
  `example/audio/zh_prompt.json`, also 519]; 518 frames reached the model after truncation [M, probe P-A].

**Can score mode and an f0 curve combine?** **Not through `infer()`: it is either/or** (the table above) [R]. The model's
features ADD a note-pitch embedding and an f0 embedding (`soulxsinger.py:179, 183`) [R], and the technical report says
training "randomly dropped" either input (`upstream/assets/technical-report.pdf`, §2.2.1, "Melodic Representation";
pdftotext lines 259-264) [R]. A copy of `infer()` that keeps both ("hybrid") is therefore possible, and the probe ran one:

| Probe P-A render (T1, built-in voice, seed 20260924, 32 steps, cfg 3) | Pitch error, median \|cents\| (pyin / harvest) | Within ±50 c (pyin / harvest) | Long notes: wobble RMS (pyin / harvest) | Wobble rate (pyin / harvest) |
|---|---|---|---|---|
| A1 score (today's path) | 10.6 / 14.1 | 0.914 / 0.874 | 24-46 c / 76-99 c ⚠️ | 3.6-3.9 / 3.1-3.9 Hz |
| A1s score, seed + 1 | 10.6 / 16.9 | 0.916 / 0.843 | 20-24 c / 35-40 c | 6.4-6.5 / 6.4-6.7 Hz |
| A2 melody, flat curve from the notes | 0.6 / 3.4 | 1.000 / 0.996 | 5 c / 6-8 c | — |
| A3 melody, curve + vibrato 5.5 Hz ±60 c on the two 1.2 s notes | 0.6 / 4.7 | 0.992 / 0.916 | 30-31 c / 42 c (≈ 42-43 c / 59-60 c as a sine depth) | 5.37-5.42 / 5.47 Hz |
| A4 hybrid (both inputs), same curve | 0.6 / 5.1 | 0.993 / 0.918 | 29-30 c / 41-42 c | 5.37-5.42 / 5.47 Hz |
| A0 score with an `f0` key on the target | identical bytes to A1 (same sha256 prefix `8d80961487fd638a`) | | | |

[M, probe P-A, two pitch instruments: `librosa.pyin` (85 ms frames, 10-cent bins) and `pyworld.harvest`+`stonemask`
(5 ms)]. What the table says, and what it does not:

- **Melody mode follows a synthesised curve closely**: asked 5.5 Hz ±60 c, got 5.37-5.47 Hz and 42-60 c by the two
  instruments. The pyin depth is lower because its 85 ms window smooths a 182 ms vibrato period; the instruments agree on
  the rate.
- **Score mode sings its own wobble** on long notes (20-46 c RMS by pyin), and it changes with the seed (3.6-3.9 Hz at
  one seed, 6.4-6.5 Hz at the next). So "no vibrato" is NOT something score mode can do; "Straight" needs either the
  post-render route (`vibratoScale` 0) or melody mode.
- ⚠️ **The two instruments disagree on A1's long notes** (pyin 24-46 c, harvest 76-99 c). The same disagreement appears
  on H-down, A5 and A6 (harvest 196-296 c on one note each) and never in melody mode. It reads as harvest tracking errors
  on those notes, not as wobble; the table quotes both and no decision depends on the harvest figure.
- **The hybrid adds nothing measurable over melody mode** (A3 vs A4 within 1 c and identical rates). It is an
  unsupported path (it bypasses `infer()`'s mode switch). **Decision: possible, measured, not shipped.**
- **An f0 key in score mode changes nothing**: A0's bytes equal A1's [M]. That is the score half of "either/or",
  measured.
- **Intelligibility was not measured** (there is no speech recogniser in the engine's venv). A flat synthesised curve is
  voiced straight through consonants, unlike a real singer's curve; the technical report also measured melody mode's
  English word error rate above score mode's (0.155 vs 0.129 on unseen singers, its Table 2, pdftotext lines 420-431, with REAL pitch curves taken from recordings) [R]. Owed to the
  real-model gate (§10, x9).

### 2.2 The phone set, Chinese G2P, and languages the engine never learned

**The phone set** (`upstream/soulxsinger/utils/phoneme/phone_set.json`) has 2,820 entries: **English 70** (ARPAbet with
stress, `en_` prefix), **Mandarin 1,201** (tonal pinyin syllables, `zh_`), **Cantonese 1,529** (tonal jyutping syllables,
`yue_`) and 20 specials (`<PAD>`, `<SP>`, `<AP>`, `<BOW>`, `<EOW>`, `<SEP>`, …) [M, probe P-B]. Language is carried ONLY
by that prefix: `DataProcessor` never reads `meta["language"]` (`data_processor.py:44-47, 152`) [R]. An English token is
split into its phones inside the model's input (`data_processor.py:96-100`); a Chinese token is ONE whole syllable
(`:101-104`) [R]. So a phrase may mix languages word by word, as upstream's own preprocessing does
(`upstream/preprocess/tools/g2p.py:37-71`) [R].

**Measured coverage** [M, probe P-B, CPU only]:

| Language | What was measured | Result |
|---|---|---|
| English | Every phone CMUdict uses (with stress), against the `en_` set | 70 of 70; 853,918 of 853,918 phone tokens over 123,455 words |
| Mandarin | `g2pM`'s full output inventory (its 876 classes) | 805 of 876 in the set (91.9%); the 71 missing are rare tone forms such as `ha3`, `dui3`, `m2` |
| Mandarin | `g2pM` on each of the 5,207 characters in its own vocabulary, one at a time | 5,137 in the set (98.66%, NOT frequency-weighted, so rare characters are over-counted) |
| Mandarin | Tones available per base syllable in the set | 402 base syllables; only 139 have all four main tones. So a nearest-tone fallback is needed (§6.4) |
| Cantonese | `ToJyutping` on the same 5,207 characters | 5,085 in the set (97.66%) |
| Test lines | 一闪一闪亮晶晶, 满天都是小星星, 我爱你, 你好世界 (Mandarin); 一閃一閃亮晶晶, 我的心情 (Cantonese) | every syllable in the set |

**Upstream ships Chinese G2P, and it is already installed.** `upstream/preprocess/tools/g2p.py` uses `g2pM.G2pM` for
Mandarin (`:4, 14, 31-32`) and `ToJyutping.get_jyutping_list` for Cantonese (`:3, 28-29`) [R]. Both are pinned in
`scripts/sing/requirements.lock` (`g2pm==0.1.2.5`, `tojyutping==3.2.0`) and present in the installed venv [R][M].

| Library | Licence (its `METADATA`/`LICENSE` in the installed venv) | Dependencies | Notes |
|---|---|---|---|
| `g2pM` 0.1.2.5 | Apache License 2.0 [R] | none beyond numpy | Loads pickles shipped in its own package (`np_ckpt.pkl`, `digest_cedict.pkl`) at import [M]. ⚠️ `digest_cedict.pkl` is derived from CC-CEDICT, whose own licence is a Creative Commons share-alike licence [A: verify before shipping; item x2 owns the check]. |
| `ToJyutping` 3.2.0 | BSD 2-Clause [R] | none | A `trie.txt` dictionary inside the package |
| `g2p_en` 2.1.0 (today's) | Apache [R] | nltk, inflect, distance | unchanged |
| ⛔ `praat-parselmouth` 0.4.7 | **GPLv3** [R] | | Present in the venv only because the lock mirrors upstream's requirements (base §2.5: "the lock is not pruned"). **Nothing in DAW Pro may import it.** A test greps `scripts/sing/` for the import (positive-controlled) |

So Mandarin and Cantonese cost **no new dependency and no reinstall**: the scripts change, the runtime does not.

**A Mandarin line renders** [M, probe P-A A5]: T1's 14 notes sung as 一闪一闪亮晶晶满天都是小星星, one character per
note, `g2pM` over the whole line (context matters for characters with two readings). All 14 tokens were in the set;
the render was finite with 92-96% voiced coverage and 80-92% of frames within ±50 c (harvest / pyin). Whether it is
understandable was not measured (§2.1, last bullet).

**A language the engine never learned (Spanish) through English phones** [M, probe P-A A6]: "Estrellita, dónde estás,
me pregunto qué serás" mapped by hand to ARPAbet rendered finite (voiced coverage 91-98%, 80-91% within ±50 c). What it
would cost:

- **Engineering, small:** Spanish spelling is close to one letter per sound, so a rule-based Spanish-to-ARPAbet table
  plus a syllable counter is about one file each, with no dependency (§6.5) [A: sized, not built].
- **Sound, real:** sounds Spanish has and English lacks become their nearest English sound: the rolled and tapped r
  (→ English `R`), pure e and o vowels (English glides them into `EY`/`OW`; the table uses `EH` for e and must still use the glided `OW`
  for o), unaspirated p/t/k, the
  ñ (`N Y`) and the j (`HH`) [A: phonetics, not measured]. The result would sing with an English accent. How
  understandable it is needs a word check in Spanish and a listening round (x9); until then it is "experimental".
- **Not recommended:** imitating other untrained languages (Japanese, Korean) through Chinese syllables; nothing was
  measured and the mapping is far looser [A].

### 2.3 Breathiness, energy, vocal technique

**There is no upstream control for any of them.**

- The model's inputs are note pitch, note type, phoneme and f0, and nothing else
  (`soulxsinger.py:179, 183`) [R]. No velocity, energy, loudness or technique input exists.
- The phone set HAS a breath token, `<AP>` [M], but `DataProcessor.merge_phoneme` rewrites every `<AP>` to `<SP>` (a
  rest) before the model sees it (`data_processor.py:45`), and forces a rest's note type to 1 (`:47`) [R]. So a breath
  cannot be asked for.
- The only global "style" handle is the PROMPT: the model clones the prompt's voice and style (report §1, "reference-based
  singing style transfer", pdftotext line 119) [R]. A breathier reference gives a breathier voice for the whole take,
  never per note.

**The cheapest honest route is a post-render layer** (§5): vibrato and per-note level through the pitch-edit table the
pitch editor already owns, and an offline "air" layer for breathiness. Breathing SOUNDS between phrases are an
enrichment below the cut (§8).

⚠️ **Correction to this lane's brief.** The brief names `clip.applyBreathContour` and `clip.applyEffortShape` as audio tools
that could act on a landed vocal. They cannot: both are **MIDI-clip only** ("MIDI clips ONLY — an audio clip surfaces
notAMIDIClip verbatim", the `clip.applyBreathContour` case comment in `Commands.swift`; `clip.applyEffortShape`: "MIDI
clips only") [R]. They shape an INSTRUMENT's expression lanes, which the singing engine never reads. The audio tools that
DO apply to a landed vocal are `clip.setNoteVibrato(s)`, `clip.setNoteGain`, `clip.setNoteFormant`, `clip.setNoteShape(s)`,
`clip.findUnpitchedSounds` and `clip.autoCorrectPitch` (all need the clip's pitch-edit table) [R].

### 2.4 Harmonies: monophonic parts, seeds, voices, time

- **A part is its own monophonic render.** The facade refuses unsorted or overlapping notes (`notesUnsorted`,
  `notesOverlap`, `schema.py:178-186`) [R]. Three parts mean three times the units, rendered one after another by the
  ONE sidecar.
- **Same seed or different?** The same seed on the same input is bit-identical within one process: A1 against a repeat
  of A1, max |Δ| = 0 [M]. A different seed changes the take (A1 vs A1s: RMS difference 0.077 of full scale, a different
  wobble rate) [M]. A harmony part has different notes, so the same seed still gives a different render; whether parts
  sound better with the lead's seed (shared phrasing) or their own (looser ensemble) is taste, so it is a listening
  option, not a rule (§4.6). **For double-tracking the seed MUST differ**: the same seed on the same notes is a copy, and
  a copy panned against itself is just louder.
- **Same voice or a choice per part?** A choice per part (`voiceId` per part, defaulting to the lead's). Nothing in the
  engine ties parts together.
- **Time for 3 parts.** Each 10.08 s T1 part took 7.97-9.87 s to render here [M, under load: RTF 0.72-0.98 while other
  lanes built]; the base design's unloaded RTF is 0.38-0.51 [M, base §3.4]. So three parts cost about **11-15 s of
  rendering per 10 s of song unloaded** [D: 3 × 10 s × 0.38-0.51], up to ~30 s under load [M]. Peak memory does not grow:
  the parts render one after another, and the MPS driver held 3.09-3.10 GiB after each render [M]. The model loaded in
  40.5 s under load [M] (base §2.6: 13.7-20 s cold, unloaded).
- **The harmony renders themselves were fine** [M]: a diatonic third above and below T1 (C major) rendered finite with
  97-100% voiced coverage and 86-94% of frames within ±50 c.

---

## 3. Feature 1: typing a word onto a note (item p2-sing-x1)

### 3.1 What the user sees and does

The base Sing sheet (base §5.2) already has the words box and the note strip with a glowing chip over each word's notes.
This adds, on the strip:

- **Click a note** (or its chip) and a small field opens over it: "Word on this note". Type and press Return. The box
  above updates at once, and the chips redraw from the box. Tab moves to the next note, so a whole line can be typed note
  by note.
- **Type `+`** in that field to make the word before it hold onto this note (the base legend: "A + holds the word before
  it onto the next note").
- **Delete the word** (empty field, Return) to do the same: the previous word holds on.
- Dragging a chip's edge still adds or removes a `+` (base §5.2).
- The one-box spread is unchanged: typing a whole line into the box still spreads it over the notes by the base rules.
- While the melody plays, the chip under the playhead glows brighter (rank 2 of §8's enrichments), so the user can check the words
  land where they want before spending any singing time.

### 3.2 The rule: the text stays the only truth (base §3.1 kept)

**Decision: per-note typing is a pure text transform, `LyricTextEdit`, followed by re-derivation and a round-trip
check.** Nothing new is stored.

`LyricTextEdit` (new, `Sources/DAWCore/LyricTextEdit.swift`, Foundation only):

```swift
public enum LyricNoteEdit: Equatable, Sendable {
    case setWord(noteID: UUID, word: String)   // "+" means "hold the word before"
    case clearWord(noteID: UUID)               // the word before holds on
}
public enum LyricTextEdit {
    /// The new text, and the assignment derived from it. Throws LyricEditRefusal.
    public static func apply(_ edit: LyricNoteEdit, to clip: Clip, tempoMap: TempoMap)
        throws(LyricEditRefusal) -> (text: String, assignment: LyricAssignment)
}
```

How `setWord(noteID: n, word: w)` works:

1. Derive today's assignment `A` with `SingPlanner.assignment(for:tempoMap:)`, the ONE derivation (`SingPlanner.swift:295`)
   [R]. If it throws (no text, W > N, …), refuse with that refusal's sentence: chips are not shown for text that does not
   fit, so there is nothing to click.
2. Find the word `k` covering note `n`, and `n`'s position `j` among `k`'s notes. A note no word sings (a silent phrase in
   flow mode, or a chord note the monophony rule dropped) is refused, `noteNotSung` (§3.4).
3. **Freeze the phrase.** Rewrite every word of `n`'s breath phrase with explicit markup for the notes it has NOW: a word
   on `c` notes becomes its hyphen parts plus `+` marks totalling `c`. Markup is honoured first and never re-shared
   (base §3.3 rule 3; `LyricWord.hasMarkup`, `LyricTokenizer.swift:47`) [R], so after this step the phrase's derivation
   cannot move anything the user did not touch.
4. **Edit.** If `j == 0`, replace word `k`'s own text with `w`, keeping its `+` count so it covers the same notes. If
   `j > 0`, split: word `k` keeps notes `0..<j`, and `w` (with `+` marks for the rest of `k`'s notes) is inserted after it.
   The cut uses `LyricTokenizer.slice`/`cut` (`LyricTokenizer.swift:144-165`) [R], so punctuation and line breaks stay
   with the words they follow. `w == "+"` and `clearWord` remove `n`'s word start and add one `+` to the word before.
5. **Round-trip check.** Derive again. Every note must keep its previous word except the edited ones, and note `n` must
   sing `w`. If not, refuse `lyricEditUnstable` with "I couldn't place that word without moving others. Type the line in
   the box instead." This should never happen; it is the gate that catches a defect in steps 3-4 (§3.5's plant).

Freezing a phrase writes `+` marks the user did not type. That is the price of "what you see is what is sung": the box
shows exactly why each word sits where it does, and the user can delete the marks. The freeze touches ONE phrase, not
the whole text.

**Alternatives that lose:**

- **A stored per-note override (`[noteID: word]` beside the text).** Two sources of truth for one fact. A note edit,
  split or duplicate would have to keep both in step, which is exactly the stored-record-disagrees failure base §3.1
  rejected. Its only gain, keeping the text free of `+` marks, is not worth a second record.
- **Storing word spans for the whole clip once the user types per note** ("switch to manual mode"). The same failure,
  plus a mode the user has to understand.

### 3.3 Domain, facade and file changes

- **Domain:** the new pure file above. No `Codable` change, so no old file can be affected.
- **Facade:** none.
- **Persistence:** none. `ClipLyrics.text` already round-trips through `Clip` and the `ClipDocument` mirror
  (`ClipLyrics.swift:22-30`) [R].

### 3.4 Wire and MCP

| Verb (new) | MCP tool | Params | Returns | Refusals |
|---|---|---|---|---|
| `clip.setNoteWord` | `clip_set_note_word` | `clipId`, `noteId`, `word` (one word, or `"+"` to hold the word before, or `""` to clear), `dryRun?` | `{text, stored, assignment {words: [{text, noteIds, startBeat, endBeat, held}]}, warnings}`: the base `clip.setLyrics` shape | `clipNotFound`, `lyricsNeedMIDIClip`, `lyricsNoText` ("Type the words in the box first; then you can change single notes."), `noteNotFound`, `noteNotSung` ("This note isn't sung: it is part of a chord, or no words reach this line yet."), `lyricWordHasSpace` ("Type one word per note. To type several, use the words box."), the assigner's refusals (W > N, not English / wrong language), `lyricEditUnstable`, `lyricsTooLong` |

- It stores through the same store call as `clip.setLyrics` (base §6 row 12), as one undo step ("Type Word").
- The UI's note field calls the same `LyricTextEdit.apply` through the same store method, so a spy test (base §6 rule)
  proves the field and the wire reach one method.
- `rejectUnknownKeys` with the tree's teaching hint.

### 3.5 Tests and gates

- **Table tests** over hand-built clips (pure DAWCore, nonisolated, a NEW suite file): replace a word at a word start;
  type on a held note (split); type on a `+` note; clear a word; `"+"`; a word with hyphen parts; punctuation and line
  breaks survive; an edit in phrase 2 leaves phrase 1's text byte-identical; a `linePerPhrase` text stays in that mode.
- **The round-trip property**, on 500 generated clips with generated texts (seeded): for every sung note and a random
  word, `apply` either refuses with a listed refusal or yields a text whose derivation changes exactly the edited notes.
- ⛔ **Plant:** skip step 3 (the freeze). Rule 5.1's spare-note sharing then re-shares neighbours after some edits, and
  the round-trip property must go red. If it stays green the property cannot fail and is not used.
- **No-impact:** the suite never touches a clip it did not edit; `ClipLyricsPersistenceTests` and
  `ClipLyricsRebuildTests` run unchanged (§9).

---

## 4. Feature 2: harmonies (items p2-sing-x4, x6, x7, x8)

### 4.1 What the user sees and does

A "Harmony" card in the Sing sheet, under Voice:

- **"Add a harmony"** offers, in plain words: "A third above (sweet, close)", "A sixth below (warm, under the tune)",
  "A third below", "Sing my other melody…" (pick a MIDI clip), and, when the tune has chords, "Sing the chord's other
  notes".
- Each added part shows a row: its name, its voice (default: the lead's), a range line ("Fits your voice" or "I'll sing
  this part an octave lower"), and [Remove].
- Up to 3 harmony parts plus the lead [A]. The lead plus 3 parts is about 15-20 s of rendering per 10 s of song
  unloaded [D: 4 × 10 s × RTF 0.38-0.51]; x9's measured time replaces the cap.
- **[Sing it]** renders the lead and every part in one job. Progress reads "Singing part 2 of 3 · line 1 of 4…".
- Each part lands on its OWN new violet track, named "Harmony — third above · Built-in singer", a little quieter and
  panned (§4.6). The lead lands as today. Nothing existing is edited.
- With "Sing it" already done once, "Add harmony to this vocal" sings ONLY the new parts (the lead's units are cache
  hits in any case, base §4.3).

### 4.2 Where a part's notes come from

| Source | How | Words |
|---|---|---|
| **Derived** (`HarmonyPlanner`) | The lead's notes after the monophony and legato rules, each moved by a diatonic interval, or to a chord tone (§4.3) | The lead's text, unchanged. The part has the SAME note count and timing, and the assigner reads only timing and syllables (`LyricNoteAssigner.swift:229-306`) [R], so the words land on the same notes |
| **Chord tones of the melody clip** ("Sing the chord's other notes") | Where the melody clip has a chord, the part takes the chord note ranked 2nd (or 3rd) from the top; where it has a single note, the derived rule fills in | The lead's text, as above |
| **Another MIDI clip** ("Sing my other melody…") | That clip planned on its own (`SingPlanner.plan`), with its own whole-octave choice (§4.5) | That clip's own lyrics if it has them, else the lead's text copied for this job only. If the words do not fit its notes, the assigner's own refusal sentence names the part |

A derived part is planned from a TRANSIENT clip (the lead clip with its notes replaced and the same id) that is never
stored. Its note ids are derived from the lead note ids and the part index (a name-based UUID) [A], so the same input
always gives the same plan and the same `signature`.

### 4.3 `HarmonyPlanner` (new, `Sources/DAWCore/HarmonyPlanner.swift`, pure)

```swift
public struct HarmonySpec: Codable, Sendable, Equatable {
    public enum Interval: String, Codable, Sendable { case third, sixth, fifth, octave }
    public enum Direction: String, Codable, Sendable { case above, below }
    public enum ChordSource: String, Codable, Sendable { case auto, none, thisClip, otherTracks }
    public var interval: Interval; public var direction: Direction; public var chordSource: ChordSource
}
public enum HarmonyPlanner {
    public static func notes(lead: [MIDINote], spec: HarmonySpec, key: SongKey,
                             chordAt: (Double) -> Set<Int>?) -> HarmonyPlan
}
```

The rule, per lead note `p`:

1. **Diatonic step.** In the key's scale (`KeyMode.scaleIntervals`, `ChordVoicing.swift:51-62`) [R], move `p` by the
   interval in scale steps (a third = 2 steps, a sixth = 5, a fifth = 4) in the chosen direction. A chromatic lead note
   uses the nearest scale degree below it, then adds the same semitone distance that degree's interval would [A].
2. **Chord snap** (`chordSource` not `none`). If a chord sounds at the note's onset (`chordAt`: the melody clip's own
   simultaneous notes, or every OTHER pitched MIDI track's notes sounding then; drum tracks are excluded by the tree's
   one rule, `ProjectTranspose.isDrumTrack` [R]) and the diatonic note is not a chord tone, move to the nearest chord tone
   on the same side of `p`, at least 3 and at most 9 semitones away [A].
3. **Never unison, never a crossing.** An "above" part is always above `p`, a "below" part always below.
4. **Octave of the whole part, never per note** (§4.5).

**The key.** `SongKey { tonicPitchClass, mode, source: given | estimated, confidence }`:

- given: the `key` and `mode` params (wire) or the card's key picker (UI), whose default is the estimate;
- estimated: a Krumhansl-Kessler correlation over the durations of every pitched MIDI note in the project. The math
  already exists as `KeyEstimator.estimate(chroma:)` in DAWEngine, but it is not public (`DAWEngine/Analysis/
  KeyEstimator.swift:34`) [R] and DAWCore cannot reach DAWEngine. **Decision: lift that pure function into DAWCore** as
  `KeyProfileMatch.estimate(chroma:)` (profiles, Pearson, flatness and the honesty gates moved verbatim), and make
  DAWEngine's `KeyEstimator.estimate` forward to it. One home; DAWEngine's audio path must give byte-identical
  `KeyEstimate` values before and after (a test over its existing fixtures).
- An estimate that is not tonal (`KeyEstimate.tonal == false`) refuses a DERIVED part with `singHarmonyNeedsKey`: "I
  couldn't tell this song's key. Pick the key, and I'll work out the harmony." A part from another clip needs no key.

**Alternatives that lose:**

- **A fixed number of semitones** (+4 for "a third"). Half the notes of a major scale would be out of key.
- **A second copy of the Krumhansl math in DAWCore.** Two homes for one calculation drift apart; the lift is a move, not
  a copy.
- **A harmony generated by an AI provider.** A network call and a key for a rule that fits in a page, and an answer no
  test can pin.

### 4.4 How a harmony job maps onto the base §4 one-job shape

- **One job, one queue slot, one sidecar.** The job holds an ordered list of PART plans: the lead, then each part.
  Units are rendered part by part, in order. Residency (base §2.7, R2-R5) is unchanged: one SoulX process renders every
  unit, and each unit registers as `"<jobId>#<part>.<unit>"`, a shape extension of base rule R5's
  `"<jobId>#<unit>"`, not a new rule (a single-part job keeps R5's exact form).
- **Progress** is weighted by unit length across all parts: "Singing part {p} of {P} · line {i} of {n}…".
- **Cache.** The base §4.3 key already includes the unit's notes and the voice, so each part's units have their own
  entries, and re-singing only a new part re-uses the lead's.
- **Cancel** at a unit boundary, as today. A cancelled job lands nothing (base §4.2).
- **Landing.** Each part runs the base landing gates L1-L4 (base §7.1) on its own assembled take. Parts that pass land;
  a part that fails does not, and its sentence names it ("The part 'third above' didn't come out right. [Try again]"),
  with its cache kept. **Every landed part goes in ONE undo step**, "Land Sung Harmony", through a new plural store
  method `ProjectStore.landSungVocals(_ takes: [SungVocalTake], planned: SungVocalLandingGuard)` that wraps all the
  `tracks.append` calls in ONE `performEdit` (today's `landSungVocal` journals one `performEdit` per call,
  `ProjectStore+SungVocal.swift:170-173`) [R]. The single-part path keeps calling `landSungVocal` unchanged.
- **Project identity** (base §4.5) is checked once per job (`projectGeneration`) and per part (`signature`), with the
  base rules (a different project: nothing lands; a pure transposition: every part lands moved by the same Δ).
- **Provenance.** Each part's track gets its own `SungVocalProvenance` plus two optional fields, `partRole` ("lead",
  "harmony", "double") and `harmony` (the `HarmonySpec` and `SongKey` used), both omitted when nil (§9).

### 4.5 A part outside the voice's range

The base rule holds per part: **a sung part moves only by whole octaves, and the song's key never changes for a harmony.**

- Each part gets its own `VoiceRangeFit` octave choice over its own notes and its own voice, with the song
  transposition fixed at the lead's (`t` is not a candidate; base §3.5's candidates with `t = 0`) [R:
  `VoiceRangeFit.swift`].
- Ties go to the lead's octave, so a part usually sits where the lead sits.
- The whole part moves; notes never jump octaves one by one (a line that jumps is not a harmony).
- A part whose best octave still leaves more than 0.25 semitone out of band (base §3.5's octave-only threshold) [R]
  shows the range line in amber: "This part goes lower than this voice usually sings. Try 'a third above' instead."
  It is a warning, not a refusal.
- Swapping "a third above" for "a sixth below" keeps the same note NAMES an octave lower (2 + 5 = 7 scale steps): it IS a
  whole-octave move of the same part, so the octave rule above already makes it when the range needs it, and the card's
  wording names it the way a musician would.

### 4.6 Names, pan and level (defaults are [A]; listening rounds decide)

| Part | Track name | Pan | Level |
|---|---|---|---|
| Lead | as today ("Vocals — Built-in singer") | 0 (centre), as today | as today |
| Harmony above | "Harmony — third above · {voice}" | +0.3 [A] | −4 dB, `volume` 0.63 [A] |
| Harmony below | "Harmony — sixth below · {voice}" | −0.3 [A] | −4 dB [A] |
| A second harmony on the same side | "… · 2" | ±0.5 [A] | −6 dB [A] |

`Track.pan` is −1…1 and `Track.volume` is linear gain, 1 = unity (`Model.swift:1424-1428`) [R]. The new tracks are set
inside the same landing `performEdit`; the lead's existing track is never touched.

Listening rounds (§10, x9): **H1, the interval** (third above / sixth below / third below / fifth above, on one song);
**H2, the level** (−2 / −4 / −6 / −9 dB, same interval); **H3, the seed** (each part on the lead's seed vs its own).

### 4.7 Wire and MCP

| Verb | MCP tool | Params | Returns | Refusals |
|---|---|---|---|---|
| `sing.proposeHarmony` (new, read-only, works with the engine down) | `sing_propose_harmony` | `clipId`, `interval`, `direction`, `chordSource?` (`auto`), `key?` (0-11), `mode?` (`major`/`minor`) | `{key {tonic, mode, source, confidence}, notes: [{leadNoteId, leadPitch, pitch}], range {voiceId, octaveShift, outOfBandSemitones, sentence}, warnings}` | `clipNotFound`, `singNeedsMIDIClip`, `singClipHasNoNotes`, `singHarmonyNeedsKey`, `singHarmonyIntervalInvalid`, `singVoiceNotFound` |
| `sing.render` (base §6 row 14) + optional `parts` | `sing_render` | `parts?: [{kind: "harmony"\|"chordTones"\|"clip"\|"double", interval?, direction?, chordSource?, sourceClipId?, voiceId?, seed?, trackName?, pan?, volumeDb?}]` (max 3), `key?`, `mode?` | `{jobId, plan}`; the plan gains `parts: [{role, units, octaveShift, range, warnings}]` ONLY when `parts` was sent | the base refusals, plus `singTooManyParts`, `singPartClipNotFound`, `singHarmonyNeedsKey`, `singPartInvalid` (names the field) |
| `sing.jobStatus` (base row 15) | `sing_job_status` | unchanged | gains `parts: [{role, state, trackId?, error?}]` ONLY for a job that had parts | unchanged |

Without `parts`, `sing.render`'s request handling, plan and reply are byte-identical to the base verb (§9).

### 4.8 Tests and gates

- **`HarmonyPlanner` tables:** C major and A minor; every interval and direction; a chromatic lead note; chord snap from
  this clip and from another track (drums excluded); never unison; never a crossing; same input → same note ids.
- **Musical controls:** a diatonic third above C-D-E-F-G in C major is E-F-G-A-B (pins the scale arithmetic); with a G
  major triad (G-B-D) sounding under the D, the third above (F) is not a chord tone, so the snap moves it to G,
  the nearest chord tone above D [A: the rule's own arithmetic].
- **The key lift:** DAWEngine's `KeyEstimator` gives byte-identical `KeyEstimate`s on its existing fixtures before and
  after (a JSON comparison). ⛔ Plant: change one profile weight in the moved copy → red.
- **Range:** a part that fits takes the lead's octave; a part one octave too low moves up a whole octave; target − source
  is always the interval plus a multiple of 12 (the base §3.4 octave test extended per part).
- **Coordinator** (fake synthesizer, base p2-sing-e harness): 3 parts render in order with correct progress; a cancel at a
  boundary lands nothing; a part that fails L2 does not land while the others do; ONE undo removes every landed part;
  identity and Δ-landing per part. ⛔ Plant: land each part in its own `performEdit` → the one-undo test goes red.

---

## 5. Feature 3: per-note vibrato, level and breathiness (items p2-sing-x5, x6, x7, x8; x10 gated)

### 5.1 What the user sees and does

An "Expression" card in the Sing sheet, collapsed by default ("Style: as sung"):

- **Vibrato:** As sung · Straight · Gentle · Normal · Wide. One row of five buttons, plain labels.
- **Air (breathiness):** a slider from "None" to "Lots", default None.
- **Follow note loudness:** a toggle, off by default. "Quieter notes in your melody (lower velocity) are sung quieter."
- **Per note:** select notes in the strip, and the card applies to just those ("3 notes selected: Vibrato Wide, Air a
  little"). Notes with their own setting show a small dot on their chip.
- After singing, the vocal's notes carry the vibrato as ordinary pitch-editor edits: the pitch editor's Wobble tool shows
  and changes them. "Try another take" applies the same style again.

### 5.2 The decision: a post-render layer, with the engine route designed and held behind a listening round

The probe showed BOTH routes are real (§2.1): melody mode follows a synthesised vibrato closely, and score mode always
sings its own wobble. So the choice is not "which one works" but "which one we ship first":

| | **Post-render (chosen)** | Engine route: melody mode + synthesised curve (x10, gated) |
|---|---|---|
| Vibrato | Written into the landed clip's pitch table with the store's ONE clamp; rendered by the existing pitch renderer | Sung by the model from the curve [M: 5.37-5.47 Hz, 42-60 c for an asked 5.5 Hz ±60 c] |
| "Straight" | `vibratoScale` 0 removes the model's own wobble (`NoteVibratoLimits.swift:38-44`: "1 = as sung, 0 = removed") [R] | A flat curve [M: 5-8 c residual] |
| Changing it later | Instant and undoable in the pitch editor, no model time | A new render of every affected unit |
| Own voices | Work as today | Need a prompt pitch curve the facade does not have (§2.1 trap 2): the app must send SwiftF0 frames |
| Default path | Untouched (no table seeded) | Untouched (score mode) |
| Risk | The pitch renderer's quality on a synthesised voice [A] | Robotic pitch: a flat curve is "too perfect" (A2: 100% of frames within ±50 c) [M], and intelligibility through voiced consonants is unmeasured [A] |
| Breathiness, level | Same pass (§5.4) | No input exists in either mode (§2.3) |

**Why post-render first:** it reuses three shipped, tested parts (the pitch table, its one clamp, its renderer), it keeps
the user's ability to fine-tune without re-singing, it works for own voices on day one, and it cannot change a default
render. The engine route might sound more natural, which is a listening question, so it is a listening round, not a
guess: **Round VR** (§10, x9) plays the same take with "Normal" vibrato made both ways, one axis ("how the wobble is
made"), and only if the user picks the engine route does item x10 get built.

**Alternatives that lose:**

- **Engine route first.** It changes the whole take, not just the vibrato (a new render in a different mode), costs a
  render per tweak, and needs a new prompt-curve path for own voices before it works for the user's own voice.
- **The "hybrid" (both inputs).** Measured equal to melody mode (§2.1) and outside `infer()`'s supported modes.
- **A per-note vibrato insert effect on the vocal track.** A new real-time DSP effect, for something the pitch table
  already does offline and per note.

### 5.3 Domain model: `Clip.singStyle` (ADDITIVE)

```swift
public struct SingStyle: Codable, Sendable, Equatable {
    public enum Vibrato: String, Codable, Sendable { case asSung, straight, gentle, normal, wide }
    public var vibrato: Vibrato?            // nil = asSung
    public var air: Double?                 // 0...1; nil = 0
    public var followVelocity: Bool?        // nil = false
    public var notes: [UUID: NoteSingStyle]? // per-note overrides, keyed by MIDINote.id
}
public struct NoteSingStyle: Codable, Sendable, Equatable { public var vibrato: SingStyle.Vibrato?; public var air: Double? }
// Clip:
public var singStyle: SingStyle?            // nil = today
```

- **Encoded only when non-nil**, so a clip without a style encodes byte-identically (the `ClipLyrics` precedent,
  `ClipLyrics.swift:22-30`) [R]. **Normalised:** a style with every field at its default is stored as nil, so "no style"
  has one spelling (the `ClipLyrics.normalized` precedent, `ClipLyrics.swift:72-75`) [R].
- **Unknown raw values decode leniently** to nil (a file from a later build with a new preset still opens), the
  `SungVocalProvenance` raw-string precedent (`SungVocal.swift:26-32`) [R].
- **The `ClipDocument` mirror** in `ProjectDocument.swift` is a second hand-maintained field list; it must carry
  `singStyle` in its init, encode, decode and BOTH reconstructions, as it does for lyrics (`ClipLyrics.swift:24-30`) [R].
- **Not render material.** Nothing the engine plays reads it; `Clip.init` drops it from non-MIDI clips, as it drops
  lyrics (`ClipLyrics.swift:15-20`) [R].
- **Per-note overrides are keyed by note id**, a deliberate exception to "derive, don't store", because the override
  describes the note ITSELF (like its velocity), not a relation between two changing things. Rules:
  - an override whose note is gone is INERT and reported (`clip.getSingStyle`'s `orphanedNoteIds`); the next
    `clip.setSingStyle` write prunes it. Nothing prunes at load (no load-time mutation);
  - **the rebuild sites must carry overrides** the way `ClipLyrics.swift:32-45` lists for lyrics (trim, overlap trim,
    duplicate, paste, split, the bar insert/delete straddle, comp members, `TakeGroupDocument`). **Census first:** item
    x5 lists every site with its method, and decides per site whether note ids survive (keep the override), or are
    re-minted (remap through that site's own old→new id map, or, where none exists, drop the overrides AND say so in that
    edit's result). A site that silently drops a user's setting is the defect this rule exists to prevent; each site gets
    a test like `ClipLyricsRebuildTests`.

**Alternatives that lose:**

- **Fields on `MIDINote`.** `MIDINote` is read by playback, the planner and every note editor; new fields there touch
  the hottest type in the model and its own document mirror, for data only singing reads.
- **Markup in the lyric text** (`star~`). It mixes "what is sung" with "how", clutters the chips, and `~` already belongs
  to OpenUtau's `+~` hold, which the tokenizer accepts (`LyricTokenizer.swift:93-96`) [R].
- **Job-only settings (not stored).** The Sing sheet would forget per-note choices when it closes.

### 5.4 The post-render pass

**Planner (new, `Sources/DAWCore/SungExpressionPlanner.swift`, pure):** input = the `SingPlan` (every planned note's time
in the landed file: unit offset + note start), the clip's `SingStyle` resolved per note (override, else clip default),
the source notes' velocities, and the detected note table of the assembled take; output = an edited `PitchEditSet`, or
nil when every note resolves to "as sung", no air and no velocity.

- **The table** comes from `PitchNoteTable.detected(from:)` on the assembled take, the editor's own seed, where an
  untouched sound "renders as the source" (`ProjectStore+PitchNoteEdits.swift:1262-1318`) [R]. Detection runs detached,
  off the main actor (base F20).
- **Order, fixed:** (1) sum the units; (2) detect pitch on that buffer BEFORE any air is added (band-shaped noise would
  degrade the pitch track that places the vibrato edits; the timeline is the same, so segment times stay valid for the
  landed file); (3) mix the air layer; (4) the loudness gain (base §4.5 step 3); (5) the landing gates L1-L4 on the final
  bytes; (6) land with the table.
- **Mapping:** a sung segment belongs to the planned note it overlaps most, at least half its length [A]. `.unpitched`
  sounds and `.transition` slides never get vibrato.
- **Vibrato presets → `NoteVibratoEdit`**, then `PitchEditSet.applyingNoteVibratos`, the store's own pure function
  behind the one clamp (`NoteVibratoLimits.swift:12-23`) [R]:

  | Preset | Edit | Only on |
  |---|---|---|
  | As sung | none | — |
  | Straight | `vibratoScale` 0; `driftScale` NOT touched (stays as sung) | every sung segment |
  | Gentle / Normal / Wide | `vibratoScale` 0 (`driftScale` untouched), then a new wobble: `vibratoRateHz` 5.5, `vibratoDepthCents` 25 / 45 / 70, `vibratoOnsetSeconds` 0.25 [A, all: listening round V] | segments of at least 0.45 s [A] |

- **Why drift stays:** `NoteVibratoLimits` keeps two scales, the wobble (`vibratoScale`) and the slow drift
  (`driftScale`) (`NoteVibratoLimits.swift:38-44`) [R]. "Straight" removes only the wobble. Removing the drift too
  would make the pitch as perfectly flat as the probe's flat curve (A2: 100% of frames within ±50 c) [M], which is the
  robotic sound this route exists to avoid [A: Round V can add a "dead straight" option if the user wants one].
- **Follow note loudness:** `amplitudeDb` = 20·log10(velocity / 100), clamped to −12…0 dB [A] (velocity 100 or more =
  as sung; 64 = −3.9 dB). It only ever turns notes DOWN, so it cannot push the landed take past the −1 dBTP ceiling
  that L3 asserted on the written bytes (base §7.1).
- **Air layer (new, `Sources/DAWCore/SungAirLayer.swift`, pure, offline):** seeded noise (SplitMix64 on the take's seed),
  band-shaped (high-pass ~1.5 kHz, low-pass ~9 kHz) [A], following the take's own 10 ms loudness envelope, mixed at
  −24 / −18 / −12 dB under the voice for "a little" / "some" / "lots" [A: listening round A], inside each chosen note's
  span with 20 ms raised-cosine edges. It runs at ASSEMBLY, before the loudness gain (base §4.5 step 3), so the gain
  stage and gates L1-L4 see the final bytes. Air is BAKED into the take; changing it later re-assembles from the phrase
  cache with no model time and lands a new take (the "always a new track" ruling).
- **Landing:** `landSungVocal` gains ONE optional parameter, `pitchEdits: PitchEditSet? = nil`, set on the new clip
  inside the SAME `performEdit` (`ProjectStore+SungVocal.swift:165-173`) [R]. So a styled take is still one track in one
  undo, and nil is exactly today's call.
- **Provenance:** `SungVocalProvenance.style: SingStyle?` (a snapshot), omitted when nil.

**RT safety:** the planner, detection and the air layer run in the coordinator's detached task on buffers it owns; the
landed clip plays through the existing pitch renderer; **nothing touches the render thread** (§12).

### 5.5 The engine route, designed now, built only if Round VR picks it (item x10)

- Facade v2 `control: "melody"` (§7). The facade synthesises the target curve itself from the notes and each note's
  optional `vibrato {rateHz, depthCents, onsetS}`, frame by frame on the converter's OWN 10 ms-rounded boundaries
  (`score.bounds_of`) [R], so the app and facade can never disagree about where a note starts. The curve is at least the
  phrase's mel frames + 5 long (§2.1 trap 1). Rests are 0.
- Built-in voices use the curve in their shipped `prompt.json` [M]. An own voice must send `voice.prompt.f0 {fps: 50,
  hz: [...]}`, from SwiftF0 frames resampled to 50 fps (confidence below 0.9 = 0, the `clip.detectPitch` default)
  [A: that SwiftF0's curve serves as well as upstream's RMVPE]. Without it: `promptF0Missing` (§2.1 trap 2).
- **The curve rule** (what probe P-A rendered; the spec x10 ports into `singlib/score.py`, with tests):
  - frame `k` stands for time `k × 20 ms`; there are `mel_frames(meta) + 5` frames;
  - each metadata entry `i` starts at frame `round(cumulative_start_i × 50)` (the rounding `DataProcessor.preprocess`
    itself uses, `data_processor.py:91-93`) [R]; frame `k` belongs to the last entry starting at or before it;
  - a rest entry gives 0 (unvoiced); a note entry of MIDI `m` gives `440 × 2^((m − 69) / 12)` Hz, multiplied, when the
    note has a vibrato and the entry lasts at least the threshold, by `2^(g × depth × sin(2π × rate × t) / 1200)` with
    `t = (k − entry_start_frame) / 50 − onset`, applied only while `t > 0`, and `g = min(1, t / fade)` (fade 0.1 s);
  - values are written `"%.1f"`, space-separated, as the facade's existing test hook writes them (`score.py:120-122`)
    [R].
- Gate before x10 may ship: the Round VR pick, plus a word check (Whisper, English) on melody-mode takes no worse than
  0.10 above the same take in score mode [A], plus a planted missing prompt curve that must be refused, never rendered.

### 5.6 Wire and MCP

| Verb (new) | MCP tool | Params | Returns | Refusals |
|---|---|---|---|---|
| `clip.setSingStyle` | `clip_set_sing_style` | `clipId`; any of `vibrato` (`asSung`\|`straight`\|`gentle`\|`normal`\|`wide`), `air` (0-1), `followVelocity`, `notes: [{noteId, vibrato?, air?}]`; or `clear: true` alone | the stored style (nil when cleared or all-default), `orphanedNoteIds` | `clipNotFound`, `singStyleNeedsMIDIClip`, `singStyleVibratoInvalid` (lists the five), `singStyleAirOutOfRange`, `noteNotFound` (all or nothing, names the id), `singStyleClearAlone` ("send clear on its own"), `nothingToChange` |
| `clip.getSingStyle` | `clip_get_sing_style` | `clipId` | the style or null, `orphanedNoteIds` | `clipNotFound` |

`clip.setSingStyle` is one undo step ("Set Singing Style"). `sing.render` reads the stored style; there is no per-call
override, so the clip is the one source of truth and the provenance records what was used.

### 5.7 Tests and gates

- **Model:** `SingStyle` absent decodes nil; an all-default style normalises to nil; unknown preset strings decode
  leniently; a MIDI clip WITHOUT a style encodes byte-identically to a pinned pre-change JSON (§9 S2); the `ClipDocument`
  round trip carries it; one test per rebuild site from the census.
- **Planner tables:** mapping by overlap; presets → edits; "as sung" everywhere → nil table (the default never seeds);
  sounds and slides untouched; the velocity curve (100 → 0 dB, 64 → −3.9 dB, never above 0).
- **Render physics** (DAWEngine tests, through the real pitch renderer, measured with SwiftF0): a synthetic sung line (a
  harmonic tone with known notes and a built-in 6 Hz ±40 c wobble) shaped "Straight" leaves under 10 c RMS wobble [A];
  shaped "Normal" measures 5.5 ± 0.3 Hz and 45 ± 10 c [A]. **Invariance control:** "As sung" leaves the clip with NO
  table and the render byte-identical.
- **Air layer:** in the chosen spans the energy above 2 kHz rises by at least 3 dB at "a little" [A]; **outside the spans
  the samples are bit-identical** (the boring control that catches a fade bug); the same seed gives the same bytes.
- ⛔ **Plants:** (1) map "Normal" to 4.5 Hz → the physics gate goes red; (2) let the air fade run 5 ms past the span →
  the outside-span bit-identity goes red; (3) seed a table for an all-"as sung" style → the invariance control goes red; (4) let "Straight" also
  set `driftScale` 0 → a drift test goes red (a synthetic line with a slow 0.5 Hz ±30 c drift under its 6 Hz wobble
  must keep at least 20 c of slow movement after "Straight") [A: the bar].

---

## 6. Feature 4: other languages (items p2-sing-x2, x3, x7, x8, x9)

### 6.1 What the user sees and does

- Above the words box: **"Language: English ▾"**, with "Chinese (Mandarin)" and "Chinese (Cantonese)" in the list, and
  later "Spanish (experimental)".
- Chinese is typed with the Mac's own input method (no setup in DAW Pro). Each character is one sung syllable, so each
  gets its own chip and its own note. Pinyin with tone numbers ("wo3 ai4 ni3") also works, for anyone without a Chinese
  keyboard.
- English words inside a Chinese line are sung in English, as the engine's own tools do.
- Picking Spanish shows, once: "Spanish is experimental: I sing it with English sounds, so it will have an accent."
- Typing words that don't match the chosen language gets one sentence that says what to change (§6.7).

### 6.2 Which languages ship first, and why

| Language | Training data [R: report §2.1.2, pdftotext line 228] | G2P | Coverage [M, §2.2] | A line rendered [M] | Ships |
|---|---|---|---|---|---|
| English | ~20,000 h | `g2p_en` (today) | 100% of CMUdict phones | yes (every spike render) | today |
| **Mandarin** | ~20,000 h | `g2pM`, already installed | 98.66% of 5,207 characters; 91.9% of g2pM's syllable inventory | yes (A5) | **first (x2 + x3)** |
| Cantonese | ~2,000 h (a tenth of the others) | `ToJyutping`, already installed | 97.66% of 5,207 characters | not probed (the G2P and set were) | second, behind a word check (x9) |
| Spanish | none | rule table → English phones (to build) | by construction (we choose the phones) | yes (A6), accented [A] | last, "experimental" |

### 6.3 How lyrics carry a language (domain, ADDITIVE)

- **`ClipLyrics.language: String?`**: `nil` = English, `"zh"` = Mandarin (simplified or traditional characters),
  `"yue"` = Cantonese, `"es"` = Spanish. Encoded only when non-nil, so every clip written today and every English clip
  later encodes byte-identically; the `ClipDocument` mirror carries it like `text`. A new decode test: an old clip
  decodes `language == nil`; an unknown code decodes and is REFUSED at sing time, never silently sung as English.
- **The tokenizer, per script** (`LyricTokenizer`):
  - In a `zh`/`yue` clip, every CJK character (U+4E00-9FFF and the extension blocks) is ONE word with ONE part, so it
    asks for one note; Chinese punctuation (，。！？、「」) is dropped for singing and kept in `typed`, as today's punctuation
    is (`LyricTokenizer.swift:86-111`) [R].
  - A Latin token matching a pinyin syllable plus tone digit (`^[a-zü]+[1-5]$`, or jyutping `[1-6]`) is one syllable.
  - Any other Latin word in a `zh`/`yue` clip is English, which is upstream's own rule (`upstream/preprocess/tools/g2p.py:
    49-55`) [R].
  - `LyricWord` gains `language: String?` (nil = English). Today's `isEnglish` keeps its meaning for English clips, so
    every English refusal sentence stays byte-identical.
- **Syllables:** `EnglishSyllables` for English (unchanged), exactly 1 for a CJK character or a pinyin/jyutping
  syllable, `SpanishSyllables` for Spanish (§6.5). A protocol `SyllableCounting` picks by the word's language.
- **The planner** sends each word's language to the facade (`SingWord.language`, nil = English), and folds it into the
  `signature` ONLY when non-nil (§9 S3).

### 6.4 The facade: a phonemiser per language (v2 only)

`scripts/sing/singlib/phonemes.py` gains a registry; today's `G2PPhonemizer` is the `"en"` entry, unchanged:

| `lang` | Phonemiser | Token |
|---|---|---|
| `en` (default) | `G2PPhonemizer` (unchanged, `phonemes.py:48-62`) [R] | `en_` + ARPAbet joined with `-` (today's `_Phonemes.token`, `score.py:50-64`) [R] |
| `zh` | `MandarinPhonemizer`: `g2pM` over the whole RUN of consecutive Chinese words in the phrase (characters with two readings need their neighbours, as upstream does, `g2p.py:58-69`) [R], mapped back one syllable per character; a pinyin token passes through | `zh_` + syllable, ONE token per note |
| `yue` | `CantoneseJyutping`: `ToJyutping.get_jyutping_list` over the run | `yue_` + syllable |
| `es` | `SpanishApprox`: the rule table of §6.5 | `en_` + ARPAbet (so it reaches the model as English phones) |

- **Missing tones** (only 139 of 402 Mandarin base syllables carry all four tones in the set, §2.2): if `zh_<syllable><tone>`
  is missing, use the same syllable's most common tone in the set [A: in singing the melody carries the pitch; x9's
  character word check confirms]. Each substitution is reported in the reply as `substitutions: [{word, asked, used}]`, a key
  present ONLY when non-empty. A syllable with NO tone in the set is refused (`unknownPhone`, naming the character).
- **Lazy import:** `g2pM` and `ToJyutping` are imported on the first request that needs them, so an English-only
  process imports exactly what it imports today.
- **No new dependency, no reinstall:** both are already in `requirements.lock` [R] and the installed venv [M].
- `_Phonemes.token(word)` becomes `token(word, lang="en")`; the `"en"` branch is today's code, byte for byte.

### 6.5 Spanish through English phones (experimental, last)

- **`SpanishApprox` (Python, the facade) and `SpanishSyllables` (Swift, DAWCore):** Spanish spelling maps almost one to
  one to sounds. Vowels a e i o u → `AA EH IY OW UW` (stressed vowel gets stress 1, by the written accent or the
  penultimate-syllable rule); `ll`/`y` → `Y`; `ñ` → `N Y`; `j`, soft `g` → `HH`; `c`/`z` (Latin American) → `S`;
  `qu` → `K`; `h` silent; `rr` and initial `r` → `R` (no trill exists in the set); `ch` → `CH` [A: the table; x9's word
  check judges it]. The probe's hand map used exactly this table for one line [M: it rendered].
- **What it costs:** two small files and their fixtures; no dependency. **What it cannot fix:** the accent (§2.2).
- **Gate:** a Spanish word check (Whisper, `es`) on a reference line set, plus a listening round. Until both pass it is
  labelled experimental in the picker, in `sing.capabilities`, and in the provenance.

### 6.6 Fixture gates, like `EnglishSyllables`' ≥ 90% on 1,000 words

| Gate | Fixture [A: sources must be licence-clean; x2/x3 records each licence] | Bar [A] |
|---|---|---|
| Mandarin readings | 1,000 common characters, each in a short line, with hand-checked pinyin (single-character keys can come from Unicode's Unihan `kMandarin`, Unicode licence) | ≥ 95% exact syllable; 100% in the set after the tone fallback |
| Mandarin polyphones | 50 lines with characters read two ways (长, 行, 了, 的, 还, 得…) | ≥ 90% |
| Cantonese readings | the same 1,000 characters with jyutping (Unihan `kCantonese`) | ≥ 95%; 100% in the set after the fallback |
| Spanish syllables | 1,000 hand-syllabified words | ≥ 90% exact (the English bar) |
| Spanish phones | 100 words with hand-checked approximations | 100% of phones in the `en_` set; ≥ 95% match the key |
| CJK tokenizer | mixed lines (characters, punctuation, pinyin, English words) | exact (it is a rule, not an estimate) |

### 6.7 Copy when a language is not supported

| Where | Text |
|---|---|
| English clip, Chinese characters typed | "These look like Chinese characters. Set Language to Chinese (Mandarin) or Chinese (Cantonese), and I'll sing them." |
| English clip, other non-English letters ("café") | base §5.7 "Not English", VERBATIM: "I can only sing English words so far — '{word}' isn't one I can pronounce." Kept byte-identical on purpose (§9). It stays true for an English clip; the language picker is where other languages are offered |
| Chinese clip, a character with no sung form | "I don't know how to sing '{char}'. Try a different character, or type its pinyin with a tone number, like ni3." |
| Spanish chosen | "Spanish is experimental: I sing it with English sounds, so it will have an accent." |
| Engine too old for a language | "This language needs a newer singing engine. Update it from the Sing sheet." |

⚖️ **The one reply that changes for old input:** Chinese characters typed into an ENGLISH clip get the first row's sentence (code `lyricsScriptMismatch`) instead of base §5.7's "Not English" (code `lyricsNotEnglish`), once x3 lands. It is deliberate: the old sentence would send a Chinese typist away from a feature that exists. It is safe only because `clip.setLyrics` and `sing.render` have not shipped yet (base item e builds them, `ClipLyrics.swift:47` "nothing sets lyrics yet") [R]. If x3 lands AFTER they ship, this is a documented wire change in that item's report, with a test that pins both sentences.

### 6.8 Word check per language

`WhisperTranscriber.transcribe` already takes a language (base §4.6 passes "en") [R: base §4.6]. For Chinese the check
scores CHARACTERS, not words (Chinese has no spaces), through `WordErrorRate` with a per-character mode [A]; its bands
are set by x9's measurements, not copied from English.

### 6.9 Wire and MCP

| Verb | MCP tool | Change |
|---|---|---|
| `clip.setLyrics` (base row 12) | `clip_set_lyrics` | optional `language` (`"en"`, `"zh"`, `"yue"`, `"es"`); new refusals `lyricsLanguageUnsupported`, `lyricsScriptMismatch` (the §6.7 sentences). Without `language`, the reply is the base reply exactly |
| `clip.getLyrics` (base row 13) | `clip_get_lyrics` | the reply carries `language` ONLY when the clip has one |
| `sing.capabilities` (new; works with the engine down) | `sing_capabilities` | `{languages: [{code, name, status: "supported"\|"experimental", needsEngineUpdate}], expression: [...], maxParts}`, read from the installed scripts and `install.json` |

### 6.10 Tests and gates

The §6.6 fixtures; tokenizer tables for each script; `ClipLyrics.language` decode/encode (absent → nil, byte-identical
encode without it); the facade registry against the stub (the stub's `stub_phonemize` gains a language stand-in) and
against the real venv (`test_venv_g2p.py`'s pattern); the lazy-import test (an English request imports neither library:
`sys.modules` checked, positive-controlled by a Mandarin request that does). ⛔ **Plant:** route `"zh"` words through the
English phonemiser → the Mandarin fixture goes red (it would produce `en_` tokens or refuse).

---

## 7. The facade, version 2 (item p2-sing-x2; `control: "melody"` only in x10)

### 7.1 The rule

- `schema.validate` accepts `facadeVersion` 1 **or** 2 (today it requires exactly 1, `scripts/sing/singlib/schema.py:273-275`)
  [R].
- **A v1 body is today's body.** Every v2 key is unknown under v1 and refused exactly as today (`badRequest`, "Unknown key
  … Allowed: …", `schema.py:113-122`) [R], with one added sentence: "'{key}' needs facadeVersion 2."
- **Every v2 key is optional at every level**, and a v2 body that uses none of them validates to the SAME
  `PhraseRequest` as the v1 body (§9 P5).
- **The client sends `facadeVersion: 2` ONLY when the request carries a v2 key.** So the base §4.3 cache key, which hashes
  `facadeVersion`, is unchanged for every phrase that uses nothing new, and every phrase already in a user's cache stays
  a hit.

### 7.2 The new optional keys

| Where | Key | Meaning | Default (= today) |
|---|---|---|---|
| top level | `control` | `"score"` or `"melody"` (melody only after x10) | `"score"` |
| `phrase.words[j]` | `lang` | `"en"`, `"zh"`, `"yue"`, `"es"` | `"en"` |
| `phrase.notes[i]` | `vibrato` | `{rateHz 3-9, depthCents 0-150, onsetS 0-2}`; melody mode only (x10) | none |
| `voice` (own voice) | `prompt.f0` | `{fps: 50, hz: [ … ]}`, window-relative; melody mode only (x10) | none |

`PhraseRequest` gains `control = "score"`, `words[j].lang = "en"`, `notes[i].vibrato = None`, `voice.prompt_f0 = None`.

### 7.3 Why a v1 body stays byte-identical through `build_meta` and `model.infer`

1. `validate(v1)` builds the `PhraseRequest` it builds today; the new fields hold their defaults.
2. `SoulXBackend.render` calls `score.build_meta(req.notes, req.words, lead=…, trail=…, phonemize=…, phoneset=…)`
   (`engine.py:250-251`) [R]. With every word's `lang == "en"`, `_Phonemes.token` takes today's branch, `"en_" +
   "-".join(toks)` (`score.py:62`) [R], and no `f0` key is added (score mode). So the metadata dict is today's dict.
   **Pinned by bytes:** `test_score.py` already reproduces the spike's T1, T2 and T1T2 JSON byte for byte [R]; the gate
   runs unchanged.
3. `model.infer(…, auto_shift=False, pitch_shift=0, n_steps=req.n_steps, cfg=req.cfg, control=req.control,
   use_fp16=False)`: with `req.control == "score"` these are today's keyword values (`engine.py:257-258`) [R]. **Pinned by
   a spy** (§9 P3).
4. The reply gains `control` and `substitutions` ONLY for a v2 request (and `substitutions` only when non-empty), so a
   v1 reply has today's keys.
5. Measured: an `f0` key on a SCORE-mode target leaves the render bit-identical (A0 = A1) [M], so even a client bug that
   sent a curve in score mode could not change a default render. The facade still refuses `vibrato` in score mode, so
   such a bug is loud.

### 7.4 New refusals (v2 only; added to `refusals.py`'s table)

| HTTP | Code | When |
|---|---|---|
| 400 | `badRequest` | a v2 key under `facadeVersion: 1` (the sentence names the key) |
| 400 | `languageNotSupported` | a `lang` this facade does not know (names it) |
| 400 | `unknownPhone` (existing) | a Chinese syllable with no tone in the set; names the character |
| 400 | `vibratoNeedsMelody` | `vibrato` in score mode |
| 400 | `promptF0Missing` | melody mode with an own voice and no `prompt.f0` (§2.1 trap 2) |
| 400 | `f0TooShort` | an internally built curve shorter than the phrase's mel frames (a facade defect; never expected) |

### 7.5 `/health`

Today's keys stay, with `facadeVersion: 1` unchanged. ⚖️ **The provenance records the version the REQUEST used**
(`SungVocalProvenance.facadeVersion`, base §3.9): 1 for a v1-shaped request, 2 when a v2 key was sent; never `/health`'s
value, which would record 1 for a take rendered with v2 keys. One additive key:
`capabilities: {facadeVersions: [1, 2], controls: ["score"], languages: ["en", "zh", "yue"]}` (`"melody"` appears only
after x10, `"es"` only after its gate). The app reads `capabilities` to decide what the Sing sheet offers; an engine
whose scripts predate x2 has no `capabilities`, and the app then offers English only.

### 7.6 The stub

`stub_server.py` imports the same schema, refusals and converter (`stub_server.py:46-48`) [R], so it validates v2
exactly as the facade does. Its `stub_phonemize` (`:58-60`) gains a per-language stand-in (one dummy token per word of
any language). In melody mode (x10) it renders a sine that FOLLOWS the synthesised curve, so the app's expression gates
can measure a vibrato on stub output. Its v1 output for T1 is pinned by sha256 (§9 P6).

### 7.7 Tests (Python, `scripts/sing/tests/`)

`test_schema.py` gains the v2 table (each key's range and refusal; v2 keys under v1 refused, naming the key);
`test_score.py` gains the language branches and the tone fallback (with `table_phonemize`-style injected phonemisers, no
venv needed); `test_venv_g2p.py` gains the Mandarin and Cantonese registry against the real venv; and the §9 P-tests.

---

## 8. Enrichments, ranked, with the cut line

Value is value to a NOVICE (1-5), cost is build-and-gate cost (1-5); both are my judgement [A], and the user's taste
may reorder them. The ratio decides the order.

| Rank | Enrichment | Value | Cost | Value ÷ cost | Lands in |
|---|---|---|---|---|---|
| 1 | **"Ooh" / "Aah" / "Mm" without words** | 5 | 1 | 5.0 | x6 (text generator), x8 (UI) |
| 2 | **Word chips light up while the melody plays** | 3 | 1 | 3.0 | x8 |
| 3 | **"Write words for me" that fit the tune** (`ai.writeLyrics` + `fitClipId`) | 5 | 2 | 2.5 | x7, x8 |
| 4 | **Double-tracking** (a second take on a new seed, panned) | 4 | 2 | 2.0 | x6 |
| 5 | **"Sounds like" spelling** for names and odd words | 3 | 1.5 | 2.0 | x3 (tokenizer: the braces' content becomes `LyricWord.sung`; the facade needs no change) |
| 6 | **"Sing the chord's other notes"** (chord-tone harmony from the melody clip) | 3 | 1.5 | 2.0 | x4 |
| 7 | **Dynamics from note velocity** ("Follow note loudness", §5.4) | 2 | 1 | 2.0 | x5 |
| — | **CUT LINE** | | | | |
| 8 | A per-word listen button | 3 | 3 | 1.0 | filed |
| 9 | Translate my lyrics into another language, then sing them | 2 | 2 | 1.0 | filed |
| 10 | A choir / ensemble preset | 3 | 4 | 0.75 | filed; composes from 4 + harmonies later |
| 11 | Breath sounds between phrases | 2 | 3 | 0.67 | filed |

**Why the line sits there.** Everything above it costs at most 2 and reuses machinery this design already builds or the
tree already has (the text, the job, the pitch table, the provider). Everything below needs a NEW engine-facing concept:
a preview render that does not land (8), a second AI round trip whose output must then fit the notes (9), many renders
of few voices (10, with one built-in voice), or a new audio source the engine cannot make (11: `<AP>` becomes a rest,
`data_processor.py:45`) [R].

### 8.1 Rank 1: singing without words

- **UI:** under the words box, "No words? Sing: Ooh · Aah · Mm", and "one sound per line" / "one per note".
- **How:** a pure generator writes LYRIC TEXT, so the text stays the one truth and the user can edit the result: one
  line per breath phrase, the vowel word with `+` marks across the phrase ("ooh+++++"), or the word once per note.
- **The engine side:** a word on k notes becomes k entries carrying the word's phonemes (base §2.4), which is how a held
  vowel is already sung. "ooh" → `UW1`, "aah" → `AA1` through `g2p_en` [A: x2's venv test pins all three, and "mm" falls
  back to "hum" if its phones come out wrong]. Upstream's own English example sings "Ooh"
  (`upstream/example/audio/en_prompt.json`, text "Ooh Ooh …") [R].
- **Wire:** `clip.setLyrics` with the generated text, plus an optional `wordless: "ooh"|"aah"|"mm"` and
  `wordlessPerNote?` that generate it server-side (mutually exclusive with `text`; refused together).

### 8.2 Rank 2: chips that light up during playback

UI only. The Sing sheet's strip highlights the chip whose notes contain the playhead, at the UI's 30 Hz. The assignment is
derived once per text or note change, never per frame, so nothing new runs on the main actor at frame rate and nothing
touches the engine.

### 8.3 Rank 3: lyrics written to fit the tune

- **`ai.writeLyrics` gains optional `fitClipId` (and `language`).** The prompt carries, per breath phrase, its note
  count and length, and asks for ONE line per phrase with at most that many syllables (ideally exactly that many), no
  section tags (the ACE bracket tags are stripped if they appear).
- The reply is CHECKED, not trusted: the base assigner must accept it in line-per-phrase mode, and each line's syllable
  count must be at most its notes. One retry with the failing lines named; then the reply returns with
  `fit: {lines: [{phrase, notes, syllables, fits}], allFit}`.
- It does NOT store: the Sing sheet's "Write words for me" puts the text in the box; an agent calls `clip.setLyrics`.
- Without a provider key it fails with the existing actionable message (the `ai.writeLyrics` case comment) [R].

### 8.4 Rank 4: double-tracking

`sing.render` `parts: [{kind: "double"}]`: the lead's notes and words on seed `take seed + 7919` [A], landed as
"Vocals — double · {voice}" at pan +0.4 and −4 dB [A]. Measured basis: the same seed is a bit-identical copy (useless as
a double) and a different seed is a different performance [M, §2.4]. Listening round D picks the width and level.

### 8.5 Rank 5: "sounds like" spelling

`Siobhan{shi-vawn}`: the chip shows "Siobhan", the engine sings "shivawn", and hyphen parts inside the braces ask for
notes as usual. Today the tokenizer drops braces as punctuation and would sing "Siobhanshivawn"
(`LyricTokenizer.swift:311-315`) [R]. Nothing sets lyrics yet (`ClipLyrics.swift:47`) [R], so defining braces now changes
no stored text; **this syntax must be settled before base item e ships `clip.setLyrics`**, or deferred with a test that
pins today's brace behaviour.

### 8.6 Ranks 6-7

Covered in §4.2 (chord tones) and §5.4 (velocity).

### 8.7 Below the line, filed with what would move them up

- **Per-word listen:** moves up if the base design ever gains a non-landing preview (an "audition" job that plays a
  cached unit). Until then a click would cold-start a 6 GB engine.
- **Translate my lyrics:** moves up when rank 3 has shipped and a translation can reuse its fit check.
- **Choir preset:** moves up after x9 measures 4-part time and a second built-in voice exists.
- **Breath sounds:** moves up only with a licence-clean breath source; a synthetic noise burst is likely to sound fake
  [A].

---

## 9. The no-impact gate (concrete, named, with plants)

**The promise:** when none of the new things is used, every request, render, file and wire reply is byte-identical to
today's. Each test below is named, says what it pins, and has a plant that must turn it red. ⭐ **Pin-before:** every
golden value (JSON, sha256, signature) is recorded from a run on the tree BEFORE the item changes anything, and the item
report shows that run. A golden recorded after the change pins nothing.

### 9.1 Python (`scripts/sing/tests/test_v1_compat.py`, new; item x2)

| Test | Pins | Plant that must turn it red |
|---|---|---|
| **P1** `test_v1_bodies_validate_unchanged` | Every v1 body in the existing schema/HTTP tests validates to a `PhraseRequest` whose new fields hold their defaults (`control "score"`, every `lang "en"`, no `vibrato`, no `prompt_f0`) | default `control` = `"melody"` |
| **P2** the existing T1/T2/T1T2 byte gate (`test_score.py`) and every case in its `ALL` list | The metadata bytes | route `"en"` words through a changed token builder (e.g. drop the `en_` prefix) |
| **P3** `test_v1_infer_kwargs_spy` | A spy model records `infer`'s kwargs for a v1 body: exactly `auto_shift=False, pitch_shift=0, n_steps, cfg, control="score", use_fp16=False`, and the target metadata has no `f0` key; compared with a pin-before golden | pass `control=req.control` with a default of `"melody"` |
| **P4** `test_v2_key_under_v1_refused` | Each v2 key under `facadeVersion: 1` is `badRequest`, naming the key | accept v2 keys under v1 |
| **P5** `test_v2_defaults_equal_v1` | A v2 body using only defaults gives the same request fields, metadata bytes and infer kwargs as the v1 body | default `lang` = `"zh"` |
| **P6** `test_stub_v1_render_sha` | The stub's T1 render WAV, by sha256 (the stub is deterministic sines) | change the stub's amplitude |
| **P7** `test_health_superset` | `/health`'s existing keys and values unchanged; `capabilities` is the only new key | bump `facadeVersion` in `/health` to 2 |
| **P8** `test_lazy_imports` | An English request leaves `g2pM` and `ToJyutping` out of `sys.modules`; positive control: a Mandarin request loads them | import both at module load |
| **P9** `test_no_gpl_import` | No file under `scripts/sing/` imports `parselmouth`; positive control: the same scan finds `soxr` | add `import parselmouth` to a scratch copy |

### 9.2 Swift (items x1, x3, x4, x5, x6, x7)

| Test | Pins | Plant |
|---|---|---|
| **S1** `ClipLyricsPersistenceTests.languageAbsentIsByteIdentical` (appended to the existing suite) | `ClipLyrics` without `language` encodes to the pin-before JSON; an old clip decodes `language == nil` | always encode `language` (as `"en"`) |
| **S2** `ProjectDocumentFidelity` (extend the existing fixtures `Tests/DAWCoreTests/Fixtures/ProjectDocumentFidelity/*.json`) | Each fixture decodes with `singStyle == nil` and `lyrics?.language == nil` and re-encodes to its pin-before bytes | encode `singStyle: null` instead of omitting it |
| **S3** `SingPlannerTests.defaultSignatureUnchanged` | `SingPlan.signature` (`"sing-plan-v1\|…"`, `SingPlanner.swift:529`) [R] for the `Fixtures/Sing` clips equals its pin-before value; the language and style are appended ONLY when non-default | append the language unconditionally |
| **S4** `SingPlannerTests.defaultPlanUnchanged` | The whole default `SingPlan` (units, notes, words, offsets) equals the pin-before value | change the default lead |
| **S5** coordinator, default job (x6; appended to SE1's coordinator suite) | The facade request bodies are byte-equal to pin-before goldens with `facadeVersion: 1`; the cache keys are equal; the provenance records `facadeVersion` 1; landing makes ONE track in ONE undo, the clip has `pitchEdits == nil`, the track keeps `Track`'s init defaults for pan and volume, as today | (a) always send `facadeVersion: 2`; (b) always run the expression pass |
| **S6** wire and MCP (x7) | `sing.render`, `sing.jobStatus`, `clip.setLyrics`, `clip.getLyrics` without new params reply with the pin-before keys and values; npm: each tool's `required` list is unchanged and every new param is absent from it | add a new param to a `required` list |
| **S7** `EveryNewFieldIsOptional` (nonisolated, new file) | For EACH new `Codable` field (`ClipLyrics.language`, `Clip.singStyle` and every nested field, `SungVocalProvenance.style/partRole/harmony`, `SingWord.language`), a full JSON with that one key removed still decodes; the Python twin does the same for every v2 key | make one new field non-optional |
| **S8** real model, ONE process (x9) | A v1 body and a v2-defaults body render bit-identical audio (basis: the same seed in one process is bit-identical, max \|Δ\| = 0 [M, §2.4]) | send `control: "melody"` in the v2 body |

### 9.3 What the gate deliberately does NOT claim

- **Across processes**, renders are not known to be bit-identical (base §4.3's warning stands). S8 compares within one
  process; P6 uses the deterministic stub.
- **A user's existing phrase cache** stays valid because the request bytes and `facadeVersion` it hashes are unchanged
  (S5), not because a re-render would match.

---

## 10. Staged delivery: how the new items slot into base §9

**Base §9's standing constraints apply to every item** (staging 17695 only, never 17600; stop SoulX pid-exact after any
leg that loaded it; never start ACE; `./scripts/test.sh`; no checkout/stash/restore/clean; no commits without the user's
word; never touch audio devices, `.env`, `scripts/ace-step/`, `scripts/rvc/`). **Plus this tree's current round rules:**
no new `@MainActor` test suite (append MainActor tests to existing suites; new test files are nonisolated only); new
wire verbs, MCP tools and count pins wait for the orchestrator to release the wire count; `scripts/sing/singlib/*` and
`server.py` are frozen for the current round; `ClipLyrics.swift`, `SungVocal.swift` and `ProjectStore+SungVocal.swift`
belong to W8-SE1 until it reports.

| Id | Item | Route | Depends on | Gate | Can start before the base UI (f)? |
|---|---|---|---|---|---|
| **p2-sing-x1** | `LyricTextEdit` (per-note typing as text edits) | `swift-app-engineer` | — | §3.5, with the freeze plant | **yes** (pure DAWCore, new files) |
| **p2-sing-x2** | Facade v2: schema, the language registry (Mandarin, Cantonese) with the tone fallback, `capabilities`, stub parity, P1-P9; the CC-CEDICT licence check for `g2pM`'s data | `audio-dsp-engineer` (the facade's owner, base item b) | the round's `singlib` freeze lifting | §7.7, §9.1 | **yes** (Python only) |
| **p2-sing-x3** | Languages in the domain: `ClipLyrics.language` (+ `ClipDocument`), per-script tokenizer, `LyricWord`/`SingWord.language`, syllable counters, "sounds like" braces, the Swift fixtures of §6.6 | `swift-app-engineer` | W8-SE1 releasing `ClipLyrics.swift` | §6.10, S1, S3, S4, S7 | **yes** |
| **p2-sing-x4** | `HarmonyPlanner`, the `KeyProfileMatch` lift (DAWEngine forwards), per-part range, the chord-tone source | `swift-app-engineer`; the lift by `audio-dsp-engineer` | — | §4.8 | **yes** |
| **p2-sing-x5** | `Clip.singStyle` + the rebuild-site census, `SungExpressionPlanner`, `SungAirLayer`, `landSungVocal(pitchEdits:)`, `landSungVocals`, the provenance fields | `audio-dsp-engineer` (planner, air, physics); `swift-app-engineer` (model, census) | W8-SE1 releasing `SungVocal*.swift` | §5.7, S2, S7 | **yes** |
| **p2-sing-x6** | Coordinator: part jobs (harmony, chord tones, another clip, double), the expression pass and air at assembly, the wordless generator | `mcp-integration-engineer`; RT review by `daw-architect` | base e, x4, x5 | §4.8 coordinator, S5 | no (needs e) |
| **p2-sing-x7** | Wire + MCP: `clip.setNoteWord`, `clip.setSingStyle`, `clip.getSingStyle`, `sing.proposeHarmony`, `sing.capabilities`; the optional params on `sing.render`, `clip.setLyrics`, `ai.writeLyrics`; `sing.jobStatus.parts` | `mcp-integration-engineer` | base e's verbs, x1, x3-x6, the wire-count release | S6, per-verb tests, `doc-count-drift.mjs` | no |
| **p2-sing-x8** | UI: note-word field, playback highlight, Harmony card, Expression card, language picker, wordless, "Write words for me" | `swift-app-engineer` + `ui-design-engineer` | base f, x7 | `/dogfood` on staging with the stub; screenshots of every state; every string against §5.7 and §14 | no |
| **p2-sing-x9** | Real-model gates and listening rounds: S8; Mandarin word check (characters); Cantonese word check; Rounds V, VR, H1-H3, D, A; the Spanish check if pursued | `qa-test-engineer` + `audio-dsp-engineer` | base g, x8 | §9 S8; the word-check bars set from measurement; rounds published on the user's listening page | no |
| **p2-sing-x10** | The engine route (melody mode, curve synthesis, own-voice prompt curve) | `audio-dsp-engineer` | **Round VR picks it** | §5.5 | no |
| **p2-sing-x11** | Docs: the ARCHITECTURE decision (§15), AI-INTEGRATIONS languages, ROADMAP boxes, CHANGELOG, plugin regeneration **plus the hand-maintained agent allowlists** | `docs-scribe` | x9 | `doc-count-drift.mjs`; the allowlist diff checked against the artifact the user loads | no |

**Order of value:** x1 and x2 first (they unblock the most), then x3 (Mandarin needs it), x4, x5; then x6/x7 right after
base e, x8 right after base f.

### 10.1 Decisions that are the user's (listening rounds, later, never blocking)

Each round: 3-4 options on ONE axis, published on the user's listening page; **the pick is the feedback**. Defaults
marked [A] above ship until a pick replaces them.

| Round | The one axis | Options |
|---|---|---|
| **V** | Vibrato depth | Straight · 25 c · 45 c · 70 c, same take, same notes |
| **VR** | How the wobble is made | post-render vs sung by the engine (melody mode), same depth; a third option "as sung" as the anchor |
| **H1** | Harmony interval | third above · sixth below · third below · fifth above |
| **H2** | Harmony level | −2 · −4 · −6 · −9 dB, same interval |
| **H3** | The part's seed | the lead's seed · three other seeds |
| **D** | Double-track width | pan ±0.2 · ±0.4 · ±0.7 · ±1.0, same level |
| **A** | Air amount | none · a little · some · lots |

**Not a taste question, so not a round:** whether Mandarin or Cantonese is understandable. That is measured (the
character-level word check); the user is not asked to judge pronunciation in a language they may not speak.

**One possible question, only if a check finds it:** if the `g2pM` licence check (x2) finds a share-alike obligation in
its CC-CEDICT-derived data, the options go to the user (ship it with attribution, or use a different dictionary).

---

## 11. Where this departs from the base design, and why

| Base design | This design | Why |
|---|---|---|
| §10: languages other than English out of scope ("our G2P and UI are English only") | Mandarin, then Cantonese, are in; Spanish experimental | The G2P for both Chinese languages is already in the locked, installed venv [R][M]; coverage measured [M]; a Mandarin line rendered [M] |
| §10: harmonies and backing vocals out ("Chords sing their top note") | Harmonies as N monophonic parts in one job; chords still sing their top note in the lead | The reason was scope, not capability: the facade is monophonic by design and stays so |
| §10: per-note expression out ("Score mode has no velocity input") | Per-note vibrato, level and air as a POST-RENDER layer; the engine route held behind Round VR | **The base reason still holds** [R: `soulxsinger.py:179`]: the engine has no velocity, energy or breath input. This design works around it after the render; it does not claim the engine gained one |
| §10: melody-conditioned mode out | Melody mode with a SYNTHESISED curve designed (x10), built only if Round VR picks it; melody from an AUDIO recording stays out | The probe measured that melody mode follows a synthesised vibrato [M] |
| §10: MLX/quantised weights, SVC, live singing, more than one render at a time | unchanged | No reason changed |
| §2.4: the facade "always calls `infer(..., control="score", ...)`" | v1 requests always do; a v2 request may ask for `"melody"` (x10 only) | Opt-in, versioned, and pinned by P3/P5 |
| §2.4: request schema v1 only | `facadeVersion` 1 or 2; the client sends 2 only with a v2 key | Keeps every existing cache key and request byte-identical (§7.1) |
| §3.2: "Non-English words are refused up front" | Refused only when they do not match the clip's language; English clips keep base §5.7's sentence verbatim; CJK in an English clip gets a new sentence (one deliberate reply change, §6.7) | A Chinese clip must accept Chinese |
| §3.3: one syllable counter (`EnglishSyllables`) | One per language (`SyllableCounting`) | Chinese is one syllable per character, exactly |
| §3.1: only the text is stored | Kept for lyrics. NEW, separate: `Clip.singStyle` stores per-note style keyed by note id | A note's own style is a property of the note, not a relation that a text edit can invalidate; orphans are inert and reported (§5.3) |
| §4.5: one sung take = one track in one undo | A multi-part job lands N tracks in ONE undo (`landSungVocals`); a styled single take is still one track in one undo (`pitchEdits:` inside the same `performEdit`) | One user action, one undo |
| §4.6: word check in English | Per language; characters for Chinese | Chinese has no spaces |
| This lane's brief: `clip.applyBreathContour` / `clip.applyEffortShape` act on a landed vocal | They are MIDI-only [R]; the audio tools are the pitch-table verbs | Read in source (§2.3) |

---

## 12. Full Xcode, signing, entitlements, the render thread

- **None of these is needed.** No new entitlement, no AUv3, no signing change. Chinese input uses the Mac's own input
  methods. The new Python code ships inside `scripts/sing/` like the rest of the facade (base §12).
- **The render thread is untouched.** Expression planning, pitch detection and the air layer run offline in the job's
  detached task; harmony and double parts are ordinary audio tracks; the vibrato plays through the existing pitch
  renderer. **Nothing here allocates, locks or blocks on the render thread.**
- **DAWCore stays headless and dependency-free:** `LyricTextEdit`, `HarmonyPlanner`, `KeyProfileMatch` (moved, not new
  math), `SingStyle`, `SungExpressionPlanner`, `SungAirLayer` and the syllable counters are Foundation only (the air
  layer's filters are plain loops, no Accelerate).
- **DAWEngine** keeps hiding the audio stack; its one change is `KeyEstimator` forwarding to the lifted function.
- **One command surface:** every capability above has a wire verb or an optional param and an MCP tool (§3.4, §4.7, §5.6,
  §6.9, §8), and the UI calls the same store and coordinator methods (spy tests, base §6).

---

## 13. Verification ledger

### 13.1 Read first-hand for this design (2026-10-06)

- **The base design, whole**, including the 2026-10-05 errata; `docs/research/2026-09-24-lyrics-sung-on-a-melody.md` §2.3;
  `docs/research/2026-09-25-build-our-own-singing-voice.md` §3 and §5.
- **The facade:** `scripts/sing/server.py`; `singlib/schema.py`, `engine.py`, `score.py`, `phonemes.py`, `refusals.py`,
  `http.py`; `stub_server.py`; `run.sh`; `requirements.lock`; `tests/fixtures/spike/T1.json` and `T2.json`; the head of
  `tests/_util.py`.
- **The INSTALLED upstream** (`~/Library/Application Support/DAWPro/SingingEngine/upstream`, commit `81aeb3a…`):
  `soulxsinger/models/soulxsinger.py` (whole), `soulxsinger/utils/data_processor.py` (whole), `cli/inference.py` (whole),
  `preprocess/tools/g2p.py` (whole), `preprocess/tools/midi_parser.py:54-120`, `soulxsinger/config/soulxsinger.yaml`,
  `requirements.txt`, `preprocess/requirements.txt`, `example/infer.sh`, the README's control lines, the five
  `example/audio/*.json` metadata files, `phone_set.json`, and the technical report (`assets/technical-report.pdf`, through
  `pdftotext`: §2.1-2.2.3 and Table 2).
- **The installed venv's** `METADATA`/`LICENSE` for `g2pM`, `ToJyutping`, `pyworld`, `praat-parselmouth`, `g2p_en`;
  `install.json`; `voices/builtin-1/prompt.json`.
- **DAWCore:** `ClipLyrics.swift`, `LyricTokenizer.swift`, `LyricNoteAssigner.swift`, `SingPlanner.swift`, `SungVocal.swift`,
  `ProjectStore+SungVocal.swift`, `VoiceRangeFit.swift:1-140`, `NoteVibratoLimits.swift:1-80`,
  `ProjectStore+PitchNoteEdits.swift:290-370` and `:1255-1320`, `ChordVoicing.swift:40-110` and `:600-680`,
  `Model.swift:1420-1432` and `:745-756`, the head of `AudioAnalysis.swift`.
- **DAWEngine:** `Analysis/KeyEstimator.swift` (its signatures).
- **`Commands.swift` case labels:** `clip.setNoteVibrato`, `clip.setNoteVibratos`, `clip.setNoteGain`,
  `clip.findUnpitchedSounds`, `clip.applyBreathContour`, `clip.applyEffortShape`, `chord.voice`, `ai.writeLyrics`.
- **ROADMAP:** the p2-sing entries and the wave-8 launch line.

### 13.2 Measured by me in this session

Both probes ran the INSTALLED venv's python directly (`venv/bin/python -B`), with every cache redirected into the lane's
scratch folder, `NLTK_DATA` pointing at the runtime's `nltk_data` read-only, `PYTHONDONTWRITEBYTECODE=1`, offline flags
set, no sidecar and no port. Each ran under its own `locks-q.sh take-aux` slot, released after.

- **P-B (G2P coverage, CPU only):** 2.1 s; pid 94509 exited 0 and `ps -p` found nothing (positive control: `ps -p` of the
  lane's own shell found it). Results: §2.2's table.
- **P-A (11 renders, MPS):** pid 1945, 208.9 s in all, exited 0, gone (same proof). The model loaded through the facade's
  own `SoulXBackend.load()` in 40.5 s [under load]. The T1 metadata the probe built was checked byte-equal to the gate
  fixture `T1.json` before any render (a positive control that the probe sang the gate's melody). Results: §2.1's table
  and §2.4.
- **Pitch instruments:** `librosa.pyin` (2048-sample frames, 120-sample hop) and `pyworld.harvest` + `stonemask` (5 ms),
  both from the installed venv. Where they disagree, both are quoted (§2.1).
- **The runtime was left untouched:** a manifest of all 33,433 paths with size and mtime, taken before P-B and after P-A,
  compared identical (`cmp`; negative control: a copy with one line removed differs).
- **Facts read by measurement:** the upstream commit (`git rev-parse HEAD`); the built-in prompt's 519 f0 values
  (positive control: upstream's `zh_prompt.json`, also 519); no `__pycache__` under `upstream/` (positive control: the
  same `find` finds `upstream/cli`).
- **Not measured, and said so:** intelligibility in any mode or language (no recogniser in the venv); renders across two
  processes; any clean (unloaded) timing.

### 13.3 Derived

- Three parts cost 11-15 s of rendering per 10 s of song, unloaded: 3 × 10 s × RTF 0.38-0.51 (base §3.4's measured RTF).
- The velocity curve's values (64 → −3.9 dB).
- The pyin depth being lower than harvest's: an 85 ms analysis window against a 182 ms vibrato period (an explanation of
  a measured disagreement, not a measurement of the cause).

### 13.4 Assumed, and what replaces each

| [A] | Replaced by |
|---|---|
| Vibrato presets (5.5 Hz; 25/45/70 c; onset 0.25 s; notes ≥ 0.45 s) | Round V |
| Air levels (−24/−18/−12 dB), filter corners, the +3 dB physics bar | Round A; x5's physics gate |
| Harmony pan/level defaults; seed policy; part cap 3 | Rounds H2, H3, D; x9's measured 4-part time |
| Chord-snap window (3-9 semitones) and the chromatic-note rule | x4's tables and Round H1 |
| Segment-to-note mapping (≥ half overlap) | x5's planner tables on real takes (x9) |
| The Mandarin tone fallback ("most common tone of the syllable") | x9's character word check |
| Spanish phone table; its intelligibility | x9's Spanish word check and a listening round |
| Fixture bars (95% readings, 90% polyphones, 90% Spanish syllables) and their licence-clean sources | x2/x3, before first use |
| `g2pM`'s CC-CEDICT-derived data licence | x2's licence check |
| SwiftF0's curve as a melody-mode prompt (x10) | x10's gate |
| "mm" sung correctly through `g2p_en` | x2's venv test |
| Value and cost scores in §8 | the user's picks, as features ship |

### 13.5 Found in passing (reported, not changed)

- **An existing spike dependency:** `scripts/sing/tests/_util.py:35-36` defaults `SPIKE` to `~/DAWPro-spikes/sing-soulx`
  and `UPSTREAM` to the spike's checkout [R]. This is W8-SFIX's lane (re-homing every test input that lives in the spike).
- **During this lane's window, `scripts/sing` changed, but not through this lane:** `install.sh` (W8-SFIX's file) and the
  removal of `singlib/__pycache__/*.cpython-314.pyc` [M: two manifests of `scripts/sing`, 17:09:58 and 17:23:58]. The probes only
  imported `singlib`, with bytecode writing off.
- **Base §2.3's bundling claim was already filed as wrong** (ROADMAP, "FILED for p2-sing-h": `bundle.sh` does not copy
  `scripts/sing`) [R]. The new Python files of x2 inherit that open item.

---

## 14. The novice copy, in one place (adds to base §5.7; nothing there changes)

| Where | Text |
|---|---|
| Note field placeholder | "Word on this note" |
| Note field hint | "Type + to hold the word before onto this note." |
| Note not sung | "This note isn't sung: it is part of a chord, or no words reach this line yet." |
| Space in a note's word | "Type one word per note. To type several, use the words box." |
| No words yet | "Type the words in the box first; then you can change single notes." |
| Word could not be placed | "I couldn't place that word without moving others. Type the line in the box instead." |
| Harmony card | "Harmony" · [Add a harmony] |
| Harmony choices | "A third above (sweet, close)" · "A sixth below (warm, under the tune)" · "A third below" · "Sing my other melody…" · "Sing the chord's other notes" |
| Part fits | "Fits your voice." |
| Part moved | "I'll sing this part an octave lower." / "I'll sing this part an octave higher." |
| Part out of range | "This part goes lower than this voice usually sings. Try 'a third above' instead." / "This part goes higher than this voice usually sings. Try 'a sixth below' instead." |
| Key unknown | "I couldn't tell this song's key. Pick the key, and I'll work out the harmony." |
| Too many parts | "You can add up to 3 harmony parts." |
| Progress, parts | "Singing part {p} of {P} · line {i} of {n}…" |
| A part failed | "The part '{name}' didn't come out right. [Try again]" |
| Expression card, closed | "Style: as sung" |
| Vibrato | "Vibrato" · "As sung" · "Straight" · "Gentle" · "Normal" · "Wide" — help: "Vibrato is the gentle wobble singers put on long notes." |
| Air | "Air (breathiness)" · "None" … "Lots" — help: "Adds a soft breathy layer to the notes you choose." |
| Follow note loudness | "Follow note loudness" — "Quieter notes in your melody are sung quieter." |
| Notes selected | "{n} notes selected" |
| After a styled take | "You can fine-tune the wobble on any note in the pitch editor." |
| Language | "Language" · "English" · "Chinese (Mandarin)" · "Chinese (Cantonese)" · "Spanish (experimental)" |
| Language refusals | §6.7's table |
| Singing without words | "No words? Sing: Ooh · Aah · Mm" · "One sound per line" · "One per note" |
| Write words for me | "Write words for me" · "Writing words that fit your tune…" · "Some lines didn't fit the tune: {lines}. Edit them, or try again." |
| Double | "Double the vocal" — "Sings a second take and puts it to the side, for a fuller sound." |
| Sounds like | "To change how a word is sung, add how it sounds in braces, like Siobhan{shi-vawn}." |

---

## 15. Proposed "Key future decisions" line for `docs/ARCHITECTURE.md` (owed to item x11; not edited by this lane)

> **Singing expansion (settled by design 2026-10-06, `docs/design/2026-10-06-p2-sing-expansion.md`).** Expression on a
> sung vocal is a post-render layer: per-note vibrato and level go into the landed clip's pitch-edit table (one clamp,
> one undo with the landing) and breathiness is an offline air layer at assembly; the engine stays in score mode unless
> listening Round VR picks melody mode. Harmonies and doubles are N monophonic renders in one job, landed as N new tracks
> in one undo, each moving only by whole octaves. A clip's lyric language rides on `ClipLyrics.language` (absent =
> English); the facade phonemises per language (Mandarin `g2pM`, Cantonese `ToJyutping`, both already in the lock).
> Facade v2 keys are optional, and the client sends `facadeVersion: 2` only when it uses one, so every v1 request,
> cache key and render stays byte-identical.


## 16. Errata (orchestrator, from measurement and review)

- **§5.4, note times (W8-X5D, READ in source, 2026-10-06):** "unit offset + note start" puts every note 0.24 s EARLY,
  because `SingUnit.offsetSeconds` is where the unit's AUDIO starts, `leadSeconds` before its first onset. The one
  correct source is `SingTakeAssembly.noteWindows(plan)` (`SingJobAudio.swift`), zipped in order with `plan.notes`.
  W8-X6 wired it that way.
- **§5.7 bars (W8-X5D, MEASURED):** "Straight" leaves 14.0 c RMS of a ±40 c wobble at 110 Hz (bar 10; the
  natural-tuning G3 renderer limit, 09-27), and "a little" air adds +1.46 dB above 2 kHz on real SoulX spectra
  (bar +3). Both are held as known issues; listening rounds V and A decide. SwiftF0 cannot see a wobble under ~10 c,
  so physics gates use the validated tone tracker.
- **§4.4 rule 1, landing a DERIVED part (W8-RV6 review S2, READ; ruled by the orchestrator 2026-10-07 as an
  engineering default):** the landing check compared only the lead clip, so a harmony or chord-tone part could land
  over chords or a key that changed during the render, with no word. **Amended:** each derived part carries its
  planned notes, and landing re-derives it against the CURRENT tracks and key. On a mismatch the part STILL LANDS (the
  same policy as a changed melody today: land and say so), and the job adds a notice naming the part. The words are
  PROVISIONAL: "The chords changed while '{part}' was being sung, so it may not fit now. Sing it again to match."
  A different project still lands nothing, and a pure transposition still moves every part by the same Δ.
- **§4.4, cancel during landing (W8-RV6 S1, READ):** a cancel accepted after the last cancel check but before landing
  was silently ignored (the job landed, and `cancelRequested` stayed true). **Amended:** once landing starts, `cancel`
  refuses with `jobFinished` (a cancel is either honoured or refused, never ignored).
- **§4.5 / §14 "Part out of range" (W8-X9R MEASURED on the real engine, W8-X9F1 built, 2026-10-07):** the fixed suggestion (too high → "Try 'a sixth below'", too low → "Try 'a third above'") told a "sixth below" that moved up an octave to try a sixth below, and suggested parts that did not fit either. **Amended:** the suggestion is DERIVED. A line names another §4.1 choice only when that choice, planned from the same melody, key and chords, fits by the same rule (`HarmonyPlanner.fit`, one home). A moved part says it moved, and names the choice whose notes it now sings (exact pitches, not pitch classes: an unmoved sixth below shares pitch classes with a third above). If none fits, the line names the others and offers a different voice or moving the song's key. A part sung from another clip names nothing (the planner never sees the lead there). The §14 rows "Fits your voice." and "Part moved" stay VERBATIM; the new sentences are PROVISIONAL. ⚠️ OPEN: on the built-in voice (p10/p90 61.7/68.7) NO §4.1 choice fits the X9R fixture (best out-of-band 0.731 semitones against a 0.25 tolerance), although the real engine sang every one in interval on 19 of 19 notes, so the tolerance itself is the next question (p2-sing-x9-f3).
