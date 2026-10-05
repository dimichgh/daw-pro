# Deliverables

**Starlight, developed — five new pieces (the current question):**
https://claude.ai/artifact/WXnudxjUYGjMdHCmSXRRTD

Full-length audio for all five, level-matched to −19.5 LUFS within 0.1 LU, with
each piece's real filter curve and its measured per-section loudness and
brightness drawn beside it. One button per piece; the pick lands in
`decisions/developed`.

**Film + Starlight A–D (the previous round, answered):**
https://claude.ai/artifact/13jcBFG3u9V6nXHxVF92pk

> ⛔ **A CORRECTION I OWE YOU, AND IT IS MINE.** I said I was reading
> "~3+ min composition" as meaning the 5:13 long form was too long, and I built
> on that. **It was wrong.** Your own answers are recorded in that page's
> database: `decisions/starlight` = **"d"**, and `decisions/longform` = **"yes"**
> — *it earns its length*. So the long forms stand. The five new pieces are an
> **addition**, not a replacement.
>
> The lesson is bigger than the mistake: a handoff page exists to be *read back*,
> and I inferred from the phrasing of a chat message instead of reading the click
> that was already sitting in the database. Recorded answers outrank my reading
> of what someone meant.

## 0a. YouTube — the channel

All uploads are **private drafts**; the uploader (`publish.py`) creates nothing
else, so flipping them to public is your action and only yours.

✅ **Ten videos had wrong metadata; all were fixed on the channel, and there is
nothing for you to do about it.** Two separate mistakes:

- **Six descriptions** claimed bar counts no section has. I lengthened three
  arrival sections in the last round of form fixes (Summit 14→16, Aurora 18→24,
  Return 20→24) and did not carry the change into the prose. The music was
  right; the sentence describing it was not.
- **Seven Short titles said "· long"** — "· long" is part of the piece's own
  name for the long-form cuts, and the Short inherited it, so the title
  contradicted itself. The videos themselves were always correct.

(Three videos were on both lists, hence ten and not thirteen.) The repair sent
`snippet` only, so every one stayed exactly as private as it was — checked
afterwards rather than assumed, and all ten re-read from YouTube to confirm the
new text landed. **Five of those ten have since been deleted and replaced by the
looping Shorts below**, so only five of the repairs are still on the channel.

**I nearly asked you to fix these by hand, and that is the more useful
confession.** This page previously said the uploader could only create videos,
that editing one needed a wider Google permission than we hold, and that you
should therefore paste ten fields into Studio yourself. All of it was from
memory and none of it was true: the uploader asks for the full YouTube
permission and always has. Checking took one `grep`. I had written three
paragraphs of workaround instead — and had put a chore on your desk to cover a
capability I never verified I was missing.

**The five-minute pieces you asked for**, long and Short each:

| video | length | Studio |
|---|---|---|
| Starlight · Ascent · long | 5:05 | https://studio.youtube.com/video/bCP2W_Q00hU/edit |
| — its Short, **loops** | 0:31 | https://studio.youtube.com/video/e3koLxetBNc/edit |
| Starlight · Heartbeat · long ⚠ pulse | 5:05 | https://studio.youtube.com/video/pK3BlsYSE_8/edit |
| — its Short, **loops** | 0:31 | https://studio.youtube.com/video/pX7ZTtjAGmA/edit |
| Starlight · Aurora · long | 5:07 | https://studio.youtube.com/video/h25gfffa06s/edit |
| — its Short, **loops** | 0:27 | https://studio.youtube.com/video/X5YmQL8teJw/edit |
| Starlight · Signal · long ⚠ pulse | 5:05 | https://studio.youtube.com/video/EicNiaQ7WRM/edit |
| — its Short, **loops** | 0:30 | https://studio.youtube.com/video/VhbYM4XZwyg/edit |
| Starlight · Collapse · long | 5:05 | https://studio.youtube.com/video/3mfrOHImpSg/edit |
| — its Short, **loops** | 0:37 | https://studio.youtube.com/video/xgkhrsNFuJE/edit |

**The two long forms you had already heard**, which is what "5 mins versions"
literally named — uploaded first, before any of the new work existed:

| video | length | Studio |
|---|---|---|
| Starlight D · long | 5:05 | https://studio.youtube.com/video/I-34z1DN7FY/edit |
| — its Short | 0:38 | https://studio.youtube.com/video/lm3jHC_KJ64/edit |
| Starlight B · long | 5:05 | https://studio.youtube.com/video/ISlWKpj9DW0/edit |
| — its Short | 0:38 | https://studio.youtube.com/video/glavfVExuLM/edit |

**Earlier round:** the demo film `biNM1-bWcYQ`, Starlight A `RJJgnFF15dY`,
B `BLvVjl6nfBU`, C `pqK4vSo6hkM`, D `bkfuEgSypvg`, Machine Room `gFOXmJGlt4s`.

### ⭐ All 39 videos are on the channel

Nothing is left for you to drag in. Every piece of music made across this whole
run — the film, the DJ and classical variants, all four original Starlight
versions, both long forms, the five developed 3½-minute pieces and the five
new five-minute ones — is uploaded as a private draft, long and Short each.

⛔⛔ **THE "SIX UPLOADS A DAY" LIMIT WAS MY OWN BAD ARITHMETIC, AND IT SHAPED A
PLAN THAT WAS SIMPLY WRONG.** It came from dividing a 10,000-unit daily quota by
a widely-quoted ~1600 units per `videos.insert`. **Thirty-three uploads went
through in a single day with no quota error at all** — and that was discovered
only because one upload was attempted as a probe rather than predicted. The
advice I gave you earlier in this session — "two slots left today, drag the other
23 in by hand" — was never true, and I am sorry for the wasted planning.
⭐ **Probe a limit; do not derive it.** A `quotaExceeded` costs nothing but the
attempt, so the loop now tries and stops on the error instead of guessing.

⛔ **One upload was silently skipped and it was a loop bug, not a quota.** The
queue file was written without a trailing newline and `while read` discards a
final partial line, so 19 queued became 18 attempted — exit 0, every attempted
upload reporting "ok". It surfaced only by comparing the loop's own tally against
the input count. `mountain-king-short` was then uploaded on its own.

`publish/UPLOAD-LIST.md` carries every title and description in pasteable form
with all 39 marked uploaded, so nothing can be sent twice.

⚠ **TWO FILENAMES DIFFER BY ONE SUFFIX AND MEAN DIFFERENT CUTS.**
`cosmic-b-long` is the long visualiser of the 2:32 **Starlight B**;
`cosmic-b-long-long` is the long visualiser of the 5:05 **long form**. Both are
uploaded now, and they are different pieces of music. Same trap for `cosmic-d`.
The five-minute pieces built this round avoid it entirely: they are `*-5m`.

⚠ **`containsSyntheticMedia` IS SET PER VIDEO AND ON PURPOSE.** The demo film is
**true** — its narration is a cloned synthetic voice, which is exactly what that
disclosure exists for. The visualisers are **false**: they are instrumental
pieces played by software synthesizers, and YouTube's disclosure is for content
that realistically depicts people, places or events. Over-flagging would attach
an "altered content" label that misdescribes them. Flip it in the JSON if you
disagree — the decision is recorded here rather than buried.

## 0c. The Shorts that loop

A Short replays the moment it ends, so the join is the most-heard second in the
video. The five on the channel now are built to survive that.

**The biggest problem was not musical.** Every Short ended with 2.4 seconds of
digital silence — the outro card, measured at −inf dBFS, concatenated onto all of
them by house convention. They looped as music → nothing → music. I had measured
the audio window many times over and never once measured what was glued onto the
end of it.

**The musical problem.** The chords in this music cycle every 8 bars. A 36-second
window is 9.45 bars at 63 BPM, so it restarted on a different chord. Each loop is
now an exact 8 bars, found by searching every bar-aligned window in the piece and
scoring how well its ends agree — with a loudness floor first, because scoring
only on agreement picks the dullest passage in the piece (nothing happening is
the easiest thing to loop; the first run chose a −29.7 dB stretch of Aurora over
its climax). The reverb tail is carried across the join by a crossfade wrap
rather than cut off.

| Short | length | cut from | wrap vs wrong offset |
|---|---|---|---|
| Ascent | 30.5 s | Summit | 6.8× closer |
| Heartbeat | 30.5 s | Summit | 6.7× |
| Aurora | 26.7 s | Aurora | 8.4× |
| Signal | 29.1 s | Return | 8.3× |
| Collapse | 36.9 s | Rekindle | 1.8× — its harmony moves least |

⭐ **A loop does not start and end on the same chord, and it must not.** Eight
bars over an eight-bar cycle starts on chord N and ends on chord N−1. What has to
be true is that the chord *following* the end is the chord at the start. That is
the same statement as "a whole number of cycles" — and testing the thing I first
said out loud would have rejected every correct loop I had just built.

**The verification was wrong twice and said ✅ both times.** First it measured
spectral flux, which finds clicks — but a wrong chord arriving underneath a
two-second crossfade in music this slow produces almost no flux, and the planted
bad copy passed on all five pieces. Then broad-band spectra, still too blunt to
separate a wrong chord from an ordinary chord change; it passed on four of five.
Only pitch-class content separates properly. The planted control was the only
thing that ever caught any of this, so it now runs on every invocation instead of
once when the file was written.

## 0b. Do the five-minute pieces actually develop? — the measured answer

The worry with a five-minute ambient piece is that it is a three-minute piece
with longer sections: nothing arrives, it just continues. So the arrival is
measured rather than asserted. Gate ④ asks whether the section the form builds
toward is, in fact, *more* than anything before it — on either of the two axes a
listener actually notices, **loudness** or **treble**. Re-measured from the
shipped masters on 2026-09-21:

| Piece | Arrival section | vs loudest earlier | vs brightest earlier | Passes on |
|---|---|---|---|---|
| Ascent 5m | Summit (16 bars) | **+1.4 LU** | +0.4 dB | louder |
| Heartbeat 5m | Summit (16 bars) | **+1.4 LU** | +0.4 dB | louder |
| Aurora 5m | Aurora (24 bars) | +0.3 LU | **+2.1 dB** | brighter |
| Signal 5m | Return (24 bars) | +0.9 LU | **+2.5 dB** | brighter |
| Collapse 5m | — | — | — | inverted form, N/A |

**The two families pass on different axes, and that is the finding.** The
D-family pieces (Ascent, Heartbeat) arrive by getting *louder* — they add a sub
octave at the top, and their treble barely moves. The B-family pieces (Aurora,
Signal) have no sub at all, so they arrive by getting *brighter* while the
loudness stays nearly flat. Each family would **fail** a gate built only on the
other's axis, which is why the gate has two.

That is not a hypothetical. The first version of this gate measured loudness
only, and it **failed `cosmic-aurora` and `cosmic-signal`** — two pieces already
built, already approved, already shipped. The gate was wrong, not the music.
⭐ It was caught only by running the new gate against work already known to be
good; a gate validated solely on the thing it was written to reject will happily
encode the bias it was written with.

Collapse is exempt by construction: it starts at full power and falls, so its
peak is its first section. The gate detects that (peak not in the final third)
and says so rather than passing it silently — a gate that cannot fail a piece
should say which piece it is not judging.

Three form attempts were rejected getting here. The lesson that cost the most:
**loudness is set by how many layers are playing, not by where the filter is.**
Two sections sharing a layer set tie by construction no matter what the filter
does, so "open the filter further" never produced an arrival. The fix was to
give the arrival section a layer no earlier section has.

## 0. Starlight, developed — five pieces, ~3:30 each

Built by `develop.mjs`, measured by `section-arc.py`, levelled by
`master-cosmic.sh` then matched for the page by `page-audio.sh`.

| id | what changed | pulse |
|---|---|---|
| `cosmic-ascent` | **the headline** — D rebuilt as a real arc, 1 layer → 6 | no |
| `cosmic-collapse` | D **inverted**: opens at full power and falls, 52 BPM | no |
| `cosmic-heartbeat` | D **+ a low impulse** that doubles for the climb | ⚠ yes |
| `cosmic-aurora` | B with **new harmony** — 4 chords not 8, none with a third | no |
| `cosmic-signal` | B with the **shimmer tightened** until it articulates | ⚠ yes |

**On the pulse.** `cosmic.mjs` opens with a flat prohibition on any pulse at all,
written after you caught the first cosmic attempt being a space-disco. That rule
is **not withdrawn** — A–D stay beatless and so do three of these five. The
exception is scoped exactly as you scoped it: *"2 versions each, one with
pulse"*. Both pulsed pieces also **end** beatless, so the ending is still a wash.
The ruling is written into `cosmic.mjs`'s own header at the point of refusal, so
a future session cannot re-refuse work you asked for.

**What "developing" is actually made of** — two mechanisms, both measured:
1. **Layer gating.** Every section names its layers; a track is clipped only
   where it is named. `cosmic-ascent` opens on one synth and climaxes on six.
2. **An undulating sweep.** Each section travels across its own length carrying
   whole cycles of a ripple, so the filter is never still.

⭐ **And they deliberately disagree once.** In `Depths` the heaviest layers arrive
at the same moment the filter closes. Measured on `cosmic-ascent`: loudness
**+3.4 LU** while brightness falls **−12.8 dB**. Thicker and darker at once —
that is what "cosmic energies fluctuating" turned into, and a loudness meter
alone cannot see it.

⚠ **These start near silence on purpose — give each one twenty seconds.**
`cosmic-ascent`'s opening measures **18.0 LU below its own integrated level**.
For calibration, the `cosmic-d` you picked sits **15.5 LU** below its own, so
this is ~2.5 dB deeper than something you already accepted, not a new extreme.
I kept it because the deep opening *is* the brief; the visualiser's waveform is
there for when the audio alone is too quiet to judge.

Base: `/Users/dsemenov/Views/daw-pro/scripts/video/features`

Everything below is **in the repo**, not in a temp directory. It was built in a
session scratchpad and copied here on 2026-09-21, verified byte-for-byte (the
film's md5 is `9a56cf698a642bbb9a2985e3bf15aeeb` in both places). The pre-release
cut that used to sit in `out/` is kept beside it as
`out-superseded-2026-09-21-0057/` — **it is not the film**; it is two hours older,
it still contains the 118 BPM space-disco cosmic you rejected, and it is there
only so the two are never confused. All of it is gitignored.

## 1. The narrated film — `out/demo-film.mp4`
1920x1080, **5:07**, −17.2 LUFS, true peak **−1.3 dBFS**, no clipping. Ten
chapters: what's new → the drum machine → the kits you can hear → the effects →
**how one is built, start to finish** → the drop → what is honestly missing →
the three variants → close.

> **This film was verified by someone other than the thing that built it**, over
> five passes, and it was held back four times. The first pass found nine
> defects that every gate I had written passed clean — including a chapter whose
> picture showed a five-track arrangement rolling while the audio was three
> isolated kick drums and two stretches of digital silence.
>
> What survives that is worth stating plainly: every chapter's footage is
> distinct and moving; all eight effect cards are on screen when their name is
> spoken; every spoken number was re-measured against the file that shipped; and
> the picture and audio in all nine play beats agree to within **0.119 s**
> (mean 0.002 s — four early, five late).

**Every chapter now carries real motion.** Ten separate screen recordings, one
per chapter, each seeked to the part of the arrangement its audio was cut from —
so the playhead on screen is in the same bar as the music you are hearing. The
previous cut reused two clips across eight beats, which read as a video that had
frozen; that cannot happen now, because the assembler refuses a manifest in
which two chapters would build the same footage or the same audio.

Narrated in **the same cloned voice as every other film**, via
`demo-film/scripts/narrate.py`, and every line passed the transcribe-and-compare
content gate.

> I got this wrong first time round and shipped a cut narrated by the macOS
> `say` voice, after two shallow probes (`which omlx`, an `import`) both came
> back empty and I read that as "not installed". It was installed the whole
> time, models cached, and the working command was sitting in shell history.
> The launcher now lives in the skill itself
> (`demo-film/scripts/speech-server.sh`), and the trap is written into the
> skill, the agent and memory so the next session cannot repeat it.

## 2. Three musical variants — one axis apart
Same drum machine, same kit, same drum patterns, same effect chain, same
64-bar structure, same 128 BPM. **Only the melody differs**, so a preference
between them is real information.

All three rebuilt with the **supersaw lead you picked** (option A), and
re-measured afterwards — the lead change moved the brightness figure the film
speaks aloud from +33 dB to +30 dB, and the narration was re-recorded to match.

| | source | key | LUFS | dBTP | drop vs intro |
|---|---|---|---|---|---|
| Machine Room | original | A minor | −15.7 | −1.0 | +6.5 dB, +29.6 dB brighter |
| Mountain King | Grieg, 1875 | B minor | −15.6 | −1.0 | +6.6 dB, +30.3 dB brighter |
| Fate | Beethoven, 1808 | C minor | −15.5 | −1.0 | +6.7 dB, +29.8 dB brighter |

Both classical themes are public domain many times over and were traced from
the **LilyPond source text** Mutopia publishes beside its engravings — not read
off an image. Beethoven's continuation past the 4-bar motif is **ours, and the
film says so**; only the motif is his.

## 3. Eighteen visualiser videos — a long and a short for each of nine pieces
`out/<piece>/video/<piece>-long.mp4` — 1920x1080, full piece + intro and outro cards
`out/<piece>/video/<piece>-short.mp4` — 1080x1920 vertical, 36 s + 2.4 s outro card

Nine pieces: the three DJ variants, the four cosmic versions, and the two long
cosmic forms. The short **window is chosen per piece to contain its climax**,
not to start at a round number — the DJ variants take Build 2 into Drop 2, the
cosmic shorts end on the peak of Wide, and the long forms sit at 240 s so the
window ends on the arrival of the Rise rather than three quarters of the way up
it.

Branding follows the house convention I found in `scripts/video/shorts/`: a
Short carries an **outro and no intro** — it has to hook immediately — while the
narrated film gets both cards, like `lessons/` and `series/`.
Constant-Q spectrogram (note-aligned, C1–C7 ruler), stereo waveform, playhead,
progress bar, per-variant title and subtitle.

## 4. The audio
`out/<variant>/<variant>.wav` — 2:00 each, all three measured and asserted.
`out/cosmic-*/cosmic-*-master.wav` — the six Starlight renders. **Not as
level-matched as I first wrote here:** measured, they run −19.5 / −19.6 / −18.9 /
−18.0 LUFS for A / B / C / D. `master-cosmic.sh` aims every piece at −18.0 but
clamps the gain so true peak never passes −1.0 dBTP (`g = min(g, c - tp)`), and
for A and B the ceiling binds first. So **D really is ~1.5 LU louder than B**,
and on a straight A/B some of D's "power" is simply level. The excerpts on the
review page are re-normalised to a common loudness for exactly that reason.

---

## What I would want you to look at first
1. **`out/demo-film.mp4`** — it is the whole story, 5:07.
2. **The `kits` chapter** — three kick drums, one command apart. That is the
   single clearest demonstration of what the drum machine actually is.
3. **The four Starlight shorts** — A, B, C, D, captioned by letter and by what
   changes. ⚠️ They are **not** level-matched (−19.5 / −19.6 / −18.9 / −18.0),
   so D starts 1.5 LU ahead on volume alone. **D is the power version you asked
   for** — but judge it on the re-normalised excerpts if the choice is close.
4. **One long form** — `cosmic-d-long`, if you only play one. The Rise arrives
   at about 4:33.

Two questions I actually need answered: **which Starlight letter**, and **does
the long form earn its length**.

## Three things you should know
- **A gap in the app, found while filming and confirmed in source:** the
  automation lane editor can only draw **two** things. `AutomationParam`
  (`Sources/DAWAppKit/AutomationLaneModel.swift:11`) has exactly the cases
  `.volume` and `.pan`; `.sendLevel`, `.effectParam` and `.instrumentParam`
  return `nil`, with the source's own comment *"the lane editor does not draw
  it."* So the 64-bar filter sweep — the single most important gesture in the
  track — **cannot be shown on screen at all**. The lane displays as empty with
  only VOL and PAN chips. The film says the sweep is there and the render proves
  it is; the picture beside those words simply cannot show it. This is the one
  defect I could not fix, because no screenshot can.
- **A related one, separate:** an automation lane drives the RENDER correctly
  but does not move the knob on the effect card during playback. The card shows
  its authored value while the automation sweeps underneath.
- **Sub-bass:** Mountain King's bass sits near 62 Hz. On a phone speaker it will
  be weak or absent. Use headphones for that one.

Both automation items are app fixes, outside this goal, and would need a commit
— which needs your word.


---

## 5. The lead — RESOLVED: **A, the supersaw** (`out/leads/`)
The film's lead sounded like a toy because the patch used **8 of the synth's 24
parameters**: `unisonVoices` defaults to **1**, so it was a single clean
oscillator — no detune, no sub, no drift, no drive, no per-note jitter. No
effect downstream fixes a one-oscillator source.

Three candidates, same notes, same drums, same bass, same effects — **only the
lead patch changes.** 8 bars each, ~4 s in:

| | `out/leads/…` | what it is |
|---|---|---|
| A | `supersaw.wav` | 7 detuned saws, wide stereo, sub underneath — the sound most dance records actually use |
| B | `analog.wav` | 4 voices, heavy drift and jitter, darker filter, more drive — warmer, less aggressive |
| C | `resonant.wav` | `resonanceBoost` at a Q near 60 — the self-oscillating whistle you picked out of the effects demos |

✅ **You picked A.** The three DJ variants and the film are rebuilt with it. The
patch now lives in `leads.mjs` and `build.mjs` **imports** it, so the lead in the
film cannot drift from the one you actually heard.

> A near-miss worth recording: the obvious move was to import `LEADS` straight
> from `lead-options.mjs`. That file is a *script* — its top level opens the
> wire, runs `project.new` three times and writes three renders. An ES import
> **runs** the module, so every build would have silently destroyed the project
> and re-rendered three comparison files. Hence the separate data-only module.

## 6. "Starlight" — the cosmic piece, **rebuilt beatless** (`out/cosmic-{a,b,c,d}/`)

You named the reference: **А. Рыбников, «Свет звёзд»** (*Через тернии к звёздам*,
1981) — "smooth with variations", and *no beats at all*.

**I had built the opposite.** The first version was 118 BPM space-disco: kick on
every beat, offbeat bass, a driving 16th arpeggio. That is not a tweak away from
Rybnikov, so it was rewritten from scratch. The drums are gone — and so is the
**bass ostinato**, because offbeat eighths are a beat too, even when nothing is
hitting a drum. What survives is the two things you singled out, which belong
here better than they did in the disco:

- **the sweep** is now the *only* thing that builds — with no drums there is no
  rhythmic arc, so the piece opens and closes purely by timbre;
- **the whistle** is the melody: `resonance` 0.78 + `resonanceBoost` 0.62 with
  `keyToCutoff` 0.9, so the self-oscillating filter peak **tracks the tune**
  rather than whistling on one fixed pitch.

D minor, **63 BPM**, 40 bars, 2:32. One chord change roughly every four seconds.

### Four versions, one axis apart — **texture density**, then **power**

Same tempo, same harmony, same ten-note melody, same effects, same length.

| | what is moving underneath |
|---|---|
| **A** `cosmic-a` | Two sustained string layers and the voice. Nothing else. |
| **B** `cosmic-b` | + a slow shimmer: eighth notes so quiet and so long-released they read as light, not as a pattern. ← **you approved this one** |
| **C** `cosmic-c` | + a sustained low register. Whole notes only — nothing you could count. |
| **D** `cosmic-d` | **The power version.** Everything in C, plus a string layer an octave *down* — and the filter set to **resonance 0.0**. |

**D is built from the sample you pointed at.** You said "Butterworth — no peak at
all ... it has that power, like something is raising". That is not loudness: a
resonant filter sweeps a *peak* across the spectrum, so you hear a whistle
travelling. At resonance 0.0 there is no peak — the whole spectrum comes up
*together*, which is what reads as rising rather than as scanning.

Measured against B: **27.5 dB more energy below 200 Hz**, full-band RMS −20.9 vs
−33.2.

⚠️ **All four were *aimed* at −18 LUFS and only D got there.** The mastering
script clamps its gain so true peak never passes −1.0 dBTP, and for A and B that
ceiling binds first, leaving them at −19.5 and −19.6. The loudest file always
wins a blind comparison, so **1.5 LU of D's advantage is level, not content** —
which is precisely the thing I level-match to avoid, and this time did not.
The review page's excerpts are re-normalised to one loudness so the choice is
about character; play those if A/B/C/D is a close call.

### Long forms — `cosmic-b-long`, `cosmic-d-long`

**5:13 each** (80 bars against the short form's 40). The extra length is not the
same music repeated: it adds a *Drift*, a *Return*, and a 16-bar **Rise** where
the filter climbs all the way open across the whole section — the D long form
ends on the full Butterworth arrival at about 4:33.

**Tell me a letter, and whether the long form earns its length.**

> Two things I could not do and did not fake. The synth has **no glide and no
> vibrato** — I enumerated all 24 parameters rather than trusting a memory note
> saying glide had shipped (it had, on a different instrument). A vocalise
> slides, so the notes **overlap** instead, letting the release carry one pitch
> into the next. And the sweep sits on the **strings track**, not the mix bus:
> at high resonance the bus filter has a measured cliff at zero (−0.08 gave
> −41.5 LUFS against −31.9 at 0.0), which a mix with no drums cannot survive.
